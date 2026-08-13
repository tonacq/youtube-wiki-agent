#!/usr/bin/env bash
# One-time, host-level setup: installs the systemd timer that dispatches
# scheduled vault runs, using this repo's REAL current location and the REAL
# invoking user (whatever the folder was named, wherever it was deployed,
# whoever actually owns it). Convention-agnostic by design: substitutes each
# of WorkingDirectory/ExecStart/User/Group/Environment=HOME by matching the
# systemd KEY, not the checked-in template's current value - so this same,
# unmodified script works correctly regardless of which hardcoded
# path/user convention a given checkout's wikiagent.service happens to ship
# with. Re-run any time the deployment is moved, renamed, or its ownership
# changes - the timer keeps pointing at whatever was true the last time this
# script ran, not the live current state. Safe to re-run at any time
# regardless (idempotent).
#
# Does NOT: create a vault, edit any vault.json, or set up credentials
# (rclone remote, Claude Code auth, Telegram bot, YouTube proxy). Does NOT
# install prerequisites (pwsh, yt-dlp, rclone, claude CLI) - it only checks
# they're already present. See README.md "Prerequisites and host setup" and
# "Fresh Install: Credential Setup" for everything this script leaves for you.

set -euo pipefail

# --- Require root up front, rather than prompting mid-script. Simpler and
# more foolproof for a non-technical user than a partial run that stops to
# ask for a password partway through - one clear instruction, one command. ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script installs a systemd service and must be run with sudo."
    echo ""
    echo "  Try:  sudo ./install.sh"
    echo ""
    exit 1
fi

# --- Self-locate: the repo root is wherever THIS script actually is, resolved
# to a real absolute path - not assumed, not hardcoded, works regardless of
# the folder's name or how the script was invoked (relative path, symlink,
# a different working directory, etc). ---
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Detected install path: $REPO_ROOT"

# --- The real, non-root user who invoked sudo - needed to check for
# prerequisites installed under their own ~/.local/bin (the same convention
# run-vault.ps1 itself relies on for non-interactive PATH), so any file this
# script creates is owned by them rather than root, and so the generated
# systemd unit runs the service as this real owner rather than a hardcoded
# "ubuntu" that may not exist or may not be who actually deployed this. ---
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
if [ -z "$REAL_HOME" ]; then REAL_HOME="$HOME"; fi
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

# --- Prerequisite checks - fail clearly and immediately, naming exactly
# what's missing, rather than failing partway through or silently. Checks
# both the root shell's own PATH and the real user's ~/.local/bin, since
# sudo does not always inherit a regular user's PATH additions. ---
check_tool() {
    local tool="$1"
    if command -v "$tool" >/dev/null 2>&1; then return 0; fi
    if [ -x "$REAL_HOME/.local/bin/$tool" ]; then return 0; fi
    return 1
}

MISSING=()
check_tool pwsh   || MISSING+=("pwsh (PowerShell)")
check_tool rclone || MISSING+=("rclone")
command -v systemctl >/dev/null 2>&1 || MISSING+=("systemctl (systemd)")

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "ERROR: missing required prerequisite(s):"
    for m in "${MISSING[@]}"; do echo "  - $m"; done
    echo ""
    echo "See README.md's \"Prerequisites and host setup\" section for how to install"
    echo "these. install.sh only wires up the scheduler once they're already present -"
    echo "it does not install them for you."
    exit 1
fi
echo "Prerequisites found: pwsh, rclone, systemctl."

