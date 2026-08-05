<#
.SYNOPSIS
The single authoritative, idempotent reconciliation pass. Reads
working/temp/synthesis-result.json (if present from this run) plus the current state of
wiki/sources/*.md, and updates working/manifest.csv accordingly.

.DESCRIPTION
Carries forward two specific fixes from the validated production history:

  Finding D fix: never downgrade a row already marked synthesis_status = included back
  to pending. An interrupted run must never destroy evidence that synthesis already
  completed for that row.

  Idempotency requirement: running this twice in a row with no new work must produce
  zero manifest changes (verified separately by agent/tests).

Also checks for template artefacts left behind in source/synthesis pages (unresolved
"REPLACE_ME" or leftover mechanical-template markers) and reports them without
"fixing" them silently — a human or Claude should resolve real content gaps.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Sync-SourcePageFrontmatter($SourceFile) {
    if (-not $SourceFile -or -not (Test-Path -LiteralPath $SourceFile)) {
        return 'missing'
    }
    $raw = Get-Content -LiteralPath $SourceFile -Raw
    if ($raw -notmatch '(?s)^(---\r?\n.*?\r?\n---\r?\n)') {
        return 'no-frontmatter'
    }
    $frontmatterBlock = $matches[1]
    if ($frontmatterBlock -match '(?m)^synthesis_status:\s*included\s*\r?$') {
        return 'skipped'
    }
    if ($frontmatterBlock -notmatch '(?m)^synthesis_status:.*$') {
        return 'no-field'
    }
    $newFrontmatterBlock = [regex]::Replace($frontmatterBlock, '(?m)^synthesis_status:.*$', 'synthesis_status: included')
    $newRaw = $newFrontmatterBlock + $raw.Substring($frontmatterBlock.Length)
    Set-Content -LiteralPath $SourceFile -Value $newRaw -NoNewline -Encoding utf8
    return 'updated'
}

$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'
$resultFile   = Join-Path $VaultRoot 'working/temp/synthesis-result.json'
$manifest = @(Import-Csv -LiteralPath $manifestPath)
$changed = 0
$includedTransitions = 0
$templateArtefacts = 0
$result = $null

if (Test-Path -LiteralPath $resultFile) {
    $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
    $processedIds = @($result.processed)

    foreach ($row in $manifest) {
        if ($processedIds -notcontains $row.video_id) { continue }
        if ($row.synthesis_status -eq 'included') { continue }  # Finding D: never downgrade

        $row.synthesis_status       = 'included'
        $row.synthesis_last_checked = (Get-Date).ToString('yyyy-MM-dd')
        $row.synthesis_evidence     = ($result.pages_created + $result.pages_updated) -join '; '
        $row.synthesis_batch        = $result.batch
        $row.last_updated           = (Get-Date).ToString('o')
        $changed++
        $includedTransitions++
    }
}

# Reconcile stale source_file pointers: create-source-pages.ps1 records a fixed
# wiki/sources/<slug>.md path when it first creates a source page, but
# run-claude-synthesis.ps1's headless Claude Code invocation is free to rename or
# recreate that page (e.g. to match the vault's established date_videoid_slug.md
# convention) — and per claude.md it is only permitted to write
# working/temp/synthesis-result.json, never the manifest directly, so nothing
# previously kept the two in sync. This locates the real file on disk via its unique
# video_id token and corrects the pointer. An absent or ambiguous match is left alone
# (surfaced via the existing missingSourcePages warning below) rather than guessed at,
# so this stays safe to run unattended.
$sourceFileReconciled = 0
$sourcesDir = Join-Path $VaultRoot 'wiki/sources'
if (Test-Path -LiteralPath $sourcesDir) {
    foreach ($row in $manifest) {
        if ($row.ingest_status -ne 'ingested') { continue }
        if ($row.source_file -and (Test-Path -LiteralPath $row.source_file)) { continue }
        $onDiskMatches = @(Get-ChildItem -LiteralPath $sourcesDir -Filter "*_$($row.video_id)_*.md" -ErrorAction SilentlyContinue)
        if ($onDiskMatches.Count -eq 1) {
            $row.source_file = $onDiskMatches[0].FullName
            $sourceFileReconciled++
            $changed++
        }
    }
}

# Frontmatter sync: extends run-vault.ps1's rule that run-qa.ps1 is "the only stage
# permitted to update synthesis_status" to also cover the wiki/sources/*.md frontmatter
# copy, so there is exactly one deterministic writer for the field in both locations.
# Runs over every row currently 'included' in the manifest - not just rows that
# transitioned this run - so a plain re-run also backfills historical rows whose
# synthesis-result.json has already been archived/consumed by an earlier run.
$frontmatterUpdated = 0
$frontmatterSkipped = 0
foreach ($row in $manifest) {
    if ($row.synthesis_status -ne 'included') { continue }
    $syncResult = Sync-SourcePageFrontmatter -SourceFile $row.source_file
    switch ($syncResult) {
        'updated'        { $frontmatterUpdated++; Write-Host "  Frontmatter synced to included: $($row.source_file)" }
        'skipped'        { $frontmatterSkipped++ }
        'missing'        { Write-Warning "Frontmatter sync skipped - source_file not found for $($row.video_id): $($row.source_file)" }
        'no-frontmatter' { Write-Warning "Frontmatter sync skipped - no frontmatter block in $($row.source_file)" }
        'no-field'       { Write-Warning "Frontmatter sync skipped - no synthesis_status field in $($row.source_file)" }
    }
}

# Report-only template-artefact scan (does not modify anything)
Get-ChildItem -LiteralPath (Join-Path $VaultRoot 'wiki') -Filter '*.md' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object {
        $text = Get-Content -LiteralPath $_.FullName -Raw
        if ($text -match 'REPLACE_ME|EXTRACTION PENDING|TODO_TEMPLATE') { $templateArtefacts++ }
    }

if ($changed -gt 0) {
    $tmp = "$manifestPath.tmp"
    $manifest | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
}

# Archive the result file only after the manifest commit above has succeeded, so a crash
# in between leaves the manifest already correct - worst case a result file is left
# un-archived (recoverable/inspectable), not silently-lost evidence of completed work.
if ($result) {
    Move-Item -LiteralPath $resultFile -Destination "$resultFile.$($result.batch).processed" -Force
}

$missingSourcePages = @($manifest | Where-Object { $_.ingest_status -eq 'ingested' -and -not (Test-Path -LiteralPath $_.source_file) }).Count

Write-Host "QA reconciliation complete."
Write-Host "  Rows updated to included: $includedTransitions"
Write-Host "  Rows with source_file path reconciled: $sourceFileReconciled"
Write-Host "  Rows with missing source pages: $missingSourcePages"
Write-Host "  Pages with template artefacts remaining: $templateArtefacts"
Write-Host "  Source-page frontmatter files updated: $frontmatterUpdated"
Write-Host "  Source-page frontmatter files already correct: $frontmatterSkipped"

if ($missingSourcePages -gt 0) {
    Write-Warning "$missingSourcePages row(s) reference a source_file that does not exist on disk."
}

# Structured, machine-readable signal for run-vault.ps1 to distinguish a real-work run
# from a no-change run when deciding which Telegram event to fire (Success vs NoChange).
# Written unconditionally (even when $changed -eq 0) so a stale file from an earlier run
# can never be misread as this run's result.
$qaResultPath = Join-Path $VaultRoot 'working/temp/qa-result.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Path $qaResultPath -Parent) | Out-Null
[ordered]@{
    rowsChanged        = $changed
    frontmatterUpdated = $frontmatterUpdated
    timestamp          = (Get-Date).ToString('o')
} | ConvertTo-Json | Out-File -LiteralPath $qaResultPath -Encoding utf8 -Force
