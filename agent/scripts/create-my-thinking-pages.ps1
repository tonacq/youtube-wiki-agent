<#
.SYNOPSIS
Creates an empty "My thinking" page beside every concept page, and links to it from the
concept page. Deterministic, idempotent, spends no Claude tokens.

.DESCRIPTION
The wiki holds what the sources say; the reader's own thinking belongs on a separate page so
the pipeline can never overwrite it. For each wiki/concepts/<name>.md this script:
  1. creates wiki/my-thinking/my-thinking-<name>.md with four prompts, if it does not exist;
  2. appends the line  My thinking: [[my-thinking-<name>]]  to the concept page, if absent.
An existing my-thinking page is never touched, so the reader's writing is safe. Re-running
makes no change. Concept pages are changed only by that one appended line.

Never throws and never fails the run.

.EXAMPLE
pwsh agent/scripts/create-my-thinking-pages.ps1 -VaultRoot vaults/DWSIM
#>

[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$VaultRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $VaultRoot = (Resolve-Path -LiteralPath $VaultRoot).Path
    $conceptsDir = Join-Path $VaultRoot 'wiki/concepts'
    $mtDir = Join-Path $VaultRoot 'wiki/my-thinking'
    if (-not (Test-Path -LiteralPath $conceptsDir)) { Write-Host 'My thinking pages: no concepts folder, nothing to do.'; exit 0 }

    $created = 0; $linked = 0
    foreach ($f in Get-ChildItem -LiteralPath $conceptsDir -Filter '*.md' -File) {
        $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $pageName = "my-thinking-$name"
        $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8
        if ($null -eq $raw) { $raw = '' }

        if (-not (Test-Path -LiteralPath $mtDir)) { New-Item -ItemType Directory -Path $mtDir -Force | Out-Null }
        $mtPath = Join-Path $mtDir "$pageName.md"
        if (-not (Test-Path -LiteralPath $mtPath)) {
            $title = $name
            if ($raw -match '(?m)^title:\s*"?(.*?)"?\s*\r?$') { $title = $Matches[1] }
            $stub = @"
---
title: "My thinking: $title"
type: my-thinking
concept: $name
---

# My thinking: $title

Concept page: [[$name]]

This page is yours. The pipeline never writes to it.

- What does this say, in my own words?
- Where have I seen this in my own work or life?
- What do I agree or disagree with, and why?
- What would I try, and how will I know it worked?
"@
            Set-Content -LiteralPath $mtPath -Value $stub -Encoding utf8
            $created++
        }

        if ($raw -notmatch [regex]::Escape("[[$pageName]]")) {
            $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
            $sep = if ($raw.EndsWith("`n") -or $raw.Length -eq 0) { '' } else { $nl }
            Add-Content -LiteralPath $f.FullName -Value "$sep${nl}My thinking: [[$pageName]]$nl" -NoNewline -Encoding utf8
            $linked++
        }
    }
    Write-Host "My thinking pages: $created created, $linked concept page(s) linked."
} catch {
    Write-Warning "create-my-thinking-pages.ps1 could not complete: $($_.Exception.Message)"
}
exit 0
