#!/usr/bin/env pwsh
<#
.SYNOPSIS
Test-only stand-in for the real `claude` CLI, invoked in place of it whenever
WIKIAGENT_MOCK_CLAUDE_SCRIPT points here. Used exclusively by
agent/tests/run-claude-synthesis-test.ps1. Never touched by production code paths.

Supports the two subcommand shapes run-claude-synthesis.ps1 actually invokes:
  <mock> auth status --json                          (auth preflight)
  <mock> -p <promptText> --permission-mode acceptEdits (a synthesis/lint-review batch)

Behavior is entirely driven by WIKIAGENT_TEST_* environment variables so each test
scenario can control it without touching this file:
  WIKIAGENT_TEST_AUTH_LOGGED_IN     - 'false' => auth status reports loggedIn=false,
                                       exit 1. Anything else (including unset) => true/0.
  WIKIAGENT_TEST_CLAUDE_TIMEOUT_SECONDS - if set, sleeps this many seconds before doing
                                       anything else (used to force a Wait-Job timeout).
  WIKIAGENT_TEST_CLAUDE_OUTPUT      - literal text to print to stdout instead of the
                                       default "Mock Claude: processing batch..." line.
  WIKIAGENT_TEST_CLAUDE_EXIT_CODE   - process exit code (default 0).
  WIKIAGENT_TEST_WRITE_RESULT       - 'false' => never write synthesis-result.json.
  WIKIAGENT_TEST_RESULT_CONTENT     - raw text written verbatim as synthesis-result.json
                                       (lets a test inject malformed JSON, a wrong batch
                                       id, an empty processed list, etc). If unset, a
                                       valid result is auto-built from the prompt file's
                                       "(video_id: XXXX)" tokens, marking all of them
                                       processed (or the WIKIAGENT_TEST_PROCESSED_SUBSET
                                       subset, if set).
  WIKIAGENT_TEST_PROCESSED_SUBSET   - comma-separated video_ids to mark processed instead
                                       of every id found in the prompt (partial-batch
                                       tests).
  WIKIAGENT_TEST_RESULT_BATCH_OVERRIDE - overrides just the auto-built result's "batch"
                                       field (real batch ids are timestamp-generated at
                                       runtime, unknowable to a test in advance) - used to
                                       simulate a stale/wrong batch label while still
                                       auto-deriving processed ids from the real prompt.
  WIKIAGENT_TEST_LIMIT_HIT_FIRST_N  - the first N invocations of this mock (tracked via a
                                       per-vault counter file, so it survives across the
                                       separate processes each Start-Job invocation is)
                                       behave as a session/usage-limit hit: print a limit
                                       phrase, write no result file, ignore every other
                                       WIKIAGENT_TEST_CLAUDE_* var for that call. Every
                                       invocation after N behaves normally. Used to
                                       exercise the continuity sleep-and-resume path
                                       without looping forever.
  WIKIAGENT_TEST_CREATE_WIKI_FILE   - a vault-relative path (e.g.
                                       "wiki/concepts/evidence.md") to write a dummy file
                                       to, simulating a real Claude wiki edit. Written
                                       BEFORE the WIKIAGENT_TEST_CLAUDE_TIMEOUT_SECONDS
                                       sleep (if any) and independent of exit
                                       code/WIKIAGENT_TEST_WRITE_RESULT, so a test can
                                       simulate "Claude touched real files, then crashed/
                                       hung/produced no usable result" - the exact shape
                                       of the real 2026-09-05 incident this mock harness
                                       was built to reproduce. Used to prove
                                       Get-WikiMutationEvidence-gated 'partial' marking
                                       fires when there's real evidence, and does not fire
                                       when there is none.
#>

$allArgs = $args

if ($allArgs.Count -gt 0 -and $allArgs[0] -eq 'auth') {
    $loggedIn = -not ($env:WIKIAGENT_TEST_AUTH_LOGGED_IN -eq 'false')
    if ($loggedIn) {
        Write-Output '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"test@example.com","subscriptionType":"pro"}'
        exit 0
    } else {
        Write-Output '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'
        exit 1
    }
}

