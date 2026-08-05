# YouTube Wiki Agent

An agentic system that ingests YouTube channels and uses Claude Code to autonomously
manifest structured Obsidian knowledge pages — combining a deterministic ingestion
pipeline (scan, download, clean) with agentic synthesis and quality review. Point it at
a channel; it turns that channel's content into a searchable, linked personal wiki you
can open in Obsidian.

## What's real vs. what's a skeleton

- **Real and verified through extensive production testing:** the full `agent/` +
  `vaults/_template/` layout, every required file the conformance test checks for,
  the locking/orchestration logic in `run-vault.ps1`, the interruption-safe manifest
  reconciliation in `run-qa.ps1`, the scheduler contract and `schedule.csv`-driven
  dispatch, systemd units, `ingest-youtube.ps1` (real channel ingestion, real
  caption downloads, real retry-cap/parking behavior), `run-claude-synthesis.ps1`
  (real synthesis runs and real monthly lint-review runs, both verified against
  production vault data, real Claude Code subscription/OAuth auth confirmed
  working).
- **Explicit placeholders, not hidden:** PDF/DOCX text extraction in
  `ingest-documents.ps1` — see the `[EXTRACTION PENDING]` marker it writes; wire in a real
  extractor before relying on document ingestion.

See `agent/docs/README.md` for the full gap list.

## Development approach

This project was developed using an agentic engineering approach: architectural and
product decisions made directly, with Claude Code handling implementation, and a
deliberately heavy verification discipline throughout — visible directly in this repo
via the runnable architecture conformance test
(`agent/tests/architecture-conformance-test.ps1`) and the inline "verified for real"
evidence documented in the Upgrade and Uninstall sections below, rather than taken on
faith.

**Questions or issues:** use this repo's Issues tab.

## Built with — versions this was tested against

Real, confirmed versions, pulled directly from the test VM (not estimated):

| Component | Version tested | Notes |
|---|---|---|
| OS | Ubuntu 24.04.4 LTS ("noble") | |
| PowerShell | `pwsh` 7.6.3 (Core) | No version-gated syntax (ternary, null-coalescing, etc.) found anywhere in `agent/scripts/`, confirmed via direct grep — the real requirement is PowerShell **Core** specifically (cross-platform), not legacy Windows PowerShell 5.1, which doesn't run on Linux at all. Older Core versions are plausible but untested. |
| `yt-dlp` | 2026.07.04 (kept current via `pip install -U yt-dlp`) | **Not on the default SSH `$PATH`** — installs to `$HOME/.local/bin/yt-dlp` via `pip --user`. If you SSH in and `yt-dlp --version` says "not found," check that path explicitly before assuming it's not installed. |
| `rclone` | v1.74.4 | |
| Claude Code CLI | 2.1.207, `@anthropic-ai/claude-code` | **Does not require Node.js to run** — confirmed on the test VM (zero Node.js installed anywhere on the filesystem): it's a standalone compiled binary once installed, not a Node.js script at runtime. Node.js may still be needed for the *installation* step itself depending on how you install it — check current official install docs. |
| `systemd` | 255 (255.4-1ubuntu8.16) | |

**Host/infrastructure:** developed and tested on an Oracle Cloud VM (ARM64/aarch64),
but **Oracle is not a requirement** — any Linux host that stays on and reachable
works (see "Always-on host expectation" below). The only reason Oracle came up
specifically: its VM's IP happened to be a datacenter range YouTube blocks more
aggressively than residential IPs — that's a property of datacenter IPs in general,
not anything Oracle-specific (see the proxy note in Prerequisites). No minimum
CPU/RAM/disk specs have been established through real testing — if you hit
resource limits on a small host, that's genuinely unverified territory this
project hasn't characterized yet.

If you hit a version-specific issue, check `agent/docs/README.md`'s known-gaps list
before assuming it's new.

## Attribution

This project is an independent extension of a publicly shared idea, not an original
concept from scratch. It builds on:

- **Andrej Karpathy** — original concept/gist describing an LLM-driven pipeline that
  turns YouTube video transcripts into structured wiki-style knowledge pages.
  https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f
- **Nate Herk** — the YouTube channel whose content was used as the original real-world
  source/proving ground for the single-vault predecessor to this multi-vault build.
  https://www.youtube.com/watch?v=sboNwYmH3AY

This repository is an independent, from-scratch rebuild, verified through its own
testing process. It is not affiliated with, endorsed by, or produced by either of the
above.

## YouTube content — copyright and Terms of Service

This pipeline downloads caption/transcript data from YouTube via `yt-dlp` and uses it
as input to an LLM synthesis step. Before pointing this at any channel:

- **You are responsible for your own compliance** with YouTube's Terms of Service and
  applicable copyright law for any channel you configure this against — this includes
  channels you don't own or control. This project does not provide legal advice, and
  using it against content you don't have rights to process is done at your own risk.
- **Intended use is personal reference and curation** — turning a creator's public
  video/transcript content into a private, personal knowledge base that helps you decide
  what's worth your time and how it maps to your own goals, not republishing,
  reposting, or repackaging someone else's content as your own output. That distinction
  matters in practice, not just in principle: a private research/decision-support tool
  and a tool for scraping content to redistribute elsewhere are different activities with
  different risk, even when the underlying code is identical.
- Captions/transcripts, once downloaded, are transformed (cleaned, then synthesized into
  new wiki pages by an LLM) rather than republished verbatim — but the synthesized output
  can still closely track the source material's substance. If you intend to publish or
  share any vault's output beyond personal use, that shifts you toward the
  redistribution end of the spectrum above, and you should weigh ToS/copyright
  obligations accordingly at that point, not assume the transformation alone settles it.
- YouTube's ToS restricts automated access and downloading in ways that can change
  without notice; `yt-dlp` itself is a third-party tool not affiliated with YouTube, and
  its continued function against any given channel is not guaranteed by this project.

## Architecture

```
agentic-knowledge-vault-pipeline/
│
├── agent/                    shared code — one copy, used by every vault
│   ├── scripts/               ingest-youtube.ps1, run-vault.ps1, etc.
│   ├── scheduling/             schedule.csv (which vault runs when)
│   └── docs/
│
└── vaults/
    ├── _template/             ← the master pattern (tracked in git)
    │   ├── config/              vault.json, claude.md, secrets.env.example
    │   └── (empty scaffold: working/, wiki/, reports/, logs/, ...)
    │
    ├── wiki_1/                ← real vault, copied FROM _template
    │   config/vault.json:        channel_url = "youtube.com/@ChannelOne"
    │
    ├── wiki_2/                ← real vault, copied FROM _template
    │   config/vault.json:        channel_url = "youtube.com/@ChannelTwo"
    │
    └── wiki_N/                ← as many as you want, each independent
        config/vault.json:        channel_url = "youtube.com/@AnyChannel"

    (wiki_1, wiki_2, wiki_N are gitignored — real vault content/config
     never gets committed; only the empty _template scaffold is tracked)
```
Code lives in one place (`agent/`) and is never duplicated. What gets replicated is
only the empty `_template` pattern — every real vault then diverges purely through
its own `config/vault.json`, never through different code.

## Pipeline flow

```
YouTube channel
      │
      ▼
┌─────────────────┐
│ ingest-youtube    │  scan channel, download captions (yt-dlp)
└────────┬─────────┘
         ▼
┌─────────────────┐
│ clean-transcripts │  raw .vtt → plain text
└────────┬─────────┘
         ▼
┌─────────────────┐
│ create-source-    │  plain text → wiki/sources/*.md
│ pages              │
└────────┬─────────┘
         ▼
┌─────────────────┐
│ run-claude-        │  Claude Code reads source, decides:
│ synthesis           │  create/update concept, tool, or workflow page
└────────┬─────────┘
         ▼
┌─────────────────┐
│ run-qa             │  reconciles manifest ↔ real files
└────────┬─────────┘
         ▼
┌─────────────────┐
│ sync-vault (push)  │  → Google Drive (canonical copy)
└────────┬─────────┘
         ▼
┌─────────────────┐
│ Telegram notify    │  Success / PartialSuccess / Failed / NoChange
└──────────────────┘
```

