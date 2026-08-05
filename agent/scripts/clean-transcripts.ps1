<#
.SYNOPSIS
Converts each downloaded raw VTT caption into clean plain text and updates the manifest
accordingly, so create-source-pages.ps1 has clean_status = clean_ready rows to work from.

.DESCRIPTION
Ported from the proven VM pipeline (weekly_update_channel_wiki_v8_linux.ps1's
Convert-VttToPlainText plus its inline clean_status transition), which this multivault
rebuild had not yet carried over — youtube-sourced rows previously stayed at
clean_status = '' forever, so create-source-pages.ps1 could never fire for them.

For every manifest row not already clean_status = clean_ready:
  - if a raw .vtt exists for that video_id under working/temp/raw, clean it and set
    clean_status = clean_ready, clean_transcript_file = <absolute path to the clean .txt>;
  - otherwise set clean_status = blocked_missing_transcript (the status
    ingest-documents.ps1/create-source-pages.ps1 already expect - no new status strings
    invented here).

Re-runnable: rows already clean_ready are left untouched; rows previously marked
blocked_missing_transcript are re-attempted (a later ingest-youtube retry may have
produced a raw .vtt since the last run).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-VttToPlainText([string]$VttPath, [string]$OutPath) {
    $lines = Get-Content -LiteralPath $VttPath -Encoding UTF8
    $clean = New-Object System.Collections.Generic.List[string]
    $prev = ""

    foreach ($line in $lines) {
        $s = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -eq "WEBVTT") { continue }
        if ($s.StartsWith("Kind:")) { continue }
        if ($s.StartsWith("Language:")) { continue }
        if ($s -match "-->") { continue }
        if ($s -match "^\d+$") { continue }

        $s = [regex]::Replace($s, "<[^>]+>", "")
        $s = $s -replace "&amp;", "&"
        $s = $s -replace "&lt;", "<"
        $s = $s -replace "&gt;", ">"
        $s = $s -replace "&quot;", '"'
        $s = $s -replace "&#39;", "'"
        $s = [regex]::Replace($s, "\s+", " ").Trim()

        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -eq $prev) { continue }
        $clean.Add($s)
        $prev = $s
    }

    $text = ($clean -join " ")
    Set-Content -LiteralPath $OutPath -Value $text -Encoding UTF8
}

$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'
$rawDir       = Join-Path $VaultRoot 'working/temp/raw'
$cleanDir     = Join-Path $VaultRoot 'working/temp/clean_transcripts'
New-Item -ItemType Directory -Force -Path $cleanDir | Out-Null

if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Host "No manifest found; nothing to clean."
    return
}

$manifest = @(Import-Csv -LiteralPath $manifestPath)
$cleaned = 0
$blocked = 0

foreach ($row in $manifest) {
    if ($row.clean_status -eq 'clean_ready') { continue }

    $rawVtt = Get-ChildItem -LiteralPath $rawDir -Filter "$($row.video_id).*.vtt" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($rawVtt) {
        $cleanBase = [System.IO.Path]::GetFileNameWithoutExtension($rawVtt.Name)
        $cleanPath = Join-Path $cleanDir "$cleanBase.txt"
        Convert-VttToPlainText -VttPath $rawVtt.FullName -OutPath $cleanPath

        $row.clean_status          = 'clean_ready'
        $row.clean_transcript_file = $cleanPath
        $row.last_updated          = (Get-Date).ToString('o')
        $cleaned++
    } else {
        $row.clean_status = 'blocked_missing_transcript'
        $row.last_updated = (Get-Date).ToString('o')
        $blocked++
    }
}

if ($cleaned -gt 0 -or $blocked -gt 0) {
    $tmp = "$manifestPath.tmp"
    $manifest | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
}

Write-Host "Transcript cleaning complete: $cleaned cleaned, $blocked blocked (missing transcript)."
