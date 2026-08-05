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

$scanResults = & $ytdlp @ytArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "yt-dlp channel scan failed (exit code $LASTEXITCODE): $($scanResults -join ' ')"
}
$scanned = @($scanResults | Where-Object { $_ -match '\|' })

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

$maxVideos = if ($config.max_videos) { [int]$config.max_videos } else { 80 }
$candidates = @($scanned | Select-Object -First $maxVideos)

$newRows = @()
$skippedAlreadyParked = 0
$newIngestedCount = 0
$retriedCount = 0
$parkedThisRun = 0
foreach ($line in $candidates) {
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
        Write-Warning "Video $id ($title): $($_.Exception.Message)"
    }

    $attempts = $attemptsSoFar + 1
    if ($status -ne 'downloaded' -and $attempts -ge $maxAttempts) {
        $status = 'parked'
        Write-Warning "Video $id ($title): reached $attempts/$maxAttempts attempts - parking permanently."
    }

    if ($existing) { $retriedCount++ } else { $newIngestedCount++ }
    if ($status -eq 'parked') { $parkedThisRun++ }

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
}

if ($newRows.Count -gt 0) {
    # Atomic write: build the full manifest in memory, write to temp, then replace.
    $merged = @($manifest | Where-Object { -not ($newRows.video_id -contains $_.video_id) }) + $newRows
    $tmp = "$manifestPath.tmp"
    $merged | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
}

$ingestResultPath = Join-Path $VaultRoot 'working/temp/ingest-result.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Path $ingestResultPath -Parent) | Out-Null
[ordered]@{
    scanned              = $candidates.Count
    newIngested          = $newIngestedCount
    retried              = $retriedCount
    parkedThisRun        = $parkedThisRun
    skippedAlreadyParked = $skippedAlreadyParked
    timestamp            = (Get-Date).ToString('o')
} | ConvertTo-Json | Out-File -LiteralPath $ingestResultPath -Encoding utf8 -Force

Write-Host "YouTube ingestion complete: scanned $($candidates.Count), new/retried $($newRows.Count), parked $parkedThisRun, skipped-parked $skippedAlreadyParked"
