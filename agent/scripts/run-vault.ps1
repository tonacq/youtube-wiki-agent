<#
.SYNOPSIS
Runs the full WikiAgent pipeline for exactly one vault. This is the single entry point
the scheduler (or a human) calls; it never touches any vault other than -VaultRoot.

.DESCRIPTION
Stage order (matches the locked architecture spec, section 5):
  1. Acquire vault lock (fails fast if another run is already in progress for this vault)
  2. ingest-youtube.ps1      (unless -SkipYoutube)
  3. clean-transcripts.ps1   (unless -SkipClean; converts raw .vtt captions to clean text
                                and sets clean_status so create-source-pages.ps1 can act)
  4. ingest-documents.ps1    (unless -SkipDocuments)
  5. create-source-pages.ps1
  6. run-claude-synthesis.ps1 (unless -SkipClaude)
  7. run-qa.ps1              (deterministic reconciliation; always runs, even after a
                                partial/interrupted run above)
  8. backup-vault.ps1        (unless -SkipBackup)
  9. release lock, write run result

.EXAMPLE
pwsh agent/scripts/run-vault.ps1 -VaultRoot vaults/DWSIM -JobType full

.EXAMPLE
pwsh agent/scripts/run-vault.ps1 -VaultRoot vaults/DWSIM -JobType lint-review -ReportOnly
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [ValidateSet('full', 'lint-review')][string]$JobType = 'full',
    [switch]$ReportOnly,
    [switch]$SkipYoutube,
    [switch]$SkipClean,
    [switch]$SkipDocuments,
    [switch]$SkipClaude,
    [switch]$SkipBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Non-interactive invocations (ssh, cron) don't source ~/.bashrc, so ~/.local/bin
# (yt-dlp, claude) is missing from PATH unless we add it here explicitly.
$localBin = Join-Path $HOME '.local/bin'
if ($env:PATH -notlike "*$localBin*") {
    $env:PATH = "${localBin}:$env:PATH"
}

$VaultRoot = (Resolve-Path -LiteralPath $VaultRoot).Path
$AgentRoot = Split-Path -Parent $PSScriptRoot   # .../agent
$VaultName = Split-Path -Leaf $VaultRoot

# --- Locking -----------------------------------------------------------------
# Locks are agent-owned but vault-scoped, so two different vaults can run concurrently
# while the same vault can never overlap itself. Stale locks (owner process no longer
# running) are detected and cleared rather than left to block forever.
$lockDir = Join-Path $AgentRoot 'scheduling/locks'
New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
$lockFile = Join-Path $lockDir "$VaultName.lock"

function Test-StaleLock($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $pid_recorded = [int](Get-Content -LiteralPath $path -Raw)
        return -not (Get-Process -Id $pid_recorded -ErrorAction SilentlyContinue)
    } catch { return $true }  # unreadable lock file counts as stale
}

if (Test-Path -LiteralPath $lockFile) {
    if (Test-StaleLock $lockFile) {
        Write-Warning "Clearing stale lock for vault '$VaultName'."
        Remove-Item -LiteralPath $lockFile -Force
    } else {
        & (Join-Path $AgentRoot 'scripts/send-notification.ps1') -VaultRoot $VaultRoot -Event Blocked
        throw "Vault '$VaultName' already has a run in progress (lock: $lockFile). Aborting."
    }
}
$PID | Out-File -LiteralPath $lockFile -Encoding ascii -Force

$runStart = Get-Date
$stageResults = [ordered]@{}

# Stages whose failure is cosmetic/recoverable (e.g. the known first-run sync-vault
# pull-clobber-protection refusal) and must not be reported as a pipeline Failure -
# real content work can still have succeeded even if one of these trips.
$softStageNames = @('sync-vault (pull)', 'sync-vault (push)', 'backup-vault')

function Invoke-Stage($name, $scriptPath, $extraArgs) {
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        $stageResults[$name] = 'SKIPPED (script not present)'
        return
    }
    Write-Host "=== Stage: $name ==="
    try {
        & $scriptPath -VaultRoot $VaultRoot @extraArgs
        $stageResults[$name] = 'OK'
    } catch {
        $stageResults[$name] = "FAILED: $($_.Exception.Message)"
        Write-Warning "Stage '$name' failed: $($_.Exception.Message)"
        # Do not rethrow: QA must still run so partial progress is reconciled safely.
    }
}

