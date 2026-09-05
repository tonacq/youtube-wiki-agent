<#
.SYNOPSIS
Invokes Claude Code headlessly against this vault's pending sources, in batches, or in
-LintReview mode for the scheduled report-only monthly review.

.DESCRIPTION
Critical safety rule carried over from the production incident history (Finding D/E in
the validation record): this script NEVER writes synthesis_status = included into
manifest.csv directly. Per-batch, it calls run-qa.ps1 itself (the sole authoritative
reconciler for the included transition) so manifest-state comparison between batches is
real, not stale - run-qa.ps1's own file is not modified by this change and remains
idempotent/safe to call more than once per run.

One narrow, deliberate exception to that rule was added following the 2026-08-24
SabrinaRamonov_Rev00 incident (18/20 silently reported as TARGET_MET): when a batch
comes back with fewer included rows than sources sent, this script marks the specific
dropped rows synthesis_status = 'partial' (never 'included' - that transition still
belongs to run-qa.ps1 alone). 'partial' is a distinct, durable "attempted but
incomplete" signal a future run/operator can tell apart from a row that was never
attempted at all ('pending'). It does not conflict with run-qa.ps1's Finding-D guard
(never downgrade an 'included' row) since a 'partial' row is, by construction, not yet
included; run-qa.ps1's disk-truth fallback can still promote it to 'included' later,
because that fallback's eligibility check is "not already included", not "must be
pending".

Extended following the 2026-09-05 SabrinaRamonov_Rev01 reliability investigation
(synthesis_batch_20260905_170255: Claude substantially edited wiki pages but never wrote
a usable synthesis-result.json; the run reported SYNTHESIS_ERROR with an errorSnippet
that was actually ordinary Claude progress stdout, and none of that batch's 10 sources
were durably marked as attempted). A zero-manifest-progress batch (not just a
some-but-not-all batch) can now also promote its sources to 'partial' - but only when
there is real evidence synthesis actually happened, never merely because a Claude
invocation was attempted. "Attempted" and "partially synthesized" are deliberately kept
distinct: every attempt (job started, exit code, timeout) is unconditionally recorded in
the durable diagnostics JSONL regardless of outcome, but synthesis_status only ever
moves off 'pending' when Get-WikiMutationEvidence finds at least one file under wiki/
with a write time after this batch's own invocation started - i.e. Claude demonstrably
touched something, even though run-qa.ps1 (for whatever reason - a missing/invalid
result, a genuine reconciliation gap) could not attribute it to specific video_ids. A
batch that errors out or times out before touching any wiki file (e.g. an immediate
auth/crash failure, or a timeout that fires while Claude is still thinking) leaves its
sources at bare 'pending', exactly as if nothing had been attempted - because nothing
observable was. This mirrors the same disk-truth-over-guessing principle run-qa.ps1's
own fallback already uses, and closes the exact gap the 2026-09-05 incident exposed (real
wiki edits with zero durable trace) without over-claiming partial work that never
happened.

