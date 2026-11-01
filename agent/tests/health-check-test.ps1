<#
.SYNOPSIS
Behavioural tests for the login alerting: agent/scripts/health-check.ps1 (daily check and
weekly heartbeat), the AuthAlert sent by agent/scripts/run-vault.ps1, and the
WIKIAGENT_NOTIFY_CAPTURE_FILE hook in agent/scripts/send-notification.ps1.

.DESCRIPTION
Uses agent/tests/fixtures/mock-claude.ps1 (WIKIAGENT_MOCK_CLAUDE_SCRIPT) for the login
state, and WIKIAGENT_NOTIFY_CAPTURE_FILE so every notification is written to a temp file
instead of being sent. No real Claude call, no usage spent, no Telegram message sent.
Every deployment root and vault is a disposable temp directory; nothing under vaults/ is
read or written.

No Pester dependency - plain assertions, PASS/FAIL output, exit 0/1, matching
agent/tests/run-claude-synthesis-test.ps1.

.EXAMPLE
pwsh agent/tests/health-check-test.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$HealthScript = Join-Path $RepoRoot 'agent/scripts/health-check.ps1'
$RunVaultScript = Join-Path $RepoRoot 'agent/scripts/run-vault.ps1'
$MockClaude = Join-Path $PSScriptRoot 'fixtures/mock-claude.ps1'
foreach ($p in @($HealthScript, $RunVaultScript, $MockClaude)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Required file not found: $p" }
}

$script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wikiagent-health-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $script:tempRoot | Out-Null
$script:passCount = 0
$script:failCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:passCount++; Write-Host "  PASS: $Message" }
    else { $script:failCount++; Write-Host "  FAIL: $Message" -ForegroundColor Red }
}

$testEnvVars = @('WIKIAGENT_MOCK_CLAUDE_SCRIPT', 'WIKIAGENT_TEST_AUTH_LOGGED_IN', 'WIKIAGENT_NOTIFY_CAPTURE_FILE')
function Clear-TestEnv { foreach ($v in $testEnvVars) { Remove-Item -Path "env:$v" -ErrorAction SilentlyContinue } }

$manifestHeader = 'video_id,title,source_type,transcript_status,clean_status,clean_transcript_file,source_status,source_file,source_created,ingest_status,synthesis_status,synthesis_last_checked,synthesis_evidence,synthesis_batch,checksum,last_updated'

function New-ManifestFile {
    param([string]$Path, [int]$Included, [int]$Pending, [int]$Partial = 0)
    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add($manifestHeader)
    $n = 0
    foreach ($spec in @(@('included', $Included), @('pending', $Pending), @('partial', $Partial))) {
        for ($i = 0; $i -lt $spec[1]; $i++) {
            $n++; $vid = "V{0:D3}" -f $n
            $rows.Add("$vid,Title $vid,document,n/a,clean_ready,,source_created,/fake/source_$vid.md,2026-01-01T00:00:00Z,ingested,$($spec[0]),,,,,2026-01-01T00:00:00Z")
        }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    ($rows -join "`n") | Out-File -LiteralPath $Path -Encoding utf8
}

# A disposable deployment root: agent/scheduling/schedule.csv, dispatch-logs, vaults/.
function New-TestRoot {
    param([string[]]$ScheduleRows)
    $root = Join-Path $script:tempRoot "root_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'agent/scheduling/dispatch-logs') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'vaults/_template') | Out-Null
    $csv = @('vault_name,job_type,day_of_week,time_utc,enabled,batch_size,batch_iterations,continuity') + $ScheduleRows
    ($csv -join "`n") | Out-File -LiteralPath (Join-Path $root 'agent/scheduling/schedule.csv') -Encoding utf8
    return $root
}

function Invoke-Health {
    param([string]$Root, [string]$Mode, [hashtable]$Env = @{})
    Clear-TestEnv
    $capture = Join-Path $script:tempRoot "capture_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    $env:WIKIAGENT_MOCK_CLAUDE_SCRIPT = $MockClaude
    $env:WIKIAGENT_NOTIFY_CAPTURE_FILE = $capture
    foreach ($k in $Env.Keys) { Set-Item -Path "env:$k" -Value $Env[$k] }
    $out = & pwsh -NoProfile -File $HealthScript -Mode $Mode -RootPath $Root 2>&1
    $exit = $LASTEXITCODE
    Clear-TestEnv
    [pscustomobject]@{ ExitCode = $exit; Output = ($out -join "`n"); Messages = @(Get-Captured $capture) }
}

# Parses the capture file into one object per notification: Event + Text.
function Get-Captured {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $items = [System.Collections.Generic.List[object]]::new()
    $evt = $null; $buf = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^Event=(.+)$' -and $null -eq $evt) { $evt = $Matches[1]; continue }
        if ($line -eq '---') {
            $items.Add([pscustomobject]@{ Event = $evt; Text = ($buf -join "`n") })
            $evt = $null; $buf = [System.Collections.Generic.List[string]]::new(); continue
        }
        $buf.Add($line)
    }
    return @($items)
}

