<#
.SYNOPSIS
Invokes Claude Code headlessly against this vault's pending sources, in batches, or in
-LintReview mode for the scheduled report-only monthly review.

.DESCRIPTION
Critical safety rule carried over from the production incident history (Finding D/E in
the validation record): this script NEVER writes synthesis_status = included into
manifest.csv directly. Per-batch, it calls run-qa.ps1 itself (the sole authoritative
reconciler for the included transition) so manifest-state comparison between batches is
real, not stale - run-qa.ps1's own file is not modified by this change and remains
idempotent/safe to call more than once per run.

One narrow, deliberate exception to that rule was added following the 2026-08-24
SabrinaRamonov_Rev00 incident (18/20 silently reported as TARGET_MET): when a batch
comes back with fewer included rows than sources sent, this script marks the specific
dropped rows synthesis_status = 'partial' (never 'included' - that transition still
belongs to run-qa.ps1 alone). 'partial' is a distinct, durable "attempted but
incomplete" signal a future run/operator can tell apart from a row that was never
attempted at all ('pending'). It does not conflict with run-qa.ps1's Finding-D guard
(never downgrade an 'included' row) since a 'partial' row is, by construction, not yet
included; run-qa.ps1's disk-truth fallback can still promote it to 'included' later,
because that fallback's eligibility check is "not already included", not "must be
pending".

