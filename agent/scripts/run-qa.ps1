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
    # A malformed result file must not crash the whole reconciliation pass - the disk-truth
    # fallback and frontmatter sync below are independent, unconditional safety nets that
    # still need to run even when Claude's own result file is unusable (confirmed via a
    # real 2026-09-05 SabrinaRamonov_Rev01 reliability investigation: without this guard, a
    # malformed synthesis-result.json here previously propagated as an uncaught terminating
    # error out of run-qa.ps1 entirely). Left in place, not archived (the `if ($result)`
    # guard on the archive step below skips it), so it stays on disk for a human to inspect
    # rather than silently disappearing.
    try {
        $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "synthesis-result.json present but failed to parse - left in place (not archived) for inspection: $($_.Exception.Message)"
        $result = $null
    }
}
if ($result) {
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

# Disk-truth reconciliation fallback: a standing safety net for interrupted synthesis
# runs. run-claude-synthesis.ps1 only writes working/temp/synthesis-result.json when an
# ENTIRE batch finishes (config/claude.md step 3-4 instructs updating
# wiki/synthesis/synthesis_register.md only "with the batch you just completed" too -
# same blind spot), so a session interrupted mid-batch leaves genuinely-completed work
# permanently invisible to the manifest via the block above alone. This scans the real
# downstream output directories directly - unconditionally, independent of whether a
# result file exists at all - for any row still synthesis_status = pending despite
# ingest_status already = ingested.
#
# Deliberately does NOT scan wiki/sources/: create-source-pages.ps1 writes that
# mechanical stub unconditionally, before Claude ever runs, so a file existing there
# proves nothing about whether real synthesis happened (confirmed empirically - a
# genuinely-included row's own source page is byte-identical in structure to a
# still-pending stub, differing only in a frontmatter value that this same script's
# Sync-SourcePageFrontmatter function writes, downstream of this same result-file gate).
# Only concepts/, tools/, workflows/, and synthesis/ contain content Claude itself
# produces.
#
# Only ever reached for 'full' job runs - lint-review jobs never invoke run-qa.ps1 at
# all (see run-vault.ps1's JobType branch), so no internal mode check is needed here.
$fallbackDirs = @('concepts', 'tools', 'workflows', 'synthesis') |
    ForEach-Object { Join-Path $VaultRoot "wiki/$_" } |
    Where-Object { Test-Path -LiteralPath $_ }

$diskReconciled = 0
if ($fallbackDirs.Count -gt 0) {
    $candidateFiles = @(Get-ChildItem -LiteralPath $fallbackDirs -Filter '*.md' -Recurse -ErrorAction SilentlyContinue)

    # Read every candidate file's content exactly once, up front - same "build once,
    # reuse per row" pattern already used above for the frontmatter video_id map
    # (lines 101-112) - so file reads stay bounded by file count regardless of how many
    # pending rows are checked against them, not O(rows x files).
    $candidateContents = @(
        foreach ($file in $candidateFiles) {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($raw) { [pscustomobject]@{ Path = $file.FullName; Raw = $raw } }
        }
    )

    foreach ($row in $manifest) {
        if ($row.ingest_status -ne 'ingested') { continue }
        if ($row.synthesis_status -eq 'included') { continue }  # Finding D: never downgrade / never re-touch

        $escapedId = [regex]::Escape($row.video_id)
        # Exact match only, no fuzzy matching - same principle as the source_file
        # fallback above: a frontmatter video_id field (mirrors that block's own regex),
        # or the bare id elsewhere in the file bounded by non-identifier characters
        # (covers the inline-link style, e.g. "...(CkoJauJIyQs)").
        $frontmatterPattern = '(?m)^video_id:\s*"?' + $escapedId + '"?\s*$'
        $bodyPattern        = '(?<![A-Za-z0-9_-])' + $escapedId + '(?![A-Za-z0-9_-])'

        $matchedFile = $null
        foreach ($candidate in $candidateContents) {
            $raw = $candidate.Raw
            if (-not (($raw -match $frontmatterPattern) -or ($raw -match $bodyPattern))) { continue }

            # Malformed/partial-page guard: require a closed frontmatter block (the same
            # regex Sync-SourcePageFrontmatter already uses below) plus non-trivial body
            # content after it - rejects a file truncated mid-write by an interrupt.
            # Deliberately no word-count or other arbitrary threshold beyond this - a
            # page that finished valid frontmatter and some body before being cut off
            # would still pass; that residual risk is accepted, not solved, here.
            if ($raw -notmatch '(?s)^(---\r?\n.*?\r?\n---\r?\n)') { continue }
            $body = $raw.Substring($matches[1].Length).Trim()
            if ([string]::IsNullOrWhiteSpace($body)) { continue }

            $matchedFile = $candidate.Path
            break
        }

        # Known, accepted limitation (not fixed here): this matching logic cannot
        # distinguish genuine per-video synthesis from a bare video_id citation inside a
        # shared/cumulative page (e.g. a tool reference page cited by many videos, built up
        # incrementally across multiple batches). Investigated (B4) after a real production
        # run recovered 49 rows via just 22 shared files; all 49 were independently verified
        # correct that time via a coincidental corroborating artifact (per-video extraction-
        # notes files) that is NOT a guaranteed convention - confirmed (B5 Part 1) absent
        # from config/claude.md and every vault template, so it cannot be relied on as a
        # check. A future interrupted run with heavy citation-sharing could theoretically
        # produce a false-positive inclusion this fallback has no way to detect. Real fix
        # would need either (a) a synthesis prompt/output-contract change adding explicit
        # per-source markers inside wiki pages themselves (its own track, not a run-qa.ps1
        # tweak), or (b) a mandated, enforced extraction-notes convention added to claude.md
        # across all vault templates. Neither is implemented as of this commit.
        if ($matchedFile) {
            $row.synthesis_status       = 'included'
            $row.synthesis_last_checked = (Get-Date).ToString('yyyy-MM-dd')
            $row.synthesis_evidence     = $matchedFile
            $row.synthesis_batch        = 'disk-reconciliation-fallback'
            $row.last_updated           = (Get-Date).ToString('o')
            $changed++
            $diskReconciled++
        }
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
#
# Two lookup strategies, in that order:
#   1. Filename-embedded video_id (the date_videoid_slug.md convention).
#   2. Frontmatter video_id field, for pages that predate that filename convention
#      (confirmed present - exact string, both schemas found on disk: the
#      Claude-Code-rewritten schema using type/creator/platform, and the untouched
#      mechanically-generated schema using video_id/source_type/title) - used only
#      as a fallback when (1) finds zero or more than one match. Exact match only;
#      never fuzzy/slug/title matching.
$sourceFileReconciled = 0
$sourcesDir = Join-Path $VaultRoot 'wiki/sources'
if (Test-Path -LiteralPath $sourcesDir) {
    # Built once, up front - every source page's frontmatter is read at most once
    # regardless of how many manifest rows need reconciling this run.
    $frontmatterVideoIdMap = @{}
    foreach ($file in Get-ChildItem -LiteralPath $sourcesDir -Filter '*.md' -ErrorAction SilentlyContinue) {
        $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $raw -or $raw -notmatch '(?s)^---\r?\n(.*?)\r?\n---\r?\n') { continue }
        $fm = $Matches[1]
        if ($fm -notmatch '(?m)^video_id:\s*"?([A-Za-z0-9_-]+)"?\s*$') { continue }
        $vid = $Matches[1]
        if (-not $frontmatterVideoIdMap.ContainsKey($vid)) {
            $frontmatterVideoIdMap[$vid] = New-Object System.Collections.Generic.List[string]
        }
        $frontmatterVideoIdMap[$vid].Add($file.FullName)
    }

    foreach ($row in $manifest) {
        if ($row.ingest_status -ne 'ingested') { continue }
        if ($row.source_file -and (Test-Path -LiteralPath $row.source_file)) { continue }

        $resolved = $null
        $onDiskMatches = @(Get-ChildItem -LiteralPath $sourcesDir -Filter "*_$($row.video_id)_*.md" -ErrorAction SilentlyContinue)
        if ($onDiskMatches.Count -eq 1) {
            $resolved = $onDiskMatches[0].FullName
        } elseif ($frontmatterVideoIdMap.ContainsKey($row.video_id) -and $frontmatterVideoIdMap[$row.video_id].Count -eq 1) {
            $resolved = $frontmatterVideoIdMap[$row.video_id][0]
        }

        if ($resolved) {
            $row.source_file = $resolved
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
Write-Host "  Rows recovered via disk-truth fallback (no result file): $diskReconciled"
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
    diskReconciled     = $diskReconciled
    frontmatterUpdated = $frontmatterUpdated
    timestamp          = (Get-Date).ToString('o')
} | ConvertTo-Json | Out-File -LiteralPath $qaResultPath -Encoding utf8 -Force
