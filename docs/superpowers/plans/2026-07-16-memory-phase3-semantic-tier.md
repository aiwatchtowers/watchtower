# Secretary Memory Phase 3 — Semantic Tier: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task is sized for one focused agent session; obey the stated dependencies.

**Goal:** Add the semantic tier on top of the phases 0–2 substrate per `docs/superpowers/specs/2026-07-15-memory-phase3-semantic-tier-design.md`: belief nodes with rank/hysteresis math, strong-tier entity-page rewrites, provenance-keyed episode dedupe, retention scoring + eviction into rollups, a two-tier world map (mechanical `index.md` + strong-tier `map.md`), concept-entity promotion from recurring extractor hints, and the housekeeping debts (ingest floor, `--once` removal). New contracts MEM-06/07/08. All strong-tier behavior dark behind `memory.semantic.enabled` (default false).

**Architecture (extends the phases 0–2 pipeline):** `internal/memory.Pipeline.Run` gains sub-steps after extraction. New order per run: owner-edit commit → `Reconcile` → `SeedEntities` → `IngestSituations` (now floored) → `runExtract` (now also persists unresolved entity hints) → **episode dedupe** (mechanical, `Merge`) → **concept-entity promotion** (mechanical, from hint recurrence) → **page rewrite** (strong) → **belief pass** (strong) → **retention + eviction** (mechanical, into rollups) → **render `index.md`** (mechanical, full listing) + **render `map.md`** (strong hot summary, mechanical fallback). Every strong-tier and structural Phase-3 step is gated by `cfg.Memory.Semantic.Enabled`; the mechanical `index.md` render and hint accumulation run whenever `memory.enabled`.

**Tech stack:** unchanged from phases 0–2. Go 1.25, `modernc.org/sqlite` (FTS5), `github.com/go-git/go-git/v5`, `gopkg.in/yaml.v3`, goose migrations, `digest.Generator` (mocked in tests). Strong tier = the **default** model route (Sonnet / `gpt-5.4`): a source tag NOT present in the light-tier switch in `internal/digest/models.go` / `internal/codex/models.go` routes to the strong model automatically — so the three new prompts need NO edit to those switches (verified: `ModelForSource` returns `ModelSonnet` / `ModelDefault` in `default:`).

## Precondition (do not start until it lands)

Per the spec's "Precondition (E2E blocker)": the killed-run watermark-loss fix must be merged on the integration branch with a contract-grade test **before** this plan starts. That fix is the 2026-07-16 first-ts-ordering change already recorded in MEM-04 (`buildWindows` orders by first message ts; `TestMemory04_InterruptedRunKeepsCommittedBatchesBehindWatermark`, `TestBuildWindowsOrdersByFirstTS`). Confirm those guards are green on this branch's base before Task 1. Dedupe (Task 5) mops up any duplicates prior incidents already produced.

## Global Constraints

- Module path `watchtower`, Go 1.25. Before each commit: `gofmt -l`, `go vet ./...`, `go build ./...`, and the affected package tests green; `golangci-lint run` clean before PR; refresh the sentrux baseline only intentionally.
- **Never weaken a `TestMemoryNN_` guard.** MEM-01..05 stay exactly as they read today (including MEM-04's batching + first-ts-ordering paragraphs and MEM-05's inbox isolation). If any Phase-3 change would relax, rename, or split a guard, **stop and ask @Vadym** (per CLAUDE.md). New guards follow the `TestMemoryNN_...` convention.
- **All vault writes flow through the existing commit discipline.** Every machine mutation goes through `Vault.WriteNodes` / `Vault.WriteFile` (one structured `memory(<op>)` commit) after `CommitOwnerEdits` has already committed any dirty worktree (MEM-03 ordering). No step writes files outside the vault helpers. Index mirroring uses `upsertIndexNode` (merge.go) so a later `Reconcile` sees files as unchanged.
- **Model proposes, code disposes (MEM-08) for every AI output.** Belief ops from `memory.revise_beliefs` are applied only when the Go rank/threshold math permits; provenance markers from `memory.entity_rewrite` are validated the MEM-01 way (every ref must already exist in the input set — unknown refs dropped and counted, never invented). No AI output ever directly flips a belief or invents a ref.
- **Strong-tier steps dark by default.** `memory.semantic.enabled` defaults false. Page rewrite, belief pass, concept promotion, dedupe, eviction, and the strong `map.md` render are all no-ops unless it is true, so phases 0–2 keep running alone on the work machine. The mechanical `index.md` render and unresolved-hint accumulation run whenever `memory.enabled`.
- **MEM-05 preserved.** No new writes to inbox/situation tables. The ingest floor and any Phase-3 bookkeeping live in `workspace` scalars or new `memory_*` index tables only — never on `situations`/`inbox_items`/`situation_signals`.
- **Budget by output tokens.** Rewrite and belief steps are count-capped per run (`rewrite_max_entities_per_run`, `beliefs_max_per_run`); each logs a `pipeline_steps` row with token accounting via the existing `usageAccumulator` (output tokens dominate cost — surface them). Eviction/dedupe/promotion are count-capped per run too.
- English docs. Every new AI step gets a fake-`Generator` fixture test; hysteresis/rank arithmetic is pure functions unit-tested exhaustively.

## File Structure

