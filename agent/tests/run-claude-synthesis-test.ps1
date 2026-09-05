<#
.SYNOPSIS
Behavioral test suite for agent/scripts/run-claude-synthesis.ps1's batching/diagnostics/
classification/auth-preflight logic, added as part of the 2026-09-05 SabrinaRamonov_Rev01
synthesis-runner reliability fixes.

.DESCRIPTION
Uses WIKIAGENT_MOCK_CLAUDE_SCRIPT (agent/tests/fixtures/mock-claude.ps1) and
WIKIAGENT_TEST_SLEEP_SECONDS - the two test-only hooks the runner script already
documents in its own .NOTES - plus a small number of additional WIKIAGENT_TEST_* env
vars the mock itself defines, to drive every reason-code branch without a live Claude
invocation. Every test vault is a disposable temp directory outside the repo; nothing
under vaults/ (including SabrinaRamonov_Rev00/Rev01) is read or written by this suite.

No Pester dependency (none is installed on this VM) - plain assertions, PASS/FAIL
console output, exit 0/1, matching the existing agent/tests/architecture-conformance-test.ps1
style.

.EXAMPLE
pwsh agent/tests/run-claude-synthesis-test.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # .../wiki-agent-pipeline
$RunnerScript = Join-Path $RepoRoot 'agent/scripts/run-claude-synthesis.ps1'
$MockClaude = Join-Path $PSScriptRoot 'fixtures/mock-claude.ps1'

if (-not (Test-Path -LiteralPath $RunnerScript)) { throw "Runner script not found: $RunnerScript" }
if (-not (Test-Path -LiteralPath $MockClaude)) { throw "Mock claude script not found: $MockClaude" }

$script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "wikiagent-synth-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $script:tempRoot | Out-Null

$script:passCount = 0
$script:failCount = 0
$script:failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:passCount++
        Write-Host "  PASS: $Message"
    } else {
        $script:failCount++
        $script:failures.Add($Message)
        Write-Host "  FAIL: $Message" -ForegroundColor Red
    }
}

# Under Set-StrictMode -Version Latest (active in this script), both indexing an empty
# array ("Index was outside the bounds of the array") and dotting into $null ("The
# property '...' cannot be found") are terminating errors - confirmed empirically. A
# diagnostics event that's legitimately absent (which a real regression, not just this
# suite's own scenarios, could cause) must fail one assertion cleanly, not crash the
# entire suite and lose every result gathered so far. Every "find the one event I expect"
# lookup below goes through this instead of bare [0]/dot-access.
function Get-Prop {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $null
}

$testEnvVars = @(
    'WIKIAGENT_MOCK_CLAUDE_SCRIPT', 'WIKIAGENT_TEST_SLEEP_SECONDS', 'WIKIAGENT_TEST_AUTH_LOGGED_IN',
    'WIKIAGENT_TEST_CLAUDE_TIMEOUT_SECONDS', 'WIKIAGENT_TEST_CLAUDE_OUTPUT', 'WIKIAGENT_TEST_CLAUDE_EXIT_CODE',
    'WIKIAGENT_TEST_WRITE_RESULT', 'WIKIAGENT_TEST_RESULT_CONTENT', 'WIKIAGENT_TEST_PROCESSED_SUBSET',
    'WIKIAGENT_TEST_RESULT_BATCH_OVERRIDE', 'WIKIAGENT_TEST_LIMIT_HIT_FIRST_N', 'WIKIAGENT_TEST_THROW_AFTER_BATCH',
    'WIKIAGENT_TEST_CREATE_WIKI_FILE'
)
function Clear-TestEnv {
    foreach ($v in $testEnvVars) { Remove-Item -Path "env:$v" -ErrorAction SilentlyContinue }
}

function New-TestVault {
    param([int]$RowCount = 10, [int]$TimeoutSeconds = 3)
    $vaultRoot = Join-Path $script:tempRoot "vault_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    foreach ($d in @('config', 'config/prompts', 'working', 'working/temp', 'wiki/sources', 'wiki/concepts', 'wiki/tools', 'wiki/workflows', 'wiki/synthesis')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $vaultRoot $d) | Out-Null
    }
    [ordered]@{
        vault_name                  = 'TestVault'
        batch_size                  = 3
        batch_iterations            = 1
        continuity                  = $false
        claude_call_timeout_seconds = $TimeoutSeconds
    } | ConvertTo-Json | Out-File -LiteralPath (Join-Path $vaultRoot 'config/vault.json') -Encoding utf8
    "# test claude.md placeholder - not read by run-claude-synthesis.ps1" | Out-File -LiteralPath (Join-Path $vaultRoot 'config/claude.md') -Encoding utf8

    $header = 'video_id,title,source_type,transcript_status,clean_status,clean_transcript_file,source_status,source_file,source_created,ingest_status,synthesis_status,synthesis_last_checked,synthesis_evidence,synthesis_batch,checksum,last_updated'
    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add($header)
    for ($i = 1; $i -le $RowCount; $i++) {
        $vid = "V{0:D3}" -f $i
        $rows.Add("$vid,Title $vid,document,n/a,clean_ready,,source_created,/fake/source_$vid.md,2026-01-01T00:00:00Z,ingested,pending,,,,,2026-01-01T00:00:00Z")
    }
    ($rows -join "`n") | Out-File -LiteralPath (Join-Path $vaultRoot 'working/manifest.csv') -Encoding utf8
    return $vaultRoot
}

