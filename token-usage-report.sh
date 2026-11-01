#!/usr/bin/env bash
# Read-only report: scans ~/.claude/projects/ for real Claude Code synthesis session
# .jsonl files belonging to this repo's vaults, sums real per-session token usage, and
# appends new rows to token-usage.csv. Never touches any pipeline script, vault content,
# manifest, or config file - worst case is a bad report, never a bad synthesis run.
#
# Usage:
#   ./token-usage-report.sh              # scan all vaults
#   ./token-usage-report.sh <vault_name> # scope to one vault's sessions only
#
# Matching method (no sessionId capture in the pipeline - deliberately deferred, see
# the batch_size/batch_iterations/continuity brief that shipped alongside this script):
#   1. Each session's own real `cwd` field (not the ~/.claude/projects/ directory name,
#      which mangles vault names inconsistently - e.g. underscores become hyphens too,
#      not just slashes - confirmed against real session files before relying on it)
#      identifies which vault it belongs to. Sessions whose cwd isn't under this repo's
#      vaults/ are skipped entirely - not this pipeline's synthesis calls.
#   2. The batch name ("synthesis_batch_YYYYMMDD_HHMMSS") is read verbatim from the
#      session's first user-turn prompt text - the exact string
#      run-claude-synthesis.ps1 generates per batch. Lint-review sessions (whose first
#      prompt starts differently) simply won't match - they still get real token totals
#      recorded, just with batch-config fields left blank.
#   3. sources_synthesized comes from working/temp/synthesis-result.json.<batch>.processed
#      - a real, persisted, per-batch file (one per batch, never overwritten) written by
#        that batch's own claude -p call; length of its "processed" array.
#   4. batch_size/batch_iterations/continuity come from working/temp/synthesis-run-
#      result.json - but that file is OVERWRITTEN by every run-vault.ps1 invocation, so
#      it is only historically accurate for the vault's most recent run. A session is
#      only trusted for these three fields (match_confidence=matched) when the vault's
#      persisted logs/run_<timestamp>.json shows a run whose [startedUtc, endedUtc]
#      window contains both this session's own timestamps AND synthesis-run-result.json's
#      own timestamp - i.e. that transient file still reflects the run this session
#      belongs to, not a later one. Once a newer run has occurred for that vault, older
#      sessions correctly fall back to match_confidence=unmatched for these three fields
#      even though token totals and sources_synthesized remain fully known. This is a
#      real, load-bearing limitation of not capturing sessionId at write-time, not a
#      bug - confirmed against real multi-run history on this VM before shipping.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PROJECTS_DIR="${HOME}/.claude/projects"
CSV_PATH="${REPO_ROOT}/token-usage.csv"
VAULT_FILTER="${1:-}"

if [ ! -d "${CLAUDE_PROJECTS_DIR}" ]; then
  echo "No ${CLAUDE_PROJECTS_DIR} found; nothing to scan." >&2
  exit 0
fi

TUR_REPO_ROOT="${REPO_ROOT}" \
TUR_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR}" \
TUR_CSV_PATH="${CSV_PATH}" \
TUR_VAULT_FILTER="${VAULT_FILTER}" \
python3 <<'PYEOF'
import csv
import glob
import json
import os
import re
import sys
from datetime import datetime, timedelta

repo_root = os.environ['TUR_REPO_ROOT']
projects_dir = os.environ['TUR_PROJECTS_DIR']
csv_path = os.environ['TUR_CSV_PATH']
vault_filter = os.environ.get('TUR_VAULT_FILTER', '').strip()

VAULTS_PREFIX = repo_root.rstrip('/') + '/vaults/'
BATCH_RE = re.compile(r'synthesis_batch_\d{8}_\d{6}')
WINDOW_BUFFER = timedelta(seconds=5)

FIELDNAMES = [
    'date', 'vault', 'batch_size', 'batch_iterations', 'continuity',
    'sources_synthesized', 'input_tokens', 'cache_creation_tokens',
    'cache_read_tokens', 'output_tokens', 'fresh_tokens_per_source',
    'session_id', 'match_confidence',
]


