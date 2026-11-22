<#
.SYNOPSIS
Behavioural tests for agent/scripts/repair-stale-manifest-paths.ps1. Disposable temp vault
only: no Claude, no network, no vault data.
Run: pwsh -NoProfile -File agent/tests/repair-stale-manifest-paths-test.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepoRoot 'agent/scripts/repair-stale-manifest-paths.ps1'
if (-not (Test-Path -LiteralPath $Script)) { throw "Required file not found: $Script" }

$script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wikiagent-pathfix-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $script:tempRoot | Out-Null
$script:pass = 0; $script:fail = 0
function Assert-True { param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:pass++; Write-Host "  PASS: $Message" } else { $script:fail++; Write-Host "  FAIL: $Message" -ForegroundColor Red; Write-Host "::error::FAIL $($Message -replace '[
]+',' ')" } }

$header = 'video_id,title,source_type,transcript_status,transcript_attempts,clean_status,clean_transcript_file,source_status,source_file,source_created,ingest_status,synthesis_status,synthesis_last_checked,synthesis_evidence,synthesis_batch,checksum,last_updated'
$VaultName = 'PathFixVault'
$v = Join-Path $script:tempRoot $VaultName
foreach ($d in 'working/temp/clean_transcripts', 'wiki/sources') { New-Item -ItemType Directory -Force -Path (Join-Path $v $d) | Out-Null }

function New-Page { param([string]$Name, [string]$VideoId)
    "---`nvideo_id: `"$VideoId`"`ntype: source`n---`nbody`n" | Out-File -LiteralPath (Join-Path $v "wiki/sources/$Name.md") -Encoding utf8 }
function New-Clean { param([string]$Name) 'clean text' | Out-File -LiteralPath (Join-Path $v "working/temp/clean_transcripts/$Name.txt") -Encoding utf8 }
$old = "/home/ubuntu/test-multivault/vaults/$VaultName"
function Row { param($Id, $Src, $Clean, $Ingest = 'pending', $Synth = 'included')
    "$Id,Title $Id,youtube,downloaded,0,clean_ready,$Clean,source_created,$Src,2026-01-01T00:00:00Z,$Ingest,$Synth,,,,," }
function Get-Manifest { @(Import-Csv -LiteralPath (Join-Path $v 'working/manifest.csv')) }
function Get-Row($Id) { Get-Manifest | Where-Object { $_.video_id -eq $Id } | Select-Object -First 1 }
function Run($Extra = @()) { $out = & pwsh -NoProfile -File $Script -VaultRoot $v @Extra 2>&1 | Out-String; [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out } }

try {
    # A: fully repairable. B: stale, target missing. C: already live. D: page names another id. E: not included.
    New-Page 'a' 'AAA'; New-Clean 'a'
    New-Page 'd' 'OTHER'; New-Clean 'd'
    New-Page 'e' 'EEE'; New-Clean 'e'
    New-Page 'c' 'CCC'; New-Clean 'c'
    $rows = @(
        (Row 'AAA' "$old/wiki/sources/a.md" "$old/working/temp/clean_transcripts/a.txt"),
        (Row 'BBB' "$old/wiki/sources/b.md" "$old/working/temp/clean_transcripts/b.txt"),
        (Row 'CCC' (Join-Path $v 'wiki/sources/c.md') (Join-Path $v 'working/temp/clean_transcripts/c.txt') 'ingested'),
        (Row 'DDD' "$old/wiki/sources/d.md" "$old/working/temp/clean_transcripts/d.txt"),
        (Row 'EEE' "$old/wiki/sources/e.md" "$old/working/temp/clean_transcripts/e.txt" 'pending' 'pending')
    )
    (@($header) + $rows) -join "`n" | Out-File -LiteralPath (Join-Path $v 'working/manifest.csv') -Encoding utf8
    $before = (Get-FileHash -LiteralPath (Join-Path $v 'working/manifest.csv')).Hash

    Write-Host "[1] dry run reports and changes nothing"
    $r = Run
    Assert-True ($r.Exit -eq 0) "exit 0"
    Assert-True ($r.Out -match 'DRY RUN') "says dry run"
    Assert-True ($r.Out -match 'Rows to repair: 3') "3 rows repairable (A, D, E) (got: $(($r.Out -split "`n" | Where-Object { $_ -match 'Rows to repair' }) -join ''))"
    Assert-True ($r.Out -match 'BBB') "names BBB as unresolved"
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $v 'working/manifest.csv')).Hash -eq $before) "manifest byte-identical"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $v 'working') -Filter 'manifest.csv.bak_pathfix_*').Count -eq 0) "no backup made on a dry run"

    Write-Host "[2] -Apply refuses while the run lock exists"
    $lockDir = Join-Path $RepoRoot 'agent/scheduling/locks'
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
    $lock = Join-Path $lockDir "$VaultName.lock"
    '999999' | Out-File -LiteralPath $lock -Encoding ascii
    $r = Run @('-Apply')
    Remove-Item -LiteralPath $lock -Force
    Assert-True ($r.Exit -ne 0 -and $r.Out -match 'lock') "refused with a lock message"
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $v 'working/manifest.csv')).Hash -eq $before) "manifest unchanged"

    Write-Host "[3] -Apply repairs, backs up, leaves the rest"
    $r = Run @('-Apply')
    Assert-True ($r.Exit -eq 0 -and $r.Out -match 'Repaired 3') "repaired 3 rows"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $v 'working') -Filter 'manifest.csv.bak_pathfix_*').Count -eq 1) "one backup written"
    $a = Get-Row 'AAA'
    Assert-True ($a.source_file -eq (Join-Path $v 'wiki/sources/a.md')) "AAA source_file re-rooted"
    Assert-True ($a.clean_transcript_file -eq (Join-Path $v 'working/temp/clean_transcripts/a.txt')) "AAA clean_transcript_file re-rooted"
    Assert-True ($a.ingest_status -eq 'ingested') "AAA ingest_status -> ingested"
    $b = Get-Row 'BBB'
    Assert-True ($b.source_file -like "$old*" -and $b.ingest_status -eq 'pending') "BBB (target missing) untouched"
    $c = Get-Row 'CCC'
    Assert-True ($c.last_updated -eq '' -and $c.ingest_status -eq 'ingested') "CCC (already live) untouched"
    $d = Get-Row 'DDD'
    Assert-True ($d.source_file -eq (Join-Path $v 'wiki/sources/d.md') -and $d.ingest_status -eq 'pending') "DDD paths fixed but ingest_status stays pending (page names another id)"
    $e = Get-Row 'EEE'
    Assert-True ($e.source_file -eq (Join-Path $v 'wiki/sources/e.md') -and $e.ingest_status -eq 'pending' -and $e.synthesis_status -eq 'pending') "EEE paths fixed, ingest_status and synthesis_status unchanged (not included)"
    Assert-True ((Get-Manifest).Count -eq 5) "still 5 rows"

    Write-Host "[4] second run finds nothing to repair"
    $r = Run @('-Apply')
    Assert-True ($r.Out -match 'Nothing to repair') "idempotent"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $v 'working') -Filter 'manifest.csv.bak_pathfix_*').Count -eq 1) "no second backup"
}
finally {
    Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== Summary: $($script:pass) passed, $($script:fail) failed ==="
if ($script:fail -gt 0) { exit 1 }
