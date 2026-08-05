<#
.SYNOPSIS
Syncs this vault's config/working/wiki state with its Google Drive remote via rclone.
Direction is explicit: -Direction Pull (before a run) or -Direction Push (after a run).

.DESCRIPTION
Ported directly from the proven production pattern (run_nate_herk_weekly.sh on the
Oracle VM): Google Drive is the durable canonical store; the vault directory on the
host is treated as a working copy that is pulled fresh before each run and pushed
back after a successful run. This is what makes the VM itself disposable/rebuildable.

Excludes the vault's own copied-in scripts folder from sync (scripts are agent-owned,
not vault data) — mirrors the proven --exclude "/scripts/*_linux.ps1" flag.

Vault directories are not git-tracked (they're runtime/data, gitignored like everything
under .tmp/-style working state), so Drive itself - not git - is the only record of
"what was last pushed". Before a pull, we diff local vs. Drive with `rclone check` and
abort if local has anything Drive doesn't already have, rather than silently letting
`rclone sync` delete/overwrite it. Pass -ForcePull to skip this and pull anyway.

logs/ is excluded from that check specifically (not from the actual pull/push, which still
sync it normally): run-vault.ps1 writes its own result log under logs/ *after* the push
stage completes, so that file is always local-only the instant a run finishes. Without this
exclusion every run would falsely trip the guard on its own previous log. Nothing in the
pipeline reads old run logs back for decisions, so losing an unpushed one on the next pull
isn't the kind of data loss this check exists to prevent.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [Parameter(Mandatory = $true)][ValidateSet('Pull', 'Push')][string]$Direction,
    [switch]$ForcePull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $VaultRoot 'config/vault.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

if (-not $config.drive_remote -or -not $config.drive_path) {
    Write-Host "No drive_remote/drive_path configured for this vault; skipping sync."
    return
}

if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    Write-Warning "rclone not found on PATH; skipping sync (this is expected in a build/test sandbox)."
    return
}

$remote = "$($config.drive_remote):$($config.drive_path)"

if ($Direction -eq 'Pull') {
    if (-not $ForcePull) {
        Write-Host "Checking for local changes not yet pushed to $remote ..."
        $checkOutput = & rclone check $VaultRoot $remote --one-way --exclude '/config/prompts/**' --exclude '/logs/**' --combined - 2>&1
        $atRisk = @($checkOutput | Where-Object { $_ -match '^[+*] ' })

        if ($atRisk.Count -gt 0) {
            $fileList = ($atRisk -join "`n  ")
            throw "Pull aborted: local changes in $VaultRoot are not yet pushed to $remote and would be deleted or overwritten:`n  $fileList`n`nPush these changes first (run this script with -Direction Push), or re-run with -ForcePull to discard them and overwrite from Drive."
        }
    }

    Write-Host "Pulling vault state from $remote ..."
    & rclone sync $remote $VaultRoot --exclude '/config/prompts/**' --progress
} else {
    Write-Host "Pushing vault state to $remote ..."
    & rclone copy $VaultRoot $remote --exclude '/config/prompts/**' --progress
}
if ($LASTEXITCODE -ne 0) {
    throw "rclone $Direction failed for $remote (exit code $LASTEXITCODE)"
}