- `internal/db/migrations/00018_memory_semantic.sql` (+ mirror in `internal/db/schema.sql`, golden snapshot, `TestAllTablesExist`) — expand `memory_nodes.status` CHECK to add `shaken`/`retired` (table-recreation dance); new `memory_entity_hints` table; `workspace.memory_last_ingested_situation_id` column.
- `internal/db/memory.go` (+`_test.go`) — hint upsert/count/mark-promoted, ingest-floor get/set, links-in count query, eviction-candidate query, rollup upsert helper; ensure `DropMemoryIndex` behavior for the hint table is deliberate.
- `internal/memory/node.go` (+`node_test.go`) — belief frontmatter keys (`confidence`/`stability`/`subject`) gated to `type: belief`; belief-only statuses `shaken`/`retired`; History-section render helpers.
- `internal/memory/belief.go` (+`belief_test.go`) — pure rank/hysteresis/decay functions (MEM-08 core) and the belief-pass applier.
- `internal/memory/rewrite.go` (+`rewrite_test.go`) — page-rewrite step: prompt build/parse, marker validation (MEM-01 discipline), owner-line preservation, `## Links` maintained mechanically.
- `internal/memory/dedupe.go` (+`dedupe_test.go`) — provenance-keyed episode dedupe over `Merge`.
- `internal/memory/promote.go` (+`promote_test.go`) — concept-entity promotion from hint recurrence (mechanical).
- `internal/memory/evict.go` (+`evict_test.go`) — retention scoring + eviction into per-channel-per-month rollups (MEM-07).
- `internal/memory/worldmap.go` (+`worldmap_test.go`) — split `index.md` (mechanical) and `map.md` (strong) renders; move the current `renderMap` mechanical body into `renderIndex`.
- `internal/memory/pipeline.go` — wire the new sub-steps into `Run`, gated by `cfg.Memory.Semantic.Enabled`; per-step `pipeline_steps` accounting.
- `internal/prompts/store.go`, `internal/prompts/defaults.go` — register `memory.entity_rewrite`, `memory.revise_beliefs`, `memory.render_map` (const + `Defaults` + `AllIDs` + `DefaultVersions` + `Descriptions`).
- `internal/config/config.go` — extend `MemoryConfig` with `Semantic` + the new caps; add `v.SetDefault` entries.
- `internal/mcp/memory.go` — `memory_map` returns the hot `map.md` + counts + pointer (unchanged read target, refreshed doc); optional index counts.
- `cmd/memory.go` (+`_test.go`) — drop `--once`; add `memory index` (or `memory map --full`) to print `index.md`.
- `docs/inventory/memory.md` (+ changelog) — MEM-06/07/08; `CLAUDE.md` feature-note refresh; `docs/app-guide.md` section.

---

## Task 1: Migration — belief statuses, hint table, ingest floor

**Depends on:** nothing. **Blocks:** Tasks 2, 4, 9, 13.

**Files:** new `internal/db/migrations/00018_memory_semantic.sql`; modify `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), the golden snapshot. Follow `.claude/skills/add-migration`.

Three changes:
1. **Expand `memory_nodes.status` CHECK** from `('active','closed','tombstone')` to `('active','closed','tombstone','shaken','retired')` — beliefs use `shaken`/`retired`, and a belief indexed with either must pass the CHECK or `UpsertMemoryNode` fails and `Reconcile` quarantines the file. SQLite has no `ALTER … ADD CONSTRAINT`, so recreate the table (create-new/insert-select/drop/rename, recreate no indexes — `memory_nodes` has none beyond its PK). `memory_aliases.node_id` and `memory_node_stats.node_id` `REFERENCES memory_nodes(id)` **without** `ON DELETE CASCADE`, so wrap the dance in `PRAGMA foreign_keys = OFF;` … `PRAGMA foreign_keys = ON;` (issued outside any transaction) per the skill's gotcha — never `defer_foreign_keys`.
2. **`memory_entity_hints`** — persists the unresolved extractor hints (`entity_hints`) already logged today, for concept promotion:
   ```sql
   CREATE TABLE IF NOT EXISTS memory_entity_hints (
       hint        TEXT NOT NULL,          -- normalized (lowercased, trimmed) hint text
       episode_id  TEXT NOT NULL,          -- the ep_* node that emitted it (distinct-episode counting)
       first_seen  TEXT NOT NULL,
       promoted_to TEXT NOT NULL DEFAULT '', -- ent_* once a concept entity was created; '' until then
       PRIMARY KEY (hint, episode_id)
   );
   ```
   Distinct-episode recurrence = `COUNT(*)` per `hint`. This is runtime accumulation like `memory_node_stats` — **not derivable from files**, so it is excluded from the MEM-02 reindex-equivalence comparison. Decision (recorded): it is **NOT** cleared by `DropMemoryIndex`/`Rebuild` (unlike `memory_node_stats`) so a reindex never resets promotion progress. Note this exclusion in the migration comment and in Task 12's MEM-02 known-limitation touch-up.
3. **`workspace.memory_last_ingested_situation_id INTEGER NOT NULL DEFAULT 0`** — the ingest floor (Task 13). A `workspace` scalar, not a `situations` column, so MEM-05 holds.

Down: recreate `memory_nodes` with the old CHECK (filtering out any `shaken`/`retired` rows in the insert-select, like other CHECK-narrowing Downs); drop `memory_entity_hints`; drop the workspace column (precedent: 00017's Down drops its ALTER-added columns).

- [ ] **Step 1: failing test** — add `"memory_entity_hints"` to `TestAllTablesExist` (`internal/db/db_test.go:106` list); add a column-presence assertion for `workspace.memory_last_ingested_situation_id`; add a CHECK assertion that inserting a `memory_nodes` row with `status='shaken'` now succeeds (it fails pre-migration).
- [ ] **Step 2:** `go test ./internal/db/ -run 'TestAllTablesExist|TestMigration'` → FAIL.
- [ ] **Step 3: implement** the goose Up/Down above.
- [ ] **Step 4:** mirror all three changes into `internal/db/schema.sql`; regenerate `go test ./internal/db/ -run TestSchemaGolden -update`.
- [ ] **Step 5:** `go test ./internal/db/ -run 'TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden|TestMigration_TableRecreationPreservesCascadeChildren'` green; full `go test ./internal/db/` green. Commit `feat(db): memory belief statuses + hint recurrence table + ingest floor`.

## Task 2: Belief node type — `internal/memory/node.go`

**Depends on:** Task 1 (index CHECK must accept the statuses first). **Blocks:** Tasks 7, 8.

Add belief-specific frontmatter keys and statuses to the strict `frontmatter` schema. `validTypes` already includes `belief`; `vaultSubdirs` already includes `beliefs`. Additions:
- New frontmatter fields `confidence *float64` (`yaml:"confidence"`), `stability *int` (`yaml:"stability"`), `subject string` (`yaml:"subject"`). Pointers so absence is distinguishable and so `Render`→`Parse` round-trips (only emitted when present). Extend the `Node` struct with `Confidence float64`, `Stability int`, `Subject string`.
- **Per-type gating (schema discipline):** `confidence`/`stability`/`subject` are known keys **only for `type: belief`** — a non-belief node carrying any of them is a parse error (mirrors the existing `redirect_to` gate at node.go:102). `yaml.KnownFields(true)` accepts them structurally; the type gate is an explicit post-decode check.
- **Belief-only statuses:** allow `shaken`/`retired` only when `type == belief`; every other type stays `active|closed|tombstone` (a non-belief `shaken`/`retired`, or a belief `closed`, is a parse error). Keep `tombstone` valid for beliefs (merge/eviction paths).
- **Render:** emit `confidence`/`stability`/`subject` after `status` for beliefs; keep byte-stable `Parse(Render(n)) == n`.
- **History-section convention:** add a small helper (e.g. `appendHistory(body, line string) string`, sibling of `appendToLinks` in merge.go, or in node.go) that appends a dated bullet under `## History`, creating the section if absent. Belief mutations (Task 8) and eviction never rewrite History — they only append, so `git log` + History form the revision journal Phase 4 reads.

