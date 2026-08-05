# `schedule.csv` — quick reference

This file governs when the hourly systemd timer (`wikiagent.timer` →
`run-wikiagent.sh`) dispatches a vault run. Full detail: `agent/docs/schedule-contract.md`.

## Columns

| column        | values                              | notes |
|---------------|--------------------------------------|-------|
| vault_name    | a directory name under `vaults/` (not `_template`) | case-sensitive |
| job_type      | `full` \| `lint-review`              | see `schedule-contract.md` and vault `config/claude.md` |
| day_of_week   | `Mon`..`Sun`                          | UTC |
| time_utc      | `HH:MM`, 24h, UTC                     | only the hour is matched — minutes are ignored |
| enabled       | `true` \| `false`                     | `false` rows are ignored entirely |

## job_type nomenclature

```
# full = channel ingestion + synthesis, runs weekly on the nominated day and time
# lint-review = vault maintenance review, runs on the LAST occurrence of the
#   nominated day each month (e.g. day=Sat -> the final Saturday of the month),
#   at the nominated time — see schedule-contract.md for full detail
```

See `agent/docs/schedule-contract.md` for the full explanation of the last-occurrence
logic, why the gap between `lint-review` runs is always 4 or 5 weeks (never 3), and a
worked example.
