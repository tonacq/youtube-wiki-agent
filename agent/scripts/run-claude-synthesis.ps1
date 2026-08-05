<#
.SYNOPSIS
Invokes Claude Code headlessly against this vault's pending sources, or in -LintReview
mode for the scheduled report-only monthly review.

.DESCRIPTION
Critical safety rule carried over from the production incident history (Finding D/E in
the validation record): this script NEVER writes synthesis_status into manifest.csv
directly. It writes an intermediate result file and lets run-qa.ps1 do the one
authoritative, idempotent reconciliation. This is what makes an interrupted Claude call
safe to re-run without corrupting state or silently losing evidence of completed work.

Also carries over the fix for stale-prompt selection: if a prompt was generated during
*this* run, it is always preferred; otherwise the newest matching historical prompt wins
(not the oldest).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [switch]$LintReview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $VaultRoot 'config/vault.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$claudeMd = Join-Path $VaultRoot 'config/claude.md'
$promptsDir = Join-Path $VaultRoot 'config/prompts'
New-Item -ItemType Directory -Force -Path $promptsDir | Out-Null

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warning "claude CLI not found on PATH. Skipping synthesis (this is expected in a build/test sandbox)."
    return
}

if ($LintReview) {
    $lintPrompt = Join-Path $promptsDir "lint_review_$(Get-Date -Format 'yyyyMMdd').md"
    @"
# Scheduled lint-review

Follow the "Scheduled lint-review runs" section of config/claude.md exactly.
This is report-only: analyze the vault, write reports/lint_report_$(Get-Date -Format 'yyyy-MM-dd').md,
make no other changes.
"@ | Out-File -LiteralPath $lintPrompt -Encoding utf8

    Push-Location $VaultRoot
    try {
        & claude -p (Get-Content -LiteralPath $lintPrompt -Raw) --permission-mode acceptEdits
        if ($LASTEXITCODE -ne 0) { throw "claude CLI exited with code $LASTEXITCODE (lint-review)" }
    } finally { Pop-Location }
    return
}

$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'
$manifest = @(Import-Csv -LiteralPath $manifestPath)
$pending = @($manifest | Where-Object { $_.ingest_status -eq 'ingested' -and $_.synthesis_status -eq 'pending' })

if (-not $pending) { Write-Host "No sources pending synthesis."; return }

$batchId = "synthesis_batch_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$promptFile = Join-Path $promptsDir "$batchId.md"

$sourceList = ($pending | ForEach-Object { "- $($_.source_file) (video_id: $($_.video_id))" }) -join "`n"
@"
# Synthesis batch: $batchId

Follow config/claude.md. Process these pending source pages:

$sourceList

When finished, write a JSON summary to working/temp/synthesis-result.json with this shape:

{
  "batch": "$batchId",
  "processed": ["<video_id>", ...],
  "pages_created": ["<path>", ...],
  "pages_updated": ["<path>", ...]
}

Do not edit working/manifest.csv. run-qa.ps1 will reconcile it from your result file.
"@ | Out-File -LiteralPath $promptFile -Encoding utf8

Write-Host "Invoking Claude Code for batch $batchId ($($pending.Count) sources)..."
Push-Location $VaultRoot
try {
    & claude -p (Get-Content -LiteralPath $promptFile -Raw) --permission-mode acceptEdits
    if ($LASTEXITCODE -ne 0) { throw "claude CLI exited with code $LASTEXITCODE (batch $batchId)" }
} finally { Pop-Location }

Write-Host "Synthesis invocation complete for $batchId. Manifest reconciliation happens in run-qa.ps1."
