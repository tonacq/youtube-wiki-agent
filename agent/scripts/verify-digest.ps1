<#
.SYNOPSIS
Deterministic check of what Claude wrote into wiki/digest/*.md. Spends no Claude tokens.

.DESCRIPTION
The digest is the product the weekly briefing is built from, so it must not be trusted
blindly. For every digest file (or only those written since -SinceUtc) this checks:

  ERRORS (an alert is sent, because a human should look):
    broken-link    a [[wikilink]] names a page that does not exist anywhere under wiki/
    missing-entry  the manifest says a source was included in this batch but the digest
                   has no entry linking that source's page
    no-tier        an entry outside the "Not processed" section states no Tier A, B or C
    no-digest      the manifest has included rows for a batch but its digest file is missing
  WARNINGS (logged and written to the result file only):
    long-entry     a Tier B entry is much longer than the contract's word guide, or a
                   Tier C entry is longer than a few lines
    link-budget    an entry holds more wikilinks than the contract's budget of five

Two digest layouts are accepted, because Claude has produced both:
  * one-line bullets:   - [[page|Label]] - **Tier B**. Lesson: ...
  * heading blocks:     ## [[page|Label]]  followed by "- **Tier:** B" and field lines
An entry may also take its tier from a "## Tier B" style section heading above it.
Entries under a "## Not processed" heading are exempt from the tier rule.

Writes working/temp/verify-digest-result.json. Never throws and never fails the run:
verification is a safeguard, not a gate. With errors, sends one SynthesisAlert.

.EXAMPLE
pwsh agent/scripts/verify-digest.ps1 -VaultRoot vaults/SabrinaRamonov_Rev01 -SinceUtc 2026-11-15T11:00:00Z -NoNotify
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [string]$SinceUtc,
    [switch]$NoNotify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TierBWordWarn = 150   # contract guide is about 100 words (excluding resources); warn well past it
$LinkBudget = 5        # contract: at most five wikilinks in one entry, the source page included
$TierCWordWarn = 60

try {
    $VaultRoot = (Resolve-Path -LiteralPath $VaultRoot).Path
    $AgentRoot = Split-Path -Parent $PSScriptRoot
    $digestDir = Join-Path $VaultRoot 'wiki/digest'
    $wikiDir = Join-Path $VaultRoot 'wiki'
    $manifestPath = Join-Path $VaultRoot 'working/manifest.csv'
    $resultPath = Join-Path $VaultRoot 'working/temp/verify-digest-result.json'
    $since = $null
    if ($SinceUtc) { $since = [datetime]::Parse($SinceUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }

    $issues = [System.Collections.Generic.List[object]]::new()
    function Add-Issue($Severity, $Code, $File, $Detail) {
        $issues.Add([pscustomobject]@{ severity = $Severity; code = $Code; file = $File; detail = $Detail })
    }

    $digests = @()
    if (Test-Path -LiteralPath $digestDir) {
        $digests = @(Get-ChildItem -LiteralPath $digestDir -Filter '*.md' -File | Where-Object {
            (-not $since) -or ($_.LastWriteTimeUtc -ge $since)
        })
    }

    # Page names that exist anywhere under wiki/ (wikilinks resolve by file name).
    $pageNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $wikiDir) {
        foreach ($f in Get-ChildItem -LiteralPath $wikiDir -Filter '*.md' -File -Recurse) { [void]$pageNames.Add([IO.Path]::GetFileNameWithoutExtension($f.Name)) }
    }

    $manifest = @()
    if (Test-Path -LiteralPath $manifestPath) { $manifest = @(Import-Csv -LiteralPath $manifestPath) }
    $hasBatchCol = ($manifest.Count -gt 0) -and ($manifest[0].PSObject.Properties.Name -contains 'synthesis_batch')

    $entryCount = 0
    $linkedByBatch = @{}   # batch id -> set of linked page names

    foreach ($d in $digests) {
        $batchId = [IO.Path]::GetFileNameWithoutExtension($d.Name)
        $linked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $linkedByBatch[$batchId] = $linked
        $lines = @(Get-Content -LiteralPath $d.FullName)

        # Split into entries. A new entry starts at "- [[" or "## [[". Section headings
        # ("## Tier B", "## Not processed") set context and end the current entry.
        $section = ''
        $entries = [System.Collections.Generic.List[object]]::new()
        $cur = $null
        foreach ($line in $lines) {
            if ($line -match '^##\s+\[\[') {
                if ($cur) { $entries.Add($cur) }
                $cur = [pscustomobject]@{ section = $section; text = $line }
            } elseif ($line -match '^##\s+(.+?)\s*$') {
                if ($cur) { $entries.Add($cur); $cur = $null }
                $section = $Matches[1]
            } elseif ($line -match '^\s*-\s+\[\[') {
                if ($cur) { $entries.Add($cur) }
                $cur = [pscustomobject]@{ section = $section; text = $line }
            } elseif ($cur) {
                $cur.text += "`n" + $line
            }
        }
        if ($cur) { $entries.Add($cur) }

        foreach ($e in $entries) {
            $entryCount++
            $links = [regex]::Matches($e.text, '\[\[([^\]\|#]+)(?:[#\|][^\]]*)?\]\]') | ForEach-Object { $_.Groups[1].Value.Trim() }
            if (@($links).Count -gt $LinkBudget -and ($e.section -notmatch '(?i)not processed')) { Add-Issue 'warning' 'link-budget' $d.Name "entry for [[$(@($links)[0])]] has $(@($links).Count) wikilinks (budget: $LinkBudget)" }
            $first = $true
            foreach ($l in $links) {
                if ($first) { [void]$linked.Add($l); $first = $false }
                if (-not $pageNames.Contains($l)) { Add-Issue 'error' 'broken-link' $d.Name "[[${l}]] does not exist under wiki/" }
            }
            if ($e.section -match '(?i)not processed') { continue }

            $tier = $null
            if ($e.text -match '(?i)\*{0,2}Tier:?\*{0,2}:?\s*\*{0,2}\s*([ABC])\b') { $tier = $Matches[1].ToUpper() }
            elseif ($e.section -match '(?i)^Tier\s+([ABC])\b') { $tier = $Matches[1].ToUpper() }
            $label = if ($links) { @($links)[0] } else { '(no link)' }
            if (-not $tier) { Add-Issue 'error' 'no-tier' $d.Name "entry for [[${label}]] states no Tier A, B or C"; continue }

            $plain = [regex]::Replace($e.text, '\[\[[^\]]*\]\]', ' ')
            $words = @($plain -split '\s+' | Where-Object { $_ }).Count
            if ($tier -eq 'B' -and $words -gt $TierBWordWarn) { Add-Issue 'warning' 'long-entry' $d.Name "Tier B entry for [[${label}]] is $words words (guide: about 80)" }
            if ($tier -eq 'C' -and $words -gt $TierCWordWarn) { Add-Issue 'warning' 'long-entry' $d.Name "Tier C entry for [[${label}]] is $words words (guide: one line)" }
        }
    }

    # Coverage: every source the manifest says was included in a batch needs a digest entry.
    # Sources can be Tier A with a full page; the entry still links the source page.
    if ($hasBatchCol) {
        $byBatch = $manifest | Where-Object { $_.synthesis_status -eq 'included' -and $_.synthesis_batch } | Group-Object synthesis_batch
        foreach ($g in $byBatch) {
            $batchId = [string]$g.Name
            $digestFile = Join-Path $digestDir "$batchId.md"
            $inScope = $linkedByBatch.ContainsKey($batchId)
            if (-not $inScope) {
                # Out of scope unless its digest file should have been written in this window.
                if ($since -and -not (Test-Path -LiteralPath $digestFile)) {
                    $lastUpdated = $g.Group | ForEach-Object { try { [datetime]::Parse($_.last_updated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { [datetime]::MinValue } } | Sort-Object -Descending | Select-Object -First 1
                    if ($lastUpdated -ge $since) { Add-Issue 'error' 'no-digest' "$batchId.md" "$($g.Count) included row(s) in batch $batchId but no digest file exists" }
                }
                continue
            }
            $linked = $linkedByBatch[$batchId]
            foreach ($row in $g.Group) {
                if (-not $row.source_file) { continue }
                $page = [IO.Path]::GetFileNameWithoutExtension($row.source_file)
                if (-not $linked.Contains($page)) { Add-Issue 'error' 'missing-entry' "$batchId.md" "included source $($row.video_id) has no digest entry (expected a link to [[${page}]])" }
            }
        }
    }

    $errors = @($issues | Where-Object severity -eq 'error')
    $warnings = @($issues | Where-Object severity -eq 'warning')
    $result = [pscustomobject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        digestsChecked = $digests.Count
        entriesChecked = $entryCount
        errorCount = $errors.Count
        warningCount = $warnings.Count
        issues = @($issues)
    }
    $tmp = Split-Path -Parent $resultPath
    if (-not (Test-Path -LiteralPath $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding utf8

    Write-Host "Digest verification: $($digests.Count) digest(s), $entryCount entr(ies), $($errors.Count) error(s), $($warnings.Count) warning(s)."
    foreach ($i in ($issues | Select-Object -First 25)) { Write-Host "  [$($i.severity)] $($i.code) in $($i.file): $($i.detail)" }

    if ($errors.Count -gt 0 -and -not $NoNotify) {
        $shown = ($errors | Select-Object -First 5 | ForEach-Object { "$($_.code): $($_.detail)" }) -join '; '
        $more = if ($errors.Count -gt 5) { " (and $($errors.Count - 5) more; see working/temp/verify-digest-result.json)" } else { '' }
        $detail = "Digest verification found $($errors.Count) problem(s) in what Claude wrote: $shown$more. The briefing must not use this digest until checked."
        try { & (Join-Path $AgentRoot 'scripts/send-notification.ps1') -VaultRoot $VaultRoot -Event SynthesisAlert -Detail $detail } catch { Write-Warning "Could not send the digest alert: $($_.Exception.Message)" }
    }
} catch {
    Write-Warning "verify-digest.ps1 could not complete: $($_.Exception.Message)"
}
exit 0