function Get-EventCount { param($Messages, [string]$Name) @($Messages | Where-Object { $_.Event -eq $Name }).Count }
function Get-EventText { param($Messages, [string]$Name) (@($Messages | Where-Object { $_.Event -eq $Name }) | Select-Object -First 1).Text }

Write-Host "=== health-check / AuthAlert behavioural test suite ==="
Write-Host "Repo: $RepoRoot"
Write-Host "Temp: $script:tempRoot"
Write-Host ""

# Standard root for the health-check scenarios: VaultA enabled (2 rows), VaultB disabled.
$rootStd = New-TestRoot -ScheduleRows @('VaultA,full,Sun,15:00,true,10,12,true', 'VaultA,full,Mon,07:00,true,10,12,true', 'VaultB,full,Sat,18:00,false,,,')
New-ManifestFile -Path (Join-Path $rootStd 'vaults/VaultA/working/manifest.csv') -Included 7 -Pending 2 -Partial 1
New-ManifestFile -Path (Join-Path $rootStd 'vaults/VaultB/working/manifest.csv') -Included 1 -Pending 0
$logA = Join-Path $rootStd 'agent/scheduling/dispatch-logs/VaultA_full_20261026T070132Z.log'
@('Dispatching...', 'PIPELINE_RESULT: SYNTHESIS_PARTIAL (VaultA)') | Out-File -LiteralPath $logA -Encoding utf8

Write-Host "[1] Daily, logged in: nothing is sent"
$r = Invoke-Health -Root $rootStd -Mode Daily
Assert-True ($r.ExitCode -eq 0) "exit code is 0"
Assert-True ($r.Messages.Count -eq 0) "no notification sent (got $($r.Messages.Count))"
Assert-True ($r.Output -match 'HEALTH_AUTH: OK') "output records HEALTH_AUTH: OK"

Write-Host "[2] Daily, logged out: one AuthAlert, no heartbeat"
$r = Invoke-Health -Root $rootStd -Mode Daily -Env @{ WIKIAGENT_TEST_AUTH_LOGGED_IN = 'false' }
Assert-True ($r.ExitCode -eq 0) "exit code is 0"
Assert-True ((Get-EventCount $r.Messages 'AuthAlert') -eq 1) "exactly one AuthAlert"
Assert-True ((Get-EventCount $r.Messages 'Heartbeat') -eq 0) "no Heartbeat in Daily mode"
$t = Get-EventText $r.Messages 'AuthAlert'
Assert-True ($t -match '^\[ACTION REQUIRED\]') "AuthAlert starts with [ACTION REQUIRED]"
Assert-True ($t -match 'logged out') "AuthAlert says logged out"
Assert-True ($t -match 'claude auth login') "AuthAlert gives the fix command"