try {
    # Pull-before-run, per the proven VM pattern (Drive is canonical, vault dir is a working copy).
    Invoke-Stage 'sync-vault (pull)' (Join-Path $AgentRoot 'scripts/sync-vault.ps1') @{ Direction = 'Pull' }

    if ($JobType -eq 'lint-review') {
        # Monthly cadence with no schedule.csv schema change: schedule.csv still only
        # expresses day_of_week + time_utc (weekly), so the dispatcher fires this row
        # every week same as a 'full' row - this check is what actually makes it
        # monthly. It only proceeds on the LAST occurrence of today's weekday in the
        # current calendar month (equivalently: today + 7 days rolls into next month).
        # Gap between runs is therefore always 4 or 5 weeks, never 3 - every month has
        # at least 4 full weeks, longer months stretch it to 5 - expected, not a bug.
        # Uses the same UTC clock the dispatcher itself matches day/hour against.
        $today = (Get-Date).ToUniversalTime().Date
        $isLastOccurrenceThisMonth = $today.AddDays(7).Month -ne $today.Month

        $lastDayOfMonth = Get-Date -Year $today.Year -Month $today.Month -Day ([DateTime]::DaysInMonth($today.Year, $today.Month)) -Hour 0 -Minute 0 -Second 0
        $daysBackToLastOccurrence = ([int]$lastDayOfMonth.DayOfWeek - [int]$today.DayOfWeek + 7) % 7
        $lastOccurrenceDate = $lastDayOfMonth.AddDays(-$daysBackToLastOccurrence)

        if ($isLastOccurrenceThisMonth) {
            Write-Host "lint-review for ${VaultName}: today ($($today.ToString('ddd yyyy-MM-dd'))) IS the last $($today.DayOfWeek) of $($today.ToString('MMMM')) - running."

            # Report-only vault-wide analysis. No ingestion, no synthesis writes beyond
            # the lint report itself. See vault-local config/claude.md for the exact
            # contract.
            Invoke-Stage 'run-claude-synthesis (lint-review)' (Join-Path $AgentRoot 'scripts/run-claude-synthesis.ps1') @{ LintReview = $true }
            if (-not $ReportOnly) {
                # Push-after-run: the lint report is real vault content and needs to
                # reach Drive like any other output - previously this branch never
                # pushed at all, so a scheduled lint-review's report sat on the VM and
                # never synced.
                Invoke-Stage 'sync-vault (push)' (Join-Path $AgentRoot 'scripts/sync-vault.ps1') @{ Direction = 'Push' }
            }
        } else {
            Write-Host "lint-review for ${VaultName}: today ($($today.ToString('ddd yyyy-MM-dd'))) is NOT the last $($today.DayOfWeek) of $($today.ToString('MMMM')) (that's the $($lastOccurrenceDate.Day)) - skipping until then."
        }
    } else {
        if (-not $SkipYoutube)   { Invoke-Stage 'ingest-youtube'       (Join-Path $AgentRoot 'scripts/ingest-youtube.ps1')       @() }
        if (-not $SkipClean)     { Invoke-Stage 'clean-transcripts'    (Join-Path $AgentRoot 'scripts/clean-transcripts.ps1')    @() }
        if (-not $SkipDocuments) { Invoke-Stage 'ingest-documents'     (Join-Path $AgentRoot 'scripts/ingest-documents.ps1')     @() }
        Invoke-Stage 'create-source-pages' (Join-Path $AgentRoot 'scripts/create-source-pages.ps1') @()

        if (-not $SkipClaude -and -not $ReportOnly) {
            Invoke-Stage 'run-claude-synthesis' (Join-Path $AgentRoot 'scripts/run-claude-synthesis.ps1') @()
        }

        # QA always runs, even if an earlier stage failed or Claude was interrupted.
        # It is the only stage permitted to update synthesis_status in the manifest, and
        # it must never downgrade an 'included' row back to 'pending' on re-run.
        Invoke-Stage 'run-qa' (Join-Path $AgentRoot 'scripts/run-qa.ps1') @()

        if (-not $SkipBackup -and -not $ReportOnly) {
            Invoke-Stage 'backup-vault' (Join-Path $AgentRoot 'scripts/backup-vault.ps1') @()
        }
        if (-not $ReportOnly) {
            # Push-after-run: only successful runs get pushed back to the canonical Drive copy.
            Invoke-Stage 'sync-vault (push)' (Join-Path $AgentRoot 'scripts/sync-vault.ps1') @{ Direction = 'Push' }
        }
    }
} finally {
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

$runEnd = Get-Date
$result = [ordered]@{
    vault      = $VaultName
    jobType    = $JobType
    startedUtc = $runStart.ToUniversalTime().ToString('o')
    endedUtc   = $runEnd.ToUniversalTime().ToString('o')
    stages     = $stageResults
}

$logsDir = Join-Path $VaultRoot 'logs'
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$resultFile = Join-Path $logsDir "run_$($runStart.ToString('yyyyMMdd_HHmmss')).json"
$result | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $resultFile -Encoding utf8

# Read run-qa.ps1's structured result (if it ran this pass) to tell a real-work Success
# apart from a nothing-to-do NoChange - both look identical from stage OK/FAILED status
# alone. Missing/unreadable file (e.g. lint-review job, which never invokes run-qa.ps1)
# defaults to 0, i.e. NoChange, rather than risking a stale count from an earlier run.
$qaResultPath = Join-Path $VaultRoot 'working/temp/qa-result.json'
$qaRowsChanged = 0
if (Test-Path -LiteralPath $qaResultPath) {
    try {
        $qaRowsChanged = [int](Get-Content -LiteralPath $qaResultPath -Raw | ConvertFrom-Json).rowsChanged
    } catch {
        Write-Warning "Could not parse qa-result.json for change detection: $($_.Exception.Message)"
    }
}

# Read ingest-youtube.ps1's structured result (if it ran this pass) so notifications can
# report accurate this-run ingestion stats without re-deriving them. Missing/unreadable
# file (e.g. -SkipYoutube, or a vault with no channel_url) defaults to zeros/nulls.
$ingestResultPath = Join-Path $VaultRoot 'working/temp/ingest-result.json'
$ingestResult = [ordered]@{ scanned = 0; newIngested = 0; retried = 0; parkedThisRun = 0; skippedAlreadyParked = 0 }
$ingestReasonCode = $null
$catalogueCount = 0
if (Test-Path -LiteralPath $ingestResultPath) {
    try {
        $parsed = Get-Content -LiteralPath $ingestResultPath -Raw | ConvertFrom-Json
        foreach ($key in @('scanned', 'newIngested', 'retried', 'parkedThisRun', 'skippedAlreadyParked')) {
            if ($parsed.PSObject.Properties[$key]) { $ingestResult[$key] = [int]$parsed.$key }
        }
        if ($parsed.PSObject.Properties['reasonCode']) { $ingestReasonCode = [string]$parsed.reasonCode }
        if ($parsed.PSObject.Properties['catalogueCount']) { $catalogueCount = [int]$parsed.catalogueCount }
    } catch {
        Write-Warning "Could not parse ingest-result.json for stats: $($_.Exception.Message)"
    }
}

# Read run-claude-synthesis.ps1's structured batching result (if it ran this pass).
# Missing/unreadable file (e.g. -SkipClaude, or nothing was pending) defaults to null/zeros.
$synthResultPath = Join-Path $VaultRoot 'working/temp/synthesis-run-result.json'
$synthReasonCode = $null
$synthActualSynthesized = 0
$synthTargetThisRun = 0
$synthErrorSnippet = ''
if (Test-Path -LiteralPath $synthResultPath) {
    try {
        $parsedSynth = Get-Content -LiteralPath $synthResultPath -Raw | ConvertFrom-Json
        if ($parsedSynth.PSObject.Properties['reasonCode'] -and $parsedSynth.reasonCode) { $synthReasonCode = [string]$parsedSynth.reasonCode }
        if ($parsedSynth.PSObject.Properties['actualSynthesized']) { $synthActualSynthesized = [int]$parsedSynth.actualSynthesized }
        if ($parsedSynth.PSObject.Properties['targetThisRun']) { $synthTargetThisRun = [int]$parsedSynth.targetThisRun }
        if ($parsedSynth.PSObject.Properties['errorSnippet']) { $synthErrorSnippet = [string]$parsedSynth.errorSnippet }
    } catch {
        Write-Warning "Could not parse synthesis-run-result.json for stats: $($_.Exception.Message)"
    }
}

# Manifest snapshot: totals across the vault as it stands at the end of this run, so
# notifications carry real counts rather than just this-run deltas.
$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'
$manifestTotal = 0
$manifestIncluded = 0
$manifestPending = 0
$manifestParked = 0
$manifestTransientFailed = 0
$manifestBacklog = 0
$manifestFailedBlocked = 0
$manifestMissingTranscript = 0
$manifestFailedOther = 0
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $manifestRows = @(Import-Csv -LiteralPath $manifestPath)
        $manifestTotal = $manifestRows.Count
        $manifestIncluded = @($manifestRows | Where-Object { $_.synthesis_status -eq 'included' }).Count
        $manifestPending = @($manifestRows | Where-Object { $_.synthesis_status -eq 'pending' -and $_.transcript_status -ne 'parked' }).Count
        $manifestParked = @($manifestRows | Where-Object { $_.transcript_status -eq 'parked' }).Count
        $manifestTransientFailed = @($manifestRows | Where-Object { $_.transcript_status -like 'missing*' -or $_.transcript_status -like 'failed*' }).Count
        # Backlog measured NOW (post-run), distinct from ingest-youtube.ps1's own
        # "carryover" figure, which is the same quantity measured BEFORE this run - used
        # only for this run's ingestion-target math, not for this stats snapshot.
        $manifestBacklog = @($manifestRows | Where-Object { $_.ingest_status -eq 'ingested' -and $_.synthesis_status -eq 'pending' }).Count
        # transcript_status ∈ {failed_blocked, failed, missing_transcript} implies
        # transcript_attempts < max (confirmed via code: reaching the cap always
        # overwrites status to 'parked') - no separate attempts filter needed here.
        $manifestFailedBlocked = @($manifestRows | Where-Object { $_.transcript_status -eq 'failed_blocked' }).Count
        $manifestMissingTranscript = @($manifestRows | Where-Object { $_.transcript_status -eq 'missing_transcript' }).Count
        $manifestFailedOther = @($manifestRows | Where-Object { $_.transcript_status -eq 'failed' }).Count
    } catch {
        Write-Warning "Could not parse manifest.csv for stats snapshot: $($_.Exception.Message)"
    }
}

