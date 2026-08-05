<#
.SYNOPSIS
Sends a Telegram notification for one of four events, matching the proven pattern
from run_nate_herk_weekly.sh: a run that couldn't start (lock contention), a run that
failed mid-pipeline, a run that completed with real synthesis work done, or a run that
completed with nothing to do.

.DESCRIPTION
Credentials: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID. Resolved in this order:
  1. Already-set process environment variables (useful for systemd Environment= or CI).
  2. A vault-local secrets file: <VaultRoot>/config/secrets.env
  3. A shared agent-level secrets file: agent/secrets.env
This mirrors the proven pattern of sourcing TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID from
$ROOT/secrets/.env, but allows a per-vault override since a multi-vault setup may want
different bots/chats per vault.

Never throws — a notification failure must never fail the pipeline run itself.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [Parameter(Mandatory = $true)][ValidateSet('Blocked', 'Failed', 'Success', 'NoChange', 'PartialSuccess')][string]$Event,
    [string]$ExitCode,
    [string]$LogFile,
    [string]$Stats,
    [string]$Detail
)

$ErrorActionPreference = 'Continue'
$vaultName = Split-Path -Leaf $VaultRoot

function Import-DotEnv($path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    Get-Content -LiteralPath $path | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$' -and $_ -notmatch '^\s*#') {
            $name = $Matches[1]; $value = $Matches[2].Trim('"').Trim("'")
            if (-not (Test-Path "Env:$name")) { Set-Item -Path "Env:$name" -Value $value }
        }
    }
}

if (-not $env:TELEGRAM_BOT_TOKEN -or -not $env:TELEGRAM_CHAT_ID) {
    Import-DotEnv (Join-Path $VaultRoot 'config/secrets.env')
}
if (-not $env:TELEGRAM_BOT_TOKEN -or -not $env:TELEGRAM_CHAT_ID) {
    $agentRoot = Split-Path -Parent $PSScriptRoot
    Import-DotEnv (Join-Path $agentRoot 'secrets.env')
}

if (-not $env:TELEGRAM_BOT_TOKEN -or -not $env:TELEGRAM_CHAT_ID) {
    Write-Host "Telegram not configured (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID); skipping notification."
    return
}

$now = (Get-Date).ToString('o')
$message = switch ($Event) {
    'Blocked' {
        "Wiki pipeline did not start for ${vaultName}: another run is already active. Time: $now"
    }
    'Failed' {
        "Wiki pipeline FAILED for ${vaultName}. Exit code: $ExitCode. Time: $now. Log: $LogFile. Failed stages: $Detail. Stats: $Stats"
    }
    'PartialSuccess' {
        "Wiki pipeline completed for ${vaultName} - real content work succeeded; a non-critical stage had an issue and needs attention. Time: $now. Log: $LogFile. Non-critical issue: $Detail. Stats: $Stats"
    }
    'Success' {
        "Wiki pipeline completed successfully for ${vaultName}. Time: $now. Log: $LogFile. Stats: $Stats"
    }
    'NoChange' {
        "Wiki pipeline ran for ${vaultName} - nothing to do, no changes made. Time: $now. Log: $LogFile. Stats: $Stats"
    }
}

try {
    $uri = "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage"
    Invoke-RestMethod -Uri $uri -Method Post -Body @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $message } | Out-Null
} catch {
    Write-Warning "Notification send failed (non-fatal): $($_.Exception.Message)"
}
