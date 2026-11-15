<#
.SYNOPSIS
Behavioural tests for agent/scripts/create-my-thinking-pages.ps1. Disposable temp vaults only.
Run: pwsh -NoProfile -File agent/tests/my-thinking-test.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepoRoot 'agent/scripts/create-my-thinking-pages.ps1'
if (-not (Test-Path -LiteralPath $Script)) { throw "Required file not found: $Script" }

$script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wikiagent-mythinking-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $script:tempRoot | Out-Null
$script:pass = 0; $script:fail = 0
function Assert-True { param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:pass++; Write-Host "  PASS: $Message" } else { $script:fail++; Write-Host "  FAIL: $Message" -ForegroundColor Red } }

function New-Vault { param([hashtable]$Concepts)
    $v = Join-Path $script:tempRoot ("V" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path (Join-Path $v 'wiki/concepts') | Out-Null
    foreach ($k in $Concepts.Keys) { [IO.File]::WriteAllText((Join-Path $v "wiki/concepts/$k.md"), $Concepts[$k]) }
    return $v
}
function Run($v, [string[]]$Names = @()) {
    $a = @('-VaultRoot', $v); if ($Names.Count -gt 0) { $a += @('-Concept', ($Names -join ',')) }
    $out = & pwsh -NoProfile -File $Script @a 2>&1 | Out-String
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out } }
function Txt($p) { [IO.File]::ReadAllText($p) }

try {
    Write-Host "[0] nothing is created unless concepts are named"
    $v = New-Vault @{ 'check-sources' = "---`ntitle: `"Check sources`"`ntype: concept`n---`n`n# Check sources`n`nBody.`n"; 'other' = "# Other`n" }
    $orig = Txt (Join-Path $v 'wiki/concepts/check-sources.md')
    $r = Run $v
    Assert-True ($r.Exit -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $v 'wiki/my-thinking'))) "no concepts named: no folder, no stubs"
    Assert-True ((Txt (Join-Path $v 'wiki/concepts/check-sources.md')) -eq $orig) "concept page untouched"

    Write-Host "[1] a named concept gets a stub, linked from its page; others are left alone"
    $r = Run $v @('check-sources')
    $stub = Join-Path $v 'wiki/my-thinking/my-thinking-check-sources.md'
    Assert-True ($r.Exit -eq 0) "exit 0"
    Assert-True (Test-Path -LiteralPath $stub) "stub created"
    Assert-True ((Txt $stub) -match 'title: "My thinking: Check sources"' -and (Txt $stub) -match '\[\[check-sources\]\]') "stub carries the concept title and links back"
    Assert-True ((Txt (Join-Path $v 'wiki/concepts/check-sources.md')) -match 'My thinking: \[\[my-thinking-check-sources\]\]') "concept page links to the stub"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $v 'wiki/my-thinking/my-thinking-other.md'))) "an unnamed concept gets no stub"

    Write-Host "[2] idempotent: a second run changes nothing"
    $before = Txt (Join-Path $v 'wiki/concepts/check-sources.md')
    $r = Run $v @('check-sources')
    Assert-True ((Txt (Join-Path $v 'wiki/concepts/check-sources.md')) -eq $before) "concept page unchanged"
    Assert-True ($r.Out -match '0 created, 0 concept') "reports 0 created, 0 linked"

    Write-Host "[3] never overwrites the reader's writing"
    Set-Content -LiteralPath $stub -Value "MY OWN WORDS" -Encoding utf8
    $null = Run $v @('check-sources')
    Assert-True ((Txt $stub) -match 'MY OWN WORDS' -and (Txt $stub) -notmatch 'This page is yours') "existing my-thinking page untouched"

    Write-Host "[4] concept page without a trailing newline or title still works"
    $v2 = New-Vault @{ 'bare-page' = "no frontmatter and no newline at the end" }
    $r = Run $v2 @('bare-page')
    Assert-True ($r.Exit -eq 0 -and (Test-Path -LiteralPath (Join-Path $v2 'wiki/my-thinking/my-thinking-bare-page.md'))) "stub created for a bare page"
    $c = Txt (Join-Path $v2 'wiki/concepts/bare-page.md')
    Assert-True ($c -match "no newline at the end\r?\n\r?\nMy thinking: \[\[my-thinking-bare-page\]\]") "link appended on its own line"

    Write-Host "[5] a link already present is not duplicated"
    $v3 = New-Vault @{ 'has-link' = "# T`n`nMy thinking: [[my-thinking-has-link]]`n" }
    $null = Run $v3 @('has-link')
    $c = Txt (Join-Path $v3 'wiki/concepts/has-link.md')
    Assert-True (([regex]::Matches($c, 'my-thinking-has-link')).Count -eq 1) "exactly one link"

    Write-Host "[5b] an unknown name is skipped with a warning"
    $r = Run $v3 @('no-such-page')
    Assert-True ($r.Exit -eq 0 -and $r.Out -match "No concept page named 'no-such-page'") "warning, exit 0"
    Write-Host "[5c] the .md suffix is accepted"
    $v5 = New-Vault @{ 'with-suffix' = "# T`n" }
    $null = Run $v5 @('with-suffix.md')
    Assert-True (Test-Path -LiteralPath (Join-Path $v5 'wiki/my-thinking/my-thinking-with-suffix.md')) "stub created for 'with-suffix.md'"

    Write-Host "[6] no concepts folder: exit 0, nothing created"
    $v4 = Join-Path $script:tempRoot 'Bare'; New-Item -ItemType Directory -Force -Path $v4 | Out-Null
    $r = Run $v4 @('x')
    Assert-True ($r.Exit -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $v4 'wiki/my-thinking'))) "exit 0, no folder created"
}
finally { Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "=== Summary: $($script:pass) passed, $($script:fail) failed ==="
if ($script:fail -gt 0) { exit 1 }
