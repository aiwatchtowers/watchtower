# Secretary Memory — Slice D: Importance-Ordered Rendering + Owner Override UX — Design Spec

> Date: 2026-07-26. Status: direction CONFIRMED by the owner (2026-07-26). Fourth of four planned slices in the memory-retrieval redesign brainstormed 2026-07-18 (Slice A: importance-score foundation, shipped; Slice B: unified retrieval ranking on the Go side, shipped; Slice C: chat relevant-memory unification, shipped on `feature/memory-phase5`).
> Background: Slice A's design spec named Slice D's full remit as three things: synthetic `process:*`/`approach:*` entities, owner-facing override editing UX, and importance-ordered `index.md`/`map.md` rendering. Of these, `importance_override` (the mechanism) already exists — it shipped as part of Slice A's `memory_nodes.importance_score` work (`ImportanceOverride *float64` on `Node`/`frontmatter`, honored by `computeNodeImportance`) — but the only way to set it today is hand-editing YAML frontmatter in an external editor (Obsidian, or the Desktop Memory tab's existing whole-file raw editor from the `feature/memory-desktop-browser` work, also already merged). Neither `index.md`/`map.md` nor the Desktop Memory tab currently read or display `importance_score`/`importance_override` at all. This slice closes those two gaps. The third piece — synthetic `process:*`/`approach:*` entities — is unscoped from this design entirely (see Non-Goals); it is not yet defined well enough to design and is deferred to a future Slice E.

## Concept

Two independent, already-half-built surfaces get the missing half:

1. **Go rendering** (`internal/memory/worldmap.go`): `map.md`'s top-entity ranking currently uses "links-in count" as a `// cheap importance proxy` (the code comment's own words) predating Slice A. Now that `importance_score` is a persisted, owner-overridable value, `map.md` should rank by it directly. `index.md` keeps its alphabetical People/Channels/Other grouping (a real navigation aid — "find this specific person by eye" — that importance-sorting would break) but annotates each line with its importance weight, so the value is visible without changing how the file is browsed.
2. **Desktop Memory tab** (`WatchtowerDesktop/Sources/.../Memory/*`): the master list gains a Recent/Important sort toggle, and the detail view gains a dedicated "Importance" section — the current merged score, whether a manual override is set, and controls to set or clear one — replacing "open the raw whole-file editor and hand-write `importance_override: 5.0` into YAML" with a first-class field.

Both pieces are read/write surfaces over data that already exists (`memory_nodes.importance_score`, `Node.ImportanceOverride`) — no new column, no new node type, no new AI prompt.

## Design

### 1. `map.md` ranking switches from links-in to `importance_score`

`mapInputs()` (`worldmap.go`) currently builds `entries []mapEntry` (all active entities) and then bulk-fetches `CountMemoryLinksInBulk(entIDs)` to rank them, taking the top `mapTopEntities` (12) by links-in count. This becomes: rank the same `entries` by each entity's `db.MemoryNodeRow.ImportanceScore` (already available on the row from `ListMemoryNodes()`, already the merged override-or-computed value — no new query). Tiebreak unchanged (`id` ascending, deterministic). The `CountMemoryLinksInBulk` call and the `entIDs` slice it needs are deleted from `mapInputs` — this was their only call site, so `db.CountMemoryLinksInBulk` (`internal/db/memory.go`) is deleted too, along with its dedicated unit test, per house style (no dead code left "just in case").

Open episodes and active beliefs inputs to the strong map prompt are unaffected — this only changes which entities are offered as "top entities" context.

### 2. `index.md` gains an importance annotation, keeps its alphabetical order

`renderIndex()`'s `writeMapSection` currently renders each entity line as:

```
- [[id|title]] — what
```

This becomes:

```
- [[id|title]] — what (importance 4.0)
```

`mapEntry` gains an `importance float64` field, populated from `row.ImportanceScore` alongside the existing `title`/`what` population in `renderIndex`'s main loop (no new DB query — `ListMemoryNodes()` already returns it). The `(importance N.N)` suffix is appended after the existing `what` em-dash, formatted with one decimal place (`%.1f`) — omitted entirely when `importance == 0` (the common case for a fresh, un-linked, un-touched, un-overridden node — an unconditional `(importance 0.0)` on every line would be noise, not signal). Sorting within each group (People/Channels/Other) stays alphabetical by title as today — this annotation is informational only, no ordering change.

### 3. Desktop: `importance_score` in the list, with a sort toggle

`MemoryNodeListItem` (`MemoryModels.swift`) gains an `importanceScore: Double` field. `MemoryQueries.fetchNodes` gains a `sort: MemorySort` parameter (`enum MemorySort { case recent, important }`) selecting between the existing `ORDER BY n.indexed_at DESC, n.id` and a new `ORDER BY n.importance_score DESC, n.indexed_at DESC, n.id` (importance primary, recency as tiebreak for equal — including zero — importance, id as the final deterministic tiebreak, mirroring the tiebreak convention Slice C already established for entity/belief ranking).

`MemoryViewModel` gains a `sort: MemorySort = .recent` published property (default unchanged — existing behavior is the default) and a toolbar `Picker`/segmented control in `MemoryView`'s master panel ("Recent" / "Important") that sets it and re-fetches. No persistence across launches needed (matches existing simple, in-memory UI state elsewhere in this view).

### 4. Desktop: an "Importance" section in the detail view

