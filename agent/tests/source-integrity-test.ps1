<#
.SYNOPSIS
Behavioural tests for source-page integrity: one source page per video_id
(create-source-pages.ps1), requeueing rows whose page is not their own
(requeue-shared-sources.ps1), the requeue download pass (ingest-youtube.ps1), and the
parked-sources alert (run-vault.ps1 + send-notification.ps1).

.DESCRIPTION
Disposable temp vaults only. yt-dlp is replaced by agent/tests/fixtures/mock-yt-dlp.sh
(through the test vault's yt_dlp_path), Claude by agent/tests/fixtures/mock-claude.ps1,
and Telegram by WIKIAGENT_NOTIFY_CAPTURE_FILE. No network, no secrets, no vault data.

.EXAMPLE
pwsh agent/tests/source-integrity-test.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Scripts = Join-Path $RepoRoot 'agent/scripts'
$MockYtDlp = Join-Path $PSScriptRoot 'fixtures/mock-yt-dlp.sh'
$MockClaude = Join-Path $PSScriptRoot 'fixtures/mock-claude.ps1'

$script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wikiagent-source-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $script:tempRoot | Out-Null
$script:passCount = 0
$script:failCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:passCount++; Write-Host "  PASS: $Message" }
    else { $script:failCount++; Write-Host "  FAIL: $Message" -ForegroundColor Red }
}

$testEnvVars = @('WIKIAGENT_TEST_YTDLP_CHANNEL', 'WIKIAGENT_TEST_YTDLP_FAIL_IDS', 'WIKIAGENT_TEST_YTDLP_ONLY_EN_IDS', 'WIKIAGENT_TEST_YTDLP_LOG',
    'WIKIAGENT_MOCK_CLAUDE_SCRIPT', 'WIKIAGENT_NOTIFY_CAPTURE_FILE', 'WIKIAGENT_TEST_PROCESSED_SUBSET')
function Clear-TestEnv { foreach ($v in $testEnvVars) { Remove-Item -Path "env:$v" -ErrorAction SilentlyContinue } }

$header = 'video_id,title,source_type,transcript_status,transcript_attempts,clean_status,clean_transcript_file,source_status,source_file,source_created,ingest_status,synthesis_status,synthesis_last_checked,synthesis_evidence,synthesis_batch,checksum,last_updated'

function New-Vault {
    param([string]$Name = 'SrcTestVault', [hashtable]$Extra = @{})
    $v = Join-Path $script:tempRoot "$Name`_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    foreach ($d in @('config', 'config/prompts', 'working/temp/raw', 'working/temp/clean_transcripts', 'wiki/sources', 'wiki/concepts', 'wiki/tools', 'wiki/workflows', 'wiki/synthesis', 'logs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $v $d) | Out-Null
    }
    $cfg = [ordered]@{
        vault_name = $Name; channel_url = 'https://www.youtube.com/@test'; yt_dlp_path = $MockYtDlp
        caption_languages = @('en-orig', 'en'); proxy = ''; cookie_file = ''; max_transcript_attempts = 3
        drive_remote = ''; drive_path = ''; batch_size = 3; batch_iterations = 1; continuity = $false
        claude_call_timeout_seconds = 10; backup = @{ enabled = $false }
    }
    foreach ($k in $Extra.Keys) { $cfg[$k] = $Extra[$k] }
    $cfg | ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $v 'config/vault.json') -Encoding utf8
    '# test placeholder' | Out-File -LiteralPath (Join-Path $v 'config/claude.md') -Encoding utf8
    return $v
}

function Set-Manifest { param([string]$Vault, [string[]]$Rows) (@($header) + $Rows) -join "`n" | Out-File -LiteralPath (Join-Path $Vault 'working/manifest.csv') -Encoding utf8 }
function Get-Manifest { param([string]$Vault) @(Import-Csv -LiteralPath (Join-Path $Vault 'working/manifest.csv')) }
function Get-Row { param([string]$Vault, [string]$Id) Get-Manifest $Vault | Where-Object { $_.video_id -eq $Id } | Select-Object -First 1 }
function Invoke-Script { param([string]$Name, [string[]]$ScriptArgs) $out = & pwsh -NoProfile -File (Join-Path $Scripts $Name) @ScriptArgs 2>&1; [pscustomobject]@{ Exit = $LASTEXITCODE; Output = ($out -join "`n") } }
function New-Page {
    param([string]$Path, [string]$VideoId, [string]$Body = 'body')
    "---`nvideo_id: $VideoId`nsource_type: youtube`ntitle: `"t`"`nsynthesis_status: pending`n---`n`n$Body`n" | Out-File -LiteralPath $Path -Encoding utf8
}