- [ ] **Step 1: failing tests** (`node_test.go`) — belief round-trip with all three keys + `status: shaken`; a belief with `status: closed` rejected; a `type: entity` node carrying `confidence:` rejected (unknown key for that type); a belief without confidence renders/parses cleanly; `appendHistory` creates and appends to `## History`.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/memory/ -run 'Node'` green; commit `feat(memory): belief node type — confidence/stability/subject + shaken/retired statuses`.

## Task 3: Rank / hysteresis arithmetic — pure functions (MEM-08 core)

**Depends on:** nothing (pure math; conceptually pairs with Task 2). **Blocks:** Task 8.

Implement the belief math as pure, side-effect-free functions in `internal/memory/belief.go`, unit-tested exhaustively (the spec: "hysteresis/rank arithmetic unit-tested exhaustively in code"). Constants live in code, not config (spec §Beliefs: "constants in code, not config — tune later").

Signatures (adjust as the applier in Task 8 needs):
```go
type evidenceRank int // rankInferred < rankObserved < rankOwner
func ownerRankWeight(ageDays float64) float64      // 1.0 fresh → linear to 0.4 at 180d, floor 0.4
func evidenceWeight(rank evidenceRank, ageDays float64) float64
type beliefState struct{ Confidence float64; Stability int; Status string; HasFreshOwnerSupport bool }
func applyOp(s beliefState, op beliefOp, ev []evidence) (beliefState, bool) // returns new state + whether the op was allowed
```
Rules to encode (spec §Beliefs "Rules"):
- Ranks `owner > observed > inferred`; owner weight decays linearly `1.0 → 0.4` over 180 days (below-threshold owner evidence stops protecting).
- **Asymmetric hysteresis:** birth confidence ≤ 0.6; flip (retire + propose negation) requires evidence preponderance ≥ a `stability`-scaled threshold; a **direct contradiction** (a validated episode outcome that factually negates the statement — signaled by the model op `shake`) sets `shaken` immediately, bypassing accumulation.
- **Owner-rank protection (MEM-06):** while any supporting evidence carries non-decayed owner weight (age < the 180d threshold), observations can `shake` but never `retire`/flip. `applyOp` returns `false` (op rejected) for a retire/flip against protected owner support — this is the exact seam the guard test drives.
- `shaken` is a buffer: `confirm` → active + stability+1; `retire`; or stay `shaken`. `weaken` lowers confidence by one 0.1 step without changing status.

- [ ] **Step 1: failing tests** (`belief_test.go`) — table-driven `ownerRankWeight` at 0/90/180/365 days; `applyOp` matrix over every op × {protected owner support present / absent, various stability}; assert a retire against non-decayed owner support is rejected; a `shake` always transitions active→shaken; confirm from shaken bumps stability; flip allowed only when preponderance ≥ threshold AND no protected owner support.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement pure functions. **Step 4:** `go test ./internal/memory/ -run 'Belief|OwnerRank'` green; commit `feat(memory): belief rank/hysteresis pure functions (MEM-08 math)`.

## Task 4: Hint-recurrence persistence + concept-entity promotion

**Depends on:** Task 1. **Blocks:** Task 11 (wiring).

Two mechanical pieces; no AI.

**(a) Persist unresolved hints.** In `pipeline.go`'s `buildEpisodeNodes`, the branch that currently only logs an unresolved hint (`p.logf("memory: extract [%s]: entity hint %q unresolved", …)`) also records it. Add `db.UpsertEntityHint(hint, episodeID, firstSeen)` (normalized: `strings.ToLower(strings.TrimSpace(hint))`, skip empty) invoked per unresolved hint, keyed `(hint, episode_id)` so re-extraction of the same episode never double-counts. Resolved hints are unaffected (they already back-link). This runs whenever `memory.enabled` (harmless accumulation), so it must be robust to a nil/absent semantic flag.

**(b) Promote on recurrence.** New `promote.go`: `PromoteConceptEntities(v, db, cfg) (int, error)` — for each hint with distinct-episode `COUNT(*) >= cfg.HintPromoteThreshold` (default 5) and `promoted_to = ''`, **mechanically** create a concept entity (`NewID("entity")`, `type: entity`, `tier: long`, alias = the normalized hint, `## What` empty skeleton via `entitySkeletonBody`), link the contributing episodes' back-links into its `## Links` (via `appendToLinks`), one `memory(promote): N concept entities` commit, mirror to index, and set `promoted_to` on those hint rows. Cap per run (`cfg.PromoteMaxPerRun`, default 10). The model proposes nothing here — creation is purely from recurrence (spec §6: "no hallucinated entities"); the strong-tier page rewrite (Task 7) fills the page later. Gated behind `semantic.enabled` at the call site (Task 11).