`MemoryNodeDetailView` gains a new section (alongside the existing frontmatter-chips/backlinks/history sections), showing:

- **Current importance:** the row's `importanceScore`, always shown.
- **Manual override:** present or absent, determined by scanning the node's raw file (already loaded for the existing raw-editor path) for an `importance_override:` line within the frontmatter block (via `MemoryMarkdown.splitFrontmatter`, reusing the existing frontmatter/body split rather than a new parse). When present, its numeric value is shown next to a "Clear override" button; when absent, a "Set override" affordance (a numeric field + "Save" button, non-negative validation matching Go's `>= 0` rule) is shown instead.
- No "what the computed value would be without the override" preview — that number isn't persisted anywhere (`memory_nodes.importance_score` **is** the merged value; recomputing the un-overridden value would require re-running `ComputeImportance`'s DB-backed inputs, which is Go-side logic this design does not port to Swift). To see the fallback value, the owner clears the override and waits for the next pipeline run's `Reconcile` to recompute and persist it — the same "snapshot, not live" latency that already applies to every other field this tab lets the owner edit.

### 5. Desktop: targeted override write path

A new `MemoryViewModel` method, e.g. `saveImportanceOverride(nodeID:currentRaw:value:)` where `value == nil` means "clear":

1. Takes the same non-blocking `flock` on `memory.lock` that `saveEdit()` already uses; lock-busy produces the same "memory run in progress" error surfaced inline in the new section (not a modal), leaving the rest of the detail view usable.
2. Splits the raw file via `MemoryMarkdown.splitFrontmatter` into frontmatter text + body.
3. Patches the frontmatter text: a new pure helper (e.g. `MemoryMarkdown.patchImportanceOverride(frontmatter:value:) -> String`) that — via a line-level regex matching the existing `importance_override:` key (mirroring Go's own write format, `%g`-style float) — replaces the line if present and `value != nil`, inserts a new line if absent and `value != nil`, or removes the line if present and `value == nil`. A no-op (absent + `value == nil`) is a plain return, avoiding a spurious write/commit trigger.
4. Reassembles frontmatter + fence + body, atomic-writes the file (same mechanism `saveEdit()` uses), releases the lock, refreshes the detail state from the newly-written raw text (so the section reflects the change immediately, even though `importance_score` itself won't move until the next `Reconcile`).

**Degenerate case:** if `splitFrontmatter` can't find a closing fence (a malformed or non-standard file — the same quarantine-candidate case `Reconcile` already handles on the Go side), the entire Importance section is disabled (fields grayed out, no write attempted) rather than guessing where to insert a line into a file that isn't in the expected shape. This mirrors MEM-02's existing "a file that doesn't parse degrades to unavailable, never silently corrupted" precedent.

## Non-Goals

- Synthetic `process:*`/`approach:*` entities, or any new memory node type — unscoped from this design per the owner's explicit choice; a future Slice E once that concept itself is brainstormed.
- Any new Go/MCP endpoint to preview "computed importance without the override" — not available without porting `ComputeImportance`'s DB-backed inputs to a new read path; out of scope (see §4).
- Persisting the Desktop sort-mode choice across app launches.
- Changing `renderMap`'s open-episodes or active-beliefs inputs, or its `mapByteCap`/`mapTopEntities` constants.
- Changing eviction/retention (`evict.go`'s `RetentionScore`) — untouched; this slice only changes what's *rendered*, not what's *computed* or *retained*.
- A full structured YAML frontmatter parser/serializer in Swift (Approach 3 considered and rejected during brainstorming) — the targeted regex patch (§5) is scoped to the one `importance_override` key, not a general-purpose frontmatter editor.

## Test plan

Go (`internal/memory/worldmap_test.go`):
- `mapInputs` ranks top entities by `importance_score` (not links-in) — a fixture with entities whose links-in order and importance-score order disagree, asserting the importance order wins.
- `renderIndex` emits the `(importance N.N)` suffix for a non-zero-importance entity and omits it entirely for a zero-importance one; alphabetical group ordering is unaffected by importance values (a fixture where the higher-importance entity sorts after the lower-importance one alphabetically, asserting the render keeps alphabetical order).
- `internal/db`: delete `CountMemoryLinksInBulk`'s now-orphaned unit test alongside the function.

Swift (`WatchtowerDesktop/Tests/`):
- `MemoryQueriesTests`: `fetchNodes(sort: .important)` orders by `importance_score DESC` with the documented tiebreaks; `fetchNodes(sort: .recent)` is byte-identical to today's query (regression guard on the default).
- `MemoryMarkdownTests`: `patchImportanceOverride` — insert into frontmatter with no existing key, replace an existing key's value, remove an existing key (value `nil`), no-op when absent and `value == nil`.
- `MemoryViewModelTests`: `saveImportanceOverride` set/clear round-trip against a `TestDatabase` vault fixture; lock-busy path (a held `flock` produces the inline error, no write); malformed-frontmatter fixture disables the section instead of writing.
- A detail-view test (or ViewModel-level equivalent) confirming the section shows the override value when present and the "Set override" affordance when absent, using a seeded fixture file for each case.

## Rollout

Lands on its own branch based on the current `feature/memory-phase5` tip (Slice A/B/C's established practice for this shared, actively-developed base branch), executed task-by-task via subagent-driven-development per the owner's request to run implementation work through subagents (model choice per task).
