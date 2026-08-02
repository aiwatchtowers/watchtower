# Secretary Memory — Importance Score Foundation (Slice A): Design Spec

> Date: 2026-07-18. Status: direction CONFIRMED by the owner (2026-07-18); this is **Slice A of 4** in a larger redesign of memory retrieval (weight × relevance ranking, replacing pure keyword match) brainstormed the same day. Slices B (unified `RetrieveRelevant` retrieval, replacing `memory_recall`'s FTS-only ranking and the ad hoc selection logic in briefing/meeting-prep), C (chat: Swift `relevantMemory` reads the same score), and D (belief-as-decision/approach via synthetic `process:*` entities, owner-facing override UX, importance-ordered `index.md`/`map.md`) are each their own follow-on spec — do not implement them here.
> Background: brainstorm on 2026-07-18 — the owner's framing was that memory today is "size, unfocused"; navigation is hard for both the owner (browsing the vault) and the LLM (`memory_recall` is pure FTS5 keyword rank with one alias-exact-match boost, no weighting by importance, recency, or confidence anywhere in the retrieval-to-LLM path). This slice lays the one primitive every later slice needs: a persisted, queryable per-node importance number.

## Concept

Today "importance" exists exactly once in the codebase, inline inside `internal/memory/evict.go`'s `RetentionScore = recency × importance`, computed live and only ever consumed by eviction. This slice extracts the `importance` half into a standalone, reusable primitive and persists the merged (owner-override-or-computed) result as a new `memory_nodes.importance_score` column, refreshed by the existing `Reconcile`/`Rebuild` index passes. Nothing else changes: no new MCP tool, no retrieval ranking change, no chat/briefing/meeting-prep change, no new node type. This is pure foundation — a later slice is the first thing that actually queries `importance_score` for anything user-visible.

## Design

### 1. Extract `ComputeImportance`

New file `internal/memory/importance.go`:

```go
type ImportanceInputs struct {
    LinksIn         int
    SituationOrigin bool
    OwnerTouched    bool
    Engagement      int
}
func ComputeImportance(in ImportanceInputs) float64
```

Body is exactly today's `RetentionScore` importance arm: `links-in + situation-origin(+1.0) + owner-touch(+2.0) + clamped-net-engagement(±3, ×2.0)`. The four importance constants move into this file with it; the two recency constants stay in `evict.go`. `RetentionScore`'s signature and `RetentionInputs` struct are untouched — its body becomes `recency * ComputeImportance(ImportanceInputs{...})`. This is a pure refactor: `evict_test.go`'s existing `RetentionScore` assertions must pass unchanged, which is the proof nothing shifted.

### 2. Override lives in frontmatter only; the merged value gets a column

Add `ImportanceOverride *float64` to `node.go`'s `frontmatter` struct and `Node`, YAML key `importance_override`, applicable to any node type (no belief-only gate). It is a pointer all the way through — `0` is a legitimate override ("this matters least") and must be distinguishable from "unset," unlike `Confidence`/`Stability`, which collapse to concrete zero values today. Validation: `>= 0` when present (no natural upper bound, unlike `Confidence`'s `[0,1]`).

No SQL column for the override itself — following the `Stability` precedent (used only where the file is already open), not the `Confidence` precedent (indexed because other code filters by it in bulk without opening files). Nothing in this slice queries "all nodes with an override set," so it stays frontmatter-only.

The **merged** value — `override` if present, else `ComputeImportance(...)` — is what future retrieval sorts/filters by, so it gets a real column: `memory_nodes.importance_score REAL NOT NULL DEFAULT 0`. No index in this slice (YAGNI — nothing queries by it yet; add the index in whichever slice B/C introduces the first query).

### 3. Migration `00027_memory_importance_score.sql`