Batches of batch_size pending (or previously-partial) rows, up to batch_iterations
calls. Each call runs under a Start-Job/Wait-Job timeout (claude_call_timeout_seconds).
Progress detection is primary manifest-state comparison (did synthesis_status flip for
at least one row this batch, via run-qa.ps1's reconciliation); on zero progress, falls
back to a regex match on the captured claude -p output for a session/usage/rate-limit
phrase. If neither signal fires, stops safely (SYNTHESIS_ERROR) rather than looping or
guessing.

Full-batch completeness is checked separately from "did anything happen at all": each
batch's own input video_ids are diffed against which of them are actually 'included'
after run-qa.ps1 reconciles that batch. A batch that returns some-but-not-all of its
inputs as included is SYNTHESIS_PARTIAL, not treated as identical to a full success -
this is the exact gap the 2026-08-24 incident exposed (an 8-of-10 batch silently counted
as a completed iteration with no error, park, or timeout signal for the other 2).

continuity=true: on a detected limit hit, extracts a reset time from the same matched
output (ported from the proven standalone predecessor's Get-ResetSleepSeconds pattern),
sleeps until reset+buffer, and resumes the same batch. This only works if the same VM
process survives the full sleep; if it dies mid-sleep, nothing auto-resumes until the
next independently-scheduled systemd trigger - expected, not a bug, not solved here.
On resume, if this run has already had a partial batch, the reason code is NOT cleared
back to a clean $null the way a plain limit-hit recovery is - it propagates
SYNTHESIS_PARTIAL instead, so a later successful continuity resume can never mask an
earlier silent drop the way TARGET_MET masked the 2026-08-24 incident. When continuity
resumes (for any stop condition - limit hit, error, or a partial batch itself), the next
batch always prioritizes any still-not-included 'partial' rows from earlier in this run
ahead of fresh 'pending' rows, so stragglers get first crack at the retry rather than
being permanently skipped in favor of new work.

Also carries over the fix for stale-prompt selection: each batch's prompt file is fresh,
generated at the start of that batch's iteration.

.NOTES
Test-only hooks (never active unless the corresponding env var is explicitly set, so
production behavior is unchanged when unset):
  WIKIAGENT_MOCK_CLAUDE_SCRIPT   - path to a script/executable to invoke instead of the
                                   real `claude` CLI. Used by agent/tests' mock harness.
  WIKIAGENT_TEST_SLEEP_SECONDS   - overrides Get-ResetSleepSeconds's computed sleep, so
                                   continuity-retry tests don't block for real minutes.
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

# Test hook: WIKIAGENT_MOCK_CLAUDE_SCRIPT swaps in a stand-in for the real `claude` CLI.
# Resolved once, used everywhere below `claude` would otherwise be invoked, so a run with
# the env var unset is byte-for-byte the same code path as before this change.
$claudeCommand = if ($env:WIKIAGENT_MOCK_CLAUDE_SCRIPT) { $env:WIKIAGENT_MOCK_CLAUDE_SCRIPT } else { 'claude' }

if (-not (Get-Command $claudeCommand -ErrorAction SilentlyContinue)) {
    Write-Warning "$claudeCommand not found on PATH. Skipping synthesis (this is expected in a build/test sandbox)."
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
        & $claudeCommand -p (Get-Content -LiteralPath $lintPrompt -Raw) --permission-mode acceptEdits
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
    # Test hook - see .NOTES above. Lets continuity-retry tests run in real seconds
    # instead of blocking for up to an hour.
    if ($env:WIKIAGENT_TEST_SLEEP_SECONDS) { return [int]$env:WIKIAGENT_TEST_SLEEP_SECONDS }

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

# The one narrow exception to "this script never writes synthesis_status" (see top-of-file
# .DESCRIPTION). Only ever promotes a row to 'partial', never to/from 'included', and only
# for rows this run's own batch sent to Claude but that did not come back included. Uses
# the same read-modify-tmp-write-move pattern run-qa.ps1 uses for its own manifest writes,
# for the same crash-safety reason.
function Set-PartialStatus {
    param(
        [string]$ManifestPath,
        [string[]]$VideoIds
    )
    if (-not $VideoIds -or $VideoIds.Count -eq 0) { return }
    $rows = @(Import-Csv -LiteralPath $ManifestPath)
    $touched = $false
    foreach ($row in $rows) {
        if ($VideoIds -notcontains $row.video_id) { continue }
        # Finding D's rule (never downgrade 'included') applies here too - only promote a
        # still-not-included row to 'partial'; never touch a row run-qa.ps1 already
        # marked included between our read and this write (e.g. a shared-citation
        # disk-truth match on a later pass).
        if ($row.synthesis_status -eq 'included') { continue }
        $row.synthesis_status       = 'partial'
        $row.synthesis_last_checked = (Get-Date).ToString('yyyy-MM-dd')
        $row.last_updated           = (Get-Date).ToString('o')
        $touched = $true
    }
    if ($touched) {
        $tmp = "$ManifestPath.tmp"
        $rows | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $ManifestPath -Force
    }
}

$synthesisRunResultPath = Join-Path $VaultRoot 'working/temp/synthesis-run-result.json'
function Write-SynthesisRunResult {
    param(
        [string]$ReasonCode,
        [int]$BatchesCompleted = 0,
        [string]$ErrorSnippet = '',
        [string]$SleptUntil = '',
        [array]$DroppedSources = @()
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
        droppedSources        = $DroppedSources
        timestamp             = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $synthesisRunResultPath -Encoding utf8 -Force
}

if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Host "No manifest found; nothing to synthesize."; return }

$includedBefore = Get-IncludedCount
$actualSynthesized = 0
$batchesCompleted = 0
$reasonCode = $null
$errorSnippet = ''
$sleptUntil = ''
$hadPartialThisRun = $false
# Ordered dict keyed by video_id, holding only sources still un-recovered as of "right
# now" in this run - a later batch that successfully includes a straggler removes it
# here, so the final droppedSources reported to run-vault.ps1/Telegram reflects the
# run's real outcome (empty if continuity fully recovered every straggler), while the
# reasonCode itself stays SYNTHESIS_PARTIAL for the whole run regardless (see
# .DESCRIPTION) as a durable "this run needed recovery" signal.
$droppedSourcesThisRun = [ordered]@{}
$diagnosticsLogPath = Join-Path $VaultRoot 'working/temp/synthesis-partial-diagnostics.jsonl'

while ($batchesCompleted -lt $batchIterations) {
    $manifest = @(Import-Csv -LiteralPath $manifestPath)

    # Partial stragglers (from earlier in this run, or left over from a previous run)
    # always take priority over never-yet-attempted pending rows - see .DESCRIPTION.
    $partialRows = @($manifest | Where-Object { $_.ingest_status -eq 'ingested' -and $_.synthesis_status -eq 'partial' })
    $pendingRows = @($manifest | Where-Object { $_.ingest_status -eq 'ingested' -and $_.synthesis_status -eq 'pending' })
    $candidates  = @($partialRows + $pendingRows)
    if (-not $candidates) { Write-Host "No sources pending synthesis."; break }

    $thisBatch = @($candidates | Select-Object -First $batchSize)
    $thisBatchIds = @($thisBatch | ForEach-Object { $_.video_id })
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
        param($vaultRoot, $promptText, $claudeCmd)
        # Confirmed empirically (Stage 3 prep, real Start-Job test on this VM): job
        # children fully inherit the parent process's $env:PATH, including the
        # ~/.local/bin fixup run-vault.ps1 applies for non-interactive invocations - no
        # re-fixup needed here.
        Set-Location -LiteralPath $vaultRoot
        $output = & $claudeCmd -p $promptText --permission-mode acceptEdits 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList $VaultRoot, $promptText, $claudeCommand

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

    # The one stage permitted to write synthesis_status = included, called here explicitly
    # (not just at the end of run-vault.ps1's sequence) so this batch's real progress is
    # visible before deciding whether to continue, sleep-and-retry, or stop. Idempotent by
    # its own design; safe to call more than once per run-vault.ps1 pass.
    & (Join-Path $AgentRoot 'scripts/run-qa.ps1') -VaultRoot $VaultRoot

    $includedAfterBatch = Get-IncludedCount
    $manifestAfterBatch = @(Import-Csv -LiteralPath $manifestPath)
    $includedIdsAfterBatch = @($manifestAfterBatch | Where-Object { $_.synthesis_status -eq 'included' } | ForEach-Object { $_.video_id })
    $includedFromThisBatch = @($thisBatchIds | Where-Object { $includedIdsAfterBatch -contains $_ })
    $droppedIds = @($thisBatchIds | Where-Object { $includedIdsAfterBatch -notcontains $_ })

    # A straggler from an earlier batch THIS run that this batch actually recovered -
    # drop it from the run-level dropped-sources ledger (reasonCode itself still stays
    # SYNTHESIS_PARTIAL for the whole run - see .DESCRIPTION).
    foreach ($id in $includedFromThisBatch) {
        if ($droppedSourcesThisRun.Contains($id)) { $droppedSourcesThisRun.Remove($id) }
    }

    if ($includedAfterBatch -le $includedBeforeBatch) {
        # Zero progress at all this batch - existing limit/error detection, unchanged
        # except for the reason-code-clearing decision on a continuity resume below.
        if ($outputText -match 'session limit|usage limit|rate limit|resets\s+\d{1,2}') {
            $reasonCode = 'SYNTHESIS_LIMIT_HIT'
            if (-not $continuity) { break }
            $sleepSeconds = Get-ResetSleepSeconds -ClaudeOutput $outputText
            $sleptUntil = (Get-Date).AddSeconds($sleepSeconds).ToString('o')
            Write-Host "SYNTHESIS_LIMIT_HIT, continuity=true - sleeping $sleepSeconds seconds until $sleptUntil, then resuming."
            Start-Sleep -Seconds $sleepSeconds
            # Only clear back to a clean $null if nothing partial has happened yet this
            # run. Once a partial batch has occurred, SYNTHESIS_PARTIAL must survive a
            # later clean resume - this is the exact masking bug from the 2026-08-24
            # SabrinaRamonov_Rev00 incident: reasonCode was unconditionally nulled here,
            # so a successful continuity resume erased all trace of the earlier batch
            # that silently dropped 2 sources, and the run reported TARGET_MET.
            $reasonCode = if ($hadPartialThisRun) { 'SYNTHESIS_PARTIAL' } else { $null }
            continue              # does not increment $batchesCompleted; not a completed batch
        } else {
            $reasonCode = 'SYNTHESIS_ERROR'
            $errorSnippet = ($outputText -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
            break
        }
    }

    if ($droppedIds.Count -gt 0) {
        # Partial batch: some, but not all, of this batch's own inputs came back
        # included. Previously this was silently treated identically to a full success
        # (batchesCompleted++, no signal at all for the dropped rows) - this is the root
        # cause fixed here.
        $hadPartialThisRun = $true
        $reasonCode = 'SYNTHESIS_PARTIAL'
        Set-PartialStatus -ManifestPath $manifestPath -VideoIds $droppedIds

        foreach ($id in $droppedIds) {
            $row = $thisBatch | Where-Object { $_.video_id -eq $id } | Select-Object -First 1
            $diag = [ordered]@{
                timestamp            = (Get-Date).ToString('o')
                batchId              = $batchId
                videoId              = $id
                title                = $row.title
                sourceFile           = $row.source_file
                presentInBatchPrompt = $true
                promptFile           = $promptFile
                batchInputCount      = $thisBatch.Count
                batchIncludedCount   = $includedFromThisBatch.Count
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Path $diagnosticsLogPath -Parent) | Out-Null
            ($diag | ConvertTo-Json -Compress) | Add-Content -LiteralPath $diagnosticsLogPath -Encoding utf8
            Write-Warning "SYNTHESIS_PARTIAL: batch $batchId sent $($thisBatch.Count) source(s), only $($includedFromThisBatch.Count) came back included. Dropped: video_id=$id title='$($row.title)' source_file=$($row.source_file) (present in batch prompt: yes; no result returned for it). Diagnostic appended to $diagnosticsLogPath."

            if (-not $droppedSourcesThisRun.Contains($id)) {
                $droppedSourcesThisRun[$id] = [ordered]@{ videoId = $id; title = $row.title; sourceFile = $row.source_file; batchId = $batchId }
            }
        }
    }

    $batchesCompleted++
}

$actualSynthesized = (Get-IncludedCount) - $includedBefore
Write-SynthesisRunResult -ReasonCode $reasonCode -BatchesCompleted $batchesCompleted -ErrorSnippet $errorSnippet -SleptUntil $sleptUntil -DroppedSources @($droppedSourcesThisRun.Values)

Write-Host "Synthesis complete: reasonCode=$reasonCode, batches=$batchesCompleted/$batchIterations, actualSynthesized=$actualSynthesized, droppedThisRun=$($droppedSourcesThisRun.Count). Manifest reconciliation happens per-batch via run-qa.ps1."
