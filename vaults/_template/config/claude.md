# Vault Operating Instructions (CLAUDE.md)

This file governs how Claude Code behaves when invoked headlessly inside this vault by
`agent/scripts/run-claude-synthesis.ps1`. It is vault-local so each vault can carry its own
scope and rules without touching shared agent code.

**Purpose.** This vault is a learning hub. The reader uses it to learn, remember and create,
and a short weekly briefing sits on top of it. The reader will not watch every source, so every
source must leave something worth knowing, written so the reader can think with it. Keep every
claim traceable to its source. `config/needs.md` says what this reader cares about.

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
   List it in `not_processed` with the reason. Exception: a short post whose title is only a
   caption, promotion or hashtag text (for example "Check out <tool> ...") does not describe
   the video, so a mismatch with that title is expected. Judge such a source by its transcript
   alone and process it normally. Treat a mismatch as real only when the transcript is clearly
   from a different video, such as a different speaker or an unrelated recording.
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

The tiers describe depth, not whether a source is kept:
- **Tier A:** gets or improves a full page. Use it when the source has enough substance for a
  page: a method with steps, a tool setup, an argument with evidence, a case study. A short
  clip whose whole content fits one entry is Tier B, however good it is.
- **Tier B:** gets a distilled digest entry. This is the default and a real note, not a discard.
- **Tier C:** gets one logged line only. Use it only if `config/needs.md` contains the line
  `Purpose: briefing filter`. Without that line, Tier C is not available: a promotional post,
  a skit or a source with nothing to learn still gets a short Tier B entry that says so.

Update an existing page in preference to creating a near-duplicate.

Size rule: if the page you would update is larger than the limit in `config/needs.md` (about
20 KB if none is given), do not rewrite it. Put the new detail on a separate page that links to
it, or in the digest entry.

## Outputs per tier

- **Every tier:** one entry in `wiki/digest/<batch>.md` with: the source wikilink, the tier,
  and these lines:
  - **Key statement:** the main point in one sentence of about 30 words at most, in your own
    words and not the speaker's phrasing. Include a philosophical or mindset point when that is
    the real content.
  - **What it adds:** how it relates to at most two pages already in the wiki: confirms,
    contradicts, extends, or is new, each with a link. If it contradicts a page, say so here and
    record the disagreement on that page (see Tier A).
  - **Resources named:** any tools, people, sites, books, links or figures the source names,
    with the URL when the source gives one. Omit the line if there are none.
  - **Why it matters:** one sentence tied to the reader's needs.
  - **Action:** what to try, or "none".
  - **Confidence:** a note when the source is a single informal opinion or its figures are
    unsupported.
  A Tier B entry is no more than about 100 words in total, not counting the resources list. Put
  detail, steps and prompts on a full page (Tier A) or leave them in the source page; never copy
  them into the digest.
  Link budget: at most five wikilinks in one entry, the source page included. Link a page only
  when the relationship is meaningful. Do not link a tool, sponsor or person just because the
  source mentions it in passing.
  Tier C (only where allowed above) needs only the source link, the tier and a few words saying
  why.
- **Tier A only:** a full page under `wiki/concepts/`, `wiki/tools/` or `wiki/workflows/`,
  or an update to an existing one. Keep it as short as the knowledge allows. Prefer the
  title a reader would search for.
  - Instructional sources become numbered steps with the exact commands, settings, values,
    prerequisites, warnings and a verification step, only where the source gives them.
  - Conceptual sources capture the argument, evidence, caveats and disagreement between
    sources. Preserve disagreement rather than forcing consensus.
  - A new concept page that states a claim is titled as that claim, for example "Check an AI
    answer against a second source before using it". A page about a thing is titled with the
    thing's name.
  - Every concept page you write or update ends with the line
    `My thinking: [[my-thinking-<page-filename>]]`. A script creates that page; you never write
    to it.
- **Provenance on every page and entry:** an Obsidian wikilink to each supporting source
  page, `[[source-page-filename|Human-readable source title]]`. Pages end with `## References`.
  Add a link from each source page back to the pages it supports. Do not invent link targets.
- Never create, edit or delete anything under `wiki/my-thinking/`. Those pages belong to the
  reader; a script creates the empty ones.
- Do not append to `wiki/synthesis/synthesis_register.md` and do not read it. The batch digest
  file replaces it.

## Scheduled lint-review runs

When invoked with a `lint-review` job (see `agent/scheduling/schedule.csv`), you are in
**report-only mode**:
- Analyze the vault for stale pages, orphaned source pages, missing references or reciprocal
  links, broken internal links, duplicate pages, and digest entries with no source link.
- Write findings to `reports/lint_report_<date>.md`.
- Make no other changes. Do not edit any other file in this run.