$counterFile = Join-Path (Get-Location).Path 'working/temp/_mock_invocation_count.txt'
$invocationCount = 1
if (Test-Path -LiteralPath $counterFile) { $invocationCount = [int](Get-Content -LiteralPath $counterFile -Raw) + 1 }
New-Item -ItemType Directory -Force -Path (Split-Path -Path $counterFile -Parent) | Out-Null
Set-Content -LiteralPath $counterFile -Value $invocationCount -NoNewline

$limitHitFirstN = if ($env:WIKIAGENT_TEST_LIMIT_HIT_FIRST_N) { [int]$env:WIKIAGENT_TEST_LIMIT_HIT_FIRST_N } else { 0 }
if ($invocationCount -le $limitHitFirstN) {
    Write-Output "Mock: session limit reached. Usage resets 3am."
    exit 0
}

if ($env:WIKIAGENT_TEST_CREATE_WIKI_FILE) {
    $wikiFilePath = Join-Path (Get-Location).Path $env:WIKIAGENT_TEST_CREATE_WIKI_FILE
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $wikiFilePath -Parent) | Out-Null
    "mock wiki content written by test harness" | Out-File -LiteralPath $wikiFilePath -Encoding utf8 -Force
}

if ($env:WIKIAGENT_TEST_CLAUDE_TIMEOUT_SECONDS) {
    Start-Sleep -Seconds ([int]$env:WIKIAGENT_TEST_CLAUDE_TIMEOUT_SECONDS)
}

$pIndex = [array]::IndexOf($allArgs, '-p')
$promptText = if ($pIndex -ge 0 -and $allArgs.Count -gt ($pIndex + 1)) { $allArgs[$pIndex + 1] } else { '' }

if ($env:WIKIAGENT_TEST_CLAUDE_OUTPUT) {
    Write-Output $env:WIKIAGENT_TEST_CLAUDE_OUTPUT
} else {
    Write-Output "Mock Claude: processing batch..."
}

$videoIds = @([regex]::Matches($promptText, '\(video_id:\s*([A-Za-z0-9_-]+)\)') | ForEach-Object { $_.Groups[1].Value })

$writeResult = -not ($env:WIKIAGENT_TEST_WRITE_RESULT -eq 'false')
if ($writeResult) {
    $resultDir = Join-Path (Get-Location).Path 'working/temp'
    New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
    $resultPath = Join-Path $resultDir 'synthesis-result.json'

    if ($env:WIKIAGENT_TEST_RESULT_CONTENT) {
        [System.IO.File]::WriteAllText($resultPath, $env:WIKIAGENT_TEST_RESULT_CONTENT)
    } else {
        $processedIds = if ($env:WIKIAGENT_TEST_PROCESSED_SUBSET) { @($env:WIKIAGENT_TEST_PROCESSED_SUBSET -split ',') } else { $videoIds }
        $batchLabel = if ($env:WIKIAGENT_TEST_RESULT_BATCH_OVERRIDE) { $env:WIKIAGENT_TEST_RESULT_BATCH_OVERRIDE }
                      elseif ($promptText -match 'Synthesis batch:\s*(\S+)') { $Matches[1] } else { 'unknown_batch' }

        [ordered]@{
            batch         = $batchLabel
            processed     = @($processedIds)
            pages_created = @()
            pages_updated = @($processedIds | ForEach-Object { "wiki/concepts/mock-$_.md" })
        } | ConvertTo-Json | Out-File -LiteralPath $resultPath -Encoding utf8
    }
}

$exitCode = if ($env:WIKIAGENT_TEST_CLAUDE_EXIT_CODE) { [int]$env:WIKIAGENT_TEST_CLAUDE_EXIT_CODE } else { 0 }
exit $exitCode
