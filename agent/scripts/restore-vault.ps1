<#
.SYNOPSIS
Restores a vault's config, manifest, and wiki content from a backup-vault.ps1 archive.

.DESCRIPTION
The counterpart to backup-vault.ps1: given a backup .zip and a target vault root, extracts
config/, working/manifest.csv, and wiki/ back into place, then recreates the standard
scaffold directories (each with .gitkeep, matching vaults/_template exactly) so the
restored vault is immediately usable without needing a pipeline run first to self-heal.

Handles backups made before and after the manifest-flattening fix in backup-vault.ps1:
looks for working/manifest.csv inside the archive first, and falls back to a root-level
manifest.csv (the older, flattened layout) if that's what the archive contains.

Refuses to restore into an existing, non-empty vault directory unless -Force is passed -
overwriting live vault data is exactly the kind of action that should never happen silently.

.EXAMPLE
pwsh agent/scripts/restore-vault.ps1 -BackupFile vaults/DWSIM/archive/DWSIM_backup_20260801_080253.zip -VaultRoot vaults/DWSIM-restored

.EXAMPLE
pwsh agent/scripts/restore-vault.ps1 -BackupFile vaults/DWSIM/archive/DWSIM_backup_20260801_080253.zip -VaultRoot vaults/DWSIM -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BackupFile,
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $BackupFile -PathType Leaf)) {
    throw "Backup file not found: $BackupFile"
}

$vaultHasContent = (Test-Path -LiteralPath $VaultRoot) -and
    (Get-ChildItem -LiteralPath $VaultRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)

if ($vaultHasContent -and -not $Force) {
    throw "Refusing to restore into non-empty vault '$VaultRoot' without -Force. This will overwrite config, manifest, and wiki content. Re-run with -Force to proceed, or point -VaultRoot at an empty/new directory."
}

New-Item -ItemType Directory -Force -Path $VaultRoot | Out-Null

Write-Host "Restoring $BackupFile into $VaultRoot ..."

$tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) "vault-restore-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $tempExtract | Out-Null
try {
    Expand-Archive -LiteralPath $BackupFile -DestinationPath $tempExtract -Force

    # config/ and wiki/ preserve their relative structure inside the archive.
    foreach ($dir in @('config', 'wiki')) {
        $src = Join-Path $tempExtract $dir
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $VaultRoot -Recurse -Force
        }
    }

    $workingDir = Join-Path $VaultRoot 'working'
    New-Item -ItemType Directory -Force -Path $workingDir | Out-Null

    # Fixed backups have working/manifest.csv; older backups (pre-fix) flattened it to the
    # archive root as manifest.csv - handle both so this script also works on existing backups.
    $manifestInArchive = Join-Path $tempExtract 'working/manifest.csv'
    if (-not (Test-Path -LiteralPath $manifestInArchive)) {
        $manifestInArchive = Join-Path $tempExtract 'manifest.csv'
    }
    if (Test-Path -LiteralPath $manifestInArchive) {
        Copy-Item -LiteralPath $manifestInArchive -Destination (Join-Path $workingDir 'manifest.csv') -Force
    } else {
        Write-Warning "No manifest.csv found in backup archive (checked working/manifest.csv and manifest.csv)."
    }
} finally {
    Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
}

# Recreate the standard scaffold (matches vaults/_template exactly) so the restored vault is
# immediately usable - the pipeline scripts create these on demand via New-Item -Force, but a
# restore shouldn't require a run first just to become a valid vault.
$scaffoldDirs = @(
    'archive',
    'config/prompts',
    'exports',
    'input',
    'logs',
    'wiki/concepts',
    'wiki/sources',
    'wiki/synthesis',
    'wiki/tools',
    'wiki/workflows',
    'working/batches',
    'working/temp'
)
foreach ($dir in $scaffoldDirs) {
    $full = Join-Path $VaultRoot $dir
    New-Item -ItemType Directory -Force -Path $full | Out-Null
    $gitkeep = Join-Path $full '.gitkeep'
    if (-not (Test-Path -LiteralPath $gitkeep)) {
        New-Item -ItemType File -Path $gitkeep -Force | Out-Null
    }
}

Write-Host "Restore complete: $VaultRoot"
