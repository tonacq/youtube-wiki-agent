# Vault Operating Instructions (CLAUDE.md)

This file governs how Claude Code behaves when invoked headlessly inside this vault by
`agent/scripts/run-claude-synthesis.ps1`. It is vault-local so each vault can carry its own
tone, scope, and synthesis rules without touching shared agent code.

## Your job in this vault

1. Read the prompt file passed to you (`config/prompts/<batch>.md`). It lists which source
   pages under `wiki/sources/` are pending synthesis for this run.
2. For each pending source, read the source page and decide which of these it updates or
   creates:
   - `wiki/concepts/*.md` — durable ideas, definitions, mental models
   - `wiki/tools/*.md` — named tools, products, libraries, platforms
   - `wiki/workflows/*.md` — repeatable step-by-step processes or SOPs
   - `wiki/synthesis/*.md` — cross-source synthesis pages that connect multiple sources
3. Update `wiki/synthesis/synthesis_register.md` with the batch you just completed.
4. Do not modify `working/manifest.csv` directly — write results to
   `working/temp/synthesis-result.json` and let `run-qa.ps1` reconcile the manifest
   deterministically. This is a hard rule: it is what makes interrupted-run recovery safe.
5. Do not invent facts. If a source page doesn't support a claim, leave it out or flag it
   for human review in the synthesis page rather than filling the gap.
6. Stay inside this vault. Never read or write another vault's `wiki/`, `working/`, or
   `config/` directories, and never modify anything under `agent/`.

## Scheduled lint-review runs

When invoked with a `lint-review` job (see `agent/scheduling/schedule.csv`), you are in
**report-only mode**:
- Analyze the full vault for stale synthesis, orphaned source pages, broken internal links,
  and structural drift against this template.
- Write findings to `reports/lint_report_<date>.md`.
- Make no other changes. Do not edit any other file in this run.

## Budget

Target effort: `{{claude_effort}}` from `config/vault.json`. Soft budget ceiling:
`{{claude_budget_usd}}` USD per run — if you judge a batch will materially exceed this,
stop and report rather than continuing silently.
