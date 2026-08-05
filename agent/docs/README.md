# WikiAgent — Agent Documentation

`agent/` is the shared engine. It contains no vault-specific data — see `01-architecture-spec.md`
(copied into this folder as `architecture-spec.md`) for the locked rules this build follows.

## Scripts (`agent/scripts/`)

| Script | Responsibility |
|---|---|
| `run-vault.ps1` | Entry point. Orchestrates one vault through the full pipeline; owns locking. |
| `ingest-youtube.ps1` | Channel scan + canonical-caption download into the vault's manifest. |
| `clean-transcripts.ps1` | Converts raw `.vtt` captions to clean plain text; sets `clean_status` so `create-source-pages.ps1` can act on youtube-sourced rows. |
| `ingest-documents.ps1` | Registers manually dropped PDFs/DOCX/MD/TXT from `input/`. |
| `create-source-pages.ps1` | Deterministic, zero-Claude-token source page generation. |
| `run-claude-synthesis.ps1` | Headless Claude Code invocation; writes an intermediate result, never the manifest directly. |
| `run-qa.ps1` | The one authoritative, idempotent manifest reconciliation pass. |
| `backup-vault.ps1` | Vault-scoped backup + optional remote sync + retention. |
| `restore-vault.ps1` | Restores config/manifest/wiki from a `backup-vault.ps1` archive and rebuilds the scaffold; refuses to overwrite a non-empty vault without `-Force`. |
| `send-notification.ps1` | Best-effort Telegram summary; never fails the run. |

## Scheduling (`agent/scheduling/`)

See `schedule-contract.md`. Short version: edit `schedule.csv`, nothing else, to add a vault
to the rotation.

## Known gaps to close before production cutover

This build is a from-spec skeleton with working control-flow, locking, and manifest logic.
Before it replaces the validated single-vault VM implementation, port in from the proven VM
scripts (referenced throughout the project's continuation-brief history, not verbatim
available to this build):
- exact yt-dlp flags/impersonation workarounds already proven on the VM;
- the real DOCX/PDF text extractors (currently placeholder markers in `ingest-documents.ps1`);
- Claude Code subscription-auth wiring specific to the target host;
- the exact `claude_budget_usd` enforcement behaviour (currently a soft, unenforced field,
  matching the locked Summary 9 decision to keep it soft for now).

## Resolved gaps

