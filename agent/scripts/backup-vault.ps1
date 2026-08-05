<#
.SYNOPSIS
Backs up exactly one vault (config, working state, wiki content) to its archive/ folder
and optionally to the remote configured in config/vault.json -> backup.

.DESCRIPTION
Vault-scoped by design (ADR-003 / ADR-004): a vault must be able to be backed up,
restored, or moved without needing anything from the shared agent/ tree beyond this
script itself.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $VaultRoot 'config/vault.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if (-not $config.backup -or -not $config.backup.enabled) {
    Write-Host "Backup disabled for this vault."
    return
}

$vaultName = Split-Path -Leaf $VaultRoot
$archiveDir = Join-Path $VaultRoot 'archive'
New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupName = "${vaultName}_backup_${stamp}.zip"
$backupPath = Join-Path $archiveDir $backupName

# Stage into a temp directory that mirrors the desired archive layout, so
# working/manifest.csv lands at working/manifest.csv inside the zip - not flattened to the
# zip root the way passing the bare file path to Compress-Archive would produce - without
# pulling in the rest of working/ (raw downloads, clean transcripts, batches).
$stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) "vault-backup-staging-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
try {
    foreach ($dir in @('config', 'wiki')) {
        $src = Join-Path $VaultRoot $dir
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $stagingDir $dir) -Recurse
        }
    }

    $manifestSrc = Join-Path $VaultRoot 'working/manifest.csv'
    if (Test-Path -LiteralPath $manifestSrc) {
        $stagedWorking = Join-Path $stagingDir 'working'
        New-Item -ItemType Directory -Force -Path $stagedWorking | Out-Null
        Copy-Item -LiteralPath $manifestSrc -Destination (Join-Path $stagedWorking 'manifest.csv')
    }

    Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $backupPath -Force
} finally {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Retention: keep only the newest N per config.backup.keep
$keep = if ($config.backup.keep) { [int]$config.backup.keep } else { 12 }
Get-ChildItem -LiteralPath $archiveDir -Filter "${vaultName}_backup_*.zip" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $keep |
    Remove-Item -Force

# Resolve the remote destination. An explicitly configured value always wins; a blank
# destination (e.g. a freshly provisioned vault still carrying the _template default) is
# auto-derived from drive_path rather than silently skipping the remote backup - this is
# the exact gap that let NateHerk_Rev07/DWSIM diverge to two different hand-typed layouts.
$backupRemote = $config.backup.remote
$backupDestination = $config.backup.destination
if ($backupRemote -and -not $backupDestination -and $config.drive_path) {
    $backupDestination = "$($config.drive_path)/working/backups"
    Write-Host "No backup.destination configured; auto-derived from drive_path: $backupDestination"
}

if ($backupRemote -and $backupDestination) {
    if (Get-Command rclone -ErrorAction SilentlyContinue) {
        & rclone copy $backupPath "${backupRemote}:${backupDestination}" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "rclone copy failed for backup destination ${backupRemote}:${backupDestination} (exit code $LASTEXITCODE)"
        }
        Write-Host "Backup synced to ${backupRemote}:${backupDestination}"

        # Drive-side retention: local archive/ pruning above only ever touched the VM copy,
        # so pushed backups accumulated on Drive forever. Mirror the same newest-N policy
        # against the real remote, scoped to this vault's own backup files only.
        try {
            $remoteListingRaw = & rclone lsjson "${backupRemote}:${backupDestination}" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $remoteBackups = $remoteListingRaw | ConvertFrom-Json |
                    Where-Object { $_.Name -like "${vaultName}_backup_*.zip" }
                $remoteToPrune = $remoteBackups |
                    Sort-Object { [regex]::Match($_.Name, '\d{8}_\d{6}').Value } -Descending |
                    Select-Object -Skip $keep
                foreach ($f in $remoteToPrune) {
                    & rclone deletefile "${backupRemote}:${backupDestination}/$($f.Name)" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "Failed to prune remote backup $($f.Name) (exit code $LASTEXITCODE)."
                    } else {
                        Write-Host "Pruned remote backup: $($f.Name)"
                    }
                }
            } else {
                Write-Warning "Could not list remote backups for retention check at ${backupRemote}:${backupDestination}: $remoteListingRaw"
            }
        } catch {
            Write-Warning "Drive-side retention check failed (non-fatal, backup itself already succeeded): $($_.Exception.Message)"
        }
    } else {
        Write-Warning "rclone not found on PATH; local backup only ($backupPath)."
    }
} elseif ($config.backup.enabled) {
    Write-Warning "backup.enabled is true but no usable backup destination could be resolved (remote='$backupRemote', destination='$backupDestination', drive_path='$($config.drive_path)'); backup stayed local-only ($backupPath)."
}

Write-Host "Backup complete: $backupPath"
