<#
.SYNOPSIS
Scans the configured YouTube channel and downloads captions for new/failed videos,
writing state only into this vault's working/manifest.csv.

.DESCRIPTION
Preserves the proven canonical-caption behaviour from the production VM history:
  - prefer en-orig, fall back to en
  - download both variants, keep only the canonical one, delete the duplicate
  - retry rows previously marked missing_transcript/failed*, do not re-scan rows
    already transcript_status = downloaded

Backlog-aware, target-driven ingestion (replaces the old fixed max_videos cap):
  carryover        = manifest rows already ingest_status=ingested AND synthesis_status=pending
  ingestion_target  = MAX(0, (batch_size * batch_iterations) - carryover)
Walks the full real channel scan in newest-first order, attempting only new/retry-eligible
candidates, and stops as soon as ingestion_target successful downloads are reached OR the
whole channel has been walked - whichever comes first. If the existing backlog already
covers this run's target, the walk is skipped entirely (BACKLOG_PRIORITY_SKIP).

Reads all channel/proxy/cookie/caption-language settings from config/vault.json so no
vault-specific values are hard-coded here.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $VaultRoot 'config/vault.json'
if (-not (Test-Path -LiteralPath $configPath)) { throw "Missing config/vault.json in $VaultRoot" }
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($config.channel_url)) {
    Write-Host "No channel_url configured for this vault; skipping YouTube ingestion."
    return
}

$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'
$rawDir       = Join-Path $VaultRoot 'working/temp/raw'
$cleanDir     = Join-Path $VaultRoot 'working/temp/clean_transcripts'
$errorLogPath = Join-Path $VaultRoot 'working/temp/ingest-errors.log'
$ingestResultPath = Join-Path $VaultRoot 'working/temp/ingest-result.json'
New-Item -ItemType Directory -Force -Path $rawDir, $cleanDir | Out-Null

$ytdlp = if ($config.yt_dlp_path) { $config.yt_dlp_path } else { 'yt-dlp' }
$captionLangs = if ($config.caption_languages) { $config.caption_languages } else { @('en-orig', 'en') }
$maxAttempts = if ($config.max_transcript_attempts) { [int]$config.max_transcript_attempts } else { 3 }

$ytArgs = @('--flat-playlist', '--print', '%(id)s|%(title)s', $config.channel_url)
if ($config.proxy)  { $ytArgs = @('--proxy', $config.proxy) + $ytArgs }

Write-Host "Scanning channel: $($config.channel_url)"
if ($ReportOnly) {
    Write-Host "[-ReportOnly] Would run: $ytdlp $($ytArgs -join ' ')"
    return
}

$manifest = @()
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = @(Import-Csv -LiteralPath $manifestPath)
}
foreach ($row in $manifest) {
    if (-not $row.PSObject.Properties['transcript_attempts']) {
        $row | Add-Member -NotePropertyName transcript_attempts -NotePropertyValue '0' -Force
    }
}
$knownIds = @{}
foreach ($row in $manifest) { $knownIds[$row.video_id] = $row }

# Backlog-aware target, computed once, before any scan - see .DESCRIPTION above.
$carryover = @($manifest | Where-Object { $_.ingest_status -eq 'ingested' -and $_.synthesis_status -eq 'pending' }).Count
if (-not $config.PSObject.Properties['batch_size'] -or -not $config.batch_size) { throw "batch_size is required in config/vault.json (no silent default - this is a deliberately-tuned per-vault value)" }
if (-not $config.PSObject.Properties['batch_iterations'] -or -not $config.batch_iterations) { throw "batch_iterations is required in config/vault.json (no silent default - this is a deliberately-tuned per-vault value)" }
$batchSize = [int]$config.batch_size
$batchIterations = [int]$config.batch_iterations
$ingestionTarget = [Math]::Max(0, ($batchSize * $batchIterations) - $carryover)

# Circuit breaker: real incident today - a walk with no bound on consecutive failures
# burned 123 real requests against a genuinely blocked proxy before finding one success,
# on a target of just 1. This stops the walk early (not the whole run) once too many
# candidates in a row fail for ANY reason (failed/failed_blocked/missing_transcript/
# parked all count - not just blocks), independent of whether the success target was
# ever reached. No sleep/retry here: unlike a session limit, a proxy block has no
# reset-time signal to wait for.
$failureCeiling = if ($config.PSObject.Properties['ingest_failure_ceiling'] -and $config.ingest_failure_ceiling) { [int]$config.ingest_failure_ceiling } else { 12 }

