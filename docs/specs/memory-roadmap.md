# Secretary Memory — Roadmap

> Single source of truth for the feature's trajectory. Statuses updated as phases land on `feature/secretary-memory` (PR #36, draft until the whole feature ships). Execution protocol: `docs/specs/memory-autonomy-protocol.md` (autonomous; owner touchpoints marked ⚑).
> Last updated: 2026-07-16.

## Phase 0–2 — Substrate: vault, index, consolidation v1, read surfaces — ✅ DONE, live-validated

Markdown vault under go-git (owner-editable, MEM-03), rebuildable SQLite index + FTS (MEM-02), mechanical entity seeding, situations ingest + light-tier episode extraction with write-time provenance validation (MEM-01), debt watermark that never passes unconsumed content (MEM-04, incl. tie-safety and per-batch durable advance), cross-process flock, quarantine for damaged owner edits, MCP `memory_map/open/recall`, CLI. Validated on the work machine 2026-07-16 (`memory-e2e-report.md`): episodes 8/10 good, situations excellent, provenance 3/3, ~27 min/day wall-clock, killed-run watermark bug found and fixed.

## Phase 3 — Semantic tier — ✅ DONE (implemented + reviewed; live validation deferred to the final run)

Beliefs with ranked evidence and asymmetric hysteresis (owner rank decays 180d, model proposes / code disposes — MEM-06/08), strong-tier entity-page rewrites with marker validation, provenance-keyed episode dedupe (with union), concept-entity promotion from recurring hints, episode aging + eviction into rollups with verbatim provenance (MEM-07), two-tier map (2 KB hot `map.md` + full `index.md`), output-token budget, all dark behind `memory.semantic.enabled`. Review panel converged in 2 rounds; merged into the integration branch.

## Phase 4 — Surfaces — 🔄 IN FLIGHT (spec done, plan being drafted)

Spec: `2026-07-16-memory-phase4-surfaces-design.md`. Discuss-chat MEMORY injection + memory tools (Swift), owner-rank write-back from chat turns (`chat:` evidence grammar, code-minted rank only — MEM-09), briefing revision journal, the arguing secretary (dispute_pending flags consumed by the inbox watchtower detector — MEM-05 preserved, MEM-10), weekly reflection over vault history (MEM-11). Four independent flags, all default off. Includes the first Swift work of the feature (add-desktop-feature flow).

Remaining steps: plan → implementation waves → review panel to convergence → merge into integration branch → final-validation-task Section 2.

## Final validation — ⚑ OWNER (one run, work machine)

`docs/specs/memory-final-validation-task.md` (living doc; Sections 0–1 concrete, Section 2 lands with Phase 4). One trigger on the work machine validates phases 0–4 together on the lived-in vault: regression sweep incl. kill-resilience, semantic-tier hand review (rewrites/beliefs/map quality), staged-disagreement drill for the surfaces. Deliverable: `memory-final-validation-report.md` with a go/no-go verdict.

## Ship — ⚑ OWNER

PR #36 leaves draft and merges to `main` on a green final-validation verdict. Enablement decision at merge time: which flags default on (`memory.enabled` at minimum; surfaces likely staged).

## Phase 5 — Pipeline convergence — 💡 DIRECTION RECORDED, ⚑ needs owner confirmation before spec

Working decision (journal, 2026-07-16): the digest/decision stack and memory both distill the same raw stream; the target architecture is the inversion — digests, decisions, briefings, people cards become **renders over memory episodes** (validated provenance kills the hallucinated-key_messages class; raw read once; likely net cheaper). Staged, one consumer at a time, dark-launched against legacy first:
1. Channel digests consume episodes as input (raw only for gaps) — compare vs legacy on live data.
2. `people_cards` ← person entity pages.
3. Channel running_summary ← channel page `## Current`.
4. Decisions → structured facet of episode outcomes; legacy table becomes a view.
Each step carries its own inventory-contract update. "Memory on top of digests" was evaluated and rejected on audit data (hallucinated links, no outcomes, coverage holes).

## Phase 6+ — Candidate backlog (unscheduled, from the design notes' open questions)

- "Remember this" chat command → general owner statements as memory (beyond situation-scoped evidence).
- Prospective memory (commitments/open loops) as a first-class type — pending experience with open-loops-on-targets.
- Access-stats-informed retention (needs the writable stats path Phase 4 chat access creates).
- Self-tuning hysteresis from reflection (deliberately deferred: constants stay code until reflection proves itself).
- Vault export/sync story (Obsidian mobile, second machine).
- FTS recall quality (paraphrase misses — embeddings stay off the table until proven necessary).

## Standing constraints

- All docs English; integration branch merges to main only as a whole (owner decision 2026-07-15).
- Inventory contracts never weakened silently; changes ship with extended guards + NEEDS-OWNER-REVIEW journal entries.
- Model economy: Sonnet for shepherds/mechanical agents, Opus for implementation/review lanes, top model for synthesis only.
- Validation consolidated into the single ⚑ final run; risky output ships dark behind flags until then.