Write-Host "[3] Weekly, logged in: heartbeat only, with per-vault lines for enabled vaults"
$r = Invoke-Health -Root $rootStd -Mode Weekly
Assert-True ((Get-EventCount $r.Messages 'AuthAlert') -eq 0) "no AuthAlert"
Assert-True ((Get-EventCount $r.Messages 'Heartbeat') -eq 1) "exactly one Heartbeat"
$t = Get-EventText $r.Messages 'Heartbeat'
Assert-True ($t -match 'WikiAgent weekly heartbeat') "Heartbeat has its heading"
Assert-True ($t -match 'Claude login: OK') "Heartbeat reports login OK"
Assert-True ($t -match 'VaultA: 7 of 10 synthesised, backlog 3') "VaultA counts: 7 of 10, backlog 3 (pending + partial)"
Assert-True ($t -match 'VaultA: .*SYNTHESIS_PARTIAL') "VaultA line carries the last PIPELINE_RESULT"
Assert-True (([regex]::Matches($t, '(?m)^VaultA:')).Count -eq 1) "VaultA listed once despite two schedule rows"
Assert-True ($t -notmatch 'VaultB') "disabled VaultB not listed"

Write-Host "[4] Weekly, logged out: AuthAlert and Heartbeat"
$r = Invoke-Health -Root $rootStd -Mode Weekly -Env @{ WIKIAGENT_TEST_AUTH_LOGGED_IN = 'false' }
Assert-True ((Get-EventCount $r.Messages 'AuthAlert') -eq 1) "one AuthAlert"
Assert-True ((Get-EventCount $r.Messages 'Heartbeat') -eq 1) "one Heartbeat"
Assert-True ((Get-EventText $r.Messages 'Heartbeat') -match 'Claude login: LOGGED_OUT') "Heartbeat reports LOGGED_OUT"

Write-Host "[5] Claude command not found: AuthAlert says the login could not be confirmed"
$r = Invoke-Health -Root $rootStd -Mode Daily -Env @{ WIKIAGENT_MOCK_CLAUDE_SCRIPT = (Join-Path $script:tempRoot 'no-such-claude') }
Assert-True ($r.ExitCode -eq 0) "exit code is 0"
Assert-True ((Get-EventCount $r.Messages 'AuthAlert') -eq 1) "one AuthAlert"
Assert-True ((Get-EventText $r.Messages 'AuthAlert') -match 'could not confirm') "AuthAlert says it could not confirm the login"
Assert-True ($r.Output -match 'HEALTH_AUTH: UNVERIFIED') "output records UNVERIFIED"

Write-Host "[6] No enabled vaults, no dispatch logs: heartbeat still sent"
$rootEmpty = New-TestRoot -ScheduleRows @('VaultB,full,Sat,18:00,false,,,')
$r = Invoke-Health -Root $rootEmpty -Mode Weekly
Assert-True ($r.ExitCode -eq 0) "exit code is 0"
Assert-True ((Get-EventCount $r.Messages 'Heartbeat') -eq 1) "one Heartbeat"
Assert-True ((Get-EventText $r.Messages 'Heartbeat') -match 'none enabled') "Heartbeat says no vaults are enabled"

Write-Host "[7] Enabled vault with no manifest and no dispatch log: reported, not fatal"
$rootBare = New-TestRoot -ScheduleRows @('VaultC,full,Sun,15:00,true,,,')
New-Item -ItemType Directory -Force -Path (Join-Path $rootBare 'vaults/VaultC') | Out-Null
$r = Invoke-Health -Root $rootBare -Mode Weekly
$t = Get-EventText $r.Messages 'Heartbeat'
Assert-True ($r.ExitCode -eq 0) "exit code is 0"
Assert-True ($t -match 'VaultC: manifest not found; no dispatch log found') "VaultC line reports both gaps"

# --- run-vault.ps1 AuthAlert -----------------------------------------------------------
function New-RunVault {
    param([int]$Included, [int]$Pending)
    $vaultRoot = Join-Path $script:tempRoot "HealthTestVault_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    # Same folder set as vaults/_template: run-qa.ps1 expects the wiki/ subfolders to exist.
    foreach ($d in @('config', 'config/prompts', 'input', 'working/batches', 'working/temp', 'wiki/sources', 'wiki/concepts', 'wiki/tools', 'wiki/workflows', 'wiki/synthesis', 'logs', 'exports', 'archive', 'reports')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $vaultRoot $d) | Out-Null
    }
    [ordered]@{
        vault_name = 'HealthTestVault'; channel_url = ''; drive_remote = ''; drive_path = ''
        batch_size = 3; batch_iterations = 1; continuity = $false; claude_call_timeout_seconds = 10
        backup = @{ enabled = $false }
    } | ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $vaultRoot 'config/vault.json') -Encoding utf8
    "# test placeholder" | Out-File -LiteralPath (Join-Path $vaultRoot 'config/claude.md') -Encoding utf8
    New-ManifestFile -Path (Join-Path $vaultRoot 'working/manifest.csv') -Included $Included -Pending $Pending
    return $vaultRoot
}