**The `run-claude-synthesis` step is where the actual agentic decision-making
happens.** Claude Code reads each source transcript and decides what to do with it,
guided by `vaults/<VaultName>/config/claude.md` — a plain-language instruction file,
**local to each vault**, that governs what counts as a concept vs. a tool vs. a
workflow, how existing pages should be updated vs. left alone, and (for the monthly
`lint-review` job) what to check the vault for. Every vault gets its own copy of this
file from `_template` when it's created, so you can tune synthesis behavior
per-channel without touching any code — edit `claude.md`, not the scripts.

## Inside one vault

```
vaults/<VaultName>/
├── config/          vault.json, claude.md, secrets.env
├── working/         manifest.csv (source of truth), backups/
├── wiki/            ← open THIS in Obsidian
│   ├── sources/      raw ingested transcripts
│   ├── concepts/      synthesized knowledge pages
│   ├── tools/
│   ├── workflows/
│   └── synthesis/     cross-source pages + register
├── reports/         lint-review output (monthly)
└── logs/            run logs (local only, not synced to Drive)
```

## Prerequisites and host setup

Everything below must exist on the host *before* this pipeline will run for real —
none of it is installed automatically by this repository.

1. **Operating system:** Ubuntu Linux (or another `systemd`-based Linux distribution).
   See "Platform support" below — Windows is out of scope for this release.
2. **PowerShell (`pwsh`):** the pipeline scripts are PowerShell, run under PowerShell
   Core on Linux. Install per the official Microsoft instructions for your
   distribution (search "install PowerShell on Ubuntu" for the current apt/snap
   steps — not duplicated here since install commands change across Ubuntu
   releases and this project hasn't re-verified every version).
3. **`yt-dlp`:** used for all YouTube channel scanning and caption downloads.
   Install via your distro's package manager or `pip install yt-dlp`
   (`--break-system-packages` may be required on newer Ubuntu/Debian). Keep it
   updated — YouTube-facing extractors break and get patched frequently upstream.
   **Note:** a user-level `pip install --user` puts the binary at
   `$HOME/.local/bin/yt-dlp`, which is not always on a plain SSH session's default
   `$PATH` — confirmed directly on this project's own test VM. If `yt-dlp --version`
   reports "not found" over SSH despite being installed, check that path explicitly
   before assuming something's broken (this pipeline's own scripts already handle
   this via their own PATH-fixup logic — this note is for your own manual
   troubleshooting, not something the pipeline itself gets tripped up by).
4. **`rclone`:** used for all Google Drive sync (pull/push) and backup. Install per
   https://rclone.org/install/, then see "Google Drive setup" below for the
   one-time remote configuration this pipeline expects.
5. **Claude Code CLI (`claude`):** see "Claude Code / Claude API authentication"
   below for the two supported auth models and setup steps.
6. **(Optional, only if a configured channel needs it) a proxy:** the production
   use of this pipeline required a WireGuard-based SOCKS5 proxy because the host's
   direct IP was blocked by YouTube — see "YouTube access via VPN/proxy" in
   `agent/docs/README.md`. This is a host-level prerequisite this package does not
   install or manage; only needed if your own host/IP hits the same restriction.
7. **Telegram (optional but recommended):** free messaging app (iOS/Android/desktop,
   telegram.org) that this pipeline uses to send you run notifications. See
   "Telegram notifications" below for full setup — nothing to install on the host
   itself beyond having the app on your phone.

## Google Drive setup