Write-Host "=== source-integrity behavioural test suite ==="
Write-Host "Temp: $script:tempRoot"

# --- [1] Two videos with the same title get two pages ---------------------------------
Write-Host "[1] create-source-pages: same title, two videos -> two pages, each with its own transcript"
$v1 = New-Vault
$c = Join-Path $v1 'working/temp/clean_transcripts'
'Transcript AAA' | Out-File -LiteralPath (Join-Path $c 'AAA.en-orig.txt') -Encoding utf8
'Transcript BBB' | Out-File -LiteralPath (Join-Path $c 'BBB.en-orig.txt') -Encoding utf8
Set-Manifest $v1 @(
    "AAA,Post by @someone,youtube,downloaded,1,clean_ready,$c/AAA.en-orig.txt,,,,pending,pending,,,,,",
    "BBB,Post by @someone,youtube,downloaded,1,clean_ready,working/temp/clean_transcripts/BBB.en-orig.txt,,,,pending,pending,,,,,"
)
$r = Invoke-Script 'create-source-pages.ps1' @('-VaultRoot', $v1)
$a = Get-Row $v1 'AAA'; $b = Get-Row $v1 'BBB'
Assert-True ($r.Exit -eq 0) "exit 0"
Assert-True ($a.source_file -ne $b.source_file) "source_file differs between the two rows"
Assert-True ((Split-Path -Leaf $a.source_file) -eq 'src_AAA_post-by-someone.md') "file name is src_<video_id>_<slug>.md (got '$(Split-Path -Leaf $a.source_file)')"
Assert-True ((Get-Content -LiteralPath $a.source_file -Raw) -match 'Transcript AAA') "AAA's page holds AAA's transcript"
Assert-True ((Get-Content -LiteralPath $b.source_file -Raw) -match 'Transcript BBB') "BBB's page holds BBB's transcript (relative clean_transcript_file resolved)"
Assert-True ((Get-Content -LiteralPath $b.source_file -Raw) -notmatch 'Transcript AAA') "BBB's page does not hold AAA's transcript"
Assert-True ($a.ingest_status -eq 'ingested' -and $b.ingest_status -eq 'ingested') "both rows ingested"

# --- [1b] Description links from info.json reach the page ------------------------------
Write-Host "[1b] create-source-pages: info.json description links are copied; no info.json or no link -> no section"
$v1b = New-Vault
$c1b = Join-Path $v1b 'working/temp/clean_transcripts'
$raw1b = Join-Path $v1b 'working/temp/raw'
foreach ($id in 'LNK', 'NOI', 'NOL') { "Transcript $id" | Out-File -LiteralPath (Join-Path $c1b "$id.en-orig.txt") -Encoding utf8 }
(@{ description = "Intro line without a link`nMy FREE resources: https://example.com/free?x=1&y=2`nplain text`nTool: https://example.com/tool`n" } | ConvertTo-Json) | Out-File -LiteralPath (Join-Path $raw1b 'LNK.info.json') -Encoding utf8
(@{ description = "No links in this description at all" } | ConvertTo-Json) | Out-File -LiteralPath (Join-Path $raw1b 'NOL.info.json') -Encoding utf8
Set-Manifest $v1b @(
    "LNK,With links,youtube,downloaded,1,clean_ready,$c1b/LNK.en-orig.txt,,,,pending,pending,,,,,",
    "NOI,No info,youtube,downloaded,1,clean_ready,$c1b/NOI.en-orig.txt,,,,pending,pending,,,,,",
    "NOL,No link,youtube,downloaded,1,clean_ready,$c1b/NOL.en-orig.txt,,,,pending,pending,,,,,"
)
$r = Invoke-Script 'create-source-pages.ps1' @('-VaultRoot', $v1b)
$pl = Get-Content -LiteralPath (Get-Row $v1b 'LNK').source_file -Raw
$pn = Get-Content -LiteralPath (Get-Row $v1b 'NOI').source_file -Raw
$po = Get-Content -LiteralPath (Get-Row $v1b 'NOL').source_file -Raw
Assert-True ($r.Exit -eq 0) "exit 0"
Assert-True ($pl -match '## Video description links') "page with links has the section"
Assert-True ($pl -match '- My FREE resources: https://example\.com/free\?x=1&y=2') "link line kept whole, label and query string intact"
Assert-True ($pl -match '- Tool: https://example\.com/tool') "second link line kept"
Assert-True ($pl -notmatch 'Intro line without a link' -and $pl -notmatch 'plain text') "lines without a link are not copied"
Assert-True ($pl.IndexOf('## Video description links') -lt $pl.IndexOf('## Transcript / content')) "section sits before the transcript"
Assert-True ($pl -match 'Transcript LNK') "transcript still present"
Assert-True ($pn -notmatch 'Video description links' -and $pn -match 'Transcript NOI') "no info.json -> no section, page still created"
Assert-True ($po -notmatch 'Video description links' -and $po -match 'Transcript NOL') "description without a link -> no section"