Add DB helpers to `internal/db/memory.go`: `UpsertEntityHint`, `RecurringHints(threshold, limit int) ([]HintRecurrence, error)` (hint + episode IDs, only `promoted_to=''`), `MarkHintPromoted(hint, entityID string) error`.

- [ ] **Step 1: failing tests** — `db/memory_test.go`: upsert dedupes `(hint, episode_id)`; `RecurringHints` returns only hints ≥ threshold and unpromoted, with their episode IDs; `MarkHintPromoted` flips the marker. `promote_test.go`: 5 distinct episodes emitting "HSM" → one concept entity with alias `hsm`, 5 back-links, one commit, resolvable via `Resolve`; a 4-episode hint is not promoted; a second run promotes nothing (idempotent via `promoted_to`); cap respected.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/db/ ./internal/memory/ -run 'Hint|Promote'` green; commit `feat(memory): entity-hint recurrence tracking + mechanical concept-entity promotion`.

## Task 5: Provenance-keyed episode dedupe (first `Merge` consumer)

**Depends on:** nothing new (uses existing `Merge`). **Blocks:** Task 11.

New `dedupe.go`: `DedupeEpisodes(v, db, cfg) (merged int, err error)`. Mechanical pass over **active short-tier episodes of the same channel** with overlapping time ranges. **Keyed on provenance-ref overlap, NOT title similarity** (spec §3 + Rollout: the E2E's duplicate pairs had differing titles — a title heuristic is empirically dead; shared `channel_id+ts` refs are the reliable signal). Candidate pair = ≥1 shared `(channel_id, ts)` provenance ref within the same channel and overlapping time range. On a match, `Merge(newerID, olderID)` (older ID wins per merge.go's loser/winner contract — pass loser=newer, winner=older; provenance union and lazy `## Links` repair are already handled by `Merge`). Cap per run (`cfg.DedupeMaxPerRun`, default 20). Guards: never merge across channels, never merge a closed/long episode, never merge tombstones (`Merge` already rejects the last).

Provenance refs come from each episode's `## Provenance` section (rendered by `episodeBody`/`situationBody` as `- <channel_id> <ts>` lines) — parse them from the node body, or add a small `parseProvenance(body) []episodeRef` helper (sibling of `Links()`). Same-channel candidacy uses the channel_id in those refs (episodes carry no channel column of their own).

- [ ] **Step 1: failing tests** (`dedupe_test.go`) — two active short episodes sharing a provenance ref in one channel → merged (older wins, newer becomes a tombstone redirecting to older, resolver resolves the newer ID to the older); different channels sharing no ref → not merged; a closed/long episode never merged; two episodes with overlapping time but zero shared refs → not merged (title similarity must NOT trigger it — include a fixture with near-identical titles but disjoint refs asserting no merge); cap respected.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/memory/ -run 'Dedupe'` green; commit `feat(memory): provenance-keyed episode dedupe over Merge`.

## Task 6: Prompts — `entity_rewrite`, `revise_beliefs`, `render_map` (strong tier)

**Depends on:** nothing. **Blocks:** Tasks 7, 8, 10. Follow `.claude/skills/add-ai-prompt`.

Register three new prompt IDs (`internal/prompts/store.go` const + `internal/prompts/defaults.go` `Defaults`/`AllIDs`/`DefaultVersions`/`Descriptions`, each at v1):
- `MemoryEntityRewrite = "memory.entity_rewrite"` — input: current page + new episodes' `## Story`/`## Outcome` + a background one-liner; output JSON: rewritten `what`/`current`/`facts` + the provenance markers it cites. Instruction: cite only refs present in the input set (copy-don't-invent, MEM-01 discipline); preserve `## Facts` bullets it cannot contradict; do not touch `## Links` (maintained mechanically).
- `MemoryReviseBeliefs = "memory.revise_beliefs"` — input: existing beliefs (statement/confidence/evidence digest) + new episodes; output JSON: per-belief ops `confirm|weaken|shake|retire|propose-new` with cited evidence refs. Instruction: propose ops only; the code decides whether they apply.
- `MemoryRenderMap = "memory.render_map"` — input: top entity `## Current` excerpts (by retention score) + open episodes + active beliefs; output: a compact markdown hot summary (5–8 areas, notable beliefs with confidence, a pointer line). Instruction: aim well under 2 KB (the code still hard-truncates — the prompt cannot be trusted to obey a byte budget).

