# TASK: Real-data audit for secretary memory

> Branch: `feature/secretary-memory`. Run on the **work machine** (live DB, ~2GB over ~2 months).
> Context: `docs/specs/memory-design-notes.md` — brainstorm notes on memory (layers, tiers, node types, consolidation, economics). Read it first.

## Goal

Validate, on live data, the key bet of consolidation economics — **"don't pay twice"**: existing pipelines (digests, situations, running summaries, catchup) already distill the raw stream, so memory consolidation can feed on their output as episode seeds and dive into raw only selectively. If the bet fails, the funnel design must be revisited (the cheap tier would read raw itself, economics ×N).

## What to measure (read-only, SELECTs against the DB only)

1. **Volume and rate**
   - Actual text share: total bytes / estimated tokens in `messages.text` (and gmail tables if present) over the last 30 days, per day. Compare against the doc's estimate (3–6M tokens/day) — it's rough, a real number is needed.
   - Share of the DB taken by indexes/metadata vs text.

2. **Distillate coverage**
   - What share of the daily message stream is "covered" by any existing output: landed in digest topics / situations / running-summary windows / catchup themes. Assess per channel: where coverage is dense, where the gaps are (muted channels? DMs? threads?).
   - Total daily distillate volume in tokens (digests + situation cards + summaries per day) — this is the strong tier's input; compare against the 100–300K/day estimate.

3. **Fitness as episode seeds**
   - Manually review 10–15 random digest topics / situations across different days and answer: can an episode per our schema (time frame, participants, outcome, links to raw) be reconstructed from them? What is systematically missing (prime suspects: outcome/resolution and precise message links).
   - Does the output carry stable references to source messages (channel_id + ts) usable as provenance?

4. **Entities**
   - Estimate the entity vocabulary: how many unique people/channels/Jira projects are actually active over a month (candidates for the first wave of `ent_*` nodes). This sizes the long-term tier and staggered rewrites.

## Deliverable

`docs/specs/memory-data-audit.md` in this branch: numbers for items 1–4, a verdict on the "don't pay twice" bet (confirmed / partially confirmed + what to add / refuted), and consequences for the MVP slice in the design notes.

## Constraints

- Change nothing in the work machine's DB or config — read only.
- Do not copy raw message text into the report (work data) — aggregates, numbers, and anonymized observations only.