Batches of batch_size pending (or previously-partial) rows, up to batch_iterations
calls. Each call runs under a Start-Job/Wait-Job timeout (claude_call_timeout_seconds).
Progress detection is primary manifest-state comparison (did synthesis_status flip for
at least one row this batch, via run-qa.ps1's reconciliation); on zero progress, falls
back to a regex match on the captured claude -p output for a session/usage/rate-limit
phrase. If neither signal fires, stops safely rather than looping or guessing - but now
classifies WHY using real evidence (Claude's process exit code, and whether
working/temp/synthesis-result.json existed/parsed/matched this batch) instead of the
previous single generic SYNTHESIS_ERROR bucket that could mislabel ordinary Claude
progress stdout as an "error". See the reason-code list below.

Full-batch completeness is checked separately from "did anything happen at all": each
batch's own input video_ids are diffed against which of them are actually 'included'
after run-qa.ps1 reconciles that batch. A batch that returns some-but-not-all of its
inputs as included is SYNTHESIS_PARTIAL, not treated as identical to a full success -
this is the exact gap the 2026-08-24 incident exposed (an 8-of-10 batch silently counted
as a completed iteration with no error, park, or timeout signal for the other 2).

continuity=true: on a detected limit hit, extracts a reset time from the same matched
output (ported from the proven standalone predecessor's Get-ResetSleepSeconds pattern),
sleeps until reset+buffer, and resumes the same batch. This only works if the same VM
process survives the full sleep; if it dies mid-sleep, nothing auto-resumes until the
next independently-scheduled systemd trigger - expected, not a bug, not solved here.
On resume, if this run has already had a partial batch, the reason code is NOT cleared
back to a clean $null the way a plain limit-hit recovery is - it propagates
SYNTHESIS_PARTIAL instead, so a later successful continuity resume can never mask an
earlier silent drop the way TARGET_MET masked the 2026-08-24 incident. When continuity
resumes (for any stop condition - limit hit, error, or a partial batch itself), the next
batch always prioritizes any still-not-included 'partial' rows from earlier in this run
ahead of fresh 'pending' rows, so stragglers get first crack at the retry rather than
being permanently skipped in favor of new work.

Also carries over the fix for stale-prompt selection: each batch's prompt file is fresh,
generated at the start of that batch's iteration.

.NOTES
Reason codes written to working/temp/synthesis-run-result.json's "reasonCode" field
(also mirrored, per-batch, into the durable diagnostics JSONL described below):
  (null)                            - clean run, no problem tier code applies
  AUTH_REQUIRED                     - claude auth preflight reports not logged in; no
                                       Claude invocation was attempted this run at all
  SYNTHESIS_TIMEOUT                 - a Claude call exceeded claude_call_timeout_seconds
                                       (this is "CLAUDE_TIMEOUT" in the fix brief's
                                       vocabulary - reusing the existing, already-wired
                                       code rather than introducing a synonym)
  CLAUDE_EXIT_ERROR                 - claude's process exited non-zero and the batch made
                                       zero manifest progress
  SYNTHESIS_RESULT_MISSING          - claude exited 0 (or non-zero was already handled
                                       above) but working/temp/synthesis-result.json did
                                       not exist after the call
  SYNTHESIS_RESULT_INVALID          - the result file existed but failed to parse as JSON
  SYNTHESIS_RESULT_BATCH_MISMATCH   - the result file's "batch" field did not match the
                                       batch actually sent, AND the batch made zero
                                       progress (a mismatch alongside real progress is
                                       only logged as an anomaly, never blocks inclusion -
                                       run-qa.ps1 matches by video_id, not by batch label)
  QA_ZERO_PROGRESS                  - the result file was present, valid, and correctly
                                       labeled, but run-qa.ps1's reconciliation still
                                       produced no newly-included rows for it
  SYNTHESIS_ERROR                   - last-resort catch-all; should be rare now that the
                                       above codes cover the previously-generic cases
  SYNTHESIS_LIMIT_HIT               - session/usage/rate-limit phrase matched in output
  SYNTHESIS_PARTIAL                 - some (but not necessarily all) of a run's attempted
                                       sources ended up not included; durable for the
                                       whole run once set (see .DESCRIPTION)
  RUNNER_EXCEPTION                  - an unexpected PowerShell exception was thrown
                                       somewhere in the batch lifecycle (config already
                                       resolved, manifest present) - caught by the
                                       top-level try/catch/finally below so it cannot
                                       disappear without a durable record, then rethrown
                                       so run-vault.ps1 still marks this stage FAILED

Durable per-batch diagnostics (survive process termination; independent of console
output): working/temp/synthesis-diagnostics/<runId>.jsonl - one JSON object per line,
per lifecycle event (run start, auth preflight, each iteration entered, stale-result
quarantine, batch selected, Claude job started/completed, result-file
presence/validity/batch-match, QA start/end/counts, batch outcome/classification/wiki
mutation evidence, batch counter increment, iteration completed). Each Claude call's full
captured stdout+stderr is also persisted verbatim to
working/temp/synthesis-diagnostics/<runId>_iter<N>_<batchId>.output.txt (the runId+
iteration prefix guarantees a unique filename per attempt even though <batchId> itself
only has one-second timestamp resolution and could otherwise collide across two very
fast, close-together invocations) - the errorSnippet field in synthesis-run-result.json
is now only ever populated with text this script has actual evidence is describing a
real problem (an exit code, a missing/invalid/mismatched result file, or a QA
reconciliation gap), never an arbitrary line of ordinary Claude stdout.

Stale synthesis-result.json handling: immediately before each batch's own invocation (so
it applies on the very first iteration of a run too, not just between batches), any
working/temp/synthesis-result.json already on disk is quarantined - moved, never deleted
- to working/temp/synthesis-diagnostics/stale-results/, with its parsed-or-not content
preserved and a diagnostics event recorded, before the new invocation starts. This can
only be a leftover from an earlier attempt (this run's own previous batch always
archives or quarantines its result before the next one starts; run-qa.ps1 itself only
ever archives a result file it successfully consumed) - never something the upcoming
batch could have legitimately produced yet - so the new batch can never ambiguously
inherit a prior attempt's result. Does not change run-qa.ps1's own normal
archive-on-success contract (that only ever fires for a result run-qa.ps1 itself reads
and processes within the same call).

Test-only hooks (never active unless the corresponding env var is explicitly set, so
production behavior is unchanged when unset):
  WIKIAGENT_MOCK_CLAUDE_SCRIPT     - path to a script/executable to invoke instead of the
                                      real `claude` CLI (including its `auth status`
                                      subcommand, used by the preflight check below).
                                      Used by agent/tests' mock harness.
  WIKIAGENT_TEST_SLEEP_SECONDS     - overrides Get-ResetSleepSeconds's computed sleep, so
                                      continuity-retry tests don't block for real minutes.
  WIKIAGENT_TEST_THROW_AFTER_BATCH - if set to an integer N, deliberately throws right
                                      after the Nth batch completes (before starting
                                      batch N+1), so tests can exercise the top-level
                                      try/catch/finally's RUNNER_EXCEPTION path without
                                      faking a real bug. Never read unless set.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [switch]$LintReview,
    [string]$BatchSizeOverride = '',
    [string]$BatchIterationsOverride = '',
    [string]$ContinuityOverride = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AgentRoot = Split-Path -Parent $PSScriptRoot   # .../agent
$configPath = Join-Path $VaultRoot 'config/vault.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$claudeMd = Join-Path $VaultRoot 'config/claude.md'
$promptsDir = Join-Path $VaultRoot 'config/prompts'
New-Item -ItemType Directory -Force -Path $promptsDir | Out-Null

# Test hook: WIKIAGENT_MOCK_CLAUDE_SCRIPT swaps in a stand-in for the real `claude` CLI.
# Resolved once, used everywhere below `claude` would otherwise be invoked, so a run with
# the env var unset is byte-for-byte the same code path as before this change.
$claudeCommand = if ($env:WIKIAGENT_MOCK_CLAUDE_SCRIPT) { $env:WIKIAGENT_MOCK_CLAUDE_SCRIPT } else { 'claude' }

if (-not (Get-Command $claudeCommand -ErrorAction SilentlyContinue)) {
    Write-Warning "$claudeCommand not found on PATH. Skipping synthesis (this is expected in a build/test sandbox)."
    return
}

# --- Durable diagnostics -------------------------------------------------------------
# working/temp survives process termination (unlike console output, which a killed
# systemd/ssh session simply loses). One JSONL file per run, one line per lifecycle
# event, flushed immediately (Add-Content opens/appends/closes per call) so a crash
# mid-run still leaves every event up to that point on disk.
$diagnosticsDir = Join-Path $VaultRoot 'working/temp/synthesis-diagnostics'
New-Item -ItemType Directory -Force -Path $diagnosticsDir | Out-Null
$runId = "run_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$PID"
$runDiagnosticsPath = Join-Path $diagnosticsDir "$runId.jsonl"

function Write-Diag {
    param([string]$Event, [hashtable]$Fields = @{})
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        runId     = $runId
        event     = $Event
    }
    foreach ($key in $Fields.Keys) { $record[$key] = $Fields[$key] }
    ($record | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath $runDiagnosticsPath -Encoding utf8
}

# --- Auth preflight (Fix 4) ------------------------------------------------------------
# `claude auth status --json` is confirmed (empirically, against the real installed CLI:
# 2.1.228) to be a reliable, fully non-interactive, non-browser check: it returns
# {"loggedIn":true,...} / exit 0 when authenticated, and {"loggedIn":false,...} / exit 1
# against an isolated/empty config dir with no session - it never attempts to open a
# browser or prompt for input either way. Run under the same Start-Job/Wait-Job timeout
# pattern as the real synthesis call so a hung auth check can't block the run forever.
#
# Deliberately fails OPEN (treated as Ok, synthesis proceeds) on anything short of an
# explicit, parsed "loggedIn": false - a timeout, an unparseable response, or a CLI that
# doesn't support `auth status` at all is NOT reliable evidence of a real auth problem,
# and per the fix brief this is a secondary hardening item, not a hard gate to enforce at
# the cost of blocking otherwise-healthy runs on an ambiguous signal. Only a clean,
# parsed "not logged in" answer is trusted to block a run before it spends any Claude
# invocation.
function Test-ClaudeAuthPreflight {
    param([string]$ClaudeCmd, [int]$TimeoutSeconds = 30)
    try {
        $authJob = Start-Job -ScriptBlock {
            param($cmd)
            $out = & $cmd auth status --json 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
        } -ArgumentList $ClaudeCmd

        $done = Wait-Job -Job $authJob -Timeout $TimeoutSeconds
        if (-not $done) {
            Stop-Job -Job $authJob -ErrorAction SilentlyContinue
            Remove-Job -Job $authJob -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Ok = $true; Reason = 'AUTH_PREFLIGHT_TIMEOUT'; Detail = "claude auth status did not respond within ${TimeoutSeconds}s; proceeding without a preflight verdict." }
        }

        $authResult = Receive-Job -Job $authJob
        Remove-Job -Job $authJob -Force -ErrorAction SilentlyContinue

        try {
            $parsed = $authResult.Output | ConvertFrom-Json
        } catch {
            return [pscustomobject]@{ Ok = $true; Reason = 'AUTH_PREFLIGHT_UNAVAILABLE'; Detail = "claude auth status output was not parseable JSON (exit=$($authResult.ExitCode)); proceeding without a preflight verdict. Raw: $($authResult.Output)" }
        }

        if ($parsed.PSObject.Properties['loggedIn'] -and $parsed.loggedIn -eq $true) {
            return [pscustomobject]@{ Ok = $true; Reason = $null; Detail = "authMethod=$($parsed.authMethod) subscriptionType=$($parsed.subscriptionType)" }
        }
        if ($parsed.PSObject.Properties['loggedIn'] -and $parsed.loggedIn -eq $false) {
            return [pscustomobject]@{ Ok = $false; Reason = 'AUTH_REQUIRED'; Detail = "claude auth status reports loggedIn=false (authMethod=$($parsed.authMethod))." }
        }
        return [pscustomobject]@{ Ok = $true; Reason = 'AUTH_PREFLIGHT_UNAVAILABLE'; Detail = "claude auth status output had no boolean 'loggedIn' field; proceeding without a preflight verdict." }
    } catch {
        return [pscustomobject]@{ Ok = $true; Reason = 'AUTH_PREFLIGHT_UNAVAILABLE'; Detail = "auth preflight threw: $($_.Exception.Message)" }
    }
}