**Tier:** all three are STRONG tier = the default route. Do NOT add them to the light-tier switch in `internal/digest/models.go` / `internal/codex/models.go` (adding them there would wrongly downgrade to Haiku/mini). Add a models test asserting each of the three resolves to the strong model (mirror of the existing light-tier assertion, inverted).

Each default template starts with a `%s` language directive slot (like `defaultMemoryExtractEpisodes`) filled via `prompts.Directive` from `p.Language`. **Never start the user message with a `--`/`-` line** (the claude-CLI argv gotcha recorded in MEM-04's 2026-07-16 changelog — see `TestBuildExtractPromptsNeverStartWithDash`); reuse that guard shape for the new builders.

- [ ] **Step 1: failing tests** — `internal/digest/models_test.go` + `internal/codex/models_test.go`: the three sources route to the strong model. `internal/prompts`: the three IDs are in `Defaults`/`AllIDs`/`DefaultVersions`/`Descriptions` (whatever existing completeness test covers this).
- [ ] **Step 2:** run → FAIL. **Step 3:** register. **Step 4:** `go test ./internal/prompts/ ./internal/digest/ ./internal/codex/` green; commit `feat(prompts): memory.entity_rewrite/revise_beliefs/render_map (strong tier)`.

## Task 7: Page-rewrite step — `internal/memory/rewrite.go`

**Depends on:** Tasks 2, 6. **Blocks:** Task 11.

`RewriteEntityPages(ctx, p, cfg) (rewritten int, usage, err)` (method on `*Pipeline` or a helper taking the seams). **Trigger** per entity: ≥ `cfg.RewriteTriggerNewLinks` (default 5) new episode links since last rewrite OR staggered age (each entity at most once per 7 days, spread deterministically by id-hash so runs don't all fire together). Track "links since last rewrite" and "last rewrite time" — decision (recorded): derive both from git/index rather than new columns where possible; simplest is a per-entity marker line the render writes, or reuse the index. **Chosen:** compute "new links since last rewrite" from the count of `## Links` entries vs a stored count is over-engineering; instead gate purely on staggered age (7-day bucket by id-hash) for v1 and treat the link-count trigger as an OR that fires when the entity's index row shows growth — but since link-growth isn't cheaply tracked, **v1 uses the deterministic 7-day stagger alone**, and records the link-count trigger as a documented follow-up (consistent with the spec's own "Rewrite trigger stays at the draft default N=5 — unvalidatable until back-links exist"). Cap: `cfg.RewriteMaxEntitiesPerRun` (default 10).

**Input** per entity: current page + the new episodes' `## Story`/`## Outcome` (episodes linked from the page) + a background one-liner (leave empty in v1, as extraction does for `RunningSummary`). **Output handling (MEM-08 + MEM-01):** parse the JSON, then validate every provenance marker the model emitted against the input set (a marker not present in the supplied episodes/refs is dropped and counted — never invented; reuse `validateRefs` or a marker-set check). Rewrite only `## What`/`## Current`/`## Facts`; regenerate `## Links` mechanically (do not let the model touch it); preserve `## Open loops` untouched. **Owner-line rule (honest guarantee):** the prompt receives the page as-is (owner edits already committed by MEM-03 before this runs) and is instructed to preserve `## Facts` bullets it cannot contradict; git history preserves everything regardless — do NOT promise line-level preservation in code or docs. Post-validation mirrors MEM-01: unknown refs dropped and counted. One `memory(rewrite): N pages` commit; per-entity failure sets nothing catastrophic — log and continue to the next entity (a rewrite failure leaves the existing page untouched, like a compose failure leaving situations untouched). Language-aware via `p.Language`.

- [ ] **Step 1: failing tests** (fake `Generator`, `rewrite_test.go`) — happy path rewrites What/Current/Facts and leaves Links/Open-loops intact; a marker the model invents (not in the input episodes) is dropped and counted, page still written with the valid markers; a model failure leaves the page byte-identical (no commit for that entity); staggered-age gate: an entity rewritten <7 days ago (per its deterministic bucket) is skipped; cap respected.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/memory/ -run 'Rewrite'` green; commit `feat(memory): strong-tier entity page rewrite with MEM-01 marker validation`.

## Task 8: Belief pass — `internal/memory/belief.go` (applier)

**Depends on:** Tasks 2, 3, 6. **Blocks:** Task 11.

`ReviseBeliefs(ctx, p, cfg) (touched int, usage, err)`. **Scope per run:** entities touched by this run's rewrites + all `shaken` beliefs (capped by `cfg.BeliefsMaxPerRun`, default 20). Build the `memory.revise_beliefs` prompt (existing beliefs' statement/confidence/evidence digest + new episodes), call the strong-tier generator, parse per-belief ops. **Apply through Task 3's pure math (MEM-08):** for each op, validate its cited evidence refs the MEM-01 way, then call `applyOp`; write the belief node only when `applyOp` allows the transition. `propose-new` mints a `bel_*` node (`type: belief`, `tier: long`, `status: active`, birth `confidence ≤ 0.6`, `subject` = the entity) with an `## Evidence` block and a `## History` "created at X (run:N)" line via `appendHistory`. `shake`/`confirm`/`weaken`/`retire` mutate the existing node's frontmatter + append a History line; a `retire` sets `status: retired` (belief-specific). Each mutation is an ordinary vault commit (`memory(beliefs): …`), mirrored to the index. **Owner-rank protection (MEM-06):** a retire/flip against non-decayed owner support is rejected by `applyOp` and the belief is left active (shaken at most) — this is the guarded seam.

- [ ] **Step 1: failing tests** (fake `Generator`, `belief_test.go` applier section) — `propose-new` writes a `bel_*` node with confidence ≤ 0.6, subject set, Evidence + History; a `shake` op moves active→shaken and appends History; a model `retire` op on a belief with fresh owner evidence is **not** applied (stays active/shaken) — the MEM-06 seam; a `retire` on a belief whose owner evidence has decayed below threshold IS applied; evidence refs the model invents are dropped (MEM-01) and an op citing only invented refs is a no-op; cap respected.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/memory/ -run 'Belief'` green; commit `feat(memory): belief revision pass (model proposes, rank math disposes)`.

## Task 9: Retention scoring + eviction into rollups (MEM-07)

**Depends on:** Task 1. **Blocks:** Tasks 10, 11.

New `evict.go`.

**Retention score** (computed at run time from the index — never stored in a file; spec §Retention): `recency(last event ts) × importance`, `importance = links-in count + situation-origin bonus + owner-touch bonus`. Decision (recorded): **no dedicated score column** — compute on demand from index rows + a links-in count query, keeping MEM-02 clean. Inputs:
- links-in count: add `db.CountMemoryLinksIn(id)` (scan node bodies in `memory_fts`/reconstructed, count `[[<id>` occurrences) — or a simpler precomputed pass over all bodies once per run.
- situation-origin bonus: the node has a `situation:<id>` alias.
- owner-touch bonus: the file was ever touched by a `memory(owner-edit)` commit — computed lazily from git log **only for eviction candidates** (bounded set), via a `Vault` helper walking the file's commit history for the owner-edit author/op. **Access stats are NOT an input** (spec: the counters are write-dead in production; keep the table, wire nothing).

**Eviction** (gated behind `semantic.enabled`; cap `cfg.EvictMaxPerRun`, default 20): closed long-tier episodes below a score threshold AND older than `cfg.EvictAfterDays` (default 45) collapse into a **per-channel-per-month rollup** (`sum_*`, `type: rollup`, `tier: long`). Each evicted episode contributes one gist line to the rollup (title + outcome + **provenance refs carried verbatim** — MEM-07). The episode file becomes a **tombstone `redirect_to` the rollup** (reuse the tombstone stub shape from `Merge`), so the resolver and old `[[ep_*]]` links keep working; FTS drops the episode body but the rollup line stays searchable. **Nothing is deleted; provenance never thins.** Rollup id/key: derive a stable per-(channel, YYYY-MM) rollup — add `db.FindRollup(channelID, month)` / create if absent so a second eviction into the same month appends rather than duplicating. Entities and beliefs are never evicted in Phase 3.

- [ ] **Step 1: failing tests** (`evict_test.go`) — a closed long episode older than the window with low score evicts: episode becomes a tombstone redirecting to a `sum_*`, the rollup line carries **every** provenance ref of the episode verbatim (MEM-07 assertion), `Resolve(oldEpisodeID)` returns the rollup, the rollup line is FTS-searchable; a recent/high-score episode is NOT evicted; a second eviction into the same channel-month appends to the existing rollup (no duplicate rollup); an active/short episode is never evicted; cap respected; **eviction reindex round-trip**: after eviction, `Rebuild` produces an equivalent index (MEM-02 still holds with the new tombstones + rollups).
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/memory/ -run 'Evict|Retention'` green; commit `feat(memory): retention scoring + eviction into per-channel-month rollups (MEM-07)`.

## Task 10: Two-tier world map — `index.md` (mechanical) + `map.md` (strong)

**Depends on:** Tasks 6, 9 (retention score for map ordering). **Blocks:** Task 11.

Refactor the current `pipeline.go` `renderMap` into `worldmap.go`:
- **`renderIndex`** (mechanical, always runs when `memory.enabled`): the existing full per-entity listing — counts, People/Channels/Projects groups with `## What` excerpts, recent open episodes — but written to **`index.md`** (new `indexFileName = "index.md"` const) instead of `map.md`. Unbounded size is fine; never injected. `Reconcile` only scans `vaultSubdirs`, so a root `index.md` is naturally ignored by the index (same as `map.md` today) — no reconcile change needed.
- **`renderMap`** (strong tier, `memory.render_map`, gated behind `semantic.enabled`; at most once per run when anything changed): the hot summary written to **`map.md`**, **hard-capped at ~2 KB post-render by a code-side truncation guard** (not a prompt promise — the spec's 56 KB-at-447-entities miss is why). Input = top entity `## Current` excerpts by retention score (Task 9) + open episodes + active beliefs. **Mechanical fallback on AI failure = the previous committed `map.md`** (derived state, MEM-04 untouched: a failed map render never fails the run and leaves the last good map in place). When `semantic.enabled` is false, `map.md` keeps being produced by a **mechanical** hot-summary render (a truncated projection of the index) so MCP `memory_map` always has a `map.md` to read.

- [ ] **Step 1: failing tests** (`worldmap_test.go`) — `renderIndex` writes `index.md` with the full listing and a byte-identical re-render adds no commit; `renderMap` (fake `Generator`) writes `map.md` ≤ 2 KB even when the model returns 10 KB (truncation guard); a model failure leaves the previous `map.md` intact (fallback, no commit churn); with `semantic.enabled` false, `map.md` is still produced mechanically and MCP `memory_map` reads it.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement; update `internal/mcp/memory.go` doc/description to reflect map.md = hot summary + a pointer to `memory_recall`/`memory_open` (read target unchanged: it already reads `map.md`). **Step 4:** `go test ./internal/memory/ ./internal/mcp/ -run 'Map|Index|Memory'` green; commit `feat(memory): two-tier world map — mechanical index.md + strong-tier map.md (2KB cap)`.

## Task 11: Pipeline wiring + config

**Depends on:** Tasks 4, 5, 7, 8, 9, 10. **Blocks:** Task 12.

**Config (`internal/config/config.go`):** extend `MemoryConfig`:
```go
Semantic MemorySemanticConfig `mapstructure:"semantic"` // strong-tier steps gate
// count caps (all per-run):
RewriteMaxEntitiesPerRun int `mapstructure:"rewrite_max_entities_per_run"` // default 10
BeliefsMaxPerRun         int `mapstructure:"beliefs_max_per_run"`          // default 20
EvictAfterDays           int `mapstructure:"evict_after_days"`             // default 45
EvictMaxPerRun           int `mapstructure:"evict_max_per_run"`            // default 20
DedupeMaxPerRun          int `mapstructure:"dedupe_max_per_run"`           // default 20
HintPromoteThreshold     int `mapstructure:"hint_promote_threshold"`       // default 5
PromoteMaxPerRun         int `mapstructure:"promote_max_per_run"`          // default 10
RewriteTriggerNewLinks   int `mapstructure:"rewrite_trigger_new_links"`    // default 5
```
with `type MemorySemanticConfig struct { Enabled bool `mapstructure:"enabled"` }`. Add matching `v.SetDefault("memory.semantic.enabled", false)` and one `SetDefault` per key (in the `memory.*` block at config.go:273–279). **Also register every new key in `knownConfigKeys` (`cmd/config.go:180`)** — the allowlist exists and already carries the phase 0–2 `memory.*` keys (e.g. `memory.enabled` at cmd/config.go:196); `watchtower config set` warns on keys missing from it. Add: `memory.semantic.enabled`, the rewrite/belief caps, and any other new key this task introduces, with a cmd test extension.

**Pipeline (`pipeline.go` `Run`):** insert the new sub-steps after `runExtract` (step 4) and before the map render, each with its own `pipeline_steps` accounting row and each strong/structural one gated `if p.cfg.Memory.Semantic.Enabled` (use `p.cfg.Semantic.Enabled` — `MemoryConfig` is `p.cfg`). Order: dedupe → concept promotion → page rewrite → belief pass → eviction. Then replace the single map render with `renderIndex` (always) + `renderMap` (gated/mechanical-fallback). Fold rewrite/belief `usage` into the existing `usageAccumulator` (`acc.add`) so `completeRun` records tokens; surface output tokens per the budget constraint. Extend `RunStats` with `Deduped`, `Promoted`, `Rewritten`, `BeliefsTouched`, `Evicted` counters and the run-done log line. A strong-step failure never fails the run (window-isolation spirit) and never advances any watermark (compose/card precedent — DASH-02 analogue).

- [ ] **Step 1: failing tests** (`pipeline_test.go`, fake `Generator`) — with `semantic.enabled=false`: dedupe/promotion/rewrite/beliefs/eviction/strong-map are all no-ops (only extract + index.md + mechanical map.md run); with `semantic.enabled=true`: the sub-steps run in order, each emits a `pipeline_steps` row, `RunStats` counters populated; a rewrite/belief AI failure leaves the run `done` and the extraction watermark unchanged (isolation); config defaults present (config test).
- [ ] **Step 2:** run → FAIL. **Step 3:** implement config + wiring. **Step 4:** `go test ./internal/config/ ./internal/memory/` green. Check the daemon coverage floor (70, recently lowered) still satisfied. Commit `feat(memory): wire Phase-3 sub-steps into Run behind memory.semantic.enabled`.

## Task 12: MEM-06/07/08 guards + inventory + validation refinement

**Depends on:** Tasks 3, 8 (MEM-06/08), Task 9 (MEM-07). **Blocks:** nothing.

Add the three guard tests exactly as named in the spec, and record the contracts. Do NOT weaken MEM-01..05.
- **`TestMemory06_OwnerRankBeliefNeverAutoFlipped`** (`belief_test.go`): a belief with non-decayed owner-rank evidence, fed contradicting observations through the belief pass, is at most `shaken`, never `retired`/flipped.
- **`TestMemory07_EvictionKeepsProvenance`** (`evict_test.go`): eviction carries every provenance ref verbatim into the rollup line and the tombstone redirect resolves to that rollup; dropping any ref fails the test.
- **`TestMemory08_BeliefOpsGatedByRankMath`** (`belief_test.go`): a model op that the rank/threshold math disallows is not applied; a rewrite marker not in the input set is dropped — model output reaches the vault only through code-side validation.

Docs:
- [ ] Append **MEM-06/07/08** to `docs/inventory/memory.md` with Status/Observable/Why-locked/Test-guards/Locked-since, plus a changelog entry dated 2026-07-16. Add the `memory_entity_hints` known-limitation note (runtime accumulation, excluded from MEM-02, not wiped on reindex) and the retention "access-stats stay unwired" note to the Known-limitations section. Refresh the "failed-window re-extraction can duplicate episodes" limitation to note dedupe (Task 5) now mops these up.
- [ ] Refresh `CLAUDE.md`'s memory feature note: belief node type, semantic tier behind `memory.semantic.enabled`, two-tier map, eviction/rollups, concept promotion.
- [ ] Refresh `docs/app-guide.md`: `map.md` (hot) vs `index.md` (full), `memory index` CLI, beliefs in the vault.
- [ ] **Final-validation refinement (phases 0–2 Self-Review §1 analogue):** the Self-Review below tightens Section 1 to also cover the strong-tier E2E (enable `memory.semantic.enabled`, run twice, inspect a rewritten page + a belief + a rollup tombstone + a 2 KB `map.md`).
- [ ] Commit `docs(memory): MEM-06/07/08 contracts + Phase-3 guides`.

## Task 13: Housekeeping debts

**Depends on:** Task 1 (ingest floor column). **Blocks:** nothing.

Per the spec's Housekeeping section:
- **Ingest floor:** `listIngestSituations` (ingest.go) currently scans every `open|done|stale|converted` situation every run. Add a floor: read `workspace.memory_last_ingested_situation_id`, scan terminal situations only with `id > floor` (open situations are always scanned regardless), and after a successful ingest commit set the floor to the max **finalized** situation id of this run. Add `db.MemoryIngestFloor()` / `db.SetMemoryIngestFloor(id)` (workspace scalar — MEM-05 preserved). Guard that MEM-05 still holds (no situations/inbox writes).
- **`--once` removed:** `cmd/memory.go`'s `memoryConsolidateCmd` currently *requires* `--once` (returns an error without it). Drop the flag entirely (`memoryConsolidateCmd.Flags().Bool("once", …)` at cmd/memory.go:94 and the guard at :323–326) — `consolidate` always runs a single pass (the daemon owns the recurring schedule). Update the command help.
- **`memory index` CLI:** add a subcommand printing `index.md` (the full mechanical listing) — the browsing surface the two-tier split created. (Chosen over `memory map --full` to keep `map` unflagged.)
- `ServerOption`/`SeedConfig` simplifications only where they fall out naturally (review nit list) — no dedicated refactor pass.

- [ ] **Step 1: failing tests** — ingest: a run finalizes situation 42, second run does not re-scan terminal situations ≤ 42 (assert via a query-count seam or that a re-finalize is skipped), open situations still always scanned; `TestMemory05_InboxUntouched` still green. cmd: `memory consolidate` (no `--once`) runs a pass; `--once` is now an unknown flag; `memory index` prints the `index.md` content.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement. **Step 4:** `go test ./internal/memory/ ./cmd/ -run 'Ingest|Memory'` green; commit `feat(memory): ingest floor + drop consolidate --once + memory index CLI`.

## Self-Review

- [ ] **Section 1 (refined):** `gofmt -l . && go vet ./... && go build ./... && go test ./...` green; `golangci-lint run` clean; daemon coverage floor (70) satisfied; sentrux baseline unchanged or refreshed intentionally.
- [ ] Guard sweep: MEM-01..05 tests byte-unchanged; MEM-06/07/08 present and green; every `TestMemoryNN_` still in the naming convention.
- [ ] Manual E2E (phases 0–2 path): enable `memory.enabled`, disable `memory.semantic.enabled`, `memory consolidate` twice → only extraction + `index.md` + mechanical `map.md`, no beliefs/rewrites/rollups.
- [ ] Manual E2E (semantic path): enable `memory.semantic.enabled`, `memory consolidate` twice → inspect a rewritten entity page (What/Current/Facts changed, Links/Open-loops intact), a `bel_*` belief with History, an evicted episode tombstone redirecting to a `sum_*` rollup (open the old `[[ep_*]]` link, it resolves), `map.md` ≤ 2 KB, `index.md` full listing; `memory reindex` → index equivalent (MEM-02); a hand-edit → separate `memory(owner-edit)` commit (MEM-03).
- [ ] Grep check: `grep -rn "inbox_\|situations\b" internal/memory/` shows reads only (MEM-05); no `SetMemoryWatermark`/`inbox_last_processed_ts` writes from the new steps.
- [ ] Run `/local-review` before PR.

## Resolved ambiguities (for reviewer attention)

1. **Migration needs (spec left latitude):** a migration IS required — for (a) the `memory_nodes.status` CHECK expansion (`shaken`/`retired`, table-recreation with `foreign_keys=OFF`), (b) `memory_entity_hints`, (c) the `workspace.memory_last_ingested_situation_id` floor. Retention score is **computed, no column**.
2. **Hint recurrence store:** `memory_entity_hints(hint, episode_id, …)`; distinct-episode count = `COUNT(*)`; runtime state, excluded from MEM-02, **not** wiped by `DropMemoryIndex` (unlike `memory_node_stats`) so reindex never resets promotion progress.
3. **Ingest floor location:** a `workspace` scalar (not a `situations` column) → MEM-05 preserved.
4. **Gating:** ALL new Phase-3 steps (dedupe, promotion, rewrite, beliefs, eviction, strong `map.md`) gate on `memory.semantic.enabled`; only the mechanical `index.md` render and hint accumulation run whenever `memory.enabled`. `map.md` is still produced mechanically when semantic is off so MCP never loses its read target.
5. **Strong-tier routing:** the three new prompts route strong by being ABSENT from the light-tier switch (default = Sonnet/`gpt-5.4`); a models test asserts this. No switch edit.
6. **`knownConfigKeys`:** the allowlist EXISTS at cmd/config.go:180 (the draft initially missed it); every new memory.semantic.* / cap key must be added there, mirroring the phase 0-2 keys.
7. **Rewrite trigger:** v1 uses the deterministic 7-day id-hash stagger alone (link-count trigger deferred — back-links barely exist until vocabulary broadening lands, per the spec's own N=5 caveat).
8. **Dedupe key:** provenance-ref overlap within one channel + overlapping time range; title similarity explicitly NOT a trigger (E2E-proven dead) — a test asserts near-identical titles with disjoint refs do NOT merge.
9. **Owner-touch bonus:** computed lazily from git log for eviction candidates only (bounded), not a stored flag; access stats stay unwired (spec).