# Ordering-fix regression fixture: a vault where run-qa.ps1's own frontmatter-sync step
# (Sync-SourcePageFrontmatter, which iterates EVERY currently-'included' manifest row,
# not just rows that transitioned this call) has genuine, real work to do on a row
# completely unrelated to the batch under test - an already-'included' historical row
# (V000) whose wiki/sources/*.md file still says synthesis_status: pending in its own
# frontmatter (i.e. never backfilled). When run-qa.ps1 runs as part of the batch under
# test's zero-progress/timeout recovery, it will genuinely Set-Content that file - the
# exact contamination risk the mutation-evidence capture must be ordered before, not
# after, run-qa.ps1.
function New-TestVaultWithUnsyncedHistoricalRow {
    param([int]$RowCount = 3, [int]$TimeoutSeconds = 3)
    $vaultRoot = New-TestVault -RowCount $RowCount -TimeoutSeconds $TimeoutSeconds

    $historicalSourceFile = Join-Path $vaultRoot 'wiki/sources/historical-v000.md'
    @"
---
video_id: V000
synthesis_status: pending
---
Some historical body content that predates the frontmatter-sync backfill.
"@ | Out-File -LiteralPath $historicalSourceFile -Encoding utf8

    $manifestPath = Join-Path $vaultRoot 'working/manifest.csv'
    $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $manifestPath)
    $lines.Add("V000,Historical Title,document,n/a,clean_ready,,source_created,$historicalSourceFile,2026-01-01T00:00:00Z,ingested,included,2026-01-01,wiki/concepts/historical.md,synthesis_batch_historical,,2026-01-01T00:00:00Z")
    ($lines -join "`n") | Out-File -LiteralPath $manifestPath -Encoding utf8

    return $vaultRoot
}

function Get-Manifest {
    param([string]$VaultRoot)
    @(Import-Csv -LiteralPath (Join-Path $VaultRoot 'working/manifest.csv'))
}

function Get-RunResult {
    param([string]$VaultRoot)
    $path = Join-Path $VaultRoot 'working/temp/synthesis-run-result.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Get-Diagnostics {
    param([string]$VaultRoot)
    $dir = Join-Path $VaultRoot 'working/temp/synthesis-diagnostics'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.jsonl')
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
            if ($line.Trim() -eq '') { continue }
            $events.Add(($line | ConvertFrom-Json))
        }
    }
    return @($events)
}

function Invoke-Runner {
    param(
        [string]$VaultRoot,
        [string]$BatchSizeOverride = '',
        [string]$BatchIterationsOverride = '',
        [string]$ContinuityOverride = '',
        [hashtable]$Env = @{}
    )
    Clear-TestEnv
    $env:WIKIAGENT_MOCK_CLAUDE_SCRIPT = $MockClaude
    foreach ($k in $Env.Keys) { Set-Item -Path "env:$k" -Value $Env[$k] }

    $runnerArgs = @('-VaultRoot', $VaultRoot)
    if ($BatchSizeOverride -ne '') { $runnerArgs += @('-BatchSizeOverride', $BatchSizeOverride) }
    if ($BatchIterationsOverride -ne '') { $runnerArgs += @('-BatchIterationsOverride', $BatchIterationsOverride) }
    if ($ContinuityOverride -ne '') { $runnerArgs += @('-ContinuityOverride', $ContinuityOverride) }

    $logPath = Join-Path $VaultRoot '_run.log'
    & pwsh -NoProfile -File $RunnerScript @runnerArgs *> $logPath
    $exitCode = $LASTEXITCODE
    Clear-TestEnv
    return $exitCode
}

Write-Host "=== run-claude-synthesis.ps1 behavioral test suite ==="
Write-Host "Repo:   $RepoRoot"
Write-Host "Runner: $RunnerScript"
Write-Host "Mock:   $MockClaude"
Write-Host "Temp:   $script:tempRoot"
Write-Host ""

# --- Scenario 1: successful single batch ----------------------------------------------
Write-Host "[1] Successful single batch"
$v1 = New-TestVault -RowCount 5
$exit1 = Invoke-Runner -VaultRoot $v1 -BatchSizeOverride '3' -BatchIterationsOverride '1'
$r1 = Get-RunResult -VaultRoot $v1
$m1 = Get-Manifest -VaultRoot $v1
Assert-True ($exit1 -eq 0) "exit code is 0"
Assert-True ($null -eq $r1.reasonCode) "reasonCode is null (clean success)"
Assert-True ($r1.batchesCompleted -eq 1) "batchesCompleted is 1"
Assert-True ($r1.actualSynthesized -eq 3) "actualSynthesized is 3"
Assert-True (@($m1 | Where-Object { $_.synthesis_status -eq 'included' }).Count -eq 3) "3 rows included"
Assert-True (@($m1 | Where-Object { $_.synthesis_status -eq 'pending' }).Count -eq 2) "2 rows still pending"
$diag1PreCheck = Get-Diagnostics -VaultRoot $v1
Assert-True ((@($diag1PreCheck | Where-Object { $_.event -eq 'stale_result_quarantined' })).Count -eq 0) "no stale-result quarantine on a clean run with nothing pre-existing (regression guard)"