$statsObject = [ordered]@{
    ingestScanned        = $ingestResult.scanned
    ingestNew            = $ingestResult.newIngested
    ingestRetried        = $ingestResult.retried
    ingestParkedThisRun  = $ingestResult.parkedThisRun
    ingestSkippedParked  = $ingestResult.skippedAlreadyParked
    manifestTotal        = $manifestTotal
    manifestIncluded     = $manifestIncluded
    manifestPending      = $manifestPending
    manifestParked       = $manifestParked
    manifestTransientFailed = $manifestTransientFailed
    qaRowsChanged        = $qaRowsChanged
}
$statsJson = $statsObject | ConvertTo-Json -Compress

$failedStageNames = @($stageResults.Keys | Where-Object { $stageResults[$_] -like 'FAILED*' })
$criticalFailed = @($failedStageNames | Where-Object { $softStageNames -notcontains $_ })
$softFailed     = @($failedStageNames | Where-Object { $softStageNames -contains $_ })

# ingest-youtube/run-claude-synthesis are excluded here even if Invoke-Stage marked them
# FAILED (e.g. INGEST_BLOCKED/INGEST_ERROR threw after writing a real reason code) -
# those are now reported via the richer RunSummary message below, not the older generic
# Failed event, for JobType=full runs specifically.
$criticalFailedOutsideReasonCoded = @($criticalFailed | Where-Object { $_ -ne 'ingest-youtube' -and $_ -ne 'run-claude-synthesis' })

