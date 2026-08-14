<#
.SYNOPSIS
Invokes Claude Code headlessly against this vault's pending sources, in batches, or in
-LintReview mode for the scheduled report-only monthly review.

.DESCRIPTION
Critical safety rule carried over from the production incident history (Finding D/E in
the validation record): this script NEVER writes synthesis_status into manifest.csv
directly. Per-batch, it calls run-qa.ps1 itself (the sole authoritative reconciler) so
manifest-state comparison between batches is real, not stale - run-qa.ps1's own file is
not modified by this change and remains idempotent/safe to call more than once per run.

Batches of batch_size pending rows, up to batch_iterations calls. Each call runs under a
Start-Job/Wait-Job timeout (claude_call_timeout_seconds). Progress detection is primary
manifest-state comparison (did synthesis_status flip for at least one row this batch,
via run-qa.ps1's reconciliation); on zero progress, falls back to a regex match on the
captured claude -p output for a session/usage/rate-limit phrase. If neither signal fires,
stops safely (SYNTHESIS_ERROR) rather than looping or guessing.

continuity=true: on a detected limit hit, extracts a reset time from the same matched
output (ported from the proven standalone predecessor's Get-ResetSleepSeconds pattern),
sleeps until reset+buffer, and resumes the same batch. This only works if the same VM
process survives the full sleep; if it dies mid-sleep, nothing auto-resumes until the
next independently-scheduled systemd trigger - expected, not a bug, not solved here.

Also carries over the fix for stale-prompt selection: each batch's prompt file is fresh,
generated at the start of that batch's iteration.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [switch]$LintReview,
    [string]$BatchSizeOverride = '',
    [string]$BatchIterationsOverride = '',
    [string]$ContinuityOverride = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AgentRoot = Split-Path -Parent $PSScriptRoot   # .../agent
$configPath = Join-Path $VaultRoot 'config/vault.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$claudeMd = Join-Path $VaultRoot 'config/claude.md'
$promptsDir = Join-Path $VaultRoot 'config/prompts'
New-Item -ItemType Directory -Force -Path $promptsDir | Out-Null

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warning "claude CLI not found on PATH. Skipping synthesis (this is expected in a build/test sandbox)."
    return
}

if ($LintReview) {
    $lintPrompt = Join-Path $promptsDir "lint_review_$(Get-Date -Format 'yyyyMMdd').md"
    @"
# Scheduled lint-review

Follow the "Scheduled lint-review runs" section of config/claude.md exactly.
This is report-only: analyze the vault, write reports/lint_report_$(Get-Date -Format 'yyyy-MM-dd').md,
make no other changes.
"@ | Out-File -LiteralPath $lintPrompt -Encoding utf8

    Push-Location $VaultRoot
    try {
        & claude -p (Get-Content -LiteralPath $lintPrompt -Raw) --permission-mode acceptEdits
        if ($LASTEXITCODE -ne 0) { throw "claude CLI exited with code $LASTEXITCODE (lint-review)" }
    } finally { Pop-Location }
    return
}

$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'

# Resolution order: schedule.csv row override (per-run, optional) wins over config/vault.json
# (per-vault default). If genuinely absent from BOTH, batch_size/batch_iterations remain a
# hard throw - no silent default - since these are deliberately-tuned values, not something
# safe to guess.
$batchSizeSource = 'vault.json'
if ($BatchSizeOverride.Trim() -ne '') {
    $batchSize = [int]$BatchSizeOverride
    $batchSizeSource = 'schedule.csv'
} elseif ($config.PSObject.Properties['batch_size'] -and $config.batch_size) {
    $batchSize = [int]$config.batch_size
} else {
    throw "batch_size is required in schedule.csv override or config/vault.json (no silent default)"
}

$batchIterationsSource = 'vault.json'
if ($BatchIterationsOverride.Trim() -ne '') {
    $batchIterations = [int]$BatchIterationsOverride
    $batchIterationsSource = 'schedule.csv'
} elseif ($config.PSObject.Properties['batch_iterations'] -and $config.batch_iterations) {
    $batchIterations = [int]$config.batch_iterations
} else {
    throw "batch_iterations is required in schedule.csv override or config/vault.json (no silent default)"
}

# Set-StrictMode -Version Latest throws PropertyNotFoundException on a genuinely-absent
# JSON property (unlike a present-but-empty one) - confirmed the hard way in Stage 3
# testing (continuity is legitimately absent from every real vault.json today, since it
# defaults to false). Existence-checked via .PSObject.Properties first, matching the
# pattern already used elsewhere in this codebase (e.g. ingest-youtube.ps1's
# transcript_attempts backfill) rather than bare property access.
$continuitySource = 'vault.json'
if ($ContinuityOverride.Trim() -ne '') {
    $continuity = [bool]::Parse($ContinuityOverride)
    $continuitySource = 'schedule.csv'
} else {
    $continuity = if ($config.PSObject.Properties['continuity'] -and $config.continuity) { [bool]$config.continuity } else { $false }
}
$claudeTimeoutSeconds = if ($config.PSObject.Properties['claude_call_timeout_seconds'] -and $config.claude_call_timeout_seconds) { [int]$config.claude_call_timeout_seconds } else { 1800 }

# Ported from the proven standalone predecessor's Get-ResetSleepSeconds (confirmed
# real/working against actual CLI output earlier this session) - regexes the same
# captured text used for the limit-hit fallback match for an explicit reset time.
# DefaultSleepMinutes covers the case where a limit phrase matched (e.g. "session limit")
# but no parseable "resets HH(:MM)am/pm" clause was present in the captured text.
function Get-ResetSleepSeconds {
    param(
        [string]$ClaudeOutput,
        [int]$DefaultSleepMinutes = 60,
        [int]$BufferMinutes = 5
    )
    if ($ClaudeOutput -match "resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)") {
        $hour = [int]$Matches[1]
        $minute = 0
        if ($Matches[2]) { $minute = [int]$Matches[2] }
        $ampm = $Matches[3].ToLower()
        if ($ampm -eq "pm" -and $hour -lt 12) { $hour += 12 }
        if ($ampm -eq "am" -and $hour -eq 12) { $hour = 0 }
        $now = Get-Date
        $reset = Get-Date -Hour $hour -Minute $minute -Second 0
        if ($reset -le $now) { $reset = $reset.AddDays(1) }
        $wake = $reset.AddMinutes($BufferMinutes)
        $seconds = [int][Math]::Ceiling(($wake - $now).TotalSeconds)
        if ($seconds -lt 60) { $seconds = 60 }
        return $seconds
    }
    return ($DefaultSleepMinutes * 60)
}

function Get-IncludedCount {
    @(Import-Csv -LiteralPath $manifestPath | Where-Object { $_.synthesis_status -eq 'included' }).Count
}

$synthesisRunResultPath = Join-Path $VaultRoot 'working/temp/synthesis-run-result.json'
function Write-SynthesisRunResult {
    param(
        [string]$ReasonCode,
        [int]$BatchesCompleted = 0,
        [string]$ErrorSnippet = '',
        [string]$SleptUntil = ''
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $synthesisRunResultPath -Parent) | Out-Null
    [ordered]@{
        reasonCode            = $ReasonCode
        batchesCompleted      = $BatchesCompleted
        batchesPlanned        = $batchIterations
        targetThisRun         = ($batchSize * $batchIterations)
        batchSize             = $batchSize
        batchSizeSource       = $batchSizeSource
        batchIterations       = $batchIterations
        batchIterationsSource = $batchIterationsSource
        continuity            = $continuity
        continuitySource      = $continuitySource
        actualSynthesized     = $actualSynthesized
        errorSnippet          = $ErrorSnippet
        sleptUntil            = $SleptUntil
        timestamp             = (Get-Date).ToString('o')
    } | ConvertTo-Json | Out-File -LiteralPath $synthesisRunResultPath -Encoding utf8 -Force
}

if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Host "No manifest found; nothing to synthesize."; return }