function Write-IngestResult {
    param(
        [string]$ReasonCode,
        [int]$Walked = 0,
        [int]$CatalogueCount = 0,
        [int]$NewIngested = 0,
        [int]$Retried = 0,
        [int]$ParkedThisRun = 0,
        [int]$SkippedAlreadyParked = 0,
        [int]$ConsecutiveFailuresAtStop = 0
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $ingestResultPath -Parent) | Out-Null
    [ordered]@{
        reasonCode                = $ReasonCode
        scanned                   = $Walked
        catalogueCount            = $CatalogueCount
        carryover                 = $carryover
        ingestionTarget           = $ingestionTarget
        requestedTarget           = ($batchSize * $batchIterations)
        newIngested               = $NewIngested
        retried                   = $Retried
        parkedThisRun             = $ParkedThisRun
        skippedAlreadyParked      = $SkippedAlreadyParked
        failureCeiling            = $failureCeiling
        consecutiveFailuresAtStop = $ConsecutiveFailuresAtStop
        timestamp                 = (Get-Date).ToString('o')
    } | ConvertTo-Json | Out-File -LiteralPath $ingestResultPath -Encoding utf8 -Force
}

if ($ingestionTarget -eq 0) {
    # Existing backlog already covers this run's whole target - skip the walk entirely.
    # Still need a real channel count for the Telegram stats block, via a scan-only call
    # (same flags as the real walk would use, just never reached this run).
    $scanResults = & $ytdlp @ytArgs 2>&1
    $catalogueCount = if ($LASTEXITCODE -eq 0) { @($scanResults | Where-Object { $_ -match '\|' }).Count } else { -1 }
    Write-IngestResult -ReasonCode 'BACKLOG_PRIORITY_SKIP' -CatalogueCount $catalogueCount
    Write-Host "Backlog ($carryover) already covers this run's target ($($batchSize * $batchIterations)); skipping ingestion walk."
    return
}

$scanResults = & $ytdlp @ytArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    $scanText = $scanResults -join ' '
    # Strict, unambiguous block/throttle detection only - same signal set as the per-video
    # failed_blocked check below. KEEP STRICT - do not broaden.
    $reasonCode = if ($scanText -match 'HTTP Error 429|Too Many Requests|HTTP Error 403|HTTP Error 402|Sign in to confirm you.?re not a bot') { 'INGEST_BLOCKED' } else { 'INGEST_ERROR' }
    Write-IngestResult -ReasonCode $reasonCode
    throw "yt-dlp channel scan failed (exit code $LASTEXITCODE): $scanText"
}
$scanned = @($scanResults | Where-Object { $_ -match '\|' })
$catalogueCount = $scanned.Count   # real total channel size - free, from this same scan

$newRows = @()
$skippedAlreadyParked = 0
$newIngestedCount = 0
$retriedCount = 0
$parkedThisRun = 0
$successCount = 0
$anyAttempted = $false
$walked = 0
$consecutiveFailures = 0
$ceilingTripped = $false