# --- Scenario 12: diagnostics persistence (validated against scenario 1's run) --------
Write-Host "[12] Diagnostics persistence"
$diag1 = Get-Diagnostics -VaultRoot $v1
Assert-True ($diag1.Count -gt 0) "diagnostics JSONL has at least one event"
$eventTypes = @($diag1 | ForEach-Object { $_.event } | Select-Object -Unique)
foreach ($expected in @('run_start', 'auth_preflight', 'iteration_entered', 'batch_selected', 'claude_job_started', 'claude_invocation_completed', 'synthesis_result_check', 'qa_invoked', 'qa_completed', 'batch_outcome', 'batch_counter_incremented', 'iteration_completed', 'run_end')) {
    Assert-True ($eventTypes -contains $expected) "diagnostics contain a '$expected' event"
}
$batchOutcome1 = $diag1 | Where-Object { $_.event -eq 'batch_outcome' } | Select-Object -First 1
Assert-True ((Get-Prop $batchOutcome1 'classification') -eq 'SYNTHESIS_SUCCESS') "batch_outcome classification is SYNTHESIS_SUCCESS"
$outputFiles1 = @(Get-ChildItem -LiteralPath (Join-Path $v1 'working/temp/synthesis-diagnostics') -Filter '*.output.txt')
Assert-True ($outputFiles1.Count -eq 1) "one per-batch Claude output file was persisted"

# --- Scenario 2: successful batch 1 -> 2 -> 3 continuation -----------------------------
Write-Host "[2] Successful batch 1 -> 2 -> 3 continuation"
$v2 = New-TestVault -RowCount 9
$exit2 = Invoke-Runner -VaultRoot $v2 -BatchSizeOverride '3' -BatchIterationsOverride '3'
$r2 = Get-RunResult -VaultRoot $v2
$m2 = Get-Manifest -VaultRoot $v2
$diag2 = Get-Diagnostics -VaultRoot $v2
Assert-True ($exit2 -eq 0) "exit code is 0"
Assert-True ($r2.batchesCompleted -eq 3) "batchesCompleted is 3"
Assert-True ($r2.actualSynthesized -eq 9) "actualSynthesized is 9"
Assert-True ((@($m2 | Where-Object { $_.synthesis_status -eq 'included' }).Count) -eq 9) "all 9 rows included"
$iterationsEntered = @($diag2 | Where-Object { $_.event -eq 'iteration_entered' } | ForEach-Object { $_.iteration } | Sort-Object -Unique)
Assert-True (($iterationsEntered -join ',') -eq '1,2,3') "runner entered iterations 1, 2, and 3 (explicit evidence of loop continuation)"
$distinctBatchIds = @($diag2 | Where-Object { $_.event -eq 'batch_selected' } | ForEach-Object { $_.batchId } | Select-Object -Unique)
Assert-True ($distinctBatchIds.Count -eq 3) "3 distinct batch ids were used"
$outputFiles2 = @(Get-ChildItem -LiteralPath (Join-Path $v2 'working/temp/synthesis-diagnostics') -Filter '*.output.txt')
Assert-True ($outputFiles2.Count -eq 3) "3 distinct per-batch output files exist (no forensic overwrite across iterations)"
foreach ($n in 1..3) {
    $matchForIter = @($outputFiles2 | Where-Object { $_.Name -match "_iter${n}_" })
    Assert-True ($matchForIter.Count -eq 1) "exactly one output file is tagged iter$n"
}

# --- Scenario 3: Claude non-zero exit, no synthesis work evidence -----------------------
Write-Host "[3] Claude non-zero exit with NO evidence of synthesis work"
$v3 = New-TestVault -RowCount 3
$exit3 = Invoke-Runner -VaultRoot $v3 -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_CLAUDE_EXIT_CODE = '1'; WIKIAGENT_TEST_WRITE_RESULT = 'false' }
$r3 = Get-RunResult -VaultRoot $v3
$m3 = Get-Manifest -VaultRoot $v3
$diag3 = Get-Diagnostics -VaultRoot $v3
Assert-True ($r3.reasonCode -eq 'CLAUDE_EXIT_ERROR') "reasonCode is CLAUDE_EXIT_ERROR (got '$($r3.reasonCode)')"
Assert-True ($r3.batchesCompleted -eq 0) "batchesCompleted is 0"
Assert-True ((@($m3 | Where-Object { $_.synthesis_status -eq 'pending' }).Count) -eq 3) "all 3 sent rows remain 'pending' - an immediate crash with no wiki mutation evidence must NOT be falsely marked partial"
Assert-True ((@($m3 | Where-Object { $_.synthesis_status -eq 'partial' }).Count) -eq 0) "zero rows marked partial"
Assert-True ($r3.errorSnippet -match 'exited with code 1') "errorSnippet reflects the real exit code, not arbitrary stdout"
$outcome3 = $diag3 | Where-Object { $_.event -eq 'batch_outcome' } | Select-Object -First 1
Assert-True ((Get-Prop $outcome3 'partialMarked') -eq $false) "diagnostics record partialMarked=false"
Assert-True ((Get-Prop $outcome3 'mutationEvidenceCount') -eq 0) "diagnostics record mutationEvidenceCount=0"