Latest migration on this branch is `00026_situation_feedback_floor.sql` (CLAUDE.md's "latest is 00024" is stale for `feature/memory-phase5`; verified via `ls internal/db/migrations/`). Additive, matching `00026`'s style:

- Up: `ALTER TABLE memory_nodes ADD COLUMN importance_score REAL NOT NULL DEFAULT 0;`
- Down: `ALTER TABLE memory_nodes DROP COLUMN importance_score;`

Mirror into `internal/db/schema.sql`'s `memory_nodes` table; update `TestAllTablesExist` if it enumerates columns; regenerate `TestSchemaGolden` (`go test ./internal/db/ -run TestSchemaGolden -update`).

### 4. Wiring into Reconcile/Rebuild

Computed in `index.go`'s per-node row build (both `Reconcile` and `Rebuild` — same code path), using the same signal calls already proven in `EvictEpisodes`: `database.CountMemoryLinksIn(n.ID)`, the situation-alias check, `v.OwnerEdited(rel)`, `database.LinkedEntityEngagement(n.ID)`. Final value: `n.ImportanceOverride` if non-nil, else `ComputeImportance(...)` — **no recency factor** (recency is eviction-specific staleness, not part of this primitive). `db.MemoryNodeRow`/`UpsertMemoryNode` (`internal/db/memory.go`) gain the `importance_score` column in their select list / upsert clause.

**`EvictEpisodes` keeps computing its own live score and does not read this column back.** The persisted `importance_score` is a periodically-refreshed snapshot for future retrieval; eviction's always-fresh computation is a separate, deliberately independent behavior — this is the one hard constraint of this slice, since collapsing the two would silently change what gets evicted.

### 5. MEM-02 guard test

`TestMemory02_ReindexEquivalence` compares whole `MemoryNodeRow` structs via `assert.Equal`, so adding the field automatically extends the comparison — no code change expected in the test's assertion logic itself. Strengthen the fixture so pass 2 introduces a node linking to an existing one (so `LinksIn`, and therefore `importance_score`, actually differs between fixtures instead of comparing two zeros). Add an inline comment (matching the `memory_provenance` precedent from Phase 5 slice 3) documenting that `importance_score` rides inside MEM-02.

### 6. Error handling — per-file quarantine (owner-confirmed)

If `CountMemoryLinksIn`/`OwnerEdited`/`LinkedEntityEngagement` errors for a given node during `Reconcile`/`Rebuild`: log it, count it, keep that node's previous `importance_score` (don't zero it, don't abort the pass) — consistent with Reconcile's existing "one bad node never bricks the pass" philosophy. This is a deliberate divergence from `EvictEpisodes`, which aborts its whole run on the same error class (safe there since eviction's candidate set is small and bounded). A node with no links/no situation/no owner-touch/non-positive engagement naturally scores `0` via `ComputeImportance` — the existing, already-tested cold-node floor; no special-casing needed for that case.

### 7. Inventory addendum — new contract MEM-16

`docs/inventory/memory.md` currently states retention importance is "recomputed on demand… keeping MEM-02 clean," i.e. never stored. This slice deliberately stores a related-but-distinct (recency-free) importance snapshot, so it needs its own contract entry rather than reading as a silent contradiction later:

> **MEM-16 (importance snapshot vs live retention score):** `memory_nodes.importance_score` is a periodically-refreshed snapshot (via `Reconcile`/`Rebuild`) of `ComputeImportance`'s output-or-owner-override, used by future retrieval ranking. It is distinct from `evict.go`'s `RetentionScore`, which always recomputes importance live per eviction candidate and never reads the persisted column. The two must not be collapsed into one without owner review — they answer different questions ("is this worth surfacing now" vs "is this worth compressing").

## Non-Goals (deferred to later slices)

- Any change to `memory_recall`/`memory_map`/`memory_open` or their ranking (Slice B).
- Any change to `briefing`/`meeting-prep`'s ad hoc memory selection (Slice B).
- Swift `relevantMemory` reading the new column (Slice C).
- Synthetic `process:*`/`approach:*` entities, owner-facing override editing UX, importance-ordered `index.md`/`map.md` rendering (Slice D).
- An index on `importance_score` (add when the first real query needs it).

## Test plan

- New `importance_test.go`: pure-math cases for `ComputeImportance` (zero-signal → 0, each bonus independently, engagement clamp both directions) — retargeted from existing `RetentionScore` cases.
- `evict_test.go`'s existing `RetentionScore` assertions pass unchanged (the byte-identical proof).
- Override-wins test: a node with `importance_override` set and zero organic signals persists exactly the override through Reconcile.
- Computed-path test: known links/situation/owner/engagement fixture → `importance_score` equals `ComputeImportance(...)` with no recency applied.
- Reconcile/Rebuild persistence test + the strengthened `TestMemory02_ReindexEquivalence` fixture above.
- Quarantine-on-error test: a forced signal-lookup error for one node leaves its prior `importance_score` untouched and does not abort the pass.
- `go test ./internal/db/ -run TestSchemaGolden -update` after the schema.sql edit.

## Known risk (not a blocker, flagged for later)

A full `Rebuild`/`watchtower memory reindex` becomes more expensive: every node now runs an `OwnerEdited` git-log walk plus the link/engagement lookups, whereas today `OwnerEdited` only runs over the small, bounded eviction-candidate set. On a large vault this could measurably slow a full reindex. Not a blocker for Slice A (`Reconcile`'s incremental path only touches actually-changed files per cycle); worth profiling before or during Slice B.

## Rollout

This is new work beyond what PR #40 already covers (Phase 5 slices 1–4, currently open against `main`). Land it as its own branch cut from `main` after PR #40 merges, not stacked on the still-open PR — same discipline as how Phase 5 itself was sequenced after PR #36.
