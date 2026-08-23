<#
.SYNOPSIS
Sends a Telegram notification for one of six events, matching the proven pattern
from run_nate_herk_weekly.sh: a run that couldn't start (lock contention), a run that
failed mid-pipeline outside the reason-coded stages, a run that completed with real
synthesis work done, a run that completed with nothing to do, a run whose non-critical
stage had an issue, or (new) a full-pipeline run summary carrying one of the
ingestion/synthesis reason codes plus the backlog-aware stats block.

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
    [Parameter(Mandatory = $true)][ValidateSet('Blocked', 'Failed', 'Success', 'NoChange', 'PartialSuccess', 'RunSummary')][string]$Event,
    [string]$ExitCode,
    [string]$LogFile,
    [string]$Stats,
    [string]$Detail,
    [string]$ReasonCode
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
    'RunSummary' {
        $s = $null
        try { $s = $Stats | ConvertFrom-Json } catch { }
        $reasonText = if ($ReasonCode) { $ReasonCode } else { 'N/A' }
        # SYNTHESIS_PARTIAL gets a plain-language qualifier inline with the reason line
        # itself, not just the bare code - added following the 2026-08-24
        # SabrinaRamonov_Rev00 incident, where a bare "Reason: TARGET_MET" next to
        # "Actual synthesised: 18" (of a "Target this run: 20") gave no indication
        # anything had gone wrong.
        if ($ReasonCode -eq 'SYNTHESIS_PARTIAL') {
            $reasonText = "$ReasonCode (one or more synthesis batches returned fewer results than sources sent - some sources may need attention; see dropped sources below)"
        }
        $lines = @(
            "Wiki pipeline run summary for ${vaultName}. Time: $now.",
            "Reason: $reasonText",
            "Target this run: $($s.targetThisRun) synthesised",
            "Actual synthesised: $($s.actualSynthesized)",
            "Backlog (downloaded, not yet synthesised): $($s.backlog)",
            "Channel catalogue: $($s.catalogueCount) total",
            "% channel reviewed: $($s.pctReviewed)",
            "% curated: $($s.pctCurated)",
            "% retry - blocked: $($s.pctRetryBlocked)",
            "% retry - awaiting captions: $($s.pctRetryAwaiting)",
            "% retry - other: $($s.pctRetryOther)",
            "% parked/failed: $($s.pctParkedFailed)",
            "Batch config: size=$($s.batchSize), iterations=$($s.batchIterations), continuity=$($s.continuity)",
            "Log: $LogFile"
        )
        # Dropped-source detail (video IDs and titles, not just a count) - only rendered
        # when there is something to show, so a clean run's message is unchanged.
        if ($s -and $s.PSObject.Properties['droppedSources'] -and $s.droppedSources -and @($s.droppedSources).Count -gt 0) {
            $droppedList = @($s.droppedSources) | ForEach-Object { "$($_.videoId) ($($_.title))" }
            $lines += "Dropped sources - sent to Claude, not included (count: $(@($s.droppedSources).Count)): $($droppedList -join '; ')"
        }
        if ($Detail) { $lines += "Detail: $Detail" }
        if ($s -and $s.PSObject.Properties['softIssue'] -and $s.softIssue) { $lines += "Note: $($s.softIssue)" }
        $lines -join "`n"
    }
}

try {
    $uri = "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage"
    Invoke-RestMethod -Uri $uri -Method Post -Body @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $message } | Out-Null
    # Previously silent on success, which made a genuine send indistinguishable in the
    # dispatch log from this script never having been reached at all - real ambiguity
    # found investigating a continuity=true run whose delivery couldn't be confirmed
    # from the log alone. Logging the real HTTP result, not just "we tried."
    Write-Host "Telegram notification sent (Event=$Event) for ${vaultName}."
} catch {
    Write-Warning "Notification send failed (non-fatal): $($_.Exception.Message)"
}