Write-Diag -Event 'run_start' -Fields @{ vaultRoot = $VaultRoot; lintReview = [bool]$LintReview; claudeCommand = $claudeCommand }

if ($LintReview) {
    $authCheck = Test-ClaudeAuthPreflight -ClaudeCmd $claudeCommand
    Write-Diag -Event 'auth_preflight' -Fields @{ ok = $authCheck.Ok; reason = $authCheck.Reason; detail = $authCheck.Detail; context = 'lint-review' }
    if (-not $authCheck.Ok) {
        Write-Warning "Claude auth preflight failed ($($authCheck.Reason)): $($authCheck.Detail) Skipping lint-review (no claude invocation attempted)."
        return
    }

    $lintPrompt = Join-Path $promptsDir "lint_review_$(Get-Date -Format 'yyyyMMdd').md"
    @"
# Scheduled lint-review

Follow the "Scheduled lint-review runs" section of config/claude.md exactly.
This is report-only: analyze the vault, write reports/lint_report_$(Get-Date -Format 'yyyy-MM-dd').md,
make no other changes.
"@ | Out-File -LiteralPath $lintPrompt -Encoding utf8

    Push-Location $VaultRoot
    try {
        & $claudeCommand -p (Get-Content -LiteralPath $lintPrompt -Raw) --permission-mode acceptEdits
        if ($LASTEXITCODE -ne 0) { throw "claude CLI exited with code $LASTEXITCODE (lint-review)" }
    } finally { Pop-Location }
    return
}

$manifestPath = Join-Path $VaultRoot 'working/manifest.csv'

# Resolution order: schedule.csv row override (per-run, optional) wins over config/vault.json
# (per-vault default). If genuinely absent from BOTH, batch_size/batch_iterations remain a
# hard throw - no silent default - since these are deliberately-tuned values, not something
# safe to guess.
$batchSizeSource = 'vault.json'
if ($BatchSizeOverride.Trim() -ne '') {
    $batchSize = [int]$BatchSizeOverride
    $batchSizeSource = 'schedule.csv'
} elseif ($config.PSObject.Properties['batch_size'] -and $config.batch_size) {
    $batchSize = [int]$config.batch_size
} else {
    throw "batch_size is required in schedule.csv override or config/vault.json (no silent default)"
}

$batchIterationsSource = 'vault.json'
if ($BatchIterationsOverride.Trim() -ne '') {
    $batchIterations = [int]$BatchIterationsOverride
    $batchIterationsSource = 'schedule.csv'
} elseif ($config.PSObject.Properties['batch_iterations'] -and $config.batch_iterations) {
    $batchIterations = [int]$config.batch_iterations
} else {
    throw "batch_iterations is required in schedule.csv override or config/vault.json (no silent default)"
}

# Set-StrictMode -Version Latest throws PropertyNotFoundException on a genuinely-absent
# JSON property (unlike a present-but-empty one) - confirmed the hard way in Stage 3
# testing (continuity is legitimately absent from every real vault.json today, since it
# defaults to false). Existence-checked via .PSObject.Properties first, matching the
# pattern already used elsewhere in this codebase (e.g. ingest-youtube.ps1's
# transcript_attempts backfill) rather than bare property access.
$continuitySource = 'vault.json'
if ($ContinuityOverride.Trim() -ne '') {
    $continuity = [bool]::Parse($ContinuityOverride)
    $continuitySource = 'schedule.csv'
} else {
    $continuity = if ($config.PSObject.Properties['continuity'] -and $config.continuity) { [bool]$config.continuity } else { $false }
}
$claudeTimeoutSeconds = if ($config.PSObject.Properties['claude_call_timeout_seconds'] -and $config.claude_call_timeout_seconds) { [int]$config.claude_call_timeout_seconds } else { 1800 }

# Ported from the proven standalone predecessor's Get-ResetSleepSeconds (confirmed
# real/working against actual CLI output earlier this session) - regexes the same
# captured text used for the limit-hit fallback match for an explicit reset time.
# DefaultSleepMinutes covers the case where a limit phrase matched (e.g. "session limit")
# but no parseable "resets HH(:MM)am/pm" clause was present in the captured text.
function Get-ResetSleepSeconds {
    param(
        [string]$ClaudeOutput,
        [int]$DefaultSleepMinutes = 60,
        [int]$BufferMinutes = 5
    )
    # Test hook - see .NOTES above. Lets continuity-retry tests run in real seconds
    # instead of blocking for up to an hour.
    if ($env:WIKIAGENT_TEST_SLEEP_SECONDS) { return [int]$env:WIKIAGENT_TEST_SLEEP_SECONDS }

    if ($ClaudeOutput -match "resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)") {
        $hour = [int]$Matches[1]
        $minute = 0
        if ($Matches[2]) { $minute = [int]$Matches[2] }
        $ampm = $Matches[3].ToLower()
        if ($ampm -eq "pm" -and $hour -lt 12) { $hour += 12 }
        if ($ampm -eq "am" -and $hour -eq 12) { $hour = 0 }
        $now = Get-Date
        $reset = Get-Date -Hour $hour -Minute $minute -Second 0
        if ($reset -le $now) { $reset = $reset.AddDays(1) }
        $wake = $reset.AddMinutes($BufferMinutes)
        $seconds = [int][Math]::Ceiling(($wake - $now).TotalSeconds)
        if ($seconds -lt 60) { $seconds = 60 }
        return $seconds
    }
    return ($DefaultSleepMinutes * 60)
}

