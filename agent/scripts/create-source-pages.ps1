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

File name: wiki/sources/src_<video_id>_<title-slug>.md. The video_id makes the name unique
per source, so two sources with the same title never share one page. The src_<id>_ shape
also matches run-qa.ps1's "*_<video_id>_*.md" source_file lookup.

A row is only marked ingested when its page holds that row's own content:
  - clean transcript file missing: no page is written; clean_status is cleared so
    clean-transcripts.ps1 rebuilds it from the raw captions (or marks it
    blocked_missing_transcript), and the row is not marked ingested.
  - a page already at the target path carries a different video_id in its frontmatter:
    the row is skipped and reported, never pointed at that page.
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

$skippedNoTranscript = 0
$skippedConflict = 0

foreach ($row in $manifest) {
    if ($row.clean_status -ne 'clean_ready') { continue }
    if ($row.source_status -in @('source_exists', 'source_created')) { continue }

    $slug = ($row.title -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLowerInvariant()
    if ($slug.Length -gt 80) { $slug = $slug.Substring(0, 80).Trim('-') }
    $fileName = if ([string]::IsNullOrWhiteSpace($slug)) { "src_$($row.video_id).md" } else { "src_$($row.video_id)_$slug.md" }
    $sourceFile = Join-Path $sourcesDir $fileName

    if (Test-Path -LiteralPath $sourceFile) {
        $existingRaw = Get-Content -LiteralPath $sourceFile -Raw -ErrorAction SilentlyContinue
        if ($existingRaw -and $existingRaw -match '(?s)^---\r?\n(.*?)\r?\n---' -and $Matches[1] -match '(?m)^video_id:\s*"?([A-Za-z0-9_-]+)"?\s*$' -and $Matches[1] -ne $row.video_id) {
            Write-Warning "Source page $sourceFile belongs to video_id $($Matches[1]), not $($row.video_id); row skipped."
            $skippedConflict++
            continue
        }
    } else {
        $transcriptPath = $row.clean_transcript_file
        if ($transcriptPath -and -not [System.IO.Path]::IsPathRooted($transcriptPath)) { $transcriptPath = Join-Path $VaultRoot $transcriptPath }
        if (-not $transcriptPath -or -not (Test-Path -LiteralPath $transcriptPath)) {
            Write-Warning "Clean transcript not found for $($row.video_id) ('$($row.clean_transcript_file)'); no source page written, row not marked ingested."
            $row.clean_status          = ''
            $row.clean_transcript_file = ''
            $row.last_updated          = (Get-Date).ToString('o')
            $skippedNoTranscript++
            continue
        }
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

$(Get-Content -LiteralPath $transcriptPath -Raw)
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

if ($updated -gt 0 -or $skippedNoTranscript -gt 0) {
    $tmp = "$manifestPath.tmp"
    $manifest | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
}

Write-Host "Source-page creation complete: $updated page(s) created/updated, $skippedNoTranscript skipped (clean transcript missing), $skippedConflict skipped (page belongs to another video_id)."
