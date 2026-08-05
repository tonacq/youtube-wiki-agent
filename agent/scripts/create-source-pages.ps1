<#
.SYNOPSIS
Mechanically creates wiki/sources/*.md pages from clean transcripts/documents. Purely
deterministic — spends zero Claude tokens, per the project's locked cost-control decision
(Claude Code is reserved for semantic synthesis, not clerical file creation).

.DESCRIPTION
For every manifest row where clean_status = clean_ready and source_status is not already
source_exists/source_created, write a templated source page and update the manifest.
Never overwrites an existing source page (so a page a human or Claude has hand-edited is
never clobbered by a re-run).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'
$sourcesDir   = Join-Path $VaultRoot 'wiki/sources'
New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null

$manifest = @(Import-Csv -LiteralPath $manifestPath)
$updated = 0

foreach ($row in $manifest) {
    if ($row.clean_status -ne 'clean_ready') { continue }
    if ($row.source_status -in @('source_exists', 'source_created')) { continue }

    $slug = ($row.title -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = $row.video_id }
    $sourceFile = Join-Path $sourcesDir "$slug.md"

    if (-not (Test-Path -LiteralPath $sourceFile)) {
        $body = @"
---
video_id: $($row.video_id)
source_type: $($row.source_type)
title: "$($row.title)"
synthesis_status: pending
---

# $($row.title)

*Source: $($row.source_type) ($($row.video_id))*

<!-- Mechanically generated source page. Claude synthesis (run-claude-synthesis.ps1)
     reads this file and produces concept/tool/workflow/synthesis pages from it. -->

## Transcript / content

$(if (Test-Path -LiteralPath $row.clean_transcript_file) { Get-Content -LiteralPath $row.clean_transcript_file -Raw } else { "*(clean transcript file not found: $($row.clean_transcript_file))*" })
"@
        $body | Out-File -LiteralPath $sourceFile -Encoding utf8
    }

    $row.source_status  = 'source_created'
    $row.source_file    = $sourceFile
    $row.source_created = (Get-Date).ToString('o')
    $row.ingest_status  = 'ingested'
    $row.last_updated   = (Get-Date).ToString('o')
    $updated++
}

if ($updated -gt 0) {
    $tmp = "$manifestPath.tmp"
    $manifest | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
}

Write-Host "Source-page creation complete: $updated page(s) created/updated."