function Get-IncludedCount {
    @(Import-Csv -LiteralPath $manifestPath | Where-Object { $_.synthesis_status -eq 'included' }).Count
}

# The one narrow exception to "this script never writes synthesis_status" (see top-of-file
# .DESCRIPTION). Only ever promotes a row to 'partial', never to/from 'included', and only
# for rows this run's own batch sent to Claude but that did not come back included. Uses
# the same read-modify-tmp-write-move pattern run-qa.ps1 uses for its own manifest writes,
# for the same crash-safety reason.
function Set-PartialStatus {
    param(
        [string]$ManifestPath,
        [string[]]$VideoIds
    )
    if (-not $VideoIds -or $VideoIds.Count -eq 0) { return }
    $rows = @(Import-Csv -LiteralPath $ManifestPath)
    $touched = $false
    foreach ($row in $rows) {
        if ($VideoIds -notcontains $row.video_id) { continue }
        # Finding D's rule (never downgrade 'included') applies here too - only promote a
        # still-not-included row to 'partial'; never touch a row run-qa.ps1 already
        # marked included between our read and this write (e.g. a shared-citation
        # disk-truth match on a later pass).
        if ($row.synthesis_status -eq 'included') { continue }
        $row.synthesis_status       = 'partial'
        $row.synthesis_last_checked = (Get-Date).ToString('yyyy-MM-dd')
        $row.last_updated           = (Get-Date).ToString('o')
        $touched = $true
    }
    if ($touched) {
        $tmp = "$ManifestPath.tmp"
        $rows | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $ManifestPath -Force
    }
}

# Fix (review round 2, item 1): "a Claude invocation was attempted" is not the same
# claim as "a source was partially synthesized". Scans wiki/ (the same directories
# Claude itself can actually write to) for any file whose write time is after this
# batch's own invocation started - i.e. real, observable evidence something was
# produced, independent of whether run-qa.ps1 could attribute it to specific video_ids
# (its own disk-truth fallback has a documented, accepted limitation there - see
# run-qa.ps1). This is deliberately vault-wide, not scoped to this batch's own source
# files, because Claude may edit a shared/cumulative page (concepts/tools/workflows) that
# doesn't map to one video_id - the same reason run-qa.ps1's own fallback can't do
# precise per-row attribution either. A small negative buffer absorbs any clock-read
# ordering slop between capturing $Since and the filesystem's own write timestamp.
function Get-WikiMutationEvidence {
    param([string]$VaultRoot, [datetime]$Since)
    # Built as an explicit List, not a filtered pipeline, and returned via
    # Write-Output -NoEnumerate: PowerShell auto-unrolls a collection with zero elements
    # into $null on the caller's side (a well-known trap - confirmed empirically against
    # this exact pattern: `return @(pipeline-that-matches-nothing)` reliably produced
    # $null here, not an empty array, even with the array subexpression operator inside
    # the function). Every call site below depends on $mutatedFiles.Count always working
    # - $null.Count throws under Set-StrictMode - so this must never come back as $null.
    $wikiDir = Join-Path $VaultRoot 'wiki'
    $matched = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $wikiDir) {
        foreach ($file in (Get-ChildItem -LiteralPath $wikiDir -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -gt $Since) { $matched.Add($file.FullName) }
        }
    }
    Write-Output -NoEnumerate $matched
}

# Fix (review round 2, item 3): a batch must never ambiguously inherit a result file left
# over from an earlier attempt - this run's own previous batch (quarantined here again
# next iteration if somehow still present) or a prior run that crashed between Claude
# writing a result and run-qa.ps1 consuming it. Called immediately before every batch's
# invocation, including the first one in a run. Never deletes - moves the file, with
# best-effort parsed provenance, to a timestamped quarantine location so it stays
# available for forensic reconciliation. Does not touch run-qa.ps1's own
# archive-on-success behavior: that only ever fires for a result run-qa.ps1 itself reads
# and successfully processes within the same call, which by construction cannot be the
# file this function finds (this function always runs, and always clears the path,
# before the upcoming invocation - the one call that could legitimately produce a new
# result for THIS batch - even starts).
function Backup-StaleSynthesisResult {
    param([string]$VaultRoot, [string]$UpcomingBatchId)
    $resultPath = Join-Path $VaultRoot 'working/temp/synthesis-result.json'
    if (-not (Test-Path -LiteralPath $resultPath)) { return $null }

    $staleDir = Join-Path $VaultRoot 'working/temp/synthesis-diagnostics/stale-results'
    New-Item -ItemType Directory -Force -Path $staleDir | Out-Null
    $quarantinePath = Join-Path $staleDir "stale_synthesis-result_$(Get-Date -Format 'yyyyMMdd_HHmmss_fff')_before_$UpcomingBatchId.json"

    $staleValid = $false
    $staleBatch = $null
    $staleParseError = ''
    try {
        $staleParsed = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $staleValid = $true
        if ($staleParsed.PSObject.Properties['batch']) { $staleBatch = [string]$staleParsed.batch }
    } catch {
        $staleParseError = $_.Exception.Message
    }

    Move-Item -LiteralPath $resultPath -Destination $quarantinePath -Force
    [pscustomobject]@{ QuarantinePath = $quarantinePath; Valid = $staleValid; Batch = $staleBatch; ParseError = $staleParseError }
}

