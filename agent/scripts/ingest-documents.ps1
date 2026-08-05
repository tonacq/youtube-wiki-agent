<#
.SYNOPSIS
Picks up manually dropped documents from this vault's input/ folder and registers them
in the same manifest.csv used by YouTube ingestion, so both feed the same downstream
source-page/synthesis pipeline.

.DESCRIPTION
Supported extensions come from config/vault.json -> documents.supported_extensions.
Extraction is intentionally simple here (plain read for .md/.txt; placeholder marker for
.pdf/.docx pending a proper extractor) — wire in a real PDF/DOCX text extractor before
production use on document-heavy vaults.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $VaultRoot 'config/vault.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

if (-not $config.documents -or -not $config.documents.enabled) {
    Write-Host "Document ingestion disabled for this vault."
    return
}

$inputDir = Join-Path $VaultRoot 'input'
$cleanDir = Join-Path $VaultRoot 'working/temp/clean_transcripts'
New-Item -ItemType Directory -Force -Path $cleanDir | Out-Null

$exts = $config.documents.supported_extensions
$files = Get-ChildItem -LiteralPath $inputDir -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $exts -contains $_.Extension.ToLowerInvariant() }

if (-not $files) { Write-Host "No documents found in input/."; return }

$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'
$manifest = @(Import-Csv -LiteralPath $manifestPath)
$knownIds = @{}
foreach ($row in $manifest) { $knownIds[$row.video_id] = $row }

$newRows = @()
foreach ($file in $files) {
    $docId = "doc_$((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.Substring(0,12))"
    if ($knownIds.ContainsKey($docId)) { continue }  # already registered, immutable id

    if ($ReportOnly) { Write-Host "[-ReportOnly] Would register: $($file.Name) -> $docId"; continue }

    $cleanFile = Join-Path $cleanDir "$docId.txt"
    switch ($file.Extension.ToLowerInvariant()) {
        { $_ -in '.md', '.txt' } { Copy-Item -LiteralPath $file.FullName -Destination $cleanFile -Force }
        default {
            # .pdf / .docx: placeholder extraction marker. Replace with a real extractor
            # (e.g. pdftotext / a DOCX text-extraction library) before production use.
            "[EXTRACTION PENDING] Source file: $($file.Name). Wire a real extractor for $($file.Extension) before relying on this row." |
                Out-File -LiteralPath $cleanFile -Encoding utf8
        }
    }

    $row = [ordered]@{
        video_id                = $docId
        title                   = $file.BaseName
        source_type             = 'document'
        transcript_status       = 'n/a'
        clean_status            = 'clean_ready'
        clean_transcript_file   = $cleanFile
        source_status           = ''
        source_file             = ''
        source_created          = ''
        ingest_status           = 'pending'
        synthesis_status        = 'pending'
        synthesis_last_checked  = ''
        synthesis_evidence      = ''
        synthesis_batch         = ''
        checksum                = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        last_updated            = (Get-Date).ToString('o')
    }
    $newRows += [pscustomobject]$row
}

if ($newRows.Count -gt 0) {
    $merged = @($manifest) + $newRows
    $tmp = "$manifestPath.tmp"
    $merged | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
}

Write-Host "Document ingestion complete: $($newRows.Count) new document(s) registered."