# --- Generate the two unit files with the REAL detected path AND the REAL
# invoking user/group/home substituted in, via a copy + sed into a temp
# location. The checked-in template files in the repo itself are never
# modified - only the copies that get installed to /etc/systemd/system/.
# Same REAL_USER/REAL_HOME already detected above - not re-derived here. ---
UNIT_SRC_DIR="$REPO_ROOT/agent/scheduling/ubuntu/systemd"
if [ ! -f "$UNIT_SRC_DIR/wikiagent.service" ] || [ ! -f "$UNIT_SRC_DIR/wikiagent.timer" ]; then
    echo "ERROR: expected unit files not found under $UNIT_SRC_DIR"
    echo "This does not look like a complete copy of the repo - re-deploy and try again."
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Convention-agnostic by design: matches each line by its systemd KEY (anchored
# at start of line), and replaces the entire value regardless of what it
# currently is - "/home/ubuntu/wiki-agent-pipeline", "/home/ubuntu/WikiAgent",
# or anything else a differently-converted checkout might have. Does not
# depend on knowing or matching the OLD value at all, unlike a literal-string
# substitution - that's the actual fix here, not just a different string.
# Confirmed via direct inspection of both this project's real repos' checked-in
# wikiagent.service files that ExecStart is always a bare script path with no
# trailing arguments, so a full-line replace loses nothing real.
sed \
    -e "s#^WorkingDirectory=.*#WorkingDirectory=${REPO_ROOT}#" \
    -e "s#^ExecStart=.*#ExecStart=${REPO_ROOT}/agent/scheduling/ubuntu/run-wikiagent.sh#" \
    -e "s#^User=.*#User=${REAL_USER}#" \
    -e "s#^Group=.*#Group=${REAL_GROUP}#" \
    -e "s#^Environment=HOME=.*#Environment=HOME=${REAL_HOME}#" \
    "$UNIT_SRC_DIR/wikiagent.service" > "$TMP_DIR/wikiagent.service"
cp "$UNIT_SRC_DIR/wikiagent.timer" "$TMP_DIR/wikiagent.timer"

echo "Generated systemd unit for this install:"
echo "  WorkingDirectory = $REPO_ROOT"
echo "  ExecStart        = $REPO_ROOT/agent/scheduling/ubuntu/run-wikiagent.sh"
echo "  User             = $REAL_USER"
echo "  Group            = $REAL_GROUP"
echo "  Environment=HOME = $REAL_HOME"

# --- Idempotency check: is the timer already installed and enabled? Report
# this rather than erroring or duplicating anything - re-applying is safe
# either way (it's just a file copy + daemon-reload + enable, all idempotent
# systemd operations on their own), but the person should know which case
# they're in. ---
ALREADY_ACTIVE=false
if systemctl is-enabled wikiagent.timer >/dev/null 2>&1 && systemctl is-active wikiagent.timer >/dev/null 2>&1; then
    ALREADY_ACTIVE=true
fi

echo "Installing systemd timer..."
cp "$TMP_DIR/wikiagent.service" /etc/systemd/system/wikiagent.service
cp "$TMP_DIR/wikiagent.timer" /etc/systemd/system/wikiagent.timer
systemctl daemon-reload
systemctl enable --now wikiagent.timer

if [ "$ALREADY_ACTIVE" = true ]; then
    echo "wikiagent.timer was already installed and active - re-applied cleanly with the current detected path (safe to re-run any time)."
else
    echo "wikiagent.timer installed and enabled."
fi
echo "Done - the pipeline will now check for scheduled vaults every hour."

# --- schedule.csv: create from the example (header row only) if missing.
# Never touch it if it already exists - it's real per-vault scheduling data,
# not something this script should ever overwrite. ---
SCHEDULE_CSV="$REPO_ROOT/agent/scheduling/schedule.csv"
SCHEDULE_EXAMPLE="$REPO_ROOT/agent/scheduling/schedule.csv.example"
if [ -f "$SCHEDULE_CSV" ]; then
    echo "agent/scheduling/schedule.csv already exists - left untouched."
else
    if [ ! -f "$SCHEDULE_EXAMPLE" ]; then
        echo "ERROR: agent/scheduling/schedule.csv.example not found - cannot create schedule.csv."
        exit 1
    fi
    head -n 1 "$SCHEDULE_EXAMPLE" > "$SCHEDULE_CSV"
    chown "$REAL_USER" "$SCHEDULE_CSV" 2>/dev/null || true
    echo "Created agent/scheduling/schedule.csv (header row only, from schedule.csv.example) - no vault rows added."
fi

echo ""
echo "Setup complete. Still your responsibility, not handled by this script:"
echo "  - Prerequisite host setup beyond pwsh/rclone/systemd (yt-dlp, claude CLI auth,"
echo "    a configured rclone remote, YouTube proxy) if not already done"
echo "  - Credentials: Telegram bot/chat, per-vault cookie files, proxy config"
echo "  - Creating your first vault: cp -r vaults/_template vaults/YourVaultName,"
echo "    then edit its config/vault.json and add a row to schedule.csv"
echo "See README.md for all of the above."