function Invoke-RunVault {
    param([string]$VaultRoot, [string[]]$ExtraArgs = @(), [hashtable]$Env = @{})
    Clear-TestEnv
    $capture = Join-Path $script:tempRoot "capture_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    $env:WIKIAGENT_MOCK_CLAUDE_SCRIPT = $MockClaude
    $env:WIKIAGENT_NOTIFY_CAPTURE_FILE = $capture
    foreach ($k in $Env.Keys) { Set-Item -Path "env:$k" -Value $Env[$k] }
    $runArgs = @('-VaultRoot', $VaultRoot, '-JobType', 'full', '-SkipYoutube', '-SkipClean', '-SkipDocuments', '-SkipBackup') + $ExtraArgs
    $out = & pwsh -NoProfile -File $RunVaultScript @runArgs 2>&1
    $exit = $LASTEXITCODE
    Clear-TestEnv
    $text = ($out -join "`n")
    $runLog = Get-ChildItem -LiteralPath (Join-Path $VaultRoot 'logs') -Filter 'run_*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($runLog) { Write-Host "    stages: $((Get-Content -LiteralPath $runLog.FullName -Raw | ConvertFrom-Json).stages | ConvertTo-Json -Compress)" }
    [pscustomobject]@{ ExitCode = $exit; Output = $text; Messages = @(Get-Captured $capture) }
}

Write-Host "[8] run-vault, logged out: separate AuthAlert sent before the RunSummary"
$v8 = New-RunVault -Included 0 -Pending 3
$r = Invoke-RunVault -VaultRoot $v8 -Env @{ WIKIAGENT_TEST_AUTH_LOGGED_IN = 'false' }
Assert-True ($r.Output -match 'PIPELINE_RESULT: AUTH_REQUIRED') "run ends PIPELINE_RESULT: AUTH_REQUIRED"
Assert-True ((Get-EventCount $r.Messages 'AuthAlert') -eq 1) "exactly one AuthAlert"
Assert-True ((Get-EventCount $r.Messages 'RunSummary') -eq 1) "RunSummary still sent"
$order = @($r.Messages | ForEach-Object { $_.Event })
Assert-True ($order.Count -ge 2 -and $order[0] -eq 'AuthAlert' -and $order[-1] -eq 'RunSummary') "AuthAlert comes before RunSummary (order: $($order -join ', '))"
Assert-True ((Get-EventText $r.Messages 'AuthAlert') -match 'synthesis for HealthTestVault_[0-9a-f]{8} did not run') "AuthAlert names the vault"

Write-Host "[9] run-vault, logged in with nothing pending: no AuthAlert"
$v9 = New-RunVault -Included 3 -Pending 0
$r = Invoke-RunVault -VaultRoot $v9
Assert-True ((Get-EventCount $r.Messages 'AuthAlert') -eq 0) "no AuthAlert"
Assert-True ((Get-EventCount $r.Messages 'RunSummary') -eq 1) "RunSummary sent"

Write-Host "[10] run-vault, stale AUTH_REQUIRED result from an earlier run, synthesis skipped: no AuthAlert"
$v10 = New-RunVault -Included 0 -Pending 3
[ordered]@{ reasonCode = 'AUTH_REQUIRED'; actualSynthesized = 0; targetThisRun = 3; timestamp = '2026-01-01T00:00:00.0000000+00:00' } |
    ConvertTo-Json | Out-File -LiteralPath (Join-Path $v10 'working/temp/synthesis-run-result.json') -Encoding utf8
$r = Invoke-RunVault -VaultRoot $v10 -ExtraArgs @('-SkipClaude')
Assert-True ((Get-EventCount $r.Messages 'AuthAlert') -eq 0) "no AuthAlert for a stale result"

Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Summary: $($script:passCount) passed, $($script:failCount) failed ==="
if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
