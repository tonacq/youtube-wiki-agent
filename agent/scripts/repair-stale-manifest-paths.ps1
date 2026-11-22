<#
.SYNOPSIS
Repairs manifest rows whose source_file and clean_transcript_file still point at another
checkout (for example /home/ubuntu/test-multivault/vaults/<Vault>/...), and whose
ingest_status was left at 'pending' although the work is done.

.DESCRIPTION
A path is "stale" when it is absolute, does not exist, and holds a "/vaults/<name>/" or
"\vaults\<name>\" segment. The part after that segment is re-rooted under this vault. The
path is only changed when the re-rooted file exists.

ingest_status is set to 'ingested' only when every check passes: it is 'pending', the
transcript is downloaded, the clean transcript is clean_ready, the source page exists, the
page's frontmatter video_id is this row's video_id, and synthesis_status is 'included'.
Anything else is reported and left alone. No other column is touched.

Default is a dry run that changes nothing. -Apply first copies the manifest to
working/manifest.csv.bak_pathfix_<timestamp> and refuses to run while the vault's run lock
exists. Spends no Claude tokens, downloads nothing. Safe to run twice: a second run finds
nothing to repair.

.EXAMPLE
pwsh agent/scripts/repair-stale-manifest-paths.ps1 -VaultRoot vaults/NateHerk_Rev07
pwsh agent/scripts/repair-stale-manifest-paths.ps1 -VaultRoot vaults/NateHerk_Rev07 -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$VaultRoot = (Resolve-Path -LiteralPath $VaultRoot).Path
$VaultName = Split-Path -Leaf $VaultRoot
$AgentRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No manifest at $manifestPath" }

function Get-ReRootedPath([string]$Path) {
    # Returns the path under this vault when $Path is a stale absolute path, else $null.
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not ($Path.StartsWith('/') -or $Path -match '^[A-Za-z]:[\\/]')) { return $null }
    if (Test-Path -LiteralPath $Path) { return $null }
    if ($Path -notmatch '(?i)[\\/]vaults[\\/][^\\/]+[\\/](.+)$') { return $null }
    $rel = $Matches[1] -replace '\\', '/'
    return (Join-Path $VaultRoot $rel)
}

function Get-PageVideoId([string]$Path) {
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw -or $raw -notmatch '(?s)^---\r?\n(.*?)\r?\n---') { return $null }
    if ($Matches[1] -match '(?m)^video_id:\s*"?([A-Za-z0-9_-]+)"?\s*$') { return $Matches[1] }
    return $null
}

$manifest = @(Import-Csv -LiteralPath $manifestPath)
$changes = [System.Collections.Generic.List[object]]::new()
$unresolved = [System.Collections.Generic.List[object]]::new()
$ingestSkipped = [System.Collections.Generic.List[object]]::new()

foreach ($row in $manifest) {
    $newSource = Get-ReRootedPath $row.source_file
    $newClean = Get-ReRootedPath $row.clean_transcript_file
    $fixSource = $newSource -and (Test-Path -LiteralPath $newSource)
    $fixClean = $newClean -and (Test-Path -LiteralPath $newClean)
    if ($newSource -and -not $fixSource) { $unresolved.Add([pscustomobject]@{ Id = $row.video_id; Column = 'source_file'; Target = $newSource }) }
    if ($newClean -and -not $fixClean) { $unresolved.Add([pscustomobject]@{ Id = $row.video_id; Column = 'clean_transcript_file'; Target = $newClean }) }

    # Decide the ingest_status change on the page this row will point at.
    $pagePath = if ($fixSource) { $newSource } elseif ($row.source_file -and (Test-Path -LiteralPath $row.source_file)) { $row.source_file } else { $null }
    $fixIngest = $false
    if ($row.ingest_status -eq 'pending' -and ($fixSource -or $fixClean -or $newSource -or $newClean)) {
        $why = $null
        if ($row.transcript_status -ne 'downloaded') { $why = "transcript_status=$($row.transcript_status)" }
        elseif ($row.clean_status -ne 'clean_ready') { $why = "clean_status=$($row.clean_status)" }
        elseif ($row.synthesis_status -ne 'included') { $why = "synthesis_status=$($row.synthesis_status)" }
        elseif (-not $pagePath) { $why = 'source page not found' }
        elseif ((Get-PageVideoId $pagePath) -ne $row.video_id) { $why = 'page does not name this video_id' }
        if ($why) { $ingestSkipped.Add([pscustomobject]@{ Id = $row.video_id; Why = $why }) } else { $fixIngest = $true }
    }
    if ($fixSource -or $fixClean -or $fixIngest) {
        $changes.Add([pscustomobject]@{ Row = $row; NewSource = if ($fixSource) { $newSource } else { $null }; NewClean = if ($fixClean) { $newClean } else { $null }; FixIngest = $fixIngest })
    }
}

Write-Host "== $VaultName : $($manifest.Count) rows"
Write-Host "Rows to repair: $($changes.Count)  (source_file: $(@($changes | Where-Object NewSource).Count), clean_transcript_file: $(@($changes | Where-Object NewClean).Count), ingest_status -> ingested: $(@($changes | Where-Object FixIngest).Count))"
foreach ($c in ($changes | Select-Object -First 5)) {
    Write-Host ("  e.g. {0}: {1}" -f $c.Row.video_id, $(if ($c.NewSource) { $c.NewSource } else { '(source_file unchanged)' }))
}
Write-Host "Stale paths whose re-rooted file does not exist (left unchanged): $($unresolved.Count)"
foreach ($u in $unresolved) { Write-Host ("  {0,-12} {1}  -> {2}" -f $u.Id, $u.Column, $u.Target) }
Write-Host "Rows left at ingest_status 'pending' despite a stale path (checks failed): $($ingestSkipped.Count)"
foreach ($s in $ingestSkipped) { Write-Host ("  {0,-12} {1}" -f $s.Id, $s.Why) }

if (-not $Apply) {
    Write-Host 'DRY RUN - nothing changed. Re-run with -Apply to repair.'
    return
}
if ($changes.Count -eq 0) { Write-Host 'Nothing to repair.'; return }

$lockFile = Join-Path $AgentRoot "scheduling/locks/$VaultName.lock"
if (Test-Path -LiteralPath $lockFile) { throw "Run lock present ($lockFile) - a run may be in progress. Nothing changed." }

$backup = "$manifestPath.bak_pathfix_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Copy-Item -LiteralPath $manifestPath -Destination $backup
Write-Host "Backup: $backup"

$now = (Get-Date).ToString('o')
foreach ($c in $changes) {
    if ($c.NewSource) { $c.Row.source_file = $c.NewSource }
    if ($c.NewClean) { $c.Row.clean_transcript_file = $c.NewClean }
    if ($c.FixIngest) { $c.Row.ingest_status = 'ingested' }
    $c.Row.last_updated = $now
}

$tmp = "$manifestPath.tmp"
$manifest | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
Move-Item -LiteralPath $tmp -Destination $manifestPath -Force
Write-Host "Repaired $($changes.Count) row(s)."