# --- [2] Missing clean transcript: no page, not ingested -------------------------------
Write-Host "[2] create-source-pages: clean transcript missing -> no page, row not ingested, clean_status cleared"
$v2 = New-Vault
Set-Manifest $v2 @("CCC,Some title,youtube,downloaded,1,clean_ready,working/temp/clean_transcripts/CCC.en-orig.txt,,,,pending,pending,,,,,")
$r = Invoke-Script 'create-source-pages.ps1' @('-VaultRoot', $v2)
$row = Get-Row $v2 'CCC'
Assert-True ($r.Exit -eq 0) "exit 0"
Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $v2 'wiki/sources') -Filter '*.md').Count -eq 0) "no source page written"
Assert-True ($row.ingest_status -eq 'pending') "row stays ingest_status pending"
Assert-True ($row.clean_status -eq '' -and $row.source_status -eq '') "clean_status cleared, source_status not set"

# --- [3] A page at the target path belonging to another video_id is not reused ---------
Write-Host "[3] create-source-pages: page at target path belongs to another video_id -> row skipped"
$v3 = New-Vault
'Transcript DDD' | Out-File -LiteralPath (Join-Path $v3 'working/temp/clean_transcripts/DDD.en-orig.txt') -Encoding utf8
New-Page -Path (Join-Path $v3 'wiki/sources/src_DDD_title.md') -VideoId 'ZZZ'
Set-Manifest $v3 @("DDD,Title,youtube,downloaded,1,clean_ready,working/temp/clean_transcripts/DDD.en-orig.txt,,,,pending,pending,,,,,")
$r = Invoke-Script 'create-source-pages.ps1' @('-VaultRoot', $v3)
$row = Get-Row $v3 'DDD'
Assert-True ($row.ingest_status -eq 'pending' -and $row.source_file -eq '') "row not pointed at the other video's page"
Assert-True ($r.Output -match '1 skipped \(page belongs to another video_id\)') "skip reported"

# --- [4] requeue dry run and apply ---------------------------------------------------
Write-Host "[4] requeue-shared-sources: dry run lists rows, changes nothing"
$v4 = New-Vault
$shared = Join-Path $v4 'wiki/sources/post-by-someone.md'
New-Page -Path $shared -VideoId 'OWN'
New-Page -Path (Join-Path $v4 'wiki/sources/good.md') -VideoId 'GOOD'
'WEBVTT' | Out-File -LiteralPath (Join-Path $v4 'working/temp/raw/PEN.en-orig.vtt') -Encoding utf8
Set-Manifest $v4 @(
    "OWN,Post by @someone,youtube,downloaded,1,clean_ready,,source_created,$shared,x,ingested,included,,,,,",
    "BLK,Post by @someone,youtube,downloaded,1,clean_ready,,source_created,wiki/sources/post-by-someone.md,x,ingested,blocked_missing_transcript,,,,,",
    "PEN,Post by @someone,youtube,downloaded,1,clean_ready,,source_created,$shared,x,ingested,pending,,,,,",
    "SUS,Post by @someone,youtube,downloaded,1,clean_ready,,source_created,$shared,x,ingested,included,,,,,",
    "GOOD,Good,youtube,downloaded,1,clean_ready,,source_created,wiki/sources/good.md,x,ingested,pending,,,,,",
    "GONE,Gone,youtube,downloaded,1,clean_ready,,source_created,wiki/sources/missing.md,x,ingested,partial,,,,,"
)
$before = Get-Content -LiteralPath (Join-Path $v4 'working/manifest.csv') -Raw
$r = Invoke-Script 'requeue-shared-sources.ps1' @('-VaultRoot', $v4)
Assert-True ($r.Exit -eq 0) "exit 0"
Assert-True ($r.Output -match 'Rows to requeue \(not included, source page not their own\): 3') "3 rows to requeue (BLK, PEN, GONE)"
Assert-True ($r.Output -match 'report only, not changed\): 1' -and $r.Output -match 'SUS') "SUS reported as included-but-mismatched"
Assert-True ($r.Output -notmatch '(?m)^\s+OWN\s' -and $r.Output -notmatch '(?m)^\s+GOOD\s') "OWN and GOOD not listed"
Assert-True ((Get-Content -LiteralPath (Join-Path $v4 'working/manifest.csv') -Raw) -eq $before) "manifest unchanged by the dry run"