if ($JobType -eq 'lint-review') {
    # Unchanged from before this brief - lint-review has no reason-code/batching concept.
    if ($criticalFailed.Count -gt 0) {
        $detail = "Critical stage(s) failed: $($criticalFailed -join ', ')"
        & (Join-Path $AgentRoot 'scripts/send-notification.ps1') -VaultRoot $VaultRoot -Event Failed -ExitCode '1' -LogFile $resultFile -Detail $detail -Stats $statsJson
        Write-Host "PIPELINE_RESULT: PARTIAL_FAILURE ($VaultName)"
        exit 1
    } elseif ($softFailed.Count -gt 0) {
        $detail = "Non-critical stage(s) had an issue (real content work still succeeded): $($softFailed -join ', ')"
        & (Join-Path $AgentRoot 'scripts/send-notification.ps1') -VaultRoot $VaultRoot -Event PartialSuccess -LogFile $resultFile -Detail $detail -Stats $statsJson
        Write-Host "PIPELINE_RESULT: PARTIAL_SUCCESS ($VaultName)"
        exit 0
    } elseif ($qaRowsChanged -gt 0) {
        & (Join-Path $AgentRoot 'scripts/send-notification.ps1') -VaultRoot $VaultRoot -Event Success -LogFile $resultFile -Stats $statsJson
        Write-Host "PIPELINE_RESULT: SUCCESS ($VaultName)"
        exit 0
    } else {
        & (Join-Path $AgentRoot 'scripts/send-notification.ps1') -VaultRoot $VaultRoot -Event NoChange -LogFile $resultFile -Stats $statsJson
        Write-Host "PIPELINE_RESULT: NO_CHANGE ($VaultName)"
        exit 0
    }
}