# --- Scenario 3b: Claude non-zero exit, WITH evidence of synthesis work -----------------
Write-Host "[3b] Claude non-zero exit WITH evidence of synthesis work"
$v3b = New-TestVault -RowCount 3
$exit3b = Invoke-Runner -VaultRoot $v3b -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_CLAUDE_EXIT_CODE = '1'; WIKIAGENT_TEST_WRITE_RESULT = 'false'; WIKIAGENT_TEST_CREATE_WIKI_FILE = 'wiki/concepts/evidence.md' }
$r3b = Get-RunResult -VaultRoot $v3b
$m3b = Get-Manifest -VaultRoot $v3b
$diag3b = Get-Diagnostics -VaultRoot $v3b
Assert-True ($r3b.reasonCode -eq 'CLAUDE_EXIT_ERROR') "reasonCode is CLAUDE_EXIT_ERROR (got '$($r3b.reasonCode)')"
Assert-True ((@($m3b | Where-Object { $_.synthesis_status -eq 'partial' }).Count) -eq 3) "all 3 sent rows marked 'partial' - real wiki mutation evidence justifies it even though Claude then exited non-zero"
$outcome3b = $diag3b | Where-Object { $_.event -eq 'batch_outcome' } | Select-Object -First 1
Assert-True ((Get-Prop $outcome3b 'partialMarked') -eq $true) "diagnostics record partialMarked=true"
Assert-True ((Get-Prop $outcome3b 'mutationEvidenceCount') -eq 1) "diagnostics record mutationEvidenceCount=1"

# --- Scenario 4: Claude timeout, no evidence of synthesis work (killed before any work) --
Write-Host "[4] Claude timeout with NO evidence of synthesis work (timeout-before-work)"
$v4 = New-TestVault -RowCount 3 -TimeoutSeconds 3
$exit4 = Invoke-Runner -VaultRoot $v4 -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_CLAUDE_TIMEOUT_SECONDS = '8' }
$r4 = Get-RunResult -VaultRoot $v4
$m4 = Get-Manifest -VaultRoot $v4
$diag4 = Get-Diagnostics -VaultRoot $v4
Assert-True ($r4.reasonCode -eq 'SYNTHESIS_TIMEOUT') "reasonCode is SYNTHESIS_TIMEOUT (got '$($r4.reasonCode)')"
Assert-True ((@($m4 | Where-Object { $_.synthesis_status -eq 'pending' }).Count) -eq 3) "all 3 sent rows remain 'pending' - a job killed before touching anything must NOT be falsely marked partial"
Assert-True ((@($m4 | Where-Object { $_.synthesis_status -eq 'partial' }).Count) -eq 0) "zero rows marked partial"
$timeoutEvent = $diag4 | Where-Object { $_.event -eq 'claude_invocation_completed' } | Select-Object -First 1
Assert-True ((Get-Prop $timeoutEvent 'timedOut') -eq $true) "diagnostics record timedOut=true"
$outcome4 = $diag4 | Where-Object { $_.event -eq 'batch_outcome' } | Select-Object -First 1
Assert-True ((Get-Prop $outcome4 'partialMarked') -eq $false) "diagnostics record partialMarked=false"

# --- Scenario 4b: Claude timeout, WITH evidence of synthesis work before the hang -------
Write-Host "[4b] Claude timeout WITH evidence of synthesis work before the hang"
$v4b = New-TestVault -RowCount 3 -TimeoutSeconds 3
$exit4b = Invoke-Runner -VaultRoot $v4b -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_CLAUDE_TIMEOUT_SECONDS = '8'; WIKIAGENT_TEST_CREATE_WIKI_FILE = 'wiki/tools/evidence-before-hang.md' }
$r4b = Get-RunResult -VaultRoot $v4b
$m4b = Get-Manifest -VaultRoot $v4b
$diag4b = Get-Diagnostics -VaultRoot $v4b
Assert-True ($r4b.reasonCode -eq 'SYNTHESIS_TIMEOUT') "reasonCode is SYNTHESIS_TIMEOUT (got '$($r4b.reasonCode)')"
Assert-True ((@($m4b | Where-Object { $_.synthesis_status -eq 'partial' }).Count) -eq 3) "all 3 sent rows marked 'partial' - real wiki mutation evidence written before the hang justifies it"
$outcome4b = $diag4b | Where-Object { $_.event -eq 'batch_outcome' } | Select-Object -First 1
Assert-True ((Get-Prop $outcome4b 'partialMarked') -eq $true) "diagnostics record partialMarked=true"

# --- Scenario 5: missing synthesis-result.json, no evidence of synthesis work -----------
Write-Host "[5] Missing synthesis-result.json with NO evidence of synthesis work"
$v5 = New-TestVault -RowCount 3
$exit5 = Invoke-Runner -VaultRoot $v5 -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_WRITE_RESULT = 'false' }
$r5 = Get-RunResult -VaultRoot $v5
$m5 = Get-Manifest -VaultRoot $v5
Assert-True ($r5.reasonCode -eq 'SYNTHESIS_RESULT_MISSING') "reasonCode is SYNTHESIS_RESULT_MISSING (got '$($r5.reasonCode)')"
Assert-True ($r5.errorSnippet -notmatch 'Mock Claude: processing batch') "errorSnippet does not contain ordinary Claude progress stdout"
Assert-True ((@($m5 | Where-Object { $_.synthesis_status -eq 'pending' }).Count) -eq 3) "all 3 sent rows remain 'pending' - no wiki mutation evidence means no partial marking"
Assert-True ((@($m5 | Where-Object { $_.synthesis_status -eq 'partial' }).Count) -eq 0) "zero rows marked partial"