Write-Host "[5] requeue-shared-sources -Apply: refuses while the run lock exists"
$lockDir = Join-Path $RepoRoot 'agent/scheduling/locks'
New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
$lock = Join-Path $lockDir "$(Split-Path -Leaf $v4).lock"
'999999' | Out-File -LiteralPath $lock -Encoding ascii
$r = Invoke-Script 'requeue-shared-sources.ps1' @('-VaultRoot', $v4, '-Apply')
Remove-Item -LiteralPath $lock -Force
Assert-True ($r.Exit -ne 0) "non-zero exit"
Assert-True ((Get-Content -LiteralPath (Join-Path $v4 'working/manifest.csv') -Raw) -eq $before) "manifest unchanged"

Write-Host "[6] requeue-shared-sources -Apply: resets the 3 rows, backs up, leaves the rest"
$r = Invoke-Script 'requeue-shared-sources.ps1' @('-VaultRoot', $v4, '-Apply')
$blk = Get-Row $v4 'BLK'; $pen = Get-Row $v4 'PEN'; $gone = Get-Row $v4 'GONE'
Assert-True ($r.Exit -eq 0) "exit 0"
Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $v4 'working') -Filter 'manifest.csv.bak_requeue_*').Count -eq 1) "backup written"
Assert-True ($blk.transcript_status -eq 'requeued' -and $gone.transcript_status -eq 'requeued') "BLK and GONE set to requeued"
Assert-True ($pen.transcript_status -eq 'downloaded') "PEN (raw captions on disk) set to downloaded"
Assert-True ($blk.ingest_status -eq 'pending' -and $blk.synthesis_status -eq 'pending' -and $blk.source_file -eq '' -and $blk.clean_status -eq '' -and $blk.transcript_attempts -eq '0') "BLK fields reset"
Assert-True ($blk.synthesis_evidence -match '^requeued: ') "synthesis_evidence records the old page"
Assert-True ((Get-Row $v4 'OWN').synthesis_status -eq 'included' -and (Get-Row $v4 'SUS').synthesis_status -eq 'included') "included rows untouched"
Assert-True ((Get-Row $v4 'GOOD').source_file -eq 'wiki/sources/good.md') "GOOD untouched"

