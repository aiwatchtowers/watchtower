# Secretary Memory — Roadmap

> Single source of truth for the feature's trajectory. Statuses updated as phases land on `feature/secretary-memory` (PR #36, draft until the whole feature ships). Execution protocol: `docs/specs/memory-autonomy-protocol.md` (autonomous; owner touchpoints marked ⚑).
> Last updated: 2026-07-17 (final validation complete — GO, pending owner content hand-review; PR #36 ready to leave draft).

## Phase 0–2 — Substrate: vault, index, consolidation v1, read surfaces — ✅ DONE, live-validated

Markdown vault under go-git (owner-editable, MEM-03), rebuildable SQLite index + FTS (MEM-02), mechanical entity seeding, situations ingest + light-tier episode extraction with write-time provenance validation (MEM-01), debt watermark that never passes unconsumed content (MEM-04, incl. tie-safety and per-batch durable advance), cross-process flock, quarantine for damaged owner edits, MCP `memory_map/open/recall`, CLI. Validated on the work machine 2026-07-16 (`memory-e2e-report.md`): episodes 8/10 good, situations excellent, provenance 3/3, ~27 min/day wall-clock, killed-run watermark bug found and fixed.

## Phase 3 — Semantic tier — ✅ DONE (implemented + reviewed; live validation deferred to the final run)

Beliefs with ranked evidence and asymmetric hysteresis (owner rank decays 180d, model proposes / code disposes — MEM-06/08), strong-tier entity-page rewrites with marker validation, provenance-keyed episode dedupe (with union), concept-entity promotion from recurring hints, episode aging + eviction into rollups with verbatim provenance (MEM-07), two-tier map (2 KB hot `map.md` + full `index.md`), output-token budget, all dark behind `memory.semantic.enabled`. Review panel converged in 2 rounds; merged into the integration branch.

## Phase 4 — Surfaces — ✅ DONE (implemented + reviewed; live validation in the final run)

Spec: `2026-07-16-memory-phase4-surfaces-design.md`. Discuss-chat MEMORY injection + memory tools (Swift), owner-rank write-back from chat turns (`chat:` evidence grammar, code-minted rank only — MEM-09), briefing revision journal, the arguing secretary (dispute_pending flags consumed by the inbox watchtower detector — MEM-05 preserved, MEM-10), weekly reflection over vault history (MEM-11). Four independent flags, all default off. Includes the first Swift work of the feature (add-desktop-feature flow).

Landed 2026-07-16: 10 plan tasks + 16 review fixes; panel converged in 2 rounds + one surgical scope fix (dispute flag gated to owner-rank downgrades). Contracts MEM-09..11 guarded; final-validation Section 2 written. Merged into the integration branch.

## Final validation — ✅ DONE — verdict: GO (one owner item outstanding)

`docs/specs/memory-final-validation-task.md` (living doc, all three sections run). Sections 0–2 run live on the work machine 2026-07-16/17 against the lived-in `whitebit` vault — see `docs/specs/memory-final-validation-report.md`. Section 1 found and fixed three real bugs invisible to mocked-generator unit tests: entity-page rewrite was structurally dead (2/450 entities ever linkable — now 191/450), belief `propose-new` rejected 100% of ops (model never shown a resolvable entity id — now fixed), and `watchtower memory reindex` broke on any live dispute flag (FK violation in `DropMemoryIndex`). All three fixed, tested, and re-verified live (commit `610ea8b`). Section 2 (Phase 4 surfaces) validated live via the Desktop app: Discuss injection + owner-rank write-back happened for real and unprompted-generalized to a second belief; the dispute-dashboard drill and MEM-06 rank-math held under real vault/DB/git conditions (scoped, then fully reverted); the briefing revision journal wove memory context into Team Pulse exactly per the prompt's framing rules. Reflection (2d) wasn't exercised — not this workspace's stagger day. **Verdict: GO**, conditional only on the owner's own content-quality read of the AI-written entity pages/beliefs (mechanically sound, accuracy not independently gradable).

## Ship — ⚑ OWNER

PR #36 is ready to leave draft on the GO verdict above. Enablement decision at merge time: `memory.enabled` at minimum; all four Phase 4 surface flags validated live this session, safe to stage on.

## Phase 5 — Universal substrate — ✅ CONFIRMED by owner (2026-07-16), spec written, own branch

Owner-confirmed scope (see `2026-07-16-memory-phase5-universal-substrate-design.md`): memory becomes the system's semantic bus — 5A universal ingestion (gmail/calendar/jira/all internal dialogs via a provenance-resolver registry; raw and operational layers mirrored, never absorbed), 5B renders over memory (the inversion below), 5C internal entities linked through memory. Implementation in its OWN integration branch `feature/memory-phase5` off main after PR #36 ships. The 5B render steps, one consumer at a time, dark-launched against legacy first:
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