# --- Scenario 5b: missing synthesis-result.json, WITH evidence (the real incident's shape) --
# This is the exact shape of the real 2026-09-05 synthesis_batch_20260905_170255 incident:
# Claude substantially edited wiki pages but never produced a usable result file.
Write-Host "[5b] Missing synthesis-result.json WITH real wiki edits (matches the 2026-09-05 incident)"
$v5b = New-TestVault -RowCount 3
$exit5b = Invoke-Runner -VaultRoot $v5b -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_WRITE_RESULT = 'false'; WIKIAGENT_TEST_CREATE_WIKI_FILE = 'wiki/workflows/evidence.md' }
$r5b = Get-RunResult -VaultRoot $v5b
$m5b = Get-Manifest -VaultRoot $v5b
Assert-True ($r5b.reasonCode -eq 'SYNTHESIS_RESULT_MISSING') "reasonCode is SYNTHESIS_RESULT_MISSING (got '$($r5b.reasonCode)')"
Assert-True ((@($m5b | Where-Object { $_.synthesis_status -eq 'partial' }).Count) -eq 3) "all 3 sent rows marked 'partial' - matches the real incident's need for a durable attempted-but-incomplete signal"

# --- Scenario 6: malformed synthesis-result.json -----------------------------------------
Write-Host "[6] Malformed synthesis-result.json"
$v6 = New-TestVault -RowCount 3
$exit6 = Invoke-Runner -VaultRoot $v6 -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_RESULT_CONTENT = '{not valid json' }
$r6 = Get-RunResult -VaultRoot $v6
Assert-True ($r6.reasonCode -eq 'SYNTHESIS_RESULT_INVALID') "reasonCode is SYNTHESIS_RESULT_INVALID (got '$($r6.reasonCode)')"

# --- Scenario 7: wrong result batch ID ----------------------------------------------------
Write-Host "[7] Wrong result batch ID"
$v7 = New-TestVault -RowCount 3
$exit7 = Invoke-Runner -VaultRoot $v7 -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_RESULT_BATCH_OVERRIDE = 'stale_batch_id_from_another_run'; WIKIAGENT_TEST_PROCESSED_SUBSET = 'NONEXISTENT_ID' }
$r7 = Get-RunResult -VaultRoot $v7
$diag7 = Get-Diagnostics -VaultRoot $v7
Assert-True ($r7.reasonCode -eq 'SYNTHESIS_RESULT_BATCH_MISMATCH') "reasonCode is SYNTHESIS_RESULT_BATCH_MISMATCH (got '$($r7.reasonCode)')"
$checkEvent7 = $diag7 | Where-Object { $_.event -eq 'synthesis_result_check' } | Select-Object -First 1
Assert-True ((Get-Prop $checkEvent7 'batchMismatch') -eq $true) "diagnostics flag the batch-label mismatch"

# --- Scenario 8: zero QA progress ---------------------------------------------------------
Write-Host "[8] Zero QA progress"
$v8 = New-TestVault -RowCount 3
$exit8 = Invoke-Runner -VaultRoot $v8 -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_PROCESSED_SUBSET = 'NONEXISTENT_ID' }
$r8 = Get-RunResult -VaultRoot $v8
Assert-True ($r8.reasonCode -eq 'QA_ZERO_PROGRESS') "reasonCode is QA_ZERO_PROGRESS (got '$($r8.reasonCode)')"

# --- Scenario 9: partial batch --------------------------------------------------------------
Write-Host "[9] Partial batch (some, not all, included)"
$v9 = New-TestVault -RowCount 5
$exit9 = Invoke-Runner -VaultRoot $v9 -BatchSizeOverride '5' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_PROCESSED_SUBSET = 'V001,V002,V003' }
$r9 = Get-RunResult -VaultRoot $v9
$m9 = Get-Manifest -VaultRoot $v9
Assert-True ($r9.reasonCode -eq 'SYNTHESIS_PARTIAL') "reasonCode is SYNTHESIS_PARTIAL (got '$($r9.reasonCode)')"
Assert-True ((@($m9 | Where-Object { $_.synthesis_status -eq 'included' }).Count) -eq 3) "3 rows included"
Assert-True ((@($m9 | Where-Object { $_.synthesis_status -eq 'partial' }).Count) -eq 2) "2 rows marked partial"

# --- Scenario 10: usage-limit / continuity branch --------------------------------------------
Write-Host "[10] Usage-limit hit then continuity resume"
$v10 = New-TestVault -RowCount 3
$exit10 = Invoke-Runner -VaultRoot $v10 -BatchSizeOverride '3' -BatchIterationsOverride '2' -ContinuityOverride 'true' -Env @{ WIKIAGENT_TEST_LIMIT_HIT_FIRST_N = '1'; WIKIAGENT_TEST_SLEEP_SECONDS = '1' }
$r10 = Get-RunResult -VaultRoot $v10
$m10 = Get-Manifest -VaultRoot $v10
$diag10 = Get-Diagnostics -VaultRoot $v10
Assert-True ($null -eq $r10.reasonCode) "reasonCode cleared back to null after a clean continuity recovery (got '$($r10.reasonCode)')"
Assert-True ((@($m10 | Where-Object { $_.synthesis_status -eq 'included' }).Count) -eq 3) "all 3 rows eventually included via continuity resume"
Assert-True (@($diag10 | Where-Object { $_.event -eq 'continuity_sleep' }).Count -ge 1) "diagnostics recorded a continuity_sleep event"