- **Clean-transcript stage (fixed).** This gap was real but was *not* on the list above when
  it was found — worth the paper trail. The multivault rewrite carried over `ingest-youtube.ps1`
  without porting the VTT-to-clean-text conversion step that the proven VM pipeline
  (`weekly_update_channel_wiki_v8_linux.ps1`'s `Convert-VttToPlainText`) already had working.
  Youtube-sourced manifest rows stayed at `clean_status = ''` forever, so
  `create-source-pages.ps1` (which gates on `clean_status = clean_ready`) could never fire for
  them, regardless of caption-download success. `ingest-documents.ps1` was unaffected — it
  already sets `clean_status = 'clean_ready'` directly since dropped documents need no cleaning.
  Fixed by porting `Convert-VttToPlainText` and the `clean_ready` /
  `blocked_missing_transcript` transition logic into a new standalone `clean-transcripts.ps1`
  stage, wired into `run-vault.ps1` between `ingest-youtube.ps1` and `ingest-documents.ps1`
  (skippable via `-SkipClean`, matching the existing `-Skip*` convention).

- **Pull-clobber data loss (fixed).** `sync-vault.ps1`'s pull stage ran `rclone sync` from
  Drive to the local vault directory unconditionally — since vault directories are not
  git-tracked (Drive is their only "last known good" record), any local file that hadn't
  been pushed yet was silently deleted or overwritten, no warning. This destroyed real local
  state three times during multivault testing: two config edits and one full set of
  manifest/wiki artifacts from clean-transcript retesting. Fixed by running
  `rclone check $VaultRoot $remote --one-way --combined -` before every pull and aborting
  with the specific at-risk file list if it finds anything local that Drive doesn't already
  have, instead of proceeding. Add `-ForcePull` to skip the check and pull anyway when an
  overwrite is intentional. Verified: a deliberate local-only file blocks the pull with a
  clear error and survives the run; a normal run with nothing local pending pulls and
  proceeds exactly as before.

- **`run-qa.ps1` archive-then-commit ordering (fixed).** The synthesis-result.json file was
  archived (`Move-Item` to `.processed`) *before* the manifest write was committed. A crash
  in that gap silently and unrecoverably lost the evidence that synthesis had completed for
  those rows - the archived result file was gone, so nothing could ever reconstruct which
  pages were created; the affected rows stayed `synthesis_status = pending` and would be
  re-synthesized by Claude on the next run at real, duplicate paid API cost. Found via code
  reading, then confirmed with a controlled reproduction (archive the result file manually,
  skip the manifest write, run `run-qa.ps1` again - the rows never recovered). Fixed by
  reversing the order: commit the manifest write first, archive the result file second. A
  crash in the new gap (after commit, before archive) leaves the manifest already correct;
  worst case a result file is left un-archived, which the next run picks up and archives
  cleanly (`synthesis_status = included` already set, so Finding D just skips it - no
  double-processing). Verified against the fixed script with a real failure injected at the
  archive step (target directory made read-only): the manifest committed correctly despite
  the archive genuinely failing, and a subsequent normal run cleanly archived the leftover
  file with zero manifest changes. Selective transition, evidence recording, idempotency,
  and Finding D all re-confirmed with no regression.

- **No restore mechanism (fixed).** `backup-vault.ps1` produced correct, complete archives,
  but nothing could restore one - no `restore-vault.ps1`, no documented manual procedure.
  Investigation found two specific problems any restore would have to handle: (1)
  `Compress-Archive` was given `working/manifest.csv` as a bare file path, so it landed at
  the zip root instead of `working/manifest.csv` - a naive `Expand-Archive` would leave the
  manifest invisible to every pipeline script; (2) `Compress-Archive` silently drops
  zero-byte files, so the empty scaffold folders (`wiki/concepts/`, `wiki/synthesis/`, etc.)
  never made it into the archive (low severity - every script recreates them via
  `New-Item -Force` on its next run, but a fresh restore shouldn't need a pipeline run first
  just to become valid). Fixed at the source: `backup-vault.ps1` now stages `config/`, `wiki/`,
  and `working/manifest.csv` into a temp directory that mirrors the desired archive layout
  before compressing, so the manifest lands at the correct relative path from now on. Added
  `agent/scripts/restore-vault.ps1`: restores config/manifest/wiki from a backup archive
  (handling both the old flattened-manifest layout and the new correct one), then explicitly
  recreates the full `_template`-matching scaffold (12 directories, each with `.gitkeep`) so
  a restored vault is immediately usable. Refuses to restore into a non-empty vault directory
  without `-Force`. Verified: fresh backup's zip structure confirmed correct via `unzip -l`;
  restored into a sandbox copy of DWSIM after deliberately deleting a wiki page and corrupting
  the manifest - both recovered byte-identical to the pre-corruption state, full scaffold
  present with no pipeline run needed; safety check confirmed to refuse overwriting the live
  DWSIM vault without `-Force`; live DWSIM and Nate_Herk both confirmed untouched throughout.

- **Systemd unit path defect (fixed, source-only - not deployed today).**
  `wikiagent.service`'s `WorkingDirectory`/`ExecStart` referenced `/home/ubuntu/WikiAgent`, a
  path that has never existed on the VM - confirmed absent, and matching neither the current
  production path (`/home/ubuntu/wiki-agent`) nor any real multivault deployment. Also
  confirmed via `systemctl`/`/etc/systemd` search that these units have never actually been
  installed; only the old `nate-herk-weekly.service`/`.timer` are live. Per the project's
  existing Key Decisions (parallel deployment precedes cutover - the old Nate timer stays
  enabled until a controlled cutover), the fix corrects the unit to reference
  `/home/ubuntu/wiki-agent-multivault`: the intended eventual parallel-deployment path,
  distinct from both the current production path and the placeholder. No directory was
  created or renamed - source-file correction only; the real deployment happens at actual
  cutover planning. Verified with `systemd-analyze verify` directly against the uninstalled
  file (no install/enable required): `wikiagent.timer` verifies clean; `wikiagent.service`
  reports only that its target script doesn't exist yet at the not-yet-deployed path -
  confirmed via a control check against the real, installed `nate-herk-weekly.service` that
  this is expected baseline behavior, not a defect. Separately confirmed the hourly/UTC timer
  design (vs. the old weekly/timezone-aware one) is deliberate, not a gap: `schedule-contract.md`
  documents `time_utc` as "matched to the hour by the hourly systemd timer" - `schedule.csv`
  is where per-vault timing actually lives (arbitrary `day_of_week`/`time_utc` per row,
  UTC-normalized), and the timer's only job is to fire often enough to catch it. Dry-ran
  `run-wikiagent.sh`'s exact matching/resolution logic against schedule.csv's real rows
  (targeting `/home/ubuntu/test-multivault`, where vaults currently live) via a temporary,
  non-invoking harness: both `DWSIM` and `Nate_Herk` correctly resolved to their real vault
  paths and job types; `_template` correctly skipped; both correctly reported as not firing
  today (`enabled=false`) - nothing was installed, enabled, started, or actually dispatched.

## YouTube access via VPN/proxy — host prerequisite, not something this package sets up

The production VM cannot reach YouTube directly (cloud/datacenter IPs get blocked). The
proven fix, documented in the project's earlier continuation briefs, is a Proton WireGuard
tunnel exposed locally as a SOCKS5 proxy via `wireproxy`, running as its own systemd service
(`wireproxy-youtube.service`) independent of WikiAgent, listening on
`socks5h://127.0.0.1:25344`.

WikiAgent's role is only to *use* that proxy: `vault.json`'s `proxy` field is passed straight
through to `yt-dlp --proxy` in `ingest-youtube.ps1`. This build does **not** install or manage
wireproxy/WireGuard itself — that has to exist on the host before `ingest-youtube.ps1` will
work against a real YouTube channel. Set `vault.json → proxy` to
`socks5h://127.0.0.1:25344` once that service is running, or leave it blank if the host
doesn't need one.

## Retry cap and permanent parking

`ingest-youtube.ps1` retries any video whose caption download previously failed —
but not forever. Each row tracks `transcript_attempts`, and once a video hits
`max_transcript_attempts` (default `3`, configurable per vault) without producing a
usable transcript, its `transcript_status` becomes `parked`.

- **A parked video is permanently skipped** on every future scan — no further
  network/proxy calls for it, no manifest churn. This exists specifically to stop
  repeatedly re-attempting videos that are genuinely caption-less on YouTube's side, or
  have persistently unusable captions — retrying those forever wastes real proxy/network
  resources for no possible gain.
- **Parking is reversible, but only manually.** If you believe a parked video should be
  retried (e.g. YouTube captions were added later, or a transient issue is now
  resolved), edit that row's `transcript_status` back to `missing_transcript` and lower
  `transcript_attempts` in `working/manifest.csv` directly. Nothing in the pipeline does
  this automatically.
- Check a vault's manifest for `transcript_status = parked` rows if you're trying to
  understand why a channel's real video count doesn't match what's actually been
  processed — a parked count is expected and healthy for any real channel with
  genuinely caption-less content, not necessarily a defect.

## Document ingestion (.pdf / .docx / .md) — untested

`ingest-documents.ps1` registers manually dropped files from a vault's `input/` folder,
and the manifest/pipeline plumbing around it is real and structurally verified. However:

- **PDF/DOCX text extraction is a documented placeholder, not a working extractor.**
  `ingest-documents.ps1` currently writes an explicit `[EXTRACTION PENDING]` marker
  rather than real extracted text — this is intentionally visible, not a silent gap, but
  it means no real PDF or DOCX has ever actually been processed end-to-end through this
  pipeline as of this release.
  - Plain `.md`/`.txt` files should ingest correctly (no extraction step needed), but
    even this path has not been exercised with a real file to date.
- **Do not rely on document ingestion for anything you need working today.** Treat it as
  a scaffold to build on, not a verified feature, until a real extractor is wired in and
  tested against real files of each supported type.

## Lint-review

A separate scheduled job type (`-JobType lint-review` in `run-vault.ps1`, driven by
`schedule.csv` rows with `job_type=lint-review`) that runs Claude Code in report-only mode:
no ingestion, no content synthesis, no manifest writes beyond what the report itself
records. It analyzes the full vault for stale synthesis, orphaned source pages, broken
internal links, and structural drift, then writes a single `reports/lint_report_<date>.md`
— a top-level folder, sibling to `wiki/`/`working/`/`config/`, kept deliberately outside
the knowledge graph so a lint report never pollutes Obsidian search/graph view.

Tested and functional as of this release: run for real against a disposable replica vault
(a full copy of real vault content, not synthetic data), with real evidence gathered at
every step — the report landed at the correct `reports/` location (not `wiki/synthesis/`,
an earlier, since-corrected path), `wiki/synthesis/` and every other file outside
`reports/` were confirmed byte-for-byte untouched, and `sync-vault (push)` correctly
delivers the report to the vault's real Drive location afterward. That last part required
a real fix: the `lint-review` job type originally never pushed at all, so a scheduled
lint-review's report would sit on the VM and never reach Drive — fixed and re-verified
with a real end-to-end run showing the report present on Drive via `rclone`.

The findings from that real test run were reviewed directly and acted on: one was
identified as a test-setup artifact (not applicable to real vaults), one was a genuine
data-quality issue (a source page missing a frontmatter field, confirmed against two
independent real sources and corrected), and one was reviewed and deliberately left as-is
(an intentionally-standalone page, no fix needed).

## Telegram notifications

Five distinct events, each sent from `run-vault.ps1` at the exact point that condition
is determined — not one generic end-of-run message:

| Event | Meaning |
|---|---|
| `Blocked` | Run couldn't start — another run for this vault is already in progress (lock contention) |
| `Failed` | A real content-pipeline stage broke (ingest, clean, create-source-pages, synthesis, or QA) |
| `PartialSuccess` | Only a non-critical stage failed (e.g. Drive sync or backup) while all real content work succeeded |
| `Success` | Real content work completed this run |
| `NoChange` | Run completed cleanly with nothing pending — no error, just nothing new to do |

Every message also carries a `Stats` line (new/retried/parked counts, current
included/pending/parked totals) so you're never left inferring what actually happened
from the event label alone — `Failed` specifically means real content work broke, not
"something, somewhere, had an issue this run."

Credentials (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`) are read from, in order: already-set
process environment variables, then `<vault>/config/secrets.env`, then a shared
`agent/secrets.env`. Copy `config/secrets.env.example` in `vaults/_template/` to
`secrets.env` and fill it in per vault (or once at the agent level if every vault shares one
bot/chat). No file means notifications are silently skipped, not an error.

## Backup destinations (Drive)

Every vault's real Drive backup location is `<drive_path>/working/backups` - nested inside
the vault's own working directory, not a sibling folder and not directly under `drive_path`.
This became the explicit standard after NateHerk_Rev07 and DWSIM were found to have
diverged to two different hand-typed values (`<drive_path>/backups` and a sideline
`<name>_backup` folder respectively), with no code-level convention or documentation behind
either - `vault.json` is gitignored, so no git history recorded when or why either value was
set. All real vaults' `backup.destination` values have been reconciled to the standard.

`backup-vault.ps1` auto-derives `backup.destination` as `<drive_path>/working/backups`
whenever it's blank and `drive_path` is set. `_template` ships `destination` blank on
purpose, so any vault provisioned from it inherits the standard by default instead of
requiring manual entry - the exact gap that caused the original divergence. If
`backup.enabled` is true but no usable destination can be resolved (blank `destination` with
a blank `drive_path` too, or no `remote` configured), the script warns instead of silently
skipping the remote push.

`backup.keep` (default 12) is enforced in two places: locally against the VM's `archive/`
folder (pre-existing, unchanged), and against the real Drive destination itself (added -
previously Drive-side backups accumulated unbounded, since local pruning never touched what
had already been pushed). Both prune to the newest N by the timestamp embedded in the
backup filename (`<vault>_backup_YYYYMMDD_HHMMSS.zip`).
