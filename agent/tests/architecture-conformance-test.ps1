<#
.SYNOPSIS
Validates a WikiAgent installation or release package against Folder Structure v1.0.

.DESCRIPTION
This is the mandatory architecture gate (ADR-007). It checks:
- required root directories and files;
- prohibited top-level operational directories;
- required shared scripts and scheduler assets;
- the canonical vault template;
- each deployed vault's required structure;
- obsolete path terminology (engine/, runtime/ at root, etc.) in text/script files.

Returns exit code 0 on PASS and 1 on FAIL. Writes a JSON report if -ReportPath is given.

.EXAMPLE
pwsh agent/tests/architecture-conformance-test.ps1 -RootPath /home/ubuntu/WikiAgent
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [string]$ReportPath,
    [switch]$SkipContentScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path
$failures = [System.Collections.Generic.List[object]]::new()
$passes   = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([bool]$Passed, [string]$Check, [string]$Path, [string]$Detail)
    $entry = [pscustomobject]@{ passed = $Passed; check = $Check; path = $Path; detail = $Detail }
    if ($Passed) { $passes.Add($entry) } else { $failures.Add($entry) }
}

function Test-RequiredDirectory {
    param([string]$RelativePath)
    $full = Join-Path $resolvedRoot $RelativePath
    Add-Result -Passed (Test-Path -LiteralPath $full -PathType Container) `
        -Check 'required-directory' -Path $RelativePath -Detail 'Required directory must exist.'
}

function Test-RequiredFile {
    param([string]$RelativePath)
    $full = Join-Path $resolvedRoot $RelativePath
    Add-Result -Passed (Test-Path -LiteralPath $full -PathType Leaf) `
        -Check 'required-file' -Path $RelativePath -Detail 'Required file must exist.'
}

$requiredDirectories = @(
    'agent', 'agent/scripts', 'agent/scheduling', 'agent/scheduling/ubuntu',
    'agent/scheduling/ubuntu/systemd', 'agent/docs', 'agent/tests',
    'vaults', 'vaults/_template'
)

$requiredFiles = @(
    'agent/scripts/run-vault.ps1', 'agent/scripts/ingest-youtube.ps1',
    'agent/scripts/ingest-documents.ps1', 'agent/scripts/create-source-pages.ps1',
    'agent/scripts/run-claude-synthesis.ps1', 'agent/scripts/run-qa.ps1',
    'agent/scripts/backup-vault.ps1', 'agent/scheduling/schedule.csv.example',
    'agent/scheduling/ubuntu/run-wikiagent.sh',
    'agent/scheduling/ubuntu/systemd/wikiagent.service',
    'agent/scheduling/ubuntu/systemd/wikiagent.timer'
)

$prohibitedRootDirectories = @(
    'engine', 'baseline', 'runtime', 'logs', 'systemd', 'tests', 'docs',
    'provenance', 'wikis', 'wiki-template'
)

$vaultDirectories = @(
    'config', 'config/prompts', 'input', 'working', 'working/batches', 'working/temp',
    'wiki', 'wiki/sources', 'wiki/concepts', 'wiki/tools', 'wiki/workflows', 'wiki/synthesis',
    'logs', 'exports', 'archive'
)

$vaultFiles = @('config/vault.json', 'config/claude.md', 'working/manifest.csv')

foreach ($path in $requiredDirectories) { Test-RequiredDirectory $path }
foreach ($path in $requiredFiles) { Test-RequiredFile $path }

foreach ($name in $prohibitedRootDirectories) {
    $full = Join-Path $resolvedRoot $name
    Add-Result -Passed (-not (Test-Path -LiteralPath $full -PathType Container)) `
        -Check 'prohibited-root-directory' -Path $name `
        -Detail 'Superseded or unapproved top-level operational directory must not exist.'
}

$templateRoot = Join-Path $resolvedRoot 'vaults/_template'
foreach ($path in $vaultDirectories) {
    $full = Join-Path $templateRoot $path
    Add-Result -Passed (Test-Path -LiteralPath $full -PathType Container) `
        -Check 'template-directory' -Path "vaults/_template/$path" -Detail 'Canonical template directory must exist.'
}
foreach ($path in $vaultFiles) {
    $full = Join-Path $templateRoot $path
    Add-Result -Passed (Test-Path -LiteralPath $full -PathType Leaf) `
        -Check 'template-file' -Path "vaults/_template/$path" -Detail 'Canonical template file must exist.'
}

$vaultRoot = Join-Path $resolvedRoot 'vaults'
if (Test-Path -LiteralPath $vaultRoot -PathType Container) {
    $deployedVaults = Get-ChildItem -LiteralPath $vaultRoot -Directory | Where-Object { $_.Name -ne '_template' }
    foreach ($vault in $deployedVaults) {
        foreach ($path in $vaultDirectories) {
            $full = Join-Path $vault.FullName $path
            Add-Result -Passed (Test-Path -LiteralPath $full -PathType Container) `
                -Check 'vault-directory' -Path "vaults/$($vault.Name)/$path" `
                -Detail 'Every deployed vault must implement the standard vault structure.'
        }
        foreach ($path in $vaultFiles) {
            $full = Join-Path $vault.FullName $path
            Add-Result -Passed (Test-Path -LiteralPath $full -PathType Leaf) `
                -Check 'vault-file' -Path "vaults/$($vault.Name)/$path" `
                -Detail 'Every deployed vault must contain required config/manifest files.'
        }
    }
}

if (-not $SkipContentScan) {
    $obsoleteTerms = @('engine/', 'top-level runtime/', 'baseline/vm-live', 'provenance/')
    Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.ps1', '.sh', '.py', '.md', '.json', '.csv' -and $_.FullName -notmatch '\.git[/\\]' -and $_.FullName -ne $PSCommandPath } |
        ForEach-Object {
            $text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
            if ($text -and $text -match 'engine/scripts|top-level runtime|/baseline/|/provenance/') {
                Add-Result -Passed $false -Check 'obsolete-path-reference' -Path $_.FullName.Substring($resolvedRoot.Length + 1) `
                    -Detail 'File references superseded path terminology (engine/, runtime/, baseline/, provenance/).'
            }
        }
}

$status = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
$report = [ordered]@{
    specification  = 'WikiAgent Folder Structure v1.0'
    rootPath       = $resolvedRoot
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    status         = $status
    passCount      = $passes.Count
    failureCount   = $failures.Count
    failures       = $failures
}

if ($ReportPath) { $report | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $ReportPath -Encoding utf8 }

Write-Host "Architecture conformance: $status ($($passes.Count) passed, $($failures.Count) failed)"
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  FAIL [$($_.check)] $($_.path)" }
    exit 1
}
exit 0
