#!/usr/bin/env bash
# Hourly dispatcher: reads agent/scheduling/schedule.csv, runs pwsh run-vault.ps1 for every
# enabled row whose day_of_week + time_utc matches the current UTC hour.
#
# Called by: agent/scheduling/ubuntu/systemd/wikiagent.timer (hourly, OnCalendar=*-*-* *:00:00)
#
# Deliberately does NOT hard-code any vault name. New vaults are picked up purely by adding
# a row to schedule.csv — see agent/docs/schedule-contract.md.

set -Eeuo pipefail

# Explicit PATH — matches the proven production wrapper (run_nate_herk_weekly.sh),
# needed because systemd services don't inherit an interactive login PATH.
export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"

AGENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WIKIAGENT_ROOT="$(cd "${AGENT_ROOT}/.." && pwd)"
SCHEDULE_CSV="${AGENT_ROOT}/scheduling/schedule.csv"
LOG_DIR="${AGENT_ROOT}/scheduling/dispatch-logs"
mkdir -p "${LOG_DIR}"

CURRENT_DAY="$(date -u +%a)"     # Mon, Tue, ...
CURRENT_HOUR="$(date -u +%H)"

if [ ! -f "${SCHEDULE_CSV}" ]; then
  echo "No schedule.csv found at ${SCHEDULE_CSV}; nothing to do." >&2
  exit 0
fi

# Skip header, match day + hour on enabled=true rows, ignore _template.
# batch_size/batch_iterations/continuity are OPTIONAL per-run overrides (new columns,
# appended at the end so any pre-existing 5-column row still reads correctly - IFS=,
# read leaves trailing unmatched variables as empty strings, which is exactly the
# blank-tolerant behavior needed here). Row value wins over vault.json's default only
# when non-blank; run-vault.ps1 and downstream own the actual resolution rule.
tail -n +2 "${SCHEDULE_CSV}" | while IFS=, read -r vault_name job_type day_of_week time_utc enabled batch_size_override batch_iterations_override continuity_override; do
  [ "${enabled}" = "true" ] || continue
  [ "${vault_name}" = "_template" ] && continue
  [ "${day_of_week}" = "${CURRENT_DAY}" ] || continue

  row_hour="${time_utc%%:*}"
  [ "${row_hour}" = "${CURRENT_HOUR}" ] || continue

  vault_path="${WIKIAGENT_ROOT}/vaults/${vault_name}"
  if [ ! -d "${vault_path}" ]; then
    echo "WARNING: schedule.csv references vault '${vault_name}' which does not exist at ${vault_path}. Skipping." >&2
    continue
  fi

  logfile="${LOG_DIR}/${vault_name}_${job_type}_$(date -u +%Y%m%dT%H%M%SZ).log"
  echo "Dispatching vault=${vault_name} job_type=${job_type} -> ${logfile}"

  extra_args=()
  [ -n "${batch_size_override}" ] && extra_args+=(-BatchSizeOverride "${batch_size_override}")
  [ -n "${batch_iterations_override}" ] && extra_args+=(-BatchIterationsOverride "${batch_iterations_override}")
  [ -n "${continuity_override}" ] && extra_args+=(-ContinuityOverride "${continuity_override}")

  pwsh -NoProfile -File "${AGENT_ROOT}/scripts/run-vault.ps1" \
    -VaultRoot "${vault_path}" \
    -JobType "${job_type}" \
    "${extra_args[@]}" \
    >"${logfile}" 2>&1 || echo "Vault ${vault_name} run exited non-zero; see ${logfile}" >&2
done
