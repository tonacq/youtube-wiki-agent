<#
.SYNOPSIS
Behavioural tests for agent/scripts/verify-digest.ps1. Disposable temp vaults only: no Claude,
no Telegram (WIKIAGENT_NOTIFY_CAPTURE_FILE captures alerts), no real vault data.
Run: pwsh -NoProfile -File agent/tests/verify-digest-test.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Verify = Join-Path $RepoRoot 'agent/scripts/verify-digest.ps1'
if (-not (Test-Path -LiteralPath $Verify)) { throw "Required file not found: $Verify" }

$script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wikiagent-verify-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $script:tempRoot | Out-Null
$script:pass = 0; $script:fail = 0
function Assert-True { param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:pass++; Write-Host "  PASS: $Message" } else { $script:fail++; Write-Host "  FAIL: $Message" -ForegroundColor Red } }

$header = 'video_id,title,source_type,transcript_status,clean_status,clean_transcript_file,source_status,source_file,source_created,ingest_status,synthesis_status,synthesis_last_checked,synthesis_evidence,synthesis_batch,checksum,last_updated'
function New-Vault {
    param([string[]]$Pages = @('src-a', 'src-b', 'src-c', 'concept-x'), [string[]]$Rows = @())
    $v = Join-Path $script:tempRoot ("V" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    foreach ($d in 'wiki/sources', 'wiki/concepts', 'wiki/digest', 'working/temp') { New-Item -ItemType Directory -Force -Path (Join-Path $v $d) | Out-Null }
    foreach ($p in $Pages) {
        $dir = if ($p -like 'src-*') { 'wiki/sources' } else { 'wiki/concepts' }
        "---`ntitle: $p`n---`nbody" | Out-File -LiteralPath (Join-Path $v "$dir/$p.md") -Encoding utf8
    }
    (@($header) + $Rows) -join "`n" | Out-File -LiteralPath (Join-Path $v 'working/manifest.csv') -Encoding utf8
    return $v
}
function Row($id, $page, $status, $batch) { "$id,Title $id,youtube,downloaded,clean_ready,,source_created,wiki/sources/$page.md,2026-01-01T00:00:00Z,ingested,$status,,,$batch,,2026-11-15T00:00:00Z" }
function Set-Digest($v, $batch, $text) { $text | Out-File -LiteralPath (Join-Path $v "wiki/digest/$batch.md") -Encoding utf8 }
function Run-Verify($v, [string[]]$Extra = @()) {
    $cap = Join-Path $v 'notify.txt'
    $env:WIKIAGENT_NOTIFY_CAPTURE_FILE = $cap
    $out = & pwsh -NoProfile -File $Verify -VaultRoot $v @Extra 2>&1 | Out-String
    $code = $LASTEXITCODE
    Remove-Item Env:WIKIAGENT_NOTIFY_CAPTURE_FILE -ErrorAction SilentlyContinue
    $res = Get-Content -LiteralPath (Join-Path $v 'working/temp/verify-digest-result.json') -Raw | ConvertFrom-Json
    [pscustomobject]@{ Exit = $code; Out = $out; Result = $res; Alert = (Test-Path -LiteralPath $cap) }
}
function Codes($r) { @($r.Result.issues | ForEach-Object { $_.code }) }

try {
    Write-Host "[1] clean digest in both layouts, plus a Not processed section: no errors, no alert"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'), (Row 'CCC' 'src-c' 'included' 'b1'))
    Set-Digest $v 'b1' @'
# Digest: b1

## Tier B

- [[src-a|Alpha]] — **Tier B**. Lesson: short. Why it matters: short. See [[concept-x]].

## Tier C

- [[src-b|Beta]] — Tier C: event promo.

## [[src-c|Gamma]]

- **Tier:** A
- **Lesson:** one sentence.

## Not processed

- [[src-zzz|ZZZ]] — transcript does not match its title.
'@
    $r = Run-Verify $v -Extra @()
    # src-zzz does not exist, so this is a broken link even in Not processed; fix the fixture first.
    Assert-True ((Codes $r) -contains 'broken-link') "a broken link is reported even under Not processed"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'), (Row 'CCC' 'src-c' 'included' 'b1'))
    Set-Digest $v 'b1' @'
# Digest: b1

## Tier B

- [[src-a|Alpha]] — **Tier B**. Lesson: short. Why it matters: short. See [[concept-x]].

## Tier C

- [[src-b|Beta]] — Tier C: event promo.

## [[src-c|Gamma]]

- **Tier:** A
- **Lesson:** one sentence.

## Not processed

- [[concept-x|Not a source]] — transcript does not match its title.
'@
    $r = Run-Verify $v
    Assert-True ($r.Exit -eq 0) "exit 0"
    Assert-True ($r.Result.errorCount -eq 0 -and $r.Result.entriesChecked -eq 4) "0 errors across 4 entries (errors $($r.Result.errorCount), entries $($r.Result.entriesChecked))"
    Assert-True (-not $r.Alert) "no alert sent for a clean digest"

    Write-Host "[2] included source with no digest entry: missing-entry error and one alert"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'))
    Set-Digest $v 'b1' "## Tier C`n`n- [[src-a|Alpha]] — Tier C: promo.`n"
    $r = Run-Verify $v
    Assert-True ((Codes $r) -contains 'missing-entry') "missing-entry reported"
    Assert-True (($r.Result.issues | Where-Object code -eq 'missing-entry').detail -match 'BBB') "names the missing source BBB"
    Assert-True ($r.Alert -and ((Get-Content -LiteralPath (Join-Path $v 'notify.txt') -Raw) -match 'Event=SynthesisAlert')) "a SynthesisAlert is sent"
    Assert-True ($r.Exit -eq 0) "still exits 0 (a safeguard, not a gate)"

    Write-Host "[3] entry with no tier"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'))
    Set-Digest $v 'b1' "# Digest`n`n- [[src-a|Alpha]] — Lesson: something, no tier given.`n"
    $r = Run-Verify $v
    Assert-True ((Codes $r) -contains 'no-tier') "no-tier reported"

    Write-Host "[4] broken wikilink inside an entry"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'))
    Set-Digest $v 'b1' "## Tier B`n`n- [[src-a|Alpha]] — **Tier B**. Why: see [[no-such-page]].`n"
    $r = Run-Verify $v
    Assert-True ((Codes $r) -contains 'broken-link') "broken-link reported for [[no-such-page]]"

    Write-Host "[5] digest file missing for a batch written this run"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b9'))
    $r = Run-Verify $v -Extra @('-SinceUtc', '2026-11-01T00:00:00Z')
    Assert-True ((Codes $r) -contains 'no-digest') "no-digest reported with -SinceUtc"
    $r = Run-Verify $v
    Assert-True (-not ((Codes $r) -contains 'no-digest')) "no-digest not reported without -SinceUtc (no window to judge by)"

    Write-Host "[6] over-long Tier B entry: warning only, no alert"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'))
    $long = (1..200 | ForEach-Object { 'word' }) -join ' '
    Set-Digest $v 'b1' "## Tier B`n`n- [[src-a|Alpha]] — **Tier B**. Lesson: $long`n"
    $r = Run-Verify $v
    Assert-True ($r.Result.errorCount -eq 0 -and $r.Result.warningCount -eq 1 -and (Codes $r) -contains 'long-entry') "one long-entry warning, no errors"
    Assert-True (-not $r.Alert) "a warning alone sends no alert"

    Write-Host "[7] -SinceUtc skips old digests; -NoNotify suppresses the alert"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'))
    Set-Digest $v 'b1' "# Digest`n`n- [[src-a|Alpha]] — no tier.`n"
    (Get-Item -LiteralPath (Join-Path $v 'wiki/digest/b1.md')).LastWriteTimeUtc = [datetime]'2026-01-01T00:00:00Z'
    $r = Run-Verify $v -Extra @('-SinceUtc', '2026-11-01T00:00:00Z')
    Assert-True ($r.Result.digestsChecked -eq 0 -and $r.Result.errorCount -eq 0) "an old digest is out of scope"
    $r = Run-Verify $v -Extra @('-NoNotify')
    Assert-True ($r.Result.errorCount -ge 1 -and -not $r.Alert) "-NoNotify records the error but sends nothing"

    Write-Host "[8] vault with no digest folder or manifest columns missing: never throws"
    $v = Join-Path $script:tempRoot 'Bare'
    New-Item -ItemType Directory -Force -Path (Join-Path $v 'working/temp') | Out-Null
    $r = Run-Verify $v
    Assert-True ($r.Exit -eq 0 -and $r.Result.errorCount -eq 0) "bare vault: exit 0, no errors"

    Write-Host "[9] more than five wikilinks in one entry: warning only"
    $v = New-Vault -Pages @('src-a', 'src-b', 'src-c', 'concept-x', 'concept-y', 'concept-z', 'concept-w', 'concept-v') -Rows @((Row 'AAA' 'src-a' 'included' 'b1'))
    Set-Digest $v 'b1' "## Tier B`n`n- [[src-a|Alpha]] - **Tier B**. See [[concept-x]], [[concept-y]], [[concept-z]], [[concept-w]], [[concept-v]].`n"
    $r = Run-Verify $v
    Assert-True ($r.Result.errorCount -eq 0 -and ((Codes $r) -contains 'link-budget')) "link-budget warning, no error"
    Assert-True (-not $r.Alert) "a link-budget warning sends no alert"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'))
    Set-Digest $v 'b1' "## Tier B`n`n- [[src-a|Alpha]] - **Tier B**. See [[concept-x]].`n"
    $r = Run-Verify $v
    Assert-True (-not ((Codes $r) -contains 'link-budget')) "two links is within budget"

    Write-Host "[10] level-3 heading entries with unbolded fields (the layout Claude produced on 16 Nov)"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'))
    Set-Digest $v 'b1' "# Synthesis digest`n`n## Tier B`n`n### [[src-a|Alpha]]`n- Tier: B`n- Lesson: one sentence.`n- Why it matters: short.`n`n## Tier C`n`n- [[src-b|Beta]]: C, promo.`n"
    $r = Run-Verify $v
    Assert-True ($r.Result.errorCount -eq 0 -and $r.Result.entriesChecked -eq 2) "no errors, 2 entries (errors $($r.Result.errorCount), entries $($r.Result.entriesChecked))"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'))
    Set-Digest $v 'b1' "## Tier B`n`n### [[src-a|Alpha]]`n- Tier: B`n- Lesson: one sentence.`n"
    $r = Run-Verify $v
    Assert-True ((Codes $r) -contains 'missing-entry' -and ($r.Result.issues | Where-Object code -eq 'missing-entry').detail -match 'BBB') "a heading-layout digest still flags a genuinely missing entry"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'))
    Set-Digest $v 'b1' "## Entries`n`n### [[src-a|Alpha]]`n- Lesson: no tier line here.`n"
    $r = Run-Verify $v
    Assert-True ((Codes $r) -contains 'no-tier') "a heading-layout entry with no tier is still flagged"

    Write-Host "[11] merged entry: every source linked on the entry's first line is covered"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'))
    Set-Digest $v 'b1' "## Tier B`n`n- [[src-a|Alpha]] and [[src-b|Beta]] (the demo clip) - **Tier B**. Lesson: one sentence for both.`n"
    $r = Run-Verify $v
    Assert-True (-not ((Codes $r) -contains 'missing-entry')) "a merged entry covers both sources (codes: $((Codes $r) -join ','))"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'))
    Set-Digest $v 'b1' "## Tier B`n`n- [[src-a|Alpha]] - **Tier B**. Lesson: one sentence. See also [[src-b]].`n"
    $r = Run-Verify $v
    Assert-True ((Codes $r) -contains 'missing-entry') "a source linked only in the body of another entry is still flagged"

    Write-Host "[12] titled heading with the source on a Source: line (layouts seen in the 22 Nov Rev01 run)"
    $rows = @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'), (Row 'CCC' 'src-c' 'included' 'b1'))
    $v = New-Vault -Rows $rows
    Set-Digest $v 'b1' "# Digest: b1`n`nAll Tier B.`n`n## Alpha title`n- **Source:** [[src-a|Alpha]]`n- **Tier:** B`n- **Key statement:** one.`n`n## Beta title`nSource: [[src-b|Beta]]. Tier B (weak signal).`n- **Key statement:** two.`n`n## Gamma title`n- Source: [[src-c|Gamma]]`n- **Tier:** B`n- **What it adds:** extends [[concept-x]].`n"
    $r = Run-Verify $v
    Assert-True (@(Codes $r).Count -eq 0) "bold, plain and bullet Source: lines all cover their source (codes: $((Codes $r) -join ','))"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'))
    Set-Digest $v 'b1' "## Alpha title`n- **Source:** [[src-a|Alpha]]`n- **Tier:** B`n- **What it adds:** see also [[src-b]].`n"
    $r = Run-Verify $v
    Assert-True ((Codes $r) -contains 'missing-entry') "a source linked only in the body of a Source:-line entry is still flagged"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'))
    Set-Digest $v 'b1' "## Alpha title`n- **Source:** [[src-a|Alpha]]`n- **Key statement:** no tier given.`n"
    $r = Run-Verify $v
    Assert-True ((Codes $r) -contains 'no-tier') "a Source:-line entry with no tier is still flagged"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'))
    Set-Digest $v 'b1' "## Tier B`n`n## Notes on nothing`nJust prose, no source line.`n"
    $r = Run-Verify $v
    Assert-True ((Codes $r) -contains 'missing-entry') "a plain heading with no source line is not an entry"

    Write-Host "[13] closing References list (the 23 Nov Rev01 digest 232905) is not read as entries"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'))
    Set-Digest $v 'b1' "## [[src-a|Alpha]]`n- **Tier:** B`n- **Key statement:** one.`n`n## [[src-b|Beta]]`n- **Tier:** B`n- **Key statement:** two.`n`n## References`n- [[src-a|Alpha]]`n- [[src-b|Beta]]`n"
    $r = Run-Verify $v
    Assert-True (@(Codes $r).Count -eq 0) "a References list adds no no-tier errors (codes: $((Codes $r) -join ','))"
    $v = New-Vault -Rows @((Row 'AAA' 'src-a' 'included' 'b1'), (Row 'BBB' 'src-b' 'included' 'b1'))
    Set-Digest $v 'b1' "## [[src-a|Alpha]]`n- **Tier:** B`n- **Key statement:** one.`n`n## References`n- [[src-a|Alpha]]`n- [[src-b|Beta]]`n"
    $r = Run-Verify $v
    Assert-True ((Codes $r) -contains 'missing-entry') "a source listed only under References is still flagged missing"
}
finally {
    Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== Summary: $($script:pass) passed, $($script:fail) failed ==="
if ($script:fail -gt 0) { exit 1 }
