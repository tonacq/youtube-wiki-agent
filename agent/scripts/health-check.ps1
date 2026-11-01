<#
.SYNOPSIS
System-level health check, run by the hourly dispatcher once a day. Daily mode alerts only
when there is a problem; Weekly mode also sends a short heartbeat so silence can be told
apart from a dead VM, timer or Telegram link.

.DESCRIPTION
Checks, in order:
  1. Claude Code login, via `claude auth status --json` (no model call, no usage spent),
     under a 30-second timeout.
       OK          - parsed "loggedIn": true
       LOGGED_OUT  - parsed "loggedIn": false
       UNVERIFIED  - claude not found, timed out, unparseable output, or no loggedIn field
  2. Weekly mode only: for every vault with at least one enabled row in schedule.csv, the
     manifest totals and the newest dispatch log's PIPELINE_RESULT line.

Notifications (via send-notification.ps1):
  - LOGGED_OUT or UNVERIFIED: an AuthAlert, in both modes. Sent every day the problem
    persists.
  - Weekly mode: a Heartbeat, whatever the auth status.
  - Daily mode with auth OK: nothing is sent.

Credentials are resolved by send-notification.ps1 exactly as for a vault run, using the
first enabled vault in schedule.csv (vault-local config/secrets.env, then
agent/secrets.env). With no enabled vault, vaults/_template is passed, so only
agent/secrets.env can apply.

Never throws and always exits 0: a health-check failure must never affect vault runs.

Test-only hook: WIKIAGENT_MOCK_CLAUDE_SCRIPT replaces the `claude` command, as in
run-claude-synthesis.ps1.

.EXAMPLE
pwsh agent/scripts/health-check.ps1 -Mode Daily

.EXAMPLE
pwsh agent/scripts/health-check.ps1 -Mode Weekly
#>

[CmdletBinding()]
param(
    [ValidateSet('Daily', 'Weekly')][string]$Mode = 'Daily',
    # Root of the deployment (the folder holding agent/ and vaults/). Defaults to the
    # deployment this script belongs to; tests pass a disposable temp root.
    [string]$RootPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$AgentScripts = $PSScriptRoot
if (-not $RootPath) { $RootPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$scheduleCsv = Join-Path $RootPath 'agent/scheduling/schedule.csv'
$dispatchLogDir = Join-Path $RootPath 'agent/scheduling/dispatch-logs'
$vaultsDir = Join-Path $RootPath 'vaults'

$localBin = Join-Path $HOME '.local/bin'
if ($env:PATH -notlike "*$localBin*") { $env:PATH = "${localBin}:$env:PATH" }

$claudeCommand = if ($env:WIKIAGENT_MOCK_CLAUDE_SCRIPT) { $env:WIKIAGENT_MOCK_CLAUDE_SCRIPT } else { 'claude' }

function Get-AuthState {
    param([string]$ClaudeCmd, [int]$TimeoutSeconds = 30)
    if (-not (Get-Command $ClaudeCmd -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ State = 'UNVERIFIED'; Detail = "'$ClaudeCmd' not found on PATH." }
    }
    try {
        $job = Start-Job -ScriptBlock {
            param($cmd)
            $out = & $cmd auth status --json 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
        } -ArgumentList $ClaudeCmd
        $done = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $done) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ State = 'UNVERIFIED'; Detail = "'claude auth status' did not respond within ${TimeoutSeconds}s." }
        }
        $r = Receive-Job -Job $job
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        try { $parsed = $r.Output | ConvertFrom-Json -ErrorAction Stop } catch {
            return [pscustomobject]@{ State = 'UNVERIFIED'; Detail = "'claude auth status' output was not JSON (exit $($r.ExitCode))." }
        }
        if ($parsed.PSObject.Properties['loggedIn'] -and $parsed.loggedIn -eq $true) {
            $sub = if ($parsed.PSObject.Properties['subscriptionType']) { $parsed.subscriptionType } else { 'n/a' }
            return [pscustomobject]@{ State = 'OK'; Detail = "logged in (authMethod=$($parsed.authMethod), subscription=$sub)" }
        }
        if ($parsed.PSObject.Properties['loggedIn'] -and $parsed.loggedIn -eq $false) {
            return [pscustomobject]@{ State = 'LOGGED_OUT'; Detail = "logged out (authMethod=$($parsed.authMethod))" }
        }
        return [pscustomobject]@{ State = 'UNVERIFIED'; Detail = "'claude auth status' output had no loggedIn field." }
    } catch {
        return [pscustomobject]@{ State = 'UNVERIFIED'; Detail = "auth check threw: $($_.Exception.Message)" }
    }
}

