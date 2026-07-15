# Secretary Memory Phase 3 — Semantic Tier: Design Spec

> Date: 2026-07-15. Branch: `feature/memory-phase3` (stacked on `feature/secretary-memory`, PR #36).
> Background: `docs/superpowers/specs/2026-07-15-secretary-memory-design.md` (phases 0–2, implemented), `docs/specs/memory-design-notes.md` (concept), `docs/inventory/memory.md` (MEM-01..05 + known limitations). Status: **draft — to be finalized after the work-machine E2E of phases 0–2** (real extraction quality and volumes feed several knobs here).

## Context

Phases 0–2 built the substrate: a vault of episodes and skeleton entity pages, validated provenance, a watermark that can never pass unconsumed content, and read surfaces. What memory still cannot do is *know* things: entity pages stay mechanical skeletons, nothing synthesizes "what I know about X", nothing holds falsifiable beliefs, nothing forgets. Phase 3 adds the semantic tier — the inert, long-term layer from the design notes — while Phase 4 (surfaces: Discuss injection, briefing revision journal, dispute situations, reflection) stays out of scope.

Review debts explicitly assigned here: duplicate episodes from failed-window re-extraction (needs dedupe), the dead access-stats question (eviction must not build on counters that never increment), the ingest scan floor, and the `Merge` primitive shipping without a caller.

## Goals

1. **Entity-page rewrites** (strong tier): accumulated episode deltas → periodic staggered rewrite of `## What` / `## Current` / `## Facts` with provenance markers preserved; the page becomes a living "what I know about X".
2. **Beliefs**: a fourth node type in active use — falsifiable inferences with confidence, ranked evidence, asymmetric hysteresis, and a `shaken` state; revised only by consolidation, never silently flipped against owner-rank evidence.
3. **Episode dedupe**: retry-duplicated episodes detected and merged (first real consumer of the `Merge` primitive).
4. **Retention & eviction**: cold closed episodes collapse into rollups (`sum_*`) with provenance kept; nothing is ever deleted.
5. **LLM world map**: `map.md` rendered by the strong tier from entity pages (mechanical render stays as fallback).
6. **Housekeeping debts**: ingest floor; access-stats decision (below); output-based budget caps.

## Non-Goals

- Phase 4 surfaces (Discuss injection + owner-rank chat writes, briefing journal lines, dispute situations via the `watchtower` detector, reflection over git log). Belief *revision* happens here; belief *conversation* happens in Phase 4.
- Embeddings. Navigation + FTS remain the only retrieval.
- Prospective-memory node type (still watching open loops on targets).
- Cross-machine vault sync.

## Design

### Beliefs (`beliefs/bel_<ulid>.md`)

Frontmatter additions (schema discipline: unknown keys still rejected, so these become known keys for `type: belief` only):

```yaml
---
id: bel_01K...
type: belief
tier: long
status: active          # active | shaken | retired  (belief-specific statuses)
confidence: 0.7         # 0..1, coarse steps of 0.1
stability: 3            # confirmations count — the hysteresis weight
subject: ent_7f3a       # the entity this belief is about (one primary subject)
---
# Billing migration will slip past August

## Statement
One-paragraph precise claim, falsifiable.

## Evidence
- for: [[ep_...|deploy freeze announced]] (observed, 2026-07-10)
- for: owner said "billing is behind" (owner, 2026-07-12)
- against: [[ep_...|two releases shipped]] (observed, 2026-07-14)

## History
- 2026-07-12 created at 0.6 (run:412)
- 2026-07-14 shaken: contradicting episode (run:498)
```

Rules (contract candidates, see MEM-06/07 below):

- **Evidence ranks**: `owner` > `observed` > `inferred`. Owner rank **decays with age**: weight `1.0` fresh, linear to `0.4` at 180 days (constants in code, not config — tune later). A belief whose supporting evidence includes non-decayed owner rank can be *shaken* by observations but never *flipped* by them — flip requires either fresh owner input (Phase 4) or the owner evidence decaying below threshold.
- **Asymmetric hysteresis**: creating a belief needs modest support (the model proposes, confidence ≤0.6 at birth). Flipping (retire + create the negation) requires evidence preponderance ≥ `stability`-scaled threshold. But a **direct contradiction** (a validated episode whose outcome factually negates the statement) puts the belief into `shaken` immediately, bypassing accumulation — inertia protects against flapping, not against falsification.
- `shaken` is a buffer, not a verdict: consolidation re-evaluates shaken beliefs on each pass over new evidence; exit is confirm (back to active, stability+1), retire, or stay shaken. Phase 4 will surface long-shaken beliefs to the owner; until then they simply read as "uncertain" in the vault.
- Belief mutations are ordinary vault commits — the History section plus git log form the revision journal Phase 4's briefing lines will read.

### Consolidation additions (strong tier, budget-capped)

Two new sub-steps appended to `Pipeline.Run` after extraction, each with its own cap and `pipeline_steps` row:

1. **Page rewrite** (`memory.entity_rewrite`, strong tier, prompts store, language-aware). Trigger per entity: ≥N new episode links since last rewrite (default 5) OR staggered age (each entity at most once per 7 days, spread deterministically by id hash). Input: current page + the new episodes' Story/Outcome sections + channel running_summary one-liner as background. Output: rewritten What/Current/Facts (+Links maintained mechanically, not by the model). Post-validation mirrors MEM-01 discipline: every provenance marker the model emits must already exist in the input set — unknown refs dropped and counted, never invented. Owner-edited lines: the rewrite prompt receives the page as-is (owner edits were committed by MEM-03 before machine writes); the model is instructed to preserve `## Facts` bullets it cannot contradict — and regardless, git history preserves everything (the honest guarantee; do not promise line-level preservation).
2. **Belief pass** (`memory.revise_beliefs`, strong tier). Scope per run: entities touched by this run's rewrites + all `shaken` beliefs (capped). The model receives existing beliefs (statement/confidence/evidence digest) + new episodes and returns per-belief ops: `confirm | weaken | shake | retire | propose-new` with cited evidence refs (validated the MEM-01 way). Hysteresis/rank arithmetic is **code, not model**: the model proposes ops, Go applies them only when the rank/threshold math allows — the model can never flip an owner-rank belief by itself.

**Budget**: caps are measured in **output tokens** (audit consequence: output dominates cost); `memory.rewrite_max_entities_per_run` (default 10) and `memory.beliefs_max_per_run` (default 20). Both steps log per-step token accounting as extraction already does.

### Episode dedupe (uses `Merge`)

After ingest+extraction, a cheap mechanical pass over *active short-tier episodes of the same channel* whose time ranges overlap: candidate pairs scored by title similarity (normalized token overlap — no embeddings) + shared provenance refs. Score above threshold → `Merge(newer, older)` (older id wins; provenance union; Links updated lazily as designed). This specifically targets the documented failed-window-retry duplicates; it is not a semantic dedupe. Guard: never merge across channels or closed episodes.

### Retention & eviction

- **Retention score** (computed in the index, never in files): `recency(last event ts) × importance` where importance = links-in count + situation origin bonus + owner-touch bonus (file ever owner-edited). **Access stats are NOT an input in Phase 3** — the counters are write-dead in production (documented); they join the formula only when Phase 4 gives chat a writable stats path. This resolves the review's "needs human": keep the table, keep the best-effort bump, wire nothing to it yet.
- **Eviction**: closed long-tier episodes below score threshold and older than `memory.evict_after_days` (default 45) collapse into a per-channel-per-month rollup (`sum_*`): one gist line each (title + outcome + provenance refs carried verbatim). The episode file becomes a tombstone `redirect_to` the rollup — resolver and old links keep working; FTS drops the body but the rollup line remains searchable. Cap per run. **Nothing is deleted; provenance never thins** (contract below).
- Entities and beliefs are never evicted in Phase 3 (hundreds of nodes — no pressure).

### LLM world map

`memory.render_map` (strong tier): input = all entity `## What`/`## Current` excerpts + open episodes + active beliefs (statements only); output = a curated `map.md` (~2KB): areas, current state one-liners, notable beliefs with confidence. Mechanical render remains the fallback on failure (map is derived state — MEM-04 untouched). Cap: at most once per run when anything changed.

### Housekeeping

- **Ingest floor**: track the max situation id already finalized; `listIngestSituations` starts terminal-situation scanning from there (open situations still always scanned).
- `--once` flag dropped from `memory consolidate` (dead surface — review F17).
- `ServerOption`/`SeedConfig` simplifications from the review nit list where they fall out naturally; no dedicated refactor pass.

## New behavioral contracts (→ docs/inventory/memory.md)

- **MEM-06 (owner-rank protection)**: a belief supported by non-decayed owner-rank evidence is never retired/flipped by consolidation alone — observations can only shake it. Guard: `TestMemory06_OwnerRankBeliefNeverAutoFlipped`.
- **MEM-07 (eviction preserves provenance)**: evicting an episode into a rollup carries every provenance ref verbatim into the rollup line, and the episode's tombstone redirect resolves to that rollup. Dropping a ref during eviction is a contract violation. Guard: `TestMemory07_EvictionKeepsProvenance`.
- **MEM-08 (model proposes, code disposes)**: belief ops and rewrite provenance markers emitted by the model are applied only after code-side validation (rank/threshold math for beliefs; MEM-01-style ref validation for markers). Guard: `TestMemory08_BeliefOpsGatedByRankMath`.

## Testing

Same discipline as phases 0–2: fake Generator fixtures for every AI step; guard tests per contract; hysteresis/rank arithmetic unit-tested exhaustively in code (it's pure functions); eviction round-trip (evict → resolve old episode id → rollup; reindex equivalence still holds); dedupe never-merge cases (cross-channel, closed, low score); budget caps observed via pipeline_steps.

## Rollout & dependencies

- Implement behind the same `memory.enabled` flag; strong-tier steps additionally gated by `memory.semantic.enabled` (default false) so phases 0–2 can run alone on the work machine first.
- **Finalize-after-E2E knobs**: rewrite trigger N, window for dedupe similarity, eviction threshold — set from real work-machine data before implementation, not guessed.
- Depends on PR #36 landing (after `feature/gmail-source` per the merge gate).

## Estimated size

- Beliefs (type, rank/hysteresis math, revise pass): ~1.5K LOC + tests.
- Page rewrites + LLM map: ~800 LOC + prompts.
- Dedupe + eviction + retention: ~1K LOC.
- Housekeeping: ~200 LOC.