# --- Scenario 11: runner exception between completed batches ---------------------------------
Write-Host "[11] Runner exception between completed batches"
$v11 = New-TestVault -RowCount 6
$exit11 = Invoke-Runner -VaultRoot $v11 -BatchSizeOverride '3' -BatchIterationsOverride '2' -Env @{ WIKIAGENT_TEST_THROW_AFTER_BATCH = '1' }
$r11 = Get-RunResult -VaultRoot $v11
$m11 = Get-Manifest -VaultRoot $v11
$diag11 = Get-Diagnostics -VaultRoot $v11
Assert-True ($exit11 -ne 0) "process exit code is non-zero (the exception propagated, so run-vault.ps1 still marks this stage FAILED)"
Assert-True ($r11.reasonCode -eq 'RUNNER_EXCEPTION') "reasonCode is RUNNER_EXCEPTION (got '$($r11.reasonCode)')"
Assert-True ($r11.batchesCompleted -eq 1) "batchesCompleted preserved as 1 (the completed batch before the exception is not lost)"
Assert-True ((@($m11 | Where-Object { $_.synthesis_status -eq 'included' }).Count) -eq 3) "the 3 rows from the completed first batch remain included despite the later crash"
Assert-True (@($diag11 | Where-Object { $_.event -eq 'runner_exception' }).Count -eq 1) "diagnostics recorded a runner_exception event"

# --- Scenario 13: authentication preflight ----------------------------------------------------
Write-Host "[13] Authentication preflight (AUTH_REQUIRED)"
$v13 = New-TestVault -RowCount 3
$exit13 = Invoke-Runner -VaultRoot $v13 -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_AUTH_LOGGED_IN = 'false' }
$r13 = Get-RunResult -VaultRoot $v13
$m13 = Get-Manifest -VaultRoot $v13
$diag13 = Get-Diagnostics -VaultRoot $v13
Assert-True ($r13.reasonCode -eq 'AUTH_REQUIRED') "reasonCode is AUTH_REQUIRED (got '$($r13.reasonCode)')"
Assert-True ($r13.batchesCompleted -eq 0) "batchesCompleted is 0"
Assert-True ((@($m13 | Where-Object { $_.synthesis_status -eq 'pending' }).Count) -eq 3) "manifest untouched - no rows changed"
Assert-True (@($diag13 | Where-Object { $_.event -eq 'batch_selected' }).Count -eq 0) "no batch was ever selected - zero Claude invocation attempted"
$promptFiles13 = @(Get-ChildItem -LiteralPath (Join-Path $v13 'config/prompts') -Filter '*.md' -ErrorAction SilentlyContinue)
Assert-True ($promptFiles13.Count -eq 0) "no prompt file was ever written"

# --- Also confirm auth preflight does NOT block a normal successful run (regression guard) ---
Write-Host "[13b] Authentication preflight does not block a logged-in run"
$v13b = New-TestVault -RowCount 3
$exit13b = Invoke-Runner -VaultRoot $v13b -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_AUTH_LOGGED_IN = 'true' }
$r13b = Get-RunResult -VaultRoot $v13b
Assert-True ($null -eq $r13b.reasonCode) "reasonCode is null when auth preflight reports logged in"
Assert-True ($r13b.batchesCompleted -eq 1) "batch proceeded normally"

# --- Scenario 14: diagnostic output filename uniqueness formula (algebraic) -------------
# Direct, deterministic proof that the runId+iteration naming scheme cannot collide even
# when $batchId itself does (its one-second timestamp resolution is exactly what made the
# old "<batchId>.output.txt" naming unsafe) - independent of real wall-clock timing, which
# scenario [2]'s 3-distinct-output-files check already corroborates against the real
# runner. Mirrors the exact "$runId + iter$iterationNumber + $batchId" formula in
# run-claude-synthesis.ps1.
Write-Host "[14] Diagnostic output filename uniqueness (formula-level, same batchId forced)"
$sameBatchId = 'synthesis_batch_20260101_000000'
function New-MockOutputFilename { param($RunId, $Iteration, $BatchId) "${RunId}_iter${Iteration}_$BatchId.output.txt" }
$pathA = New-MockOutputFilename -RunId 'run_20260101_000000_111' -Iteration 1 -BatchId $sameBatchId
$pathB = New-MockOutputFilename -RunId 'run_20260101_000000_111' -Iteration 2 -BatchId $sameBatchId
$pathC = New-MockOutputFilename -RunId 'run_20260101_000000_222' -Iteration 1 -BatchId $sameBatchId
Assert-True ($pathA -ne $pathB) "same run, different iteration -> different output filename even with an identical batchId"
Assert-True ($pathA -ne $pathC) "different run, same iteration -> different output filename even with an identical batchId"
Assert-True ($pathB -ne $pathC) "different run AND different iteration -> different output filename"