foreach ($line in $scanned) {
    if ($successCount -ge $ingestionTarget) { break }   # walk-and-count stop condition
    $walked++
    $parts = $line -split '\|', 2
    if ($parts.Count -lt 2) { continue }
    $id, $title = $parts

    $existing = $knownIds[$id]
    if ($existing -and $existing.transcript_status -eq 'parked') {
        $skippedAlreadyParked++
        continue
    }
    $needsRetry = $existing -and ($existing.transcript_status -like 'missing*' -or $existing.transcript_status -like 'failed*')
    if ($existing -and -not $needsRetry) { continue }  # already downloaded, nothing to do
    $anyAttempted = $true
    $attemptsSoFar = if ($existing -and $existing.PSObject.Properties['transcript_attempts']) { [int]$existing.transcript_attempts } else { 0 }

    $dlArgs = @(
        '--write-auto-subs', '--write-subs',
        '--sub-langs', ($captionLangs -join ','),
        '--sub-format', 'vtt', '--skip-download', '--write-info-json',
        '-o', (Join-Path $rawDir '%(id)s.%(ext)s')
    )
    if ($config.proxy)       { $dlArgs = @('--proxy', $config.proxy) + $dlArgs }
    if ($config.cookie_file) { $dlArgs = @('--cookies', $config.cookie_file) + $dlArgs }
    $dlArgs += "https://www.youtube.com/watch?v=$id"

    $status = 'downloaded'
    try {
        $dlOutput = & $ytdlp @dlArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "yt-dlp exited with code $LASTEXITCODE for ${id}: $($dlOutput -join ' ')" }

        # Canonical caption selection: prefer en-orig, else en; delete the other variant.
        $preferred = $null
        foreach ($lang in $captionLangs) {
            $candidate = Join-Path $rawDir "$id.$lang.vtt"
            if (Test-Path -LiteralPath $candidate) { $preferred = $candidate; break }
        }
        if (-not $preferred) { $status = 'missing_transcript'; throw "No caption file found for $id" }

        Get-ChildItem -LiteralPath $rawDir -Filter "$id.*.vtt" |
            Where-Object { $_.FullName -ne $preferred } |
            Remove-Item -Force
    } catch {
        $status = if ($status -eq 'downloaded') { 'failed' } else { $status }

        # Strict, unambiguous block/throttle detection only - yt-dlp's own documented FAQ
        # groups 429/402 together as IP-overuse-block signals; 403 and the literal bot-check
        # string are likewise unambiguous. Deliberately excludes generic terms (timeouts,
        # DNS failures, etc.) so those keep falling through to the existing generic 'failed'
        # status rather than being misclassified as a block.
        if ($status -eq 'failed' -and ($dlOutput -join ' ') -match 'HTTP Error 429|Too Many Requests|HTTP Error 403|HTTP Error 402|Sign in to confirm you.?re not a bot') {
            $status = 'failed_blocked'
        }

        # Durable, invocation-independent record of the raw failure text - covers BOTH
        # failed and failed_blocked (extended from failed_blocked-only, so INGEST_BLOCKED/
        # INGEST_ERROR troubleshooting in the Telegram message has real detail to point to
        # regardless of which failure category occurred). missing_transcript is not an
        # error (a successful request with no caption yet) so it is not logged here.
        if ($status -eq 'failed' -or $status -eq 'failed_blocked') {
            Add-Content -LiteralPath $errorLogPath -Value "$((Get-Date).ToString('o')) video_id=$id title=`"$title`": $($_.Exception.Message)"
        }

        Write-Warning "Video $id ($title): $($_.Exception.Message)"
    }

    $attempts = $attemptsSoFar + 1
    if ($status -ne 'downloaded' -and $attempts -ge $maxAttempts) {
        $status = 'parked'
        Write-Warning "Video $id ($title): reached $attempts/$maxAttempts attempts - parking permanently."
    }

    if ($existing) { $retriedCount++ } else { $newIngestedCount++ }
    if ($status -eq 'parked') { $parkedThisRun++ }
    if ($status -eq 'downloaded') { $successCount++ }

    $row = [ordered]@{
        video_id                = $id
        title                   = $title
        source_type             = 'youtube'
        transcript_status       = $status
        transcript_attempts     = $attempts
        clean_status            = ''
        clean_transcript_file   = ''
        source_status           = ''
        source_file             = ''
        source_created          = ''
        ingest_status           = 'pending'
        synthesis_status        = 'pending'
        synthesis_last_checked  = ''
        synthesis_evidence      = ''
        synthesis_batch         = ''
        checksum                = ''
        last_updated            = (Get-Date).ToString('o')
    }
    $newRows += [pscustomobject]$row

    # Circuit breaker check - after this candidate's row is already recorded (its real
    # outcome is kept either way), so an early stop never discards the attempt that
    # triggered it. Clean stop only, no reset-time/sleep logic - unlike a session limit,
    # a proxy block carries no signal for when it might lift.
    if ($status -eq 'downloaded') {
        $consecutiveFailures = 0
    } else {
        $consecutiveFailures++
    }
    if ($consecutiveFailures -ge $failureCeiling) {
        Write-Warning "INGEST_FAILURE_CEILING: $consecutiveFailures consecutive failures at video $walked of $($scanned.Count) walked, successCount=$successCount of target $ingestionTarget"
        $ceilingTripped = $true
        break
    }
}

if ($newRows.Count -gt 0) {
    # Atomic write: build the full manifest in memory, write to temp, then replace.
    $merged = @($manifest | Where-Object { -not ($newRows.video_id -contains $_.video_id) }) + $newRows
    $tmp = "$manifestPath.tmp"
    $merged | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
}

$reasonCode = if ($ceilingTripped) { 'INGEST_FAILURE_CEILING' }
              elseif ($successCount -ge $ingestionTarget) { 'TARGET_MET' }
              elseif (-not $anyAttempted) { 'NO_NEW_VIDEOS' }
              else { 'CHANNEL_EXHAUSTED_SHORT' }

Write-IngestResult -ReasonCode $reasonCode -Walked $walked -CatalogueCount $catalogueCount `
    -NewIngested $newIngestedCount -Retried $retriedCount -ParkedThisRun $parkedThisRun -SkippedAlreadyParked $skippedAlreadyParked `
    -ConsecutiveFailuresAtStop $consecutiveFailures

Write-Host "YouTube ingestion complete: reasonCode=$reasonCode, target=$ingestionTarget, success=$successCount, walked=$walked/$catalogueCount, new/retried $($newRows.Count), parked $parkedThisRun, skipped-parked $skippedAlreadyParked"
