# TASK: Full-feature validation on the work machine (phases 0–4)

> **Living document** — each phase appends its section as it lands on `feature/secretary-memory`. The owner runs this ONCE, when the whole memory feature is implemented, as the last gate before PR #36 leaves draft. Run on the work machine (live workspace `whitebit`).
> Protocol: `docs/specs/memory-autonomy-protocol.md`. Prior art: `docs/specs/memory-e2e-report.md` (phases 0–2 already validated 2026-07-16 — those checks are NOT repeated here except where later phases could regress them).

## Setup

```
git fetch && git checkout feature/secretary-memory && git pull
make build
./watchtower config set memory.enabled true
./watchtower config set memory.semantic.enabled true      # phase 3 (dark by default)
# phase 4 flag: added when phase 4 lands — see its section
```

The vault at `~/.local/share/watchtower/whitebit/memory/` already contains the phases 0–2 E2E data (447+ entities, ~384+ episodes incl. 8 known duplicate episodes from the killed-run incident, one manually-set watermark) — this is deliberately the starting state: phase 3 must cope with a lived-in vault, not a fresh one.

## Section 0 — regression sweep (phases 0–2, quick)

1. `./watchtower memory status` — sane counts, watermark present, debt reflects days since the E2E.
2. One `consolidate` (the mandatory `--once` flag was dropped — a plain invocation runs one pass) — stats line clean (no unexpected quarantine/malformed spikes), watermark advances.
3. Kill-resilience re-check (the E2E blocker's fix — root cause was window ordering suppressing per-batch watermark advances, fixed by first-ts ordering): note the watermark, start a pass, kill it mid-run (Ctrl-C / kill PID), run `memory status` then another pass — expect: the watermark reflects every batch that committed before the kill (per-batch durable advance), and the re-run duplicates AT MOST the in-flight batch's content, never earlier committed batches. This re-runs the exact incident from the E2E report.

## Section 1 — Phase 3: semantic tier

Enable the tier (`./watchtower config set memory.semantic.enabled true`) and run **two** passes: `./watchtower memory consolidate` (the mandatory `--once` flag was dropped — a plain invocation runs one pass). Each pass' run-done log line ends with `semantic: N deduped, N promoted, N rewritten, N belief-ops, N evicted`, and `pipeline_steps` for the run carries one row per semantic step after the extraction rows, `channel_name` ∈ {`dedupe`, `promote`, `rewrite`, `beliefs`, `evict`} (`status='error'` on an isolated step failure never fails the run). Config caps in play: `memory.semantic.{dedupe_max_merges=20, concept_min_episodes=5, concept_max_create=10, rewrite_max_entities=10, beliefs_max=20, evict_after_days=45, evict_max=50, output_budget=200000}`.

1. **Dedupe** (MEM-07): the 8 known duplicate episodes from the killed-run incident should merge (up to `dedupe_max_merges` per pass). Check the `dedupe` step row and the "N deduped" count; pick a merged pair and confirm `./watchtower memory open <newer-ep-id>` resolves (redirects) to the older winner, the winner's `## Provenance` carries the union of both refs (no ref lost), and `merged from [[…]]` is present. Record before/after episode + tombstone counts (`memory status`).
2. **Concept entities**: recurring extractor hints ("HSM", "phishing", …) promoted after ≥ `concept_min_episodes` (5) distinct-episode recurrences, ≤ `concept_max_create` (10) per pass. Check `./watchtower memory recall HSM` → concept page exists with the episodes back-linked; eyeball 5 for sanity (mechanical promotion only — no hallucinated concepts). Note that promotion progress in `memory_entity_hints` survives `memory reindex` (excluded from MEM-02).
3. **Entity-page rewrites** (hand review, the important part; capped at `rewrite_max_entities`=10 per pass, staggered ~1/entity/7 days so it takes several passes to cover the vault): pick 10 rewritten entities; grade each `## What`/`## Current`/`## Facts` good/usable/garbage; confirm `## Links`/`## Open loops` are untouched and existing owner facts survived; spot-check 3 `Provenance:` markers per page resolve to real messages (MEM-01/MEM-08 — markers not in the input set are dropped, never invented).
4. **Beliefs** (hand review; ≤ `beliefs_max`=20 ops/pass): read the `bel_*` beliefs created (`memory recall`/`memory open`). For 10 random ones: is the statement falsifiable and grounded in the cited `## Evidence`? Birth confidence ≤ 0.6, `## History` line present. Any belief that misreads its evidence = record verbatim (anonymized). Check MEM-06: hand-add a contradicting note to an owner-rank belief via an owner edit, run a pass, verify the belief is `shaken`, never `retired`/flipped (the model op is downgraded by the rank math).
5. **Two-tier map**: `map.md` ≤ ~2 KB (`wc -c map.md`; hard-capped code-side) and reads as "what's going on"; `./watchtower memory index` prints the full `index.md` listing; MCP `memory_map` returns the hot `map.md`. Toggle `memory.semantic.enabled false` and confirm `map.md` is still produced mechanically (fallback) so `memory_map` never loses its target.
6. **Cost / budget**: sum the `output_tokens` of the `rewrite`/`beliefs` `pipeline_steps` rows across a pass and compare to `memory.semantic.output_budget` (200000); extrapolate daily. Verify the budget guard: on a pass whose accumulated output tokens exceed the budget, the later strong-tier AI steps (rewrite/beliefs/strong map) are skipped and logged (no `rewrite`/`beliefs` step rows for that pass), while the mechanical dedupe/promote/evict steps still run.

## Section 2 — Phase 4: surfaces

*(To be written when phase 4 lands: Discuss injection + owner-rank writes round-trip, briefing revision-journal lines, dispute situations via the watchtower detector, reflection over git log. Will include: a staged disagreement — tell the secretary something in Discuss that contradicts an existing belief, verify owner-rank evidence lands and the belief updates; a briefing containing a revision line; one dispute situation appearing in the dashboard inbox with evidence links.)*

## Deliverable

`docs/specs/memory-final-validation-report.md` on this branch: per-section results, hand-review grades with anonymized examples (never raw message text), cost table, and the go/no-go verdict for merging PR #36 to main. Abort criteria from the E2E task still apply (watermark regressions, >20% ref rejection, machine content in owner-edit commits — stop and report).