# --- Scenario 15: stale VALID synthesis-result.json pre-existing before invocation ------
Write-Host "[15] Stale VALID synthesis-result.json quarantined before a fresh invocation"
$v15 = New-TestVault -RowCount 3
'{"batch":"old_stale_batch_from_a_prior_run","processed":["V999"],"pages_created":[],"pages_updated":["wiki/concepts/stale.md"]}' |
    Out-File -LiteralPath (Join-Path $v15 'working/temp/synthesis-result.json') -Encoding utf8
$exit15 = Invoke-Runner -VaultRoot $v15 -BatchSizeOverride '3' -BatchIterationsOverride '1'
$r15 = Get-RunResult -VaultRoot $v15
$m15 = Get-Manifest -VaultRoot $v15
$diag15 = Get-Diagnostics -VaultRoot $v15
Assert-True ($exit15 -eq 0) "exit code is 0 - a stale result does not fail the run"
Assert-True ($null -eq $r15.reasonCode) "reasonCode is null - the fresh invocation's own result was used, not the stale one"
Assert-True ((@($m15 | Where-Object { $_.synthesis_status -eq 'included' }).Count) -eq 3) "the CURRENT batch's 3 real sources were included"
Assert-True ((@($m15 | Where-Object { $_.video_id -eq 'V999' })).Count -eq 0) "the stale result's video_id (V999, not a real row in this manifest) was never acted on"
$quarantineEvent15 = @($diag15 | Where-Object { $_.event -eq 'stale_result_quarantined' })
$quarantineEvent15First = $quarantineEvent15 | Select-Object -First 1
Assert-True ($quarantineEvent15.Count -eq 1) "diagnostics recorded exactly one stale_result_quarantined event"
Assert-True ((Get-Prop $quarantineEvent15First 'staleValid') -eq $true) "diagnostics correctly identified the stale file as valid JSON"
Assert-True ((Get-Prop $quarantineEvent15First 'staleBatch') -eq 'old_stale_batch_from_a_prior_run') "diagnostics captured the stale file's own batch label"
$quarantineDir15 = Join-Path $v15 'working/temp/synthesis-diagnostics/stale-results'
$quarantinedFiles15 = @(Get-ChildItem -LiteralPath $quarantineDir15 -Filter '*.json' -ErrorAction SilentlyContinue)
Assert-True ($quarantinedFiles15.Count -eq 1) "exactly one file was quarantined (preserved, not deleted)"
if ($quarantinedFiles15.Count -eq 1) {
    $quarantinedContent15 = Get-Content -LiteralPath $quarantinedFiles15[0].FullName -Raw
    Assert-True ($quarantinedContent15 -match 'old_stale_batch_from_a_prior_run') "the quarantined file's original content is intact and inspectable"
}

# --- Scenario 16: stale MALFORMED synthesis-result.json pre-existing before invocation --
Write-Host "[16] Stale MALFORMED synthesis-result.json quarantined before a fresh invocation"
$v16 = New-TestVault -RowCount 3
'{this is not valid json at all' | Out-File -LiteralPath (Join-Path $v16 'working/temp/synthesis-result.json') -Encoding utf8
$exit16 = Invoke-Runner -VaultRoot $v16 -BatchSizeOverride '3' -BatchIterationsOverride '1'
$r16 = Get-RunResult -VaultRoot $v16
$m16 = Get-Manifest -VaultRoot $v16
$diag16 = Get-Diagnostics -VaultRoot $v16
Assert-True ($exit16 -eq 0) "exit code is 0 - a stale malformed result does not fail the run"
Assert-True ($null -eq $r16.reasonCode) "reasonCode is null - the fresh invocation's own valid result was used"
Assert-True ((@($m16 | Where-Object { $_.synthesis_status -eq 'included' }).Count) -eq 3) "the CURRENT batch's 3 real sources were included despite the stale malformed leftover"
$quarantineEvent16 = @($diag16 | Where-Object { $_.event -eq 'stale_result_quarantined' })
$quarantineEvent16First = $quarantineEvent16 | Select-Object -First 1
Assert-True ($quarantineEvent16.Count -eq 1) "diagnostics recorded exactly one stale_result_quarantined event"
Assert-True ((Get-Prop $quarantineEvent16First 'staleValid') -eq $false) "diagnostics correctly identified the stale file as malformed"
Assert-True ([string]::IsNullOrEmpty((Get-Prop $quarantineEvent16First 'staleParseError')) -eq $false) "diagnostics captured the parse error for forensic inspection"
$quarantinedFiles16 = @(Get-ChildItem -LiteralPath (Join-Path $v16 'working/temp/synthesis-diagnostics/stale-results') -Filter '*.json' -ErrorAction SilentlyContinue)
Assert-True ($quarantinedFiles16.Count -eq 1) "the malformed file was preserved (quarantined), not deleted"