$synthesisRunResultPath = Join-Path $VaultRoot 'working/temp/synthesis-run-result.json'
function Write-SynthesisRunResult {
    param(
        # Deliberately untyped (not [string]) - a [string]-typed param coerces a genuine
        # $null (clean-success reasonCode) into an empty string, so ConvertTo-Json would
        # emit "" instead of a real JSON null. run-vault.ps1's own falsy-check treats both
        # the same either way, but the diagnostics/synthesis-run-result.json contract
        # should say what actually happened, not an artifact of PowerShell's parameter
        # type coercion.
        $ReasonCode,
        [int]$BatchesCompleted = 0,
        [string]$ErrorSnippet = '',
        [string]$SleptUntil = '',
        [array]$DroppedSources = @()
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $synthesisRunResultPath -Parent) | Out-Null
    [ordered]@{
        reasonCode            = $ReasonCode
        batchesCompleted      = $BatchesCompleted
        batchesPlanned        = $batchIterations
        targetThisRun         = ($batchSize * $batchIterations)
        batchSize             = $batchSize
        batchSizeSource       = $batchSizeSource
        batchIterations       = $batchIterations
        batchIterationsSource = $batchIterationsSource
        continuity            = $continuity
        continuitySource      = $continuitySource
        actualSynthesized     = $actualSynthesized
        errorSnippet          = $ErrorSnippet
        sleptUntil            = $SleptUntil
        droppedSources        = $DroppedSources
        runId                 = $runId
        diagnosticsFile       = $runDiagnosticsPath
        timestamp             = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $synthesisRunResultPath -Encoding utf8 -Force
}

if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Host "No manifest found; nothing to synthesize."; return }

$includedBefore = Get-IncludedCount
$actualSynthesized = 0
$batchesCompleted = 0
$iterationNumber = 0
$reasonCode = $null
$errorSnippet = ''
$sleptUntil = ''
$hadPartialThisRun = $false
# Ordered dict keyed by video_id, holding only sources still un-recovered as of "right
# now" in this run - a later batch that successfully includes a straggler removes it
# here, so the final droppedSources reported to run-vault.ps1/Telegram reflects the
# run's real outcome (empty if continuity fully recovered every straggler), while the
# reasonCode itself stays SYNTHESIS_PARTIAL for the whole run regardless (see
# .DESCRIPTION) as a durable "this run needed recovery" signal.
$droppedSourcesThisRun = [ordered]@{}
$diagnosticsLogPath = Join-Path $VaultRoot 'working/temp/synthesis-partial-diagnostics.jsonl'

