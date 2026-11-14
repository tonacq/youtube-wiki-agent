# Vault Operating Instructions (CLAUDE.md)

This file governs how Claude Code behaves when invoked headlessly inside this vault by
`agent/scripts/run-claude-synthesis.ps1`. It is vault-local so each vault can carry its own
scope and rules without touching shared agent code.

**Purpose.** The reader will not watch the sources and may not read the wiki. The wiki is the
evidence layer; a short weekly briefing is the product. Spend effort where the reader's needs
(`config/needs.md`) are best served, and keep every claim traceable to its source.

## Your job in this vault

1. Read the prompt file passed to you (`config/prompts/<batch>.md`) and, if it exists,
   `config/needs.md`. The prompt lists which source pages under `wiki/sources/` are pending
   this run.
2. Assign each pending source a tier (see "Triage").
3. Write the tier outcome (see "Outputs per tier").
4. Do not modify `working/manifest.csv` directly. Write results to
   `working/temp/synthesis-result.json` and let `run-qa.ps1` reconcile the manifest
   deterministically. This is a hard rule: it is what makes interrupted-run recovery safe.
   Every source you triaged, at any tier, goes in `processed`.
5. Do not invent facts, steps, values, timestamps or links. If a source does not support a
   claim, leave it out or mark it uncertain.
6. If a source page's transcript does not match its own video_id or title, do not process it.
   List it in `not_processed` with the reason.
7. Stay inside this vault. Never read or write another vault's `wiki/`, `working/` or
   `config/`, and never modify anything under `agent/`.

## Triage

This file decides what to do with a tier, never what is important. Importance comes only from
`config/needs.md`.

- **If `config/needs.md` is missing, empty, or still holds only its template placeholders:**
  do not triage. Treat every source as Tier A, and put one line at the top of the batch digest
  saying no needs file was found.
- **Otherwise:** assign each source a tier using the criteria in `config/needs.md`, including
  its instruction for sources where you are unsure. If it gives none, treat an unsure source as
  Tier A.

The tiers:
- **Tier A:** gets or improves a full page.
- **Tier B:** gets a short digest entry only.
- **Tier C:** gets one logged line only.

Update an existing page in preference to creating a near-duplicate.

Size rule: if the page you would update is larger than the limit in `config/needs.md` (about
20 KB if none is given), do not rewrite it. Put the new detail on a separate page that links to
it, or in the digest entry.

## Outputs per tier

- **Every tier:** one entry in `wiki/digest/<batch>.md` with: the source wikilink, the tier,
  one sentence stating the lesson, one sentence on why it matters to the reader, the action to
  take (or "none"), and a confidence note when the source is a single informal opinion.
  Tier C needs only the source link, the tier and a few words saying why.
- **Tier A only:** a full page under `wiki/concepts/`, `wiki/tools/` or `wiki/workflows/`,
  or an update to an existing one. Keep it as short as the knowledge allows. Prefer the
  title a reader would search for.
  - Instructional sources become numbered steps with the exact commands, settings, values,
    prerequisites, warnings and a verification step, only where the source gives them.
  - Conceptual sources capture the argument, evidence, caveats and disagreement between
    sources. Preserve disagreement rather than forcing consensus.
- **Provenance on every page and entry:** an Obsidian wikilink to each supporting source
  page, `[[source-page-filename|Human-readable source title]]`. Pages end with `## References`.
  Add a link from each source page back to the pages it supports. Do not invent link targets.
- Do not append to `wiki/synthesis/synthesis_register.md` and do not read it. The batch digest
  file replaces it.

## Scheduled lint-review runs

When invoked with a `lint-review` job (see `agent/scheduling/schedule.csv`), you are in
**report-only mode**:
- Analyze the vault for stale pages, orphaned source pages, missing references or reciprocal
  links, broken internal links, duplicate pages, and digest entries with no source link.
- Write findings to `reports/lint_report_<date>.md`.
- Make no other changes. Do not edit any other file in this run.