# --- Scenario 17: ordering-fix regression - zero-work failure stays pending even when --
# --- run-qa.ps1 itself writes unrelated wiki/source frontmatter during recovery --------
# This is the specific defect flagged in review round 2's second pass: mutation evidence
# was previously captured AFTER run-qa.ps1 ran, so run-qa.ps1's own frontmatter-sync
# backfill (over EVERY currently-included row, not just this batch's) could be misread as
# "Claude touched something this batch". Fixed by capturing $mutatedFiles BEFORE run-qa.ps1
# is invoked in both the timeout and normal zero-progress paths.
Write-Host "[17] Zero-work Claude failure stays 'pending' even when run-qa.ps1 writes unrelated wiki/source frontmatter"
$v17 = New-TestVaultWithUnsyncedHistoricalRow -RowCount 3
$exit17 = Invoke-Runner -VaultRoot $v17 -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_CLAUDE_EXIT_CODE = '1'; WIKIAGENT_TEST_WRITE_RESULT = 'false' }
$r17 = Get-RunResult -VaultRoot $v17
$m17 = Get-Manifest -VaultRoot $v17
$diag17 = Get-Diagnostics -VaultRoot $v17
Assert-True ($r17.reasonCode -eq 'CLAUDE_EXIT_ERROR') "reasonCode is CLAUDE_EXIT_ERROR (got '$($r17.reasonCode)')"
# Test-setup sanity check: confirm the contamination SOURCE actually fired - if this ever
# fails, the fixture stopped exercising the real risk and the scenario below proves nothing.
$historicalContent17 = Get-Content -LiteralPath (Join-Path $v17 'wiki/sources/historical-v000.md') -Raw
Assert-True ($historicalContent17 -match 'synthesis_status:\s*included') "setup sanity check: run-qa.ps1's frontmatter sync really did rewrite the unrelated historical row during this batch's recovery"
# The actual regression assertion: despite that unrelated write landing inside this
# batch's own [$batchStartTime, now) window, THIS batch's 3 sources - which Claude itself
# never touched - must remain 'pending', not a falsely-manufactured 'partial'.
$currentBatchRows17 = @($m17 | Where-Object { $_.video_id -in @('V001', 'V002', 'V003') })
Assert-True ((@($currentBatchRows17 | Where-Object { $_.synthesis_status -eq 'pending' }).Count) -eq 3) "all 3 of THIS batch's rows remain 'pending' - the unrelated frontmatter rewrite was correctly excluded"
Assert-True ((@($currentBatchRows17 | Where-Object { $_.synthesis_status -eq 'partial' }).Count) -eq 0) "zero of THIS batch's rows were falsely marked partial due to run-qa.ps1's own unrelated write"
$outcome17 = $diag17 | Where-Object { $_.event -eq 'batch_outcome' } | Select-Object -First 1
Assert-True ((Get-Prop $outcome17 'partialMarked') -eq $false) "diagnostics record partialMarked=false"
Assert-True ((Get-Prop $outcome17 'mutationEvidenceCount') -eq 0) "diagnostics record mutationEvidenceCount=0 - the historical rewrite happened AFTER the pre-QA snapshot was taken"

# --- Scenario 17b: same ordering-fix regression, timeout path --------------------------
Write-Host "[17b] Timeout with zero Claude work stays 'pending' even when run-qa.ps1 writes unrelated wiki/source frontmatter"
$v17b = New-TestVaultWithUnsyncedHistoricalRow -RowCount 3 -TimeoutSeconds 3
$exit17b = Invoke-Runner -VaultRoot $v17b -BatchSizeOverride '3' -BatchIterationsOverride '1' -Env @{ WIKIAGENT_TEST_CLAUDE_TIMEOUT_SECONDS = '8' }
$r17b = Get-RunResult -VaultRoot $v17b
$m17b = Get-Manifest -VaultRoot $v17b
$diag17b = Get-Diagnostics -VaultRoot $v17b
Assert-True ($r17b.reasonCode -eq 'SYNTHESIS_TIMEOUT') "reasonCode is SYNTHESIS_TIMEOUT (got '$($r17b.reasonCode)')"
$historicalContent17b = Get-Content -LiteralPath (Join-Path $v17b 'wiki/sources/historical-v000.md') -Raw
Assert-True ($historicalContent17b -match 'synthesis_status:\s*included') "setup sanity check: run-qa.ps1's frontmatter sync really did rewrite the unrelated historical row during timeout recovery"
$currentBatchRows17b = @($m17b | Where-Object { $_.video_id -in @('V001', 'V002', 'V003') })
Assert-True ((@($currentBatchRows17b | Where-Object { $_.synthesis_status -eq 'pending' }).Count) -eq 3) "all 3 of THIS batch's rows remain 'pending' after a timeout, despite the unrelated frontmatter rewrite"
Assert-True ((@($currentBatchRows17b | Where-Object { $_.synthesis_status -eq 'partial' }).Count) -eq 0) "zero of THIS batch's rows were falsely marked partial"
$outcome17b = $diag17b | Where-Object { $_.event -eq 'batch_outcome' } | Select-Object -First 1
Assert-True ((Get-Prop $outcome17b 'partialMarked') -eq $false) "diagnostics record partialMarked=false"
Assert-True ((Get-Prop $outcome17b 'mutationEvidenceCount') -eq 0) "diagnostics record mutationEvidenceCount=0"

Write-Host ""
Write-Host "=== Summary: $($script:passCount) passed, $($script:failCount) failed ==="
if ($script:failCount -gt 0) {
    Write-Host "Failures:"
    foreach ($f in $script:failures) { Write-Host "  - $f" }
}

Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue

if ($script:failCount -gt 0) { exit 1 }
exit 0