def parse_iso(ts):
    return datetime.fromisoformat(ts.replace('Z', '+00:00'))


def compute_fresh_tokens_per_source(input_tokens, cache_creation_tokens, output_tokens, sources_synthesized):
    # Deliberately excludes cache_read_tokens: reused/cheap context, not new work.
    # Including it made longer sessions (more internal turns re-reading their own
    # accumulated context) look artificially worse per source even when fresh-token
    # cost per source was equal or better - misleading for the batch-config
    # efficiency comparison this column exists for. "fresh" in the column name
    # signals explicitly that cache reads are excluded, not just unlabeled "total".
    try:
        n = int(sources_synthesized)
    except (TypeError, ValueError):
        return ''
    if n <= 0:
        return ''
    total = int(input_tokens or 0) + int(cache_creation_tokens or 0) + int(output_tokens or 0)
    return round(total / n, 1)


# --- Load existing CSV, dedupe by session_id, and re-normalize every existing ---
# row's fresh_tokens_per_source from its own already-stored raw token counts (no
# need to re-scan the source .jsonl). Cheap, idempotent, self-healing if the
# formula is ever revised again; also transparently migrates the column from its
# old name ('tokens_per_source', included all four token categories) the first
# time this runs against a pre-existing CSV. session_id (the .jsonl filename
# itself, a stable UUID) is used for dedup rather than file path + mtime: a file
# touch/copy (e.g. during backup/restore) changes mtime without changing content,
# which would wrongly re-add a row; session_id cannot drift like that and is
# already the column we key rows on anyway.
existing_session_ids = set()
existing_rows = []
csv_exists = os.path.isfile(csv_path)
if csv_exists:
    with open(csv_path, newline='', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            sid = (row.get('session_id') or '').strip()
            if sid:
                existing_session_ids.add(sid)
            row['fresh_tokens_per_source'] = compute_fresh_tokens_per_source(
                row.get('input_tokens'), row.get('cache_creation_tokens'),
                row.get('output_tokens'), row.get('sources_synthesized'))
            existing_rows.append(row)
    with open(csv_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES, extrasaction='ignore')
        writer.writeheader()
        for row in existing_rows:
            writer.writerow(row)


def load_run_windows(vault_root):
    windows = []
    logs_dir = os.path.join(vault_root, 'logs')
    if not os.path.isdir(logs_dir):
        return windows
    for fn in glob.glob(os.path.join(logs_dir, 'run_*.json')):
        try:
            with open(fn, encoding='utf-8') as f:
                d = json.load(f)
            windows.append((parse_iso(d['startedUtc']), parse_iso(d['endedUtc'])))
        except Exception:
            continue
    return windows


run_windows_cache = {}


def run_windows_for(vault_name, vault_root):
    if vault_name not in run_windows_cache:
        run_windows_cache[vault_name] = load_run_windows(vault_root)
    return run_windows_cache[vault_name]


new_rows = []
summary_counts = {}

for dirname in sorted(os.listdir(projects_dir)):
    project_dir = os.path.join(projects_dir, dirname)
    if not os.path.isdir(project_dir):
        continue

    for jsonl_path in sorted(glob.glob(os.path.join(project_dir, '*.jsonl'))):
        session_id = os.path.splitext(os.path.basename(jsonl_path))[0]
        if session_id in existing_session_ids:
            continue

        cwd = None
        input_tokens = 0
        cache_creation_tokens = 0
        cache_read_tokens = 0
        output_tokens = 0
        first_ts = None
        last_ts = None
        batch_name = None
        any_message = False
        skip_irrelevant = False

        try:
            with open(jsonl_path, encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue

                    if cwd is None and obj.get('cwd'):
                        cwd = obj['cwd']
                        if not cwd.startswith(VAULTS_PREFIX):
                            skip_irrelevant = True
                            break  # not a session under this repo's vaults/ - stop reading

                    ts_raw = obj.get('timestamp')
                    if ts_raw:
                        ts = parse_iso(ts_raw)
                        if first_ts is None or ts < first_ts:
                            first_ts = ts
                        if last_ts is None or ts > last_ts:
                            last_ts = ts

                    t = obj.get('type')
                    if t == 'assistant':
                        any_message = True
                        usage = (obj.get('message') or {}).get('usage') or {}
                        input_tokens += usage.get('input_tokens', 0) or 0
                        cache_creation_tokens += usage.get('cache_creation_input_tokens', 0) or 0
                        cache_read_tokens += usage.get('cache_read_input_tokens', 0) or 0
                        output_tokens += usage.get('output_tokens', 0) or 0
                    elif batch_name is None and t == 'user':
                        content = (obj.get('message') or {}).get('content')
                        if isinstance(content, str):
                            m = BATCH_RE.search(content)
                            if m:
                                batch_name = m.group(0)
        except Exception as e:
            print(f"WARNING: could not read {jsonl_path}: {e}", file=sys.stderr)
            continue

        if skip_irrelevant or cwd is None or not any_message or first_ts is None:
            continue  # not a real pipeline synthesis session for this repo

        vault_name = cwd[len(VAULTS_PREFIX):].split('/')[0]
        if vault_filter and vault_name != vault_filter:
            continue

        vault_root = os.path.join(repo_root, 'vaults', vault_name)

        # sources_synthesized: real, persisted, per-batch file - independent of the
        # overwrite problem described in the header comment.
        sources_synthesized = ''
        if batch_name:
            processed_path = os.path.join(
                vault_root, 'working', 'temp',
                f'synthesis-result.json.{batch_name}.processed')
            if os.path.isfile(processed_path):
                try:
                    with open(processed_path, encoding='utf-8') as f:
                        pd = json.load(f)
                    sources_synthesized = len(pd.get('processed', []))
                except Exception:
                    pass

        # batch_size/batch_iterations/continuity: only trusted when the transient
        # synthesis-run-result.json still reflects THIS session's run - see header.
        batch_size = batch_iterations = continuity = ''
        match_confidence = 'unmatched'
        for started, ended in run_windows_for(vault_name, vault_root):
            w_start, w_end = started - WINDOW_BUFFER, ended + WINDOW_BUFFER
            if not (w_start <= first_ts <= w_end or w_start <= last_ts <= w_end):
                continue
            synth_result_path = os.path.join(vault_root, 'working', 'temp', 'synthesis-run-result.json')
            if os.path.isfile(synth_result_path):
                try:
                    with open(synth_result_path, encoding='utf-8') as f:
                        sr = json.load(f)
                    sr_ts = parse_iso(sr['timestamp'])
                    if w_start <= sr_ts <= w_end:
                        batch_size = sr.get('batchSize', '')
                        batch_iterations = sr.get('batchIterations', '')
                        continuity = sr.get('continuity', '')
                        match_confidence = 'matched'
                except Exception:
                    pass
            break  # first containing window is the run this session belongs to

        fresh_tokens_per_source = compute_fresh_tokens_per_source(
            input_tokens, cache_creation_tokens, output_tokens, sources_synthesized)

        new_rows.append({
            'date': first_ts.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'vault': vault_name,
            'batch_size': batch_size,
            'batch_iterations': batch_iterations,
            'continuity': continuity,
            'sources_synthesized': sources_synthesized,
            'input_tokens': input_tokens,
            'cache_creation_tokens': cache_creation_tokens,
            'cache_read_tokens': cache_read_tokens,
            'output_tokens': output_tokens,
            'fresh_tokens_per_source': fresh_tokens_per_source,
            'session_id': session_id,
            'match_confidence': match_confidence,
        })
        summary_counts[vault_name] = summary_counts.get(vault_name, 0) + 1

new_rows.sort(key=lambda r: r['date'])

if new_rows:
    with open(csv_path, 'a', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        if not csv_exists:
            writer.writeheader()
        for row in new_rows:
            writer.writerow(row)
    parts = ', '.join(f"{v} x{c}" for v, c in sorted(summary_counts.items()))
    print(f"Added {len(new_rows)} new session(s): {parts}. See {csv_path}.")
else:
    print(f"No new sessions found. See {csv_path}.")
PYEOF