# Enabled vaults, in schedule.csv order, de-duplicated (a vault can have several rows).
$enabledVaults = [System.Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $scheduleCsv) {
    try {
        # The real schedule.csv is self-documenting: '#' comment lines may sit above the
        # header row. Drop them (and blank lines) before parsing as CSV.
        $csvLines = @(Get-Content -LiteralPath $scheduleCsv | Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') })
        foreach ($row in @($csvLines | ConvertFrom-Csv)) {
            if (-not $row.PSObject.Properties['vault_name'] -or -not $row.PSObject.Properties['enabled']) { continue }
            $name = ([string]$row.vault_name).Trim()
            if (([string]$row.enabled).Trim() -ne 'true' -or -not $name -or $name -eq '_template') { continue }
            if (-not $enabledVaults.Contains($name)) { $enabledVaults.Add($name) }
        }
    } catch {
        Write-Warning "Could not read schedule.csv: $($_.Exception.Message)"
    }
}

$notifyVaultRoot = Join-Path $vaultsDir '_template'
foreach ($name in $enabledVaults) {
    $candidate = Join-Path $vaultsDir $name
    if (Test-Path -LiteralPath $candidate) { $notifyVaultRoot = $candidate; break }
}

function Send-Health {
    param([string]$Event, [string]$Detail)
    try {
        & (Join-Path $AgentScripts 'send-notification.ps1') -VaultRoot $notifyVaultRoot -Event $Event -Detail $Detail
    } catch {
        Write-Warning "Health notification failed (non-fatal): $($_.Exception.Message)"
    }
}

$auth = Get-AuthState -ClaudeCmd $claudeCommand
Write-Host "HEALTH_AUTH: $($auth.State) - $($auth.Detail)"

if ($auth.State -eq 'LOGGED_OUT') {
    Send-Health -Event 'AuthAlert' -Detail "Claude Code is logged out on the VM; scheduled synthesis will not run until you log in. Fix: on the VM run 'claude auth login', then confirm with 'claude auth status --json'. ($($auth.Detail))"
} elseif ($auth.State -eq 'UNVERIFIED') {
    Send-Health -Event 'AuthAlert' -Detail "the daily health check could not confirm the Claude Code login: $($auth.Detail) Check on the VM with 'claude auth status --json'."
}

if ($Mode -eq 'Weekly') {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Claude login: $($auth.State) - $($auth.Detail)")
    if ($enabledVaults.Count -eq 0) {
        $lines.Add("Scheduled vaults: none enabled in schedule.csv.")
    }
    foreach ($name in $enabledVaults) {
        $vaultPath = Join-Path $vaultsDir $name
        $manifestPath = Join-Path $vaultPath 'working/manifest.csv'
        $counts = 'manifest not found'
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $rows = @(Import-Csv -LiteralPath $manifestPath)
                $included = @($rows | Where-Object { $_.synthesis_status -eq 'included' }).Count
                $backlog = @($rows | Where-Object { $_.ingest_status -eq 'ingested' -and ($_.synthesis_status -eq 'pending' -or $_.synthesis_status -eq 'partial') }).Count
                $counts = "$included of $($rows.Count) synthesised, backlog $backlog"
            } catch {
                $counts = "manifest unreadable: $($_.Exception.Message)"
            }
        }
        $lastRun = 'no dispatch log found'
        if (Test-Path -LiteralPath $dispatchLogDir) {
            $newest = Get-ChildItem -LiteralPath $dispatchLogDir -Filter "${name}_*.log" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) {
                $resultLine = Select-String -LiteralPath $newest.FullName -Pattern '^PIPELINE_RESULT:\s*(\S+)' -ErrorAction SilentlyContinue | Select-Object -Last 1
                $resultText = if ($resultLine) { $resultLine.Matches[0].Groups[1].Value } else { 'no PIPELINE_RESULT line' }
                $lastRun = "last run $($newest.LastWriteTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC: $resultText"
            }
        }
        $lines.Add("${name}: $counts; $lastRun")
    }
    Send-Health -Event 'Heartbeat' -Detail ($lines -join "`n")
}

Write-Host "HEALTH_CHECK_DONE: mode=$Mode auth=$($auth.State) vaults=$($enabledVaults.Count)"
exit 0