$includedBefore = Get-IncludedCount
$actualSynthesized = 0
$batchesCompleted = 0
$reasonCode = $null
$errorSnippet = ''
$sleptUntil = ''

while ($batchesCompleted -lt $batchIterations) {
    $manifest = @(Import-Csv -LiteralPath $manifestPath)
    $pending = @($manifest | Where-Object { $_.ingest_status -eq 'ingested' -and $_.synthesis_status -eq 'pending' })
    if (-not $pending) { Write-Host "No sources pending synthesis."; break }

    $thisBatch = @($pending | Select-Object -First $batchSize)
    $includedBeforeBatch = Get-IncludedCount

    $batchId = "synthesis_batch_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $promptFile = Join-Path $promptsDir "$batchId.md"
    $sourceList = ($thisBatch | ForEach-Object { "- $($_.source_file) (video_id: $($_.video_id))" }) -join "`n"
    @"
# Synthesis batch: $batchId

Follow config/claude.md. Process these pending source pages:

$sourceList

When finished, write a JSON summary to working/temp/synthesis-result.json with this shape:

{
  "batch": "$batchId",
  "processed": ["<video_id>", ...],
  "pages_created": ["<path>", ...],
  "pages_updated": ["<path>", ...]
}

Do not edit working/manifest.csv. run-qa.ps1 will reconcile it from your result file.
"@ | Out-File -LiteralPath $promptFile -Encoding utf8

    Write-Host "Invoking Claude Code for batch $batchId ($($thisBatch.Count) sources)..."
    $promptText = Get-Content -LiteralPath $promptFile -Raw

    $job = Start-Job -ScriptBlock {
        param($vaultRoot, $promptText)
        # Confirmed empirically (Stage 3 prep, real Start-Job test on this VM): job
        # children fully inherit the parent process's $env:PATH, including the
        # ~/.local/bin fixup run-vault.ps1 applies for non-interactive invocations - no
        # re-fixup needed here.
        Set-Location -LiteralPath $vaultRoot
        $output = & claude -p $promptText --permission-mode acceptEdits 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList $VaultRoot, $promptText

    $completed = Wait-Job -Job $job -Timeout $claudeTimeoutSeconds
    if (-not $completed) {
        Write-Warning "Batch $batchId exceeded claude_call_timeout_seconds ($claudeTimeoutSeconds)s - stopping the job."
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $reasonCode = 'SYNTHESIS_TIMEOUT'
        break
    }
    $jobResult = Receive-Job -Job $job
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $outputText = ($jobResult.Output -join "`n")

    # The one stage permitted to write synthesis_status, called here explicitly (not just
    # at the end of run-vault.ps1's sequence) so this batch's real progress is visible
    # before deciding whether to continue, sleep-and-retry, or stop. Idempotent by its own
    # design; safe to call more than once per run-vault.ps1 pass.
    & (Join-Path $AgentRoot 'scripts/run-qa.ps1') -VaultRoot $VaultRoot

    $includedAfterBatch = Get-IncludedCount
    if ($includedAfterBatch -le $includedBeforeBatch) {
        if ($outputText -match 'session limit|usage limit|rate limit|resets\s+\d{1,2}') {
            $reasonCode = 'SYNTHESIS_LIMIT_HIT'
            if (-not $continuity) { break }
            $sleepSeconds = Get-ResetSleepSeconds -ClaudeOutput $outputText
            $sleptUntil = (Get-Date).AddSeconds($sleepSeconds).ToString('o')
            Write-Host "SYNTHESIS_LIMIT_HIT, continuity=true - sleeping $sleepSeconds seconds until $sleptUntil, then resuming."
            Start-Sleep -Seconds $sleepSeconds
            $reasonCode = $null   # cleared - this iteration is resuming, not a final stop
            continue              # does not increment $batchesCompleted; not a completed batch
        } else {
            $reasonCode = 'SYNTHESIS_ERROR'
            $errorSnippet = ($outputText -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
            break
        }
    }

    $batchesCompleted++
}

$actualSynthesized = (Get-IncludedCount) - $includedBefore
Write-SynthesisRunResult -ReasonCode $reasonCode -BatchesCompleted $batchesCompleted -ErrorSnippet $errorSnippet -SleptUntil $sleptUntil

Write-Host "Synthesis complete: reasonCode=$reasonCode, batches=$batchesCompleted/$batchIterations, actualSynthesized=$actualSynthesized. Manifest reconciliation happens per-batch via run-qa.ps1."