This pipeline treats Google Drive as the canonical, durable store for every vault —
the local `vaults/<n>/` directory on your host is only ever a working copy (see
`sync-vault.ps1`'s own docstring). Before running any vault for real:

1. Configure an `rclone` remote for Google Drive. Run `rclone config`, choose
   "New remote," select the Google Drive backend, and complete the browser OAuth
   flow. **Name the remote exactly `gdrive`** unless you deliberately change every
   vault's `drive_remote` field to match a different name — this repo's `_template`
   and every documented example assume `gdrive`.
2. Decide a Drive folder layout before creating vaults, not after — retrofitting a
   layout once real data exists is real, manual cleanup (this project's own history
   includes exactly that: a backup-path inconsistency between two real vaults that
   had to be found, decided on, and manually migrated after the fact). The
   convention this build uses: `Wikis/<VaultName>/` as each vault's root, with
   backups at `Wikis/<VaultName>/working/backups`.
3. **Do not run `rclone config show gdrive` in any logged/shared session.** It
   prints the remote's OAuth `client_secret` in plaintext to stdout — a real
   credential exposure this project hit directly. If you need to inspect config,
   do it in a private local terminal, never through an AI coding assistant or any
   session whose output might be logged or shared.
4. Set each vault's `config/vault.json` → `drive_remote` and `drive_path` to match
   what you set up here. A mismatch here is silent — the pipeline will simply sync
   against the wrong (or a nonexistent) location with no obvious error.

## Cookie file setup (per-channel, only if needed)

Some YouTube channels require an authenticated session to reliably serve captions
(age-gated, region-restricted, or otherwise rate-limited content) — `vault.json`'s
`cookie_file` field points `yt-dlp` at a real browser-exported cookie file for this.

1. Export cookies from a real logged-in browser session using a cookie-export
   extension (search "export cookies.txt" for your browser — Netscape/Mozilla
   cookie-file format is what `yt-dlp --cookies` expects). This is a manual,
   browser-side step this repository does not automate.
2. Transfer the resulting file to the host **directly** (e.g. `scp`), not through
   an AI coding assistant or any tool that might read, log, or echo its contents.
   This project's own convention: cookie files are never read or displayed by
   Claude Code — only referenced by path.
3. Set `cookie_file` in the relevant vault's `config/vault.json` to the real path
   on the host.
4. Treat the cookie file itself as a credential: keep it out of git (already
   excluded via `.gitignore`'s `vaults/*` pattern), restrict its file permissions,
   and rotate/re-export it if the source browser session's login changes.

## Claude Code / Claude API authentication

`run-claude-synthesis.ps1` calls the `claude` CLI headlessly (`claude -p`). It supports
two different auth models — pick one before running this pipeline for real:

**Subscription auth (Claude Pro/Max), via OAuth — what this project's own VM actually
uses, confirmed empirically through real testing, not assumed:**
1. Install the Claude Code CLI (npm package `@anthropic-ai/claude-code`). Once
   installed, it runs as a standalone binary and **does not require Node.js to be
   present at runtime** — confirmed on this project's own test VM, which has zero
   Node.js installed anywhere. Node.js may still be needed for the install step
   itself depending on your install method — check current official docs for the
   authoritative current process: https://docs.claude.com/en/docs/claude-code/overview.
2. Run `claude` interactively once on the host and complete the browser-based OAuth
   login with your Claude.ai account. This links the CLI to your subscription rather
   than to a billed API key.
3. Usage under this model is governed by your subscription's rolling usage window
   (confirmed in this project's own use: a rolling 5-hour window), **not** a per-call
   dollar cost — which is why `vault.json`'s `claude_budget_usd` field exists as a soft,
   currently-unenforced value in this build: it doesn't apply cleanly to subscription
   billing, and enforcing it meaningfully depends on which auth model you're actually
   running under.
4. Headless/non-interactive invocations (like this pipeline's `claude -p` calls, run via
   cron/systemd with no human present to approve tool use) require an explicit
   permission-mode flag or every tool call is silently denied — this build passes
   `--permission-mode acceptEdits` for that reason. Review what that flag actually
   authorizes before relying on it unattended.

**API key auth — supported by the underlying `claude` CLI, but not the model this
project's own scheduled runs are verified against:**
- Set the `ANTHROPIC_API_KEY` environment variable instead of completing the OAuth
  login. This shifts billing to standard per-token API pricing rather than your
  subscription's usage window.
- If you use this path, `claude_budget_usd` becomes directly meaningful (real dollar
  cost per run) — but its enforcement is still soft/unimplemented in this build as of
  this release; don't assume it will actually stop a run at the configured limit.
- This project has not verified its real end-to-end pipeline behavior under API-key
  billing specifically — only under subscription/OAuth auth. If you use API-key auth,
  treat the budget/cost behavior as unverified until you test it yourself.

For current, authoritative install and auth steps, always check the official docs
directly rather than relying solely on this section:
https://docs.claude.com/en/docs/claude-code/overview

## Telegram notifications

Every pipeline run sends you a message — success, failure, or nothing-to-do — so you
don't have to check logs manually.

**Telegram is a free messaging app**, available on iOS, Android, and desktop
(telegram.org) — if you don't already use it, install it on your phone first; this is
where your run notifications will actually appear.

Setup:
1. Message **@BotFather** on Telegram, send `/newbot`, follow the prompts — you'll get
   back a bot token (a long string like `123456:ABC-DEF...`).
2. Start a chat with your new bot (search its username, send it any message) so it's
   allowed to message you back.
3. Get your chat ID — message **@userinfobot**, it'll reply with your numeric ID.
4. Copy a template to `secrets.env` and fill in your real values — two options
   depending on whether you want one bot for every vault, or a different one per
   vault:
   - **Per-vault** (different bot/chat for each vault):
     ```bash
     cp vaults/_template/config/secrets.env.example vaults/<YourVault>/config/secrets.env
     ```
   - **Shared** (one bot/chat for every vault):
     ```bash
     cp agent/secrets.env.example agent/secrets.env
     ```
   - Vault-level `secrets.env` is checked first if both exist — see
     `send-notification.ps1`'s credential resolution order for the exact
     precedence.
   Then open the file you just created and fill in your real values:
   ```
   TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
   TELEGRAM_CHAT_ID=987654321
   ```
   Save the file — that's the entire setup, no code changes needed.
5. If this file is missing, notifications are silently skipped (not an error), so a
   run without Telegram configured still works, you just won't get pinged.

**What to expect in the message** — five possible events, each meaning something
different:

| Event | Meaning |
|---|---|
| `Blocked` | Run couldn't start — another run for this vault is already in progress |
| `Failed` | A real content-pipeline stage broke — this is the one to actually act on |
| `PartialSuccess` | Real content work succeeded; only a non-critical stage (sync/backup) had an issue |
| `Success` | Real content work completed this run |
| `NoChange` | Ran cleanly, nothing new to do — not an error |

Every message also includes a `Stats` line (new/retried/parked video counts) so you
can see what actually happened without digging into logs.

## Quick start

```bash
# 1. Deploy this whole WikiAgent/ folder to the target host (e.g. /home/ubuntu/WikiAgent)
# 2. Copy the template for a new vault:
cp -r vaults/_template vaults/MyNewVault
# 3. Edit vaults/MyNewVault/config/vault.json (channel_url, creator, drive_path, etc.)
# 4. Add one row to agent/scheduling/schedule.csv:
#    MyNewVault,full,Sun,09:00,true
# 5. Install the systemd units and enable the timer:
sudo cp agent/scheduling/ubuntu/systemd/*.service agent/scheduling/ubuntu/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wikiagent.timer
# 6. Verify architecture conformance any time:
pwsh agent/tests/architecture-conformance-test.ps1 -RootPath . -ReportPath conformance-report.json
```

`schedule.csv` only expresses a weekly day/time — for the `lint-review` job type this
maps to a monthly cadence, not weekly; see `agent/docs/schedule-contract.md` for the
exact rule before assuming a lint-review row runs every week.

## Config field reference (`config/vault.json`)

The quick-start's "edit `vault.json`" step undersells how many fields matter. Real
fields from `vaults/_template/config/vault.json`, what each does, and what happens
if you leave it at its template default:

| Field | Purpose | If left blank/default |
|---|---|---|
| `vault_name` | Human-readable vault identifier | Template ships `"REPLACE_ME"` — must be set |
| `channel_url` | YouTube channel this vault ingests from | Blank = YouTube ingestion silently skipped entirely |
| `creator` / `creator_page` | Attribution metadata for the source creator | Cosmetic only — doesn't affect pipeline behavior |
| `max_videos` | Cap on how many channel videos are scanned per run | Defaults to 80 if unset in code, but set it explicitly to match your real channel size |
| `caption_languages` | Preferred caption language(s), in priority order | Defaults to `["en-orig", "en"]` |
| `yt_dlp_path` | Path to the `yt-dlp` binary | Defaults to `yt-dlp` (must resolve on PATH) |
| `proxy` | SOCKS5 proxy URL passed to `yt-dlp --proxy` | Blank = no proxy used; required if your host's IP is blocked by YouTube |
| `cookie_file` | Path to a real exported cookie file | Blank = no auth passed to `yt-dlp`; some channels will fail without it |
| `js_runtime` | JS runtime path some yt-dlp extractors require | Blank unless your channel specifically needs it |
| `drive_remote` | rclone remote name for Drive sync | Must match a remote you actually configured (see "Google Drive setup") |
| `drive_path` | Drive folder path for this vault's canonical copy | Required for any sync/backup to function |
| `claude_effort` | Target synthesis effort passed to the LLM | Vault-defined string, no pipeline-level default enforcement |
| `claude_budget_usd` | Soft per-run budget ceiling | **Currently unenforced regardless of value** — see "Claude Code / Claude API authentication" |
| `max_transcript_attempts` | Retry cap before a caption-failing video is permanently parked | Defaults to `3` if unset |
| `documents.enabled` / `documents.supported_extensions` | Controls manual document ingestion from `input/` | See `agent/docs/README.md`'s "Document ingestion" section before relying on this |
| `backup.enabled` | Whether `backup-vault.ps1` runs at all | `true` in template; set `false` to disable |
| `backup.remote` / `backup.destination` | Where backups get pushed on Drive | Blank destination now auto-derives to `<drive_path>/working/backups` |
| `backup.keep` | Local *and* Drive backup retention count | Defaults to `12`; enforced on both sides as of this release |

## Obsidian — how to actually read the output

This pipeline's terminology (`vault`, `wiki/concepts/`, `wiki/tools/`,
`wiki/workflows/`) directly follows **Obsidian**'s (https://obsidian.md) own
conventions for a linked collection of markdown notes — but nothing in this
repository installs Obsidian, and until now nothing in the documentation said so
explicitly.

- **To view a vault as intended, open its root folder directly in Obsidian**
  (Obsidian → "Open folder as vault"). Every synthesized page is plain markdown
  with YAML frontmatter, so it's readable in any text editor or markdown viewer —
  but cross-references between concepts/tools/workflows are designed around
  Obsidian's linking and graph-view features.
- **Real gap worth knowing before relying on this:** `config/claude.md` (the file
  governing how synthesis output gets written) does not currently give the LLM any
  explicit instruction to use Obsidian's `[[wikilink]]` syntax when cross-referencing
  pages — it only instructs checking for "broken internal links" during lint-review
  without defining the link format itself. This means the actual link syntax
  produced is currently whatever the model defaults to, not a guaranteed,
  enforced convention. Confirm what your own synthesized output actually contains
  before assuming full Obsidian-native linking/graph-view behavior.
- Obsidian itself is free for personal use; check its current licensing directly
  (https://obsidian.md/license) if you intend any commercial or team use of the
  output.

## Platform support

Built and verified against Ubuntu Linux. The pipeline scripts are PowerShell (`pwsh`),
which is technically cross-platform, but scheduling, locking, and deployment all assume
`systemd` — there is no Windows equivalent implemented, tested, or documented in this
release. Windows support is out of scope for this repository; treat it as a candidate
for a separate, future project/fork rather than an assumed capability of what's here
today.

## Upgrade

To upgrade an existing installation in place:

```bash
# 1. Pull the latest commits into the existing clone
cd /path/to/WikiAgent   # e.g. /home/ubuntu/WikiAgent
git pull

# 2. Re-verify architecture conformance against the updated code
pwsh agent/tests/architecture-conformance-test.ps1 -RootPath . -ReportPath conformance-report.json

# 3. Only if the systemd unit files themselves changed in the pulled commits -
#    check first: git diff <old-HEAD> <new-HEAD> -- agent/scheduling/ubuntu/systemd/
#    systemd does not pick up changed unit files on disk automatically, so re-copy
#    and reload/restart if (and only if) that diff is non-empty:
sudo cp agent/scheduling/ubuntu/systemd/*.service agent/scheduling/ubuntu/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart wikiagent.timer
```

`vaults/` is never git-tracked (no deployed vault instance is ever committed — only
`vaults/_template` is), so a plain `git pull` does not touch it: git's merge refuses to
silently overwrite an *untracked* file at a path an incoming commit wants to create or
modify — it aborts with a "would be overwritten by merge" error instead of deleting
anything. Since no upstream commit creates paths under any deployed vault's directory,
that conflict path never arises here in practice. Verified for real in a disposable
scratch clone: hashed every file under a test vault directory, ran `git pull`,
re-hashed — byte-identical (the pull was a no-op fast-forward, since no new upstream
commits existed to pull at verification time; the untracked-path-conflict guarantee
above rests on git's documented merge behavior rather than a fabricated conflict
scenario, to avoid pushing a throwaway commit upstream just to force one).

## Uninstall

There is no automated uninstall script. Uninstalling is a manual operator procedure —
**follow this order exactly**. Skipping step 1 risks **permanently losing any vault data
that hasn't been pushed to Drive yet** — Drive is the canonical store; the local `vaults/`
directory is only ever a working copy (see `agent/scripts/sync-vault.ps1`'s own docstring).

1. **Confirm every vault is fully pushed to Drive first, always:**

   For each deployed vault under `vaults/` (excluding `_template`):
   ```bash
   # Push any pending local state - safe, additive-only (rclone copy, never deletes):
   pwsh agent/scripts/sync-vault.ps1 -VaultRoot vaults/<name> -Direction Push

   # Then confirm nothing local-only remains, using the exact same check
   # sync-vault.ps1 runs internally before every pull:
   rclone check vaults/<name> <drive_remote>:<drive_path> --one-way \
     --exclude '/config/prompts/**' --exclude '/logs/**' --combined -
   ```
   (`<drive_remote>` / `<drive_path>` come from that vault's own `config/vault.json`.) A
   non-zero exit code, or any output line starting with `+` or `*`, means something local is
   not yet on Drive — **do not proceed until this check exits 0 with "0 differences found".**

   Also run `git status` in the repo root and commit or intentionally discard any
   uncommitted code changes you care about — deleting the folder deletes those too.

2. Stop the timer:
   ```bash
   sudo systemctl disable --now wikiagent.timer
   ```
3. Remove the systemd unit files:
   ```bash
   sudo rm /etc/systemd/system/wikiagent.service /etc/systemd/system/wikiagent.timer
   sudo systemctl daemon-reload
   ```
4. Only after steps 1–3: delete the repo folder.
   ```bash
   rm -rf /path/to/WikiAgent
   ```

**Verified for real** (disposable scratch clone + scratch vault, never against real vault
data): pushed a baseline, made an unpushed local edit to simulate the exact risk this
procedure exists to prevent, then ran step 1's check exactly as documented — it correctly
failed (non-zero exit, `* config/vault.json: md5 differ`) *before* any deletion occurred.
Pushing and re-running the check brought it to a clean "0 differences found" exit 0, at which
point deletion would be safe. Confirms the documented check step genuinely stops an operator
before data loss, not just in theory.