# JobType = 'full' from here on.
if ($criticalFailedOutsideReasonCoded.Count -gt 0) {
    # A stage outside ingestion/synthesis failed critically (e.g. backup-vault,
    # create-source-pages) - not covered by any of the 9 reason codes; keep the existing
    # Failed event for this, unchanged in shape from before this brief.
    $detail = "Critical stage(s) failed: $($criticalFailedOutsideReasonCoded -join ', ')"
    & (Join-Path $AgentRoot 'scripts/send-notification.ps1') -VaultRoot $VaultRoot -Event Failed -ExitCode '1' -LogFile $resultFile -Detail $detail -Stats $statsJson
    Write-Host "PIPELINE_RESULT: PARTIAL_FAILURE ($VaultName)"
    exit 1
}

# Final reason code: precedence order approved in Stage 1. First match wins.
$precedenceOrder = @('INGEST_BLOCKED', 'INGEST_FAILURE_CEILING', 'INGEST_ERROR', 'SYNTHESIS_TIMEOUT', 'SYNTHESIS_ERROR', 'SYNTHESIS_LIMIT_HIT')
$finalReasonCode = $null
foreach ($code in $precedenceOrder) {
    if ($ingestReasonCode -eq $code -or $synthReasonCode -eq $code) { $finalReasonCode = $code; break }
}
if (-not $finalReasonCode) {
    # Nothing from the "problem" tier fired - fall through to ingestion's own informational
    # code (TARGET_MET/NO_NEW_VIDEOS/CHANNEL_EXHAUSTED_SHORT/BACKLOG_PRIORITY_SKIP).
    # Known, flagged gap (Stage 1): a vault with no channel_url, or a run invoked with
    # -SkipYoutube, produces no ingestion reason code at all and none of the 9 codes
    # accurately describes that case - left as $null rather than forcing an inaccurate
    # code; send-notification.ps1 renders "N/A" for a null reason code (see that file).
    $finalReasonCode = $ingestReasonCode
}

# Real total channel size is the percentage denominator (confirmed with T - catalogue,
# not the reviewed subset). Guard against catalogueCount = 0 (e.g. BACKLOG_PRIORITY_SKIP's
# scan-only call itself failed and returned -1, or a channel-less edge case) to avoid a
# divide-by-zero; percentages render as "N/A" in that case, not a misleading 0%/blank.
function Format-Pct($numerator, $denominator) {
    if ($denominator -le 0) { return 'N/A' }
    return "{0:N1}%" -f (100.0 * $numerator / $denominator)
}

$telegramStats = [ordered]@{
    targetThisRun      = $synthTargetThisRun
    actualSynthesized  = $synthActualSynthesized
    backlog            = $manifestBacklog
    catalogueCount     = $catalogueCount
    pctReviewed        = Format-Pct $manifestTotal $catalogueCount
    pctCurated         = Format-Pct $manifestIncluded $catalogueCount
    pctRetryBlocked    = Format-Pct $manifestFailedBlocked $catalogueCount
    pctRetryAwaiting   = Format-Pct $manifestMissingTranscript $catalogueCount
    pctRetryOther      = Format-Pct $manifestFailedOther $catalogueCount
    pctParkedFailed    = Format-Pct $manifestParked $catalogueCount
}
$telegramStatsJson = $telegramStats | ConvertTo-Json -Compress

if ($softFailed.Count -gt 0) {
    $telegramStats['softIssue'] = "Non-critical stage(s) had an issue: $($softFailed -join ', ')"
    $telegramStatsJson = $telegramStats | ConvertTo-Json -Compress
}

$ingestErrorNote = if ($finalReasonCode -eq 'INGEST_BLOCKED' -or $finalReasonCode -eq 'INGEST_ERROR') {
    "Affected rows this run: newIngested=$($ingestResult.newIngested) retried=$($ingestResult.retried). See ingest-errors.log (now covers both failed and failed_blocked rows)."
} else { '' }
$synthErrorNote = if ($finalReasonCode -eq 'SYNTHESIS_ERROR' -and $synthErrorSnippet) { "Error: $synthErrorSnippet" } else { '' }
$runSummaryDetail = @($ingestErrorNote, $synthErrorNote) -join ' '

& (Join-Path $AgentRoot 'scripts/send-notification.ps1') -VaultRoot $VaultRoot -Event RunSummary `
    -LogFile $resultFile -Detail $runSummaryDetail.Trim() -ReasonCode $finalReasonCode -Stats $telegramStatsJson
Write-Host "PIPELINE_RESULT: $finalReasonCode ($VaultName)"
exit 0