# --- [7] ingest-youtube requeue pass, then clean + source pages ------------------------
Write-Host "[7] ingest-youtube: requeued rows downloaded even when the backlog skips the walk; then each gets its own page"
$v7 = New-Vault -Extra @{ batch_size = 1; batch_iterations = 1 }
$channel = Join-Path $v7 'channel.txt'
"BLK|Post by @someone`nPEN|Post by @someone`nGONE|Gone`nNEW1|New video" | Out-File -LiteralPath $channel -Encoding utf8
New-Page -Path (Join-Path $v7 'wiki/sources/backlog.md') -VideoId 'BACK'
Set-Manifest $v7 @(
    "BACK,Backlog row,youtube,downloaded,1,clean_ready,,source_created,wiki/sources/backlog.md,x,ingested,pending,,,,,",
    "BLK,Post by @someone,youtube,requeued,0,,,,,,pending,pending,,,,,",
    "GONE,Gone,youtube,requeued,0,,,,,,pending,pending,,,,,"
)
$ytLog = Join-Path $v7 'ytdlp.log'
Clear-TestEnv
$env:WIKIAGENT_TEST_YTDLP_CHANNEL = $channel
$env:WIKIAGENT_TEST_YTDLP_LOG = $ytLog
$env:WIKIAGENT_TEST_YTDLP_FAIL_IDS = 'GONE'
$r = Invoke-Script 'ingest-youtube.ps1' @('-VaultRoot', $v7)
Clear-TestEnv
$ingest = Get-Content -LiteralPath (Join-Path $v7 'working/temp/ingest-result.json') -Raw | ConvertFrom-Json
Assert-True ($r.Exit -eq 0) "exit 0"
Assert-True ($ingest.reasonCode -eq 'BACKLOG_PRIORITY_SKIP') "backlog still skips the channel walk (reasonCode $($ingest.reasonCode))"
Assert-True ((Get-Row $v7 'BLK').transcript_status -eq 'downloaded') "BLK downloaded by the requeue pass"
Assert-True (Test-Path -LiteralPath (Join-Path $v7 'working/temp/raw/BLK.en-orig.vtt')) "BLK raw captions on disk"
Assert-True ((Get-Row $v7 'GONE').transcript_status -eq 'failed' -and (Get-Row $v7 'GONE').transcript_attempts -eq '1') "failed requeue download falls back to the normal retry path (failed, attempt 1)"
Assert-True (-not ((Get-Content -LiteralPath $ytLog -Raw) -match 'NEW1')) "no new channel video attempted (walk skipped)"
Assert-True (@(Get-Manifest $v7).Count -eq 3) "no duplicate rows"
$r = Invoke-Script 'clean-transcripts.ps1' @('-VaultRoot', $v7)
$r = Invoke-Script 'create-source-pages.ps1' @('-VaultRoot', $v7)
$blk = Get-Row $v7 'BLK'
Assert-True ($blk.ingest_status -eq 'ingested' -and (Split-Path -Leaf $blk.source_file) -eq 'src_BLK_post-by-someone.md') "BLK ingested with its own page"
Assert-True ((Get-Content -LiteralPath $blk.source_file -Raw) -match 'Transcript of video BLK') "BLK's page holds BLK's transcript"

Write-Host "[7b] ingest-youtube: requeue pass plus a normal walk - no duplicates, requeued row not counted towards the target"
$v7b = New-Vault -Extra @{ batch_size = 1; batch_iterations = 1 }
$channel = Join-Path $v7b 'channel.txt'
"NEW1|New video`nBLK|Post by @someone`nNEW2|Another" | Out-File -LiteralPath $channel -Encoding utf8
Set-Manifest $v7b @("BLK,Post by @someone,youtube,requeued,0,,,,,,pending,pending,,,,,")
Clear-TestEnv
$env:WIKIAGENT_TEST_YTDLP_CHANNEL = $channel
$r = Invoke-Script 'ingest-youtube.ps1' @('-VaultRoot', $v7b)
Clear-TestEnv
$ingest = Get-Content -LiteralPath (Join-Path $v7b 'working/temp/ingest-result.json') -Raw | ConvertFrom-Json
$ids = @(Get-Manifest $v7b | ForEach-Object { $_.video_id })
Assert-True ($ingest.reasonCode -eq 'TARGET_MET') "reasonCode TARGET_MET (got $($ingest.reasonCode))"
Assert-True (($ids | Sort-Object) -join ',' -eq 'BLK,NEW1') "manifest holds BLK and NEW1 once each (got $($ids -join ','))"
Assert-True ((Get-Row $v7b 'BLK').transcript_status -eq 'downloaded' -and (Get-Row $v7b 'NEW1').transcript_status -eq 'downloaded') "both downloaded; NEW2 not reached (target 1 met by NEW1)"