# --- Fix 2: top-level try/catch/finally around the synthesis lifecycle ---------------
# Everything from here on (auth preflight through the last batch) is wrapped so an
# unexpected PowerShell exception - e.g. between batches, or inside a called script like
# run-qa.ps1 - cannot vanish without a durable diagnostic record and a written
# synthesis-run-result.json. All state Write-SynthesisRunResult/the finally block reads
# is already predeclared above with safe defaults, so finally can always run cleanly even
# if the exception happened before those values were ever updated.
try {
    $authCheck = Test-ClaudeAuthPreflight -ClaudeCmd $claudeCommand
    Write-Diag -Event 'auth_preflight' -Fields @{ ok = $authCheck.Ok; reason = $authCheck.Reason; detail = $authCheck.Detail; context = 'batch-synthesis' }

    if (-not $authCheck.Ok) {
        $reasonCode = 'AUTH_REQUIRED'
        $errorSnippet = $authCheck.Detail
        Write-Warning "Claude auth preflight failed: $($authCheck.Detail) Skipping synthesis for this run (batchesCompleted=0, no claude invocation attempted)."
    } else {

    while ($batchesCompleted -lt $batchIterations) {
        $iterationNumber++
        $manifest = @(Import-Csv -LiteralPath $manifestPath)

        # Partial stragglers (from earlier in this run, or left over from a previous run)
        # always take priority over never-yet-attempted pending rows - see .DESCRIPTION.
        $partialRows = @($manifest | Where-Object { $_.ingest_status -eq 'ingested' -and $_.synthesis_status -eq 'partial' })
        $pendingRows = @($manifest | Where-Object { $_.ingest_status -eq 'ingested' -and $_.synthesis_status -eq 'pending' })
        $candidates  = @($partialRows + $pendingRows)

        Write-Diag -Event 'iteration_entered' -Fields @{ iteration = $iterationNumber; batchesCompleted = $batchesCompleted; batchIterations = $batchIterations; partialCandidates = $partialRows.Count; pendingCandidates = $pendingRows.Count }

        if (-not $candidates) { Write-Host "No sources pending synthesis."; break }

        $thisBatch = @($candidates | Select-Object -First $batchSize)
        $thisBatchIds = @($thisBatch | ForEach-Object { $_.video_id })
        $includedBeforeBatch = Get-IncludedCount

        $batchId = "synthesis_batch_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        $promptFile = Join-Path $promptsDir "$batchId.md"
        # runId+iteration prefix guarantees uniqueness even though $batchId's own
        # one-second timestamp resolution could otherwise collide across two fast,
        # close-together invocations and silently overwrite an earlier attempt's
        # forensic output (review round 2, item 2). $batchId is kept in the filename
        # unchanged for human traceability; the established batch-id contract itself
        # (prompt filename, the "batch" field Claude echoes back) is untouched.
        $batchOutputPath = Join-Path $diagnosticsDir "${runId}_iter${iterationNumber}_$batchId.output.txt"

        # Review round 2, item 3: clear out any result file left over from an earlier
        # attempt before this batch's own invocation can start, so it can never
        # ambiguously inherit one. See Backup-StaleSynthesisResult's own comment above.
        $staleResult = Backup-StaleSynthesisResult -VaultRoot $VaultRoot -UpcomingBatchId $batchId
        if ($staleResult) {
            Write-Diag -Event 'stale_result_quarantined' -Fields @{ batchId = $batchId; iteration = $iterationNumber; quarantinePath = $staleResult.QuarantinePath; staleValid = $staleResult.Valid; staleBatch = $staleResult.Batch; staleParseError = $staleResult.ParseError }
            Write-Warning "Found a pre-existing working/temp/synthesis-result.json before starting batch $batchId - quarantined to $($staleResult.QuarantinePath) (valid=$($staleResult.Valid), batch='$($staleResult.Batch)') so this batch cannot ambiguously inherit it."
        }

        $sourceList = ($thisBatch | ForEach-Object { "- $($_.source_file) (video_id: $($_.video_id))" }) -join "`n"
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

        Write-Diag -Event 'batch_selected' -Fields @{ batchId = $batchId; iteration = $iterationNumber; videoIds = $thisBatchIds; sourceCount = $thisBatch.Count; promptFile = $promptFile; includedBeforeBatch = $includedBeforeBatch }

        Write-Host "Invoking Claude Code for batch $batchId ($($thisBatch.Count) sources)..."
        $promptText = Get-Content -LiteralPath $promptFile -Raw

        # Captured just before the invocation starts, with a small negative buffer, so
        # Get-WikiMutationEvidence below can tell "touched during this batch's own call"
        # apart from a stale file already sitting there from long before (review round 2,
        # item 1).
        $batchStartTime = (Get-Date).AddMilliseconds(-100)

        $job = Start-Job -ScriptBlock {
            param($vaultRoot, $promptText, $claudeCmd)
            # Confirmed empirically (Stage 3 prep, real Start-Job test on this VM): job
            # children fully inherit the parent process's $env:PATH, including the
            # ~/.local/bin fixup run-vault.ps1 applies for non-interactive invocations - no
            # re-fixup needed here.
            Set-Location -LiteralPath $vaultRoot
            $output = & $claudeCmd -p $promptText --permission-mode acceptEdits 2>&1
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        } -ArgumentList $VaultRoot, $promptText, $claudeCommand
        Write-Diag -Event 'claude_job_started' -Fields @{ batchId = $batchId; jobId = $job.Id; claudeCommand = $claudeCommand; timeoutSeconds = $claudeTimeoutSeconds }

        $completed = Wait-Job -Job $job -Timeout $claudeTimeoutSeconds
        if (-not $completed) {
            Write-Warning "Batch $batchId exceeded claude_call_timeout_seconds ($claudeTimeoutSeconds)s - stopping the job."
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            "(no output captured - job was killed before completion after a ${claudeTimeoutSeconds}s timeout)" | Out-File -LiteralPath $batchOutputPath -Encoding utf8
            $reasonCode = 'SYNTHESIS_TIMEOUT'
            $errorSnippet = "claude did not complete within claude_call_timeout_seconds (${claudeTimeoutSeconds}s)."
            Write-Diag -Event 'claude_invocation_completed' -Fields @{ batchId = $batchId; jobId = $job.Id; timedOut = $true; exitCode = $null; outputFile = $batchOutputPath }

            # Review round 2 (2nd pass): captured BEFORE run-qa.ps1, not after. run-qa.ps1
            # is not read-only with respect to wiki/ - its Sync-SourcePageFrontmatter step
            # runs Set-Content on wiki/sources/*.md for every row CURRENTLY 'included' in
            # the manifest, not just rows that transitioned this call (run-qa.ps1's own
            # comment: "so a plain re-run also backfills historical rows..."). If mutation
            # evidence were captured after run-qa.ps1 ran, a routine backfill write for a
            # completely unrelated, already-included row would land inside this batch's
            # own [$batchStartTime, now) window and get misread as "Claude touched
            # something this batch" - a false positive on exactly the signal this gate
            # exists to keep honest. Snapshotting before run-qa.ps1 even starts removes
            # that possibility entirely: only wiki/ writes from BEFORE run-qa.ps1 touched
            # anything - i.e. only Claude's own invocation - can appear here.
            $mutatedFiles = Get-WikiMutationEvidence -VaultRoot $VaultRoot -Since $batchStartTime

            # Fix 3: even on a killed job, Claude may already have written real wiki edits
            # before being stopped. Reconcile via the same idempotent, disk-truth-aware QA
            # pass every other batch uses (safe to call unconditionally - it never deletes
            # or blindly overwrites anything, and only promotes to 'included' via its own
            # Finding-D-safe rules) regardless of what's found next.
            Write-Diag -Event 'qa_invoked' -Fields @{ batchId = $batchId; includedBeforeQA = $includedBeforeBatch; context = 'timeout-recovery' }
            & (Join-Path $AgentRoot 'scripts/run-qa.ps1') -VaultRoot $VaultRoot
            $includedAfterTimeout = Get-IncludedCount
            Write-Diag -Event 'qa_completed' -Fields @{ batchId = $batchId; includedAfterQA = $includedAfterTimeout; context = 'timeout-recovery' }

            # Review round 2, item 1: only promote to 'partial' - never 'included', that
            # transition still belongs solely to run-qa.ps1 - when there is real evidence
            # (a wiki/ file written during this batch's own invocation window, captured
            # above BEFORE run-qa.ps1 ran) that something was actually attempted/produced.
            # A job killed before Claude ever touched a file (e.g. it was still thinking,
            # or hung on startup) must leave its sources at bare 'pending', not a
            # manufactured 'partial' - "the job was started" is not the same claim as
            # "synthesis was partially done", and is already durably recorded either way
            # via the claude_job_started/claude_invocation_completed diagnostics events
            # above, independent of this. Deliberately does NOT rescan wiki/ here - the
            # decision uses only the pre-QA snapshot taken above.
            $partialMarked = $false
            if ($mutatedFiles.Count -gt 0) {
                Set-PartialStatus -ManifestPath $manifestPath -VideoIds $thisBatchIds
                $partialMarked = $true
            }
            Write-Diag -Event 'batch_outcome' -Fields @{ batchId = $batchId; classification = 'SYNTHESIS_TIMEOUT'; includedBefore = $includedBeforeBatch; includedAfter = $includedAfterTimeout; acceptedCount = ($includedAfterTimeout - $includedBeforeBatch); droppedCount = $thisBatchIds.Count; droppedIds = $thisBatchIds; mutationEvidenceCount = $mutatedFiles.Count; mutationEvidence = $mutatedFiles; partialMarked = $partialMarked }
            break
        }
        $jobResult = Receive-Job -Job $job
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $outputText = ($jobResult.Output -join "`n")
        $outputText | Out-File -LiteralPath $batchOutputPath -Encoding utf8 -Force
        Write-Diag -Event 'claude_invocation_completed' -Fields @{ batchId = $batchId; jobId = $job.Id; timedOut = $false; exitCode = $jobResult.ExitCode; outputLength = $outputText.Length; outputFile = $batchOutputPath }

        # Review round 2 (2nd pass): captured BEFORE run-qa.ps1 runs below, not after -
        # see the matching comment in the timeout branch above for the full reasoning.
        # run-qa.ps1's Sync-SourcePageFrontmatter step can Set-Content a wiki/sources/*.md
        # file for ANY currently-'included' row, not just this batch's own rows, so
        # capturing this snapshot after run-qa.ps1 ran risked misreading its own routine
        # backfill writes as evidence this batch's Claude invocation touched something.
        $mutatedFiles = Get-WikiMutationEvidence -VaultRoot $VaultRoot -Since $batchStartTime

        # Fix 2: actually use the captured exit code (previously computed into the job
        # result and then never read) and independently peek the result file's own
        # presence/validity/batch-label BEFORE run-qa.ps1 consumes (and archives) it - both
        # feed the zero-progress classification below with real evidence instead of a
        # stdout-content guess.
        $resultFilePath = Join-Path $VaultRoot 'working/temp/synthesis-result.json'
        $resultPresent = Test-Path -LiteralPath $resultFilePath
        $resultValid = $false
        $resultParseError = ''
        $returnedBatchId = $null
        $resultBatchMismatch = $false
        $processedIdsFromResult = @()
        if ($resultPresent) {
            try {
                $peekResult = Get-Content -LiteralPath $resultFilePath -Raw | ConvertFrom-Json
                $resultValid = $true
                if ($peekResult.PSObject.Properties['batch']) { $returnedBatchId = [string]$peekResult.batch }
                if ($peekResult.PSObject.Properties['processed']) { $processedIdsFromResult = @($peekResult.processed) }
                if ($returnedBatchId -and $returnedBatchId -ne $batchId) { $resultBatchMismatch = $true }
            } catch {
                $resultValid = $false
                $resultParseError = $_.Exception.Message
            }
        }
        Write-Diag -Event 'synthesis_result_check' -Fields @{
            batchId = $batchId; resultPresent = $resultPresent; resultValid = $resultValid
            parseError = $resultParseError; returnedBatchId = $returnedBatchId; expectedBatchId = $batchId
            batchMismatch = $resultBatchMismatch; processedIdsFromResult = $processedIdsFromResult
            processedCountFromResult = $processedIdsFromResult.Count
        }

        # The one stage permitted to write synthesis_status = included, called here explicitly
        # (not just at the end of run-vault.ps1's sequence) so this batch's real progress is
        # visible before deciding whether to continue, sleep-and-retry, or stop. Idempotent by
        # its own design; safe to call more than once per run-vault.ps1 pass.
        Write-Diag -Event 'qa_invoked' -Fields @{ batchId = $batchId; includedBeforeQA = $includedBeforeBatch }
        & (Join-Path $AgentRoot 'scripts/run-qa.ps1') -VaultRoot $VaultRoot
        $includedAfterBatch = Get-IncludedCount
        Write-Diag -Event 'qa_completed' -Fields @{ batchId = $batchId; includedAfterQA = $includedAfterBatch }

        $manifestAfterBatch = @(Import-Csv -LiteralPath $manifestPath)
        $includedIdsAfterBatch = @($manifestAfterBatch | Where-Object { $_.synthesis_status -eq 'included' } | ForEach-Object { $_.video_id })
        $includedFromThisBatch = @($thisBatchIds | Where-Object { $includedIdsAfterBatch -contains $_ })
        $droppedIds = @($thisBatchIds | Where-Object { $includedIdsAfterBatch -notcontains $_ })

        # A straggler from an earlier batch THIS run that this batch actually recovered -
        # drop it from the run-level dropped-sources ledger (reasonCode itself still stays
        # SYNTHESIS_PARTIAL for the whole run - see .DESCRIPTION).
        foreach ($id in $includedFromThisBatch) {
            if ($droppedSourcesThisRun.Contains($id)) { $droppedSourcesThisRun.Remove($id) }
        }

        if ($includedAfterBatch -le $includedBeforeBatch) {
            # Zero progress at all this batch.
            if ($outputText -match 'session limit|usage limit|rate limit|resets\s+\d{1,2}') {
                $reasonCode = 'SYNTHESIS_LIMIT_HIT'
                Write-Diag -Event 'batch_outcome' -Fields @{ batchId = $batchId; classification = 'SYNTHESIS_LIMIT_HIT'; includedBefore = $includedBeforeBatch; includedAfter = $includedAfterBatch; acceptedCount = 0; droppedCount = $thisBatchIds.Count; resultBatchMismatch = $resultBatchMismatch }
                if (-not $continuity) { break }
                $sleepSeconds = Get-ResetSleepSeconds -ClaudeOutput $outputText
                $sleptUntil = (Get-Date).AddSeconds($sleepSeconds).ToString('o')
                Write-Host "SYNTHESIS_LIMIT_HIT, continuity=true - sleeping $sleepSeconds seconds until $sleptUntil, then resuming."
                Write-Diag -Event 'continuity_sleep' -Fields @{ batchId = $batchId; sleepSeconds = $sleepSeconds; sleptUntil = $sleptUntil }
                Start-Sleep -Seconds $sleepSeconds
                # Only clear back to a clean $null if nothing partial has happened yet this
                # run. Once a partial batch has occurred, SYNTHESIS_PARTIAL must survive a
                # later clean resume - this is the exact masking bug from the 2026-08-24
                # SabrinaRamonov_Rev00 incident: reasonCode was unconditionally nulled here,
                # so a successful continuity resume erased all trace of the earlier batch
                # that silently dropped 2 sources, and the run reported TARGET_MET.
                $reasonCode = if ($hadPartialThisRun) { 'SYNTHESIS_PARTIAL' } else { $null }
                Write-Diag -Event 'iteration_completed' -Fields @{ batchId = $batchId; iteration = $iterationNumber; outcome = 'limit_hit_continuity_resume'; batchesCompleted = $batchesCompleted }
                continue              # does not increment $batchesCompleted; not a completed batch
            }

            # Not a limit-hit: something genuinely went wrong. Classify using real
            # evidence (exit code, result-file state) rather than guessing from stdout -
            # this replaces the previous single generic SYNTHESIS_ERROR bucket that could
            # save an ordinary line of Claude progress text as errorSnippet (confirmed
            # against the real 2026-09-05 synthesis_batch_20260905_170255 incident: the
            # old code's errorSnippet was "Now Gamma tool page + carousel workflow
            # alternate-build enrichment (source 7)." - normal progress narration, not an
            # error).
            if ($jobResult.ExitCode -ne 0) {
                $batchClassification = 'CLAUDE_EXIT_ERROR'
                $errorSnippet = "claude exited with code $($jobResult.ExitCode). Full output: $batchOutputPath"
            } elseif (-not $resultPresent) {
                $batchClassification = 'SYNTHESIS_RESULT_MISSING'
                $errorSnippet = "claude exited $($jobResult.ExitCode) but working/temp/synthesis-result.json was not found after the call."
            } elseif (-not $resultValid) {
                $batchClassification = 'SYNTHESIS_RESULT_INVALID'
                $errorSnippet = "synthesis-result.json present but failed to parse: $resultParseError"
            } elseif ($resultBatchMismatch) {
                $batchClassification = 'SYNTHESIS_RESULT_BATCH_MISMATCH'
                $errorSnippet = "synthesis-result.json's batch field ('$returnedBatchId') does not match the batch actually sent ('$batchId'), and zero rows were included."
            } else {
                $batchClassification = 'QA_ZERO_PROGRESS'
                $errorSnippet = "synthesis-result.json was valid and listed $($processedIdsFromResult.Count) processed id(s), but run-qa.ps1 reconciliation produced no new included rows."
            }
            $reasonCode = $batchClassification

            # Review round 2, item 1: "a Claude invocation was attempted" (true for every
            # branch that reaches here - job started, ran to completion or a non-zero
            # exit) is not the same claim as "a source was partially synthesized". Only
            # mark 'partial' (never 'included' - that transition still belongs solely to
            # run-qa.ps1) when $mutatedFiles (captured above, BEFORE run-qa.ps1 ran - see
            # that comment) shows real evidence something was actually written under
            # wiki/ during this batch's own invocation window - exactly the 2026-09-05
            # incident's shape (substantial wiki changes landed on disk with
            # batchesCompleted=0 and no durable trace). A CLAUDE_EXIT_ERROR that fired
            # before Claude touched anything (e.g. an immediate crash) must leave its
            # sources at bare 'pending', not a manufactured 'partial' - the fact that an
            # invocation was attempted is already durably recorded either way via the
            # claude_job_started/claude_invocation_completed diagnostics events, independent
            # of this. Deliberately does NOT rescan wiki/ here (that would reintroduce the
            # exact contamination risk this reordering fixes, since run-qa.ps1 has already
            # run by this point) - reuses the pre-QA snapshot only.
            $partialMarked = $false
            if ($mutatedFiles.Count -gt 0) {
                Set-PartialStatus -ManifestPath $manifestPath -VideoIds $thisBatchIds
                $partialMarked = $true
            }
            Write-Diag -Event 'batch_outcome' -Fields @{ batchId = $batchId; classification = $batchClassification; includedBefore = $includedBeforeBatch; includedAfter = $includedAfterBatch; acceptedCount = 0; droppedCount = $thisBatchIds.Count; droppedIds = $thisBatchIds; resultBatchMismatch = $resultBatchMismatch; errorSnippet = $errorSnippet; mutationEvidenceCount = $mutatedFiles.Count; mutationEvidence = $mutatedFiles; partialMarked = $partialMarked }
            Write-Warning "${batchClassification}: batch $batchId made zero progress (partialMarked=$partialMarked, mutationEvidenceCount=$($mutatedFiles.Count)). $errorSnippet"
            break
        }

        if ($droppedIds.Count -gt 0) {
            # Partial batch: some, but not all, of this batch's own inputs came back
            # included. Previously this was silently treated identically to a full success
            # (batchesCompleted++, no signal at all for the dropped rows) - this is the root
            # cause fixed here.
            $hadPartialThisRun = $true
            $reasonCode = 'SYNTHESIS_PARTIAL'
            Set-PartialStatus -ManifestPath $manifestPath -VideoIds $droppedIds

            foreach ($id in $droppedIds) {
                $row = $thisBatch | Where-Object { $_.video_id -eq $id } | Select-Object -First 1
                $diag = [ordered]@{
                    timestamp            = (Get-Date).ToString('o')
                    batchId              = $batchId
                    videoId              = $id
                    title                = $row.title
                    sourceFile           = $row.source_file
                    presentInBatchPrompt = $true
                    promptFile           = $promptFile
                    batchInputCount      = $thisBatch.Count
                    batchIncludedCount   = $includedFromThisBatch.Count
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Path $diagnosticsLogPath -Parent) | Out-Null
                ($diag | ConvertTo-Json -Compress) | Add-Content -LiteralPath $diagnosticsLogPath -Encoding utf8
                Write-Warning "SYNTHESIS_PARTIAL: batch $batchId sent $($thisBatch.Count) source(s), only $($includedFromThisBatch.Count) came back included. Dropped: video_id=$id title='$($row.title)' source_file=$($row.source_file) (present in batch prompt: yes; no result returned for it). Diagnostic appended to $diagnosticsLogPath."

                if (-not $droppedSourcesThisRun.Contains($id)) {
                    $droppedSourcesThisRun[$id] = [ordered]@{ videoId = $id; title = $row.title; sourceFile = $row.source_file; batchId = $batchId }
                }
            }
            Write-Diag -Event 'batch_outcome' -Fields @{ batchId = $batchId; classification = 'SYNTHESIS_PARTIAL'; includedBefore = $includedBeforeBatch; includedAfter = $includedAfterBatch; acceptedCount = $includedFromThisBatch.Count; droppedCount = $droppedIds.Count; droppedIds = $droppedIds; resultBatchMismatch = $resultBatchMismatch }
        } else {
            Write-Diag -Event 'batch_outcome' -Fields @{ batchId = $batchId; classification = 'SYNTHESIS_SUCCESS'; includedBefore = $includedBeforeBatch; includedAfter = $includedAfterBatch; acceptedCount = $includedFromThisBatch.Count; droppedCount = 0; resultBatchMismatch = $resultBatchMismatch }
        }

        $batchesCompleted++
        Write-Diag -Event 'batch_counter_incremented' -Fields @{ batchId = $batchId; batchesCompleted = $batchesCompleted; batchIterations = $batchIterations }
        Write-Diag -Event 'iteration_completed' -Fields @{ batchId = $batchId; iteration = $iterationNumber; outcome = 'completed'; batchesCompleted = $batchesCompleted }

        # Test-only hook - see .NOTES. Never read unless explicitly set by a test.
        if ($env:WIKIAGENT_TEST_THROW_AFTER_BATCH -and ([int]$env:WIKIAGENT_TEST_THROW_AFTER_BATCH -eq $batchesCompleted)) {
            throw "WIKIAGENT_TEST_THROW_AFTER_BATCH: simulated runner exception for testing (after batch $batchesCompleted)"
        }
    }

    }
} catch {
    $reasonCode = 'RUNNER_EXCEPTION'
    $errorSnippet = $_.Exception.Message
    Write-Diag -Event 'runner_exception' -Fields @{ message = $_.Exception.Message; scriptStackTrace = [string]$_.ScriptStackTrace; batchesCompleted = $batchesCompleted; iteration = $iterationNumber }
    Write-Warning "RUNNER_EXCEPTION: $($_.Exception.Message)"
    throw
} finally {
    # Defensive: this must never itself throw and mask the original exception (if any) -
    # $actualSynthesized/Write-SynthesisRunResult only touch state that is always
    # predeclared above, but Get-IncludedCount re-reads the manifest from disk, which is
    # one more thing that could theoretically fail after an exception left it mid-write.
    try {
        $actualSynthesized = (Get-IncludedCount) - $includedBefore
    } catch {
        Write-Warning "Could not recompute actualSynthesized in finally block: $($_.Exception.Message)"
    }
    try {
        Write-SynthesisRunResult -ReasonCode $reasonCode -BatchesCompleted $batchesCompleted -ErrorSnippet $errorSnippet -SleptUntil $sleptUntil -DroppedSources @($droppedSourcesThisRun.Values)
        Write-Diag -Event 'run_end' -Fields @{ reasonCode = $reasonCode; batchesCompleted = $batchesCompleted; actualSynthesized = $actualSynthesized; droppedThisRun = $droppedSourcesThisRun.Count }
    } catch {
        Write-Warning "Could not write synthesis-run-result.json in finally block: $($_.Exception.Message)"
    }
    Write-Host "Synthesis complete: reasonCode=$reasonCode, batches=$batchesCompleted/$batchIterations, actualSynthesized=$actualSynthesized, droppedThisRun=$($droppedSourcesThisRun.Count). Manifest reconciliation happens per-batch via run-qa.ps1."
}
