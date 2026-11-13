<#
.SYNOPSIS
Finds manifest rows whose source page does not hold their own content (for example two
videos with the same title that were given one shared page) and, with -Apply, requeues
them so the next run downloads their captions again and writes a page of their own.

.DESCRIPTION
A row is "mismatched" when it is ingested and its source page is either missing, or
belongs to another source: the page's frontmatter video_id names a different video, or
(when the page has no video_id) the page is shared by more than one manifest row.

Mismatched rows that are not 'included', and every row with synthesis_status =
blocked_missing_transcript (the containment status for such rows), are requeued:
  transcript_status   = requeued (or 'downloaded' if its raw caption file is still in
                        working/temp/raw, so no download is needed)
  transcript_attempts = 0
  clean_*, source_*, ingest_status = cleared / 'pending'
  synthesis_status    = pending; synthesis_attempts cleared
  synthesis_evidence  = "requeued: <old source page>"
ingest-youtube.ps1 downloads 'requeued' rows before, and independent of, the backlog
target. clean-transcripts.ps1 and create-source-pages.ps1 then build the new page.

Mismatched rows that are already 'included' are reported only, never changed: they may
have been synthesised against another video's transcript and need a human review.

Default is a dry run that changes nothing. -Apply first copies the manifest to
working/manifest.csv.bak_requeue_<timestamp>, and refuses to run while the vault's run
lock exists. Spends no Claude tokens.

.EXAMPLE
pwsh agent/scripts/requeue-shared-sources.ps1 -VaultRoot vaults/SabrinaRamonov_Rev01
pwsh agent/scripts/requeue-shared-sources.ps1 -VaultRoot vaults/SabrinaRamonov_Rev01 -Apply
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
$rawDir = Join-Path $VaultRoot 'working/temp/raw'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No manifest at $manifestPath" }

function Resolve-VaultPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $VaultRoot $Path)
}

function Get-PageVideoId([string]$Path) {
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw -or $raw -notmatch '(?s)^---\r?\n(.*?)\r?\n---') { return $null }
    if ($Matches[1] -match '(?m)^video_id:\s*"?([A-Za-z0-9_-]+)"?\s*$') { return $Matches[1] }
    return $null
}

$manifest = @(Import-Csv -LiteralPath $manifestPath)

$shareCount = @{}
foreach ($row in $manifest) {
    $p = Resolve-VaultPath $row.source_file
    if (-not $p) { continue }
    $key = [System.IO.Path]::GetFullPath($p)
    if ($shareCount.ContainsKey($key)) { $shareCount[$key]++ } else { $shareCount[$key] = 1 }
}

$toRequeue = [System.Collections.Generic.List[object]]::new()
$suspectIncluded = [System.Collections.Generic.List[object]]::new()
$pageOwnerCache = @{}

foreach ($row in $manifest) {
    if ($row.ingest_status -ne 'ingested') { continue }
    $p = Resolve-VaultPath $row.source_file
    $reason = $null
    if (-not $p -or -not (Test-Path -LiteralPath $p)) {
        $reason = 'source page missing'
    } else {
        $key = [System.IO.Path]::GetFullPath($p)
        if (-not $pageOwnerCache.ContainsKey($key)) { $pageOwnerCache[$key] = Get-PageVideoId $key }
        $owner = $pageOwnerCache[$key]
        if ($owner -and $owner -ne $row.video_id) {
            $reason = "page belongs to $owner"
        } elseif (-not $owner -and $shareCount[$key] -gt 1) {
            $reason = "page shared by $($shareCount[$key]) rows, no video_id in frontmatter"
        }
    }
    # Rows already contained as blocked_missing_transcript are requeued even if their
    # page looks like their own: they were blocked because synthesis could not use it.
    if (-not $reason -and $row.synthesis_status -eq 'blocked_missing_transcript') { $reason = 'blocked_missing_transcript' }
    if (-not $reason) { continue }
    $entry = [pscustomobject]@{ Row = $row; Reason = $reason }
    if ($row.synthesis_status -eq 'included') { $suspectIncluded.Add($entry) } else { $toRequeue.Add($entry) }
}

Write-Host "== $VaultName : $($manifest.Count) rows"
Write-Host "Rows to requeue (not included, source page not their own): $($toRequeue.Count)"
foreach ($e in $toRequeue) {
    $t = if ($e.Row.title.Length -gt 50) { $e.Row.title.Substring(0, 50) } else { $e.Row.title }
    Write-Host ("  {0,-12} {1,-26} {2}  [{3}]" -f $e.Row.video_id, $e.Row.synthesis_status, $t, $e.Reason)
}
Write-Host "Included rows whose source page is not their own (report only, not changed): $($suspectIncluded.Count)"
foreach ($e in $suspectIncluded) {
    $t = if ($e.Row.title.Length -gt 50) { $e.Row.title.Substring(0, 50) } else { $e.Row.title }
    Write-Host ("  {0,-12} {1}  [{2}]" -f $e.Row.video_id, $t, $e.Reason)
}

if (-not $Apply) {
    Write-Host 'DRY RUN - nothing changed. Re-run with -Apply to requeue.'
    return
}
if ($toRequeue.Count -eq 0) { Write-Host 'Nothing to requeue.'; return }

$lockFile = Join-Path $AgentRoot "scheduling/locks/$VaultName.lock"
if (Test-Path -LiteralPath $lockFile) { throw "Run lock present ($lockFile) - a run may be in progress. Nothing changed." }

$backup = "$manifestPath.bak_requeue_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Copy-Item -LiteralPath $manifestPath -Destination $backup
Write-Host "Backup: $backup"

$now = (Get-Date).ToString('o')
$rawKept = 0
foreach ($e in $toRequeue) {
    $row = $e.Row
    $hasRaw = (Test-Path -LiteralPath $rawDir) -and @(Get-ChildItem -LiteralPath $rawDir -Filter "$($row.video_id).*.vtt" -ErrorAction SilentlyContinue).Count -gt 0
    if ($hasRaw) { $rawKept++ }
    $row.transcript_status = if ($hasRaw) { 'downloaded' } else { 'requeued' }
    if ($row.PSObject.Properties['transcript_attempts']) { $row.transcript_attempts = '0' }
    $row.clean_status           = ''
    $row.clean_transcript_file  = ''
    $row.source_status          = ''
    $oldSource                  = $row.source_file
    $row.source_file            = ''
    $row.source_created         = ''
    $row.ingest_status          = 'pending'
    $row.synthesis_status       = 'pending'
    $row.synthesis_last_checked = ''
    $row.synthesis_evidence     = "requeued: $oldSource"
    $row.synthesis_batch        = ''
    if ($row.PSObject.Properties['synthesis_attempts']) { $row.synthesis_attempts = '' }
    $row.last_updated           = $now
}

$tmp = "$manifestPath.tmp"
$manifest | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
Move-Item -LiteralPath $tmp -Destination $manifestPath -Force

Write-Host "Requeued $($toRequeue.Count) row(s): $($toRequeue.Count - $rawKept) for caption download on the next run, $rawKept with raw captions already on disk."