Write-Host "[7c] ingest-youtube: one caption track per request, paced; the second track only when the first is missing"
$v7c = New-Vault -Extra @{ batch_size = 2; batch_iterations = 1; yt_sleep_subtitles_seconds = 7; yt_sleep_requests_seconds = 2 }
$channel = Join-Path $v7c 'channel.txt'
"NORM|Normal video`nENONLY|English only video" | Out-File -LiteralPath $channel -Encoding utf8
Set-Manifest $v7c @()
$ytLog = Join-Path $v7c 'ytdlp.log'
Clear-TestEnv
$env:WIKIAGENT_TEST_YTDLP_CHANNEL = $channel
$env:WIKIAGENT_TEST_YTDLP_LOG = $ytLog
$env:WIKIAGENT_TEST_YTDLP_ONLY_EN_IDS = 'ENONLY'
$r = Invoke-Script 'ingest-youtube.ps1' @('-VaultRoot', $v7c)
Clear-TestEnv
$calls = @(Get-Content -LiteralPath $ytLog | Where-Object { $_ -match 'watch\?v=' })
$normCalls = @($calls | Where-Object { $_ -match 'watch\?v=NORM' })
$enCalls = @($calls | Where-Object { $_ -match 'watch\?v=ENONLY' })
Assert-True ($r.Exit -eq 0) "exit 0"
Assert-True ($normCalls.Count -eq 1 -and $normCalls[0] -match '--sub-langs en-orig(\s|$)' -and $normCalls[0] -notmatch 'en-orig,en') "a normal video costs exactly one request, for en-orig only"
Assert-True ($enCalls.Count -eq 2 -and $enCalls[0] -match '--sub-langs en-orig(\s|$)' -and $enCalls[1] -match '--sub-langs en(\s|$)') "an English-only video falls back to a second request for en"
Assert-True (($calls | Where-Object { $_ -match '--sleep-subtitles 7' -and $_ -match '--sleep-requests 2' }).Count -eq $calls.Count) "every request carries the configured pacing flags"
Assert-True ((Get-Row $v7c 'NORM').transcript_status -eq 'downloaded' -and (Get-Row $v7c 'ENONLY').transcript_status -eq 'downloaded') "both videos downloaded"
Assert-True (Test-Path -LiteralPath (Join-Path $v7c 'working/temp/raw/ENONLY.en.vtt')) "the en track was kept for the English-only video"

# --- [8] run-vault: parked sources raise a separate alert ------------------------------
Write-Host "[8] run-vault: a source parked by the retry cap sends a separate SynthesisAlert before the RunSummary"
$v8 = New-Vault -Extra @{ channel_url = ''; max_synthesis_attempts = 1 }
$rows8 = foreach ($id in 'P01', 'P02', 'P03') {
    $p = Join-Path $v8 "wiki/sources/src_$id.md"
    New-Page -Path $p -VideoId $id
    "$id,Title $id,youtube,downloaded,1,clean_ready,,source_created,$p,x,ingested,pending,,,,,"
}
Set-Manifest $v8 $rows8
$capture = Join-Path $script:tempRoot "capture_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
Clear-TestEnv
$env:WIKIAGENT_MOCK_CLAUDE_SCRIPT = $MockClaude
$env:WIKIAGENT_NOTIFY_CAPTURE_FILE = $capture
$env:WIKIAGENT_TEST_PROCESSED_SUBSET = 'P01,P02'
$out = & pwsh -NoProfile -File (Join-Path $Scripts 'run-vault.ps1') -VaultRoot $v8 -JobType full -SkipYoutube -SkipClean -SkipDocuments -SkipBackup 2>&1
Clear-TestEnv
$captured = if (Test-Path -LiteralPath $capture) { Get-Content -LiteralPath $capture -Raw } else { '' }
$events = @([regex]::Matches($captured, '(?m)^Event=(\S+)') | ForEach-Object { $_.Groups[1].Value })
Assert-True ((Get-Row $v8 'P03').synthesis_status -eq 'parked_synthesis') "P03 set to parked_synthesis (got '$((Get-Row $v8 'P03').synthesis_status)')"
Assert-True ((Get-Row $v8 'P03').synthesis_attempts -eq '1') "P03 synthesis_attempts = 1"
Assert-True ($events.Count -ge 2 -and $events[0] -eq 'SynthesisAlert' -and $events[-1] -eq 'RunSummary') "SynthesisAlert then RunSummary (order: $($events -join ', '))"
Assert-True ($captured -match '\[ACTION REQUIRED\] WikiAgent SrcTestVault_[0-9a-f]{8}: 1 source\(s\)' -and $captured -match 'P03 \(Title P03\)') "alert names the vault and the parked source"

Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "=== Summary: $($script:passCount) passed, $($script:failCount) failed ==="
if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
