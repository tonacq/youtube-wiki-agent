# `schedule.csv` contract

Location: `agent/scheduling/schedule.csv`

| column        | required | values                          | notes |
|---------------|----------|----------------------------------|-------|
| vault_name    | yes      | must match a directory under `vaults/` (not `_template`) | case-sensitive |
| job_type      | yes      | `full` \| `lint-review`          | see `01-architecture-spec.md` §5 and vault `config/claude.md` |
| day_of_week   | yes      | `Mon`..`Sun`                      | UTC |
| time_utc      | yes      | `HH:MM`, 24h, UTC                 | matched to the hour by the hourly systemd timer |
| enabled       | yes      | `true` \| `false`                 | `false` rows are ignored entirely |

## To onboard a new vault (the whole point of this design)

1. Copy `vaults/_template/` to `vaults/<NewVaultName>/`.
2. Edit `vaults/<NewVaultName>/config/vault.json` (channel URL, creator, Drive path, etc).
3. Add one row to `agent/scheduling/schedule.csv` with `vault_name = <NewVaultName>` and
   `enabled = true`.
4. Nothing else changes. `agent/` is never touched for a new vault. The scheduler
   (`agent/scheduling/ubuntu/run-wikiagent.sh`) discovers the new row automatically on its
   next hourly tick.

## `lint-review` cadence: monthly, with no schema change

`schedule.csv` has no day-of-month column — `day_of_week` + `time_utc` only express a
*weekly* recurrence, and the dispatcher (`run-wikiagent.sh`) matches purely on those two
columns every hour. A `lint-review` row is therefore dispatched every week, same as a
`full` row would be — but `run-vault.ps1`'s `lint-review` branch adds one more check
before doing any real work: it only actually proceeds if **today is the last occurrence
of its own weekday in the current calendar month** (equivalently: today plus 7 days rolls
into next month). Every other week, it logs why it's skipping and exits cleanly — no
`claude` invocation, no report written, no Drive push.

**Worked example:** a row with `day_of_week = Sat` fires every Saturday at the dispatcher
level, but only actually runs on the *final* Saturday of each month. August 2026 has five
Saturdays (1, 8, 15, 22, 29) — only the 29th runs; the other four log a skip and exit.

**Gap between real runs is always 4 or 5 weeks, never 3** — every calendar month contains
at least 4 full weeks of any given weekday, and months long enough to contain a 5th
occurrence push the gap to 5 weeks instead. This is expected, load-bearing behavior, not
a bug to fix.

This logic lives entirely in `run-vault.ps1` and only applies to `job_type = lint-review`;
`full` rows are completely unaffected and keep running every week as configured.

## Duplicate-run prevention

`run-vault.ps1` takes a per-vault lock (`agent/scheduling/locks/<vault>.lock`) before doing
anything, so even if the scheduler fires twice for the same vault (e.g. a long-running job
still active at the next hourly tick), the second invocation aborts immediately rather than
running concurrently against the same manifest.
