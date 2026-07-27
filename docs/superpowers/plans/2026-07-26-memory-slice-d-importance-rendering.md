# Secretary Memory Slice D: Importance-Ordered Rendering + Owner Override UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `docs/superpowers/specs/2026-07-26-memory-slice-d-importance-rendering-design.md` (the whole thing — it's short) first.
>
> **Owner has requested subagent-driven-development specifically** (not inline execution) — dispatch one fresh subagent per task below, choosing the subagent's model by task nature: Tasks 1–2 and 5 are small, mechanical, well-specified diffs (cheap/fast model is fine); Tasks 3–4 and 6–7 touch more call sites and existing behavior (use a stronger model). Tasks are ordered and annotated with dependencies below so independent tasks can run in parallel.

**Goal:** `map.md` ranks its top entities by the already-persisted `importance_score` instead of a raw links-in proxy; `index.md` annotates each entity line with its importance weight (alphabetical order unchanged); the Desktop Memory tab shows `importance_score`, offers a Recent/Important sort toggle, and lets the owner set or clear a manual `importance_override` through a dedicated field instead of hand-editing YAML.

**Architecture:** Two independent surfaces over data that already exists end-to-end (`memory_nodes.importance_score`, `Node.ImportanceOverride`) — no new column, table, or AI prompt. Go: `internal/memory/worldmap.go`'s `mapEntry` gains an `importance` field read from `db.MemoryNodeRow.ImportanceScore` (already returned by `ListMemoryNodes()`), used for both `map.md`'s ranking and `index.md`'s per-line annotation; `internal/db/memory.go`'s `CountMemoryLinksInBulk` is deleted as dead code once its only call site is gone. Swift: `MemoryNodeListItem`/`MemoryQueries.fetchNodes` gain an `importanceScore` column read and a `sort` parameter; a new pure `MemoryMarkdown.patchImportanceOverride`/`currentImportanceOverride` pair does a targeted (not whole-file) frontmatter edit; `MemoryViewModel.saveImportanceOverride` reuses the existing `memory.lock` flock pattern from `saveEdit()`; `MemoryNodeDetailView` gains an Importance section.

**Tech Stack:** Go 1.25 (`internal/memory`, `internal/db`, `testify`); Swift 5.10 / SwiftUI / GRDB (`WatchtowerDesktop`, XCTest, `TestDatabase.swift` fixtures).

## Global Constraints

- Go: `go test ./...`, `go vet ./...`, `go build ./...` must stay green after every task. Run scoped tests first (`go test ./internal/memory/... -run <Name> -v`, `go test ./internal/db/... -run <Name> -v`), then the full package before committing.
- Swift: `cd WatchtowerDesktop && swift build && swift test` — capture the real exit code (never pipe through `tail` alone; redirect to a log file and check `$?`).
- No new Go/schema/migration, no new AI prompt, no new config flag — every value this slice reads or writes already exists (`memory_nodes.importance_score` since Slice A/MEM-16, `Node.ImportanceOverride`/`importance_override` YAML key since Slice A).
- `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` already has the `memory_nodes.importance_score` column and `insertMemoryNode`'s `importanceScore` parameter (added for Slice C) — no fixture-schema changes needed in this plan.
- Base branch: `feature/memory-phase5` at its current tip (Slice A/B/C's established practice for this shared, actively-developed branch).
- Every commit message ends with the same `Co-Authored-By`/session-link trailer convention already used on this branch's recent commits (see `git log -3` before your first commit for the exact current trailer — it may have changed).

---

## File Structure

| Layer | File | Change |
|---|---|---|
| Go render | `internal/memory/worldmap.go` | `mapEntry` gains `importance float64`; `renderIndex` populates it; `writeMapSection` renders `(importance N.N)`; `mapInputs` ranks by it instead of links-in |
| Go render test | `internal/memory/worldmap_test.go` | Two new tests (index annotation, map ranking) |
| Go db (deleted) | `internal/db/memory.go` | `CountMemoryLinksInBulk` deleted (dead after Task 2) |
| Go db test (deleted) | `internal/db/memory_test.go` | `TestCountMemoryLinksInBulk` deleted alongside it |
| Swift model | `WatchtowerDesktop/Sources/Models/MemoryModels.swift` | `MemoryNodeListItem.importanceScore`; new `MemorySort` enum |
| Swift query | `WatchtowerDesktop/Sources/Database/Queries/MemoryQueries.swift` | `fetchNodes(_:sort:)`, `fetchNode` SELECT gains `importance_score` |
| Swift query test | `WatchtowerDesktop/Tests/MemoryQueriesTests.swift` | Two new tests (default-sort regression, important-sort ordering) |
| Swift util | `WatchtowerDesktop/Sources/Utilities/MemoryMarkdown.swift` | `patchImportanceOverride`, `currentImportanceOverride` |
| Swift util test | `WatchtowerDesktop/Tests/MemoryMarkdownTests.swift` | Seven new tests |
| Swift ViewModel | `WatchtowerDesktop/Sources/ViewModels/MemoryViewModel.swift` | `sort`, `importanceOverrideInput`, `importanceError` published state; `refresh()` takes `sort` into account; new `saveImportanceOverride(value:)`; `MemoryNodeDetail` (defined in this file) gains `importanceOverride`/`canEditImportance` |
| Swift ViewModel test | `WatchtowerDesktop/Tests/MemoryViewModelTests.swift` | Five new tests |
| Swift view | `WatchtowerDesktop/Sources/Views/Memory/MemoryView.swift` | New sort toggle in `listColumn` |
| Swift view | `WatchtowerDesktop/Sources/Views/Memory/MemoryNodeDetailView.swift` | New Importance section |

---

### Task 1: Go — `index.md` importance annotation

**Files:**
- Modify: `internal/memory/worldmap.go:54-56` (`mapEntry` struct), `internal/memory/worldmap.go:84` (`renderIndex`'s entity construction), `internal/memory/worldmap.go:331-344` (`writeMapSection`)
- Test: `internal/memory/worldmap_test.go`

**Interfaces:**
- Consumes: `db.MemoryNodeRow.ImportanceScore` (already exists, already returned by `p.db.ListMemoryNodes()`), `db.UpdateMemoryNodeImportanceScore(id string, score float64) error` (already exists).
- Produces: `mapEntry.importance float64` — Task 2 (`mapInputs`) also populates and reads this field.

- [ ] **Step 1: write the failing test** — add to `internal/memory/worldmap_test.go` (same package, so `mapEntry`'s unexported fields and `renderIndex` are directly reachable):

```go
func TestRenderIndexAnnotatesImportance(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000001", "Zebra", "no override yet"))
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000002", "Anna", "override set"))
	require.NoError(t, d.UpdateMemoryNodeImportanceScore("ent_00000000000000000000000002", 4.0))
	p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)

	require.NoError(t, p.renderIndex(1))

	content, err := os.ReadFile(filepath.Join(v.path, indexFileName))
	require.NoError(t, err)
	s := string(content)
	assert.Contains(t, s, "Anna")
	assert.Contains(t, s, "(importance 4.0)")
	assert.NotContains(t, s, "Zebra — no override yet (importance", "zero importance gets no annotation noise")

	annaIdx := strings.Index(s, "Anna")
	zebraIdx := strings.Index(s, "Zebra")
	require.NotEqual(t, -1, annaIdx)
	require.NotEqual(t, -1, zebraIdx)
	assert.Less(t, annaIdx, zebraIdx, "alphabetical order (Anna before Zebra) unaffected by importance weight")
}
```

- [ ] **Step 2: run it — expect a red assertion failure (not a compile error)**

Run: `go test ./internal/memory/... -run TestRenderIndexAnnotatesImportance -v`
Expected: FAIL — the `assert.Contains(t, s, "(importance 4.0)")` line fails because no annotation is rendered yet. (`d.UpdateMemoryNodeImportanceScore` and `indexEntity` already exist, so this compiles cleanly today — only the assertion is red.)

- [ ] **Step 3: implement** — three edits to `internal/memory/worldmap.go`.

Change the `mapEntry` struct (currently at line 54):

```go
// mapEntry is one entity line in the mechanical index.
type mapEntry struct {
	id, title, what string
	importance      float64
}
```

Change `renderIndex`'s entity-construction line (currently line 84, inside the `case "entity":` branch):

```go
			e := mapEntry{id: row.ID, title: row.Title, what: whatExcerpt(n.Body), importance: row.ImportanceScore}
```

Change `writeMapSection` (currently lines 331-344) to append the annotation, omitted at zero:

```go
func writeMapSection(b *strings.Builder, heading string, entries []mapEntry) {
	fmt.Fprintf(b, "\n## %s\n", heading)
	if len(entries) == 0 {
		b.WriteString("(none)\n")
		return
	}
	for _, e := range entries {
		fmt.Fprintf(b, "- [[%s|%s]]", e.id, linkLabel(e.title))
		if e.what != "" {
			b.WriteString(" — " + e.what)
		}
		if e.importance != 0 {
			fmt.Fprintf(b, " (importance %.1f)", e.importance)
		}
		b.WriteString("\n")
	}
}
```

- [ ] **Step 4: run it — expect green**

Run: `go test ./internal/memory/... -run 'TestRenderIndexAnnotatesImportance|TestRenderIndexMechanical' -v`
Expected: PASS for both (the pre-existing `TestRenderIndexMechanical` has no assertions about the annotation, so it stays green unmodified — it only ever indexes an entity with no importance signal, which now silently renders no suffix).

- [ ] **Step 5: full package sanity + commit**

Run: `go build ./... && go vet ./... && go test ./internal/memory/... -v > /tmp/memory-test.log 2>&1; echo "exit: $?"`
Expected: `exit: 0`, all tests PASS.

```bash
git add internal/memory/worldmap.go internal/memory/worldmap_test.go
git commit -m "feat(memory): index.md annotates entity lines with importance_score (Slice D)"
```

---

### Task 2: Go — `map.md` ranks by `importance_score`, dead-code removal

**Depends on:** Task 1 (`mapEntry.importance` field must exist).

**Files:**
- Modify: `internal/memory/worldmap.go:186-206` (`mapInputs`'s entity loop), `internal/memory/worldmap.go:222-248` (`mapInputs`'s ranking block)
- Delete: `internal/db/memory.go:1183-1224` (`CountMemoryLinksInBulk` and its doc comment)
- Delete: `internal/db/memory_test.go:480-528` (`TestCountMemoryLinksInBulk` and its doc comment)
- Test: `internal/memory/worldmap_test.go`

**Interfaces:**
- Consumes: `mapEntry.importance` (Task 1).
- Produces: nothing new — `mapInputs()`'s public signature (`entities []mapEntry, open []string, beliefs []beliefEntry, err error`) is unchanged.

- [ ] **Step 1: write the failing test** — add to `internal/memory/worldmap_test.go`:

```go
func TestMapInputsRanksEntitiesByImportanceScore(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000001", "Low", "low importance project"))
	writeAndIndex(t, v, d, indexEntity("ent_00000000000000000000000002", "High", "high importance project"))
	require.NoError(t, d.UpdateMemoryNodeImportanceScore("ent_00000000000000000000000001", 1.0))
	require.NoError(t, d.UpdateMemoryNodeImportanceScore("ent_00000000000000000000000002", 5.0))
	p := NewPipeline(d, v, nil, pipelineTestConfig(), t.Logf)

	entities, _, _, err := p.mapInputs()
	require.NoError(t, err)
	require.Len(t, entities, 2)
	assert.Equal(t, "ent_00000000000000000000000002", entities[0].id, "higher importance_score ranks first, not links-in")
	assert.Equal(t, "ent_00000000000000000000000001", entities[1].id)
}
```

- [ ] **Step 2: run it — expect a red assertion failure**

Run: `go test ./internal/memory/... -run TestMapInputsRanksEntitiesByImportanceScore -v`
Expected: FAIL — today's ranking is by links-in count; both entities have zero links-in (no wiki-links between them in this fixture), so the tiebreak (`id` ascending) puts `...0000001` (Low) first, not `...0000002` (High) — the opposite of what the test expects.

- [ ] **Step 3: implement** — two edits to `internal/memory/worldmap.go`'s `mapInputs`.

The entity-loop's `var` block and `case "entity":` branch (currently lines 186-206) drop `entIDs` (no longer needed) and set `importance`:

```go
	var (
		entries  []mapEntry
		openRows []db.MemoryNodeRow
	)
	for _, row := range rows {
		if row.Status == "tombstone" {
			continue
		}
		switch row.Type {
		case "entity":
			if row.Status != "active" {
				continue
			}
			n, rerr := p.vault.ReadNode(row.ID)
			if rerr != nil {
				p.logf("memory: map: read %s: %v", row.ID, rerr)
				continue
			}
			entries = append(entries, mapEntry{
				id:         row.ID,
				title:      row.Title,
				what:       sectionFirstLine(n.Body, "## Current"),
				importance: row.ImportanceScore,
			})
```

(The `case "episode":` and `case "belief":` branches immediately below are unchanged — leave them exactly as they are.)

The ranking block right after the loop (currently lines 222-248, starting at the `// One grouped links-in query...` comment) becomes a direct sort of `entries` by importance, removing the `CountMemoryLinksInBulk` call and the intermediate `ranked` wrapper entirely:

```go

	sort.Slice(entries, func(a, b int) bool {
		if entries[a].importance != entries[b].importance {
			return entries[a].importance > entries[b].importance
		}
		return entries[a].id < entries[b].id
	})
	for i, e := range entries {
		if i >= mapTopEntities {
			break
		}
		entities = append(entities, e)
	}
```

- [ ] **Step 4: run it — expect green**

Run: `go test ./internal/memory/... -run 'TestMapInputsRanksEntitiesByImportanceScore|TestRenderMap' -v`
Expected: PASS for all — the pre-existing `TestRenderMap*` tests don't depend on links-in ranking specifics, only on truncation/fallback/gating behavior, so they're unaffected.

- [ ] **Step 5: delete the now-dead `CountMemoryLinksInBulk`** (its only call site was the block just removed).

In `internal/db/memory.go`, delete the entire function together with its doc comment — everything from the `// CountMemoryLinksInBulk returns...` comment through the function's closing `}` (currently lines 1183-1224):

```go
// CountMemoryLinksInBulk returns the links-in count for every id in one pass:
// how many live (non-tombstone) OTHER nodes carry a [[<id>...]] wiki-link to it.
// It loads each live node's body once with a single query instead of the
// per-id round trip CountMemoryLinksIn does, so a caller scoring many entities
// (the world-map render) avoids an N+1. Self-links and tombstones are excluded,
// matching CountMemoryLinksIn; the substring test mirrors that method's
// instr(body,'[['||id) exactly. Every requested id gets an entry (0 when unseen).
func (db *DB) CountMemoryLinksInBulk(ids []string) (map[string]int, error) {
	counts := make(map[string]int, len(ids))
	for _, id := range ids {
		counts[id] = 0
	}
	if len(ids) == 0 {
		return counts, nil
	}
	rows, err := db.Query(`
		SELECT f.id, f.body FROM memory_fts f
		JOIN memory_nodes m ON m.id = f.id
		WHERE m.status != 'tombstone'`)
	if err != nil {
		return nil, fmt.Errorf("counting links-in (bulk): %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var srcID, body string
		if err := rows.Scan(&srcID, &body); err != nil {
			return nil, fmt.Errorf("scanning links-in (bulk): %w", err)
		}
		for _, id := range ids {
			if id == srcID {
				continue // self-links excluded
			}
			if strings.Contains(body, "[["+id) {
				counts[id]++
			}
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterating links-in (bulk): %w", err)
	}
	return counts, nil
}
```

Leave `CountMemoryLinksIn` (the singular, per-id version just above it) untouched — it's still used by `internal/memory/importance.go` and `internal/memory/evict.go`.

Delete the matching test from `internal/db/memory_test.go` — everything from the `// TestCountMemoryLinksInBulk:...` comment through its closing `}` (currently lines 480-528):

```go
// TestCountMemoryLinksInBulk: the grouped links-in query returns the same counts
// as the per-id CountMemoryLinksIn, in one pass — self-links and tombstones
// excluded, and every requested id present (0 when unlinked).
func TestCountMemoryLinksInBulk(t *testing.T) {
	db := openTestDB(t)

	// a is linked by b and c; b is linked by c; c is linked by nobody. a's own
	// body links to a (self-link, must not count). A tombstone links to a but is
	// excluded.
	if err := db.UpsertMemoryNode(memTestNode("ent_a", nil), "about a, see [[ent_a]] self", nil); err != nil {
		t.Fatalf("UpsertMemoryNode a: %v", err)
	}
	if err := db.UpsertMemoryNode(memTestNode("ent_b", nil), "b references [[ent_a]]", nil); err != nil {
		t.Fatalf("UpsertMemoryNode b: %v", err)
	}
	if err := db.UpsertMemoryNode(memTestNode("ent_c", nil), "c references [[ent_a]] and [[ent_b]]", nil); err != nil {
		t.Fatalf("UpsertMemoryNode c: %v", err)
	}
	tomb := memTestNode("ent_t", func(r *MemoryNodeRow) { r.Status = "tombstone" })
	if err := db.UpsertMemoryNode(tomb, "tombstone points at [[ent_a]]", nil); err != nil {
		t.Fatalf("UpsertMemoryNode tomb: %v", err)
	}

	ids := []string{"ent_a", "ent_b", "ent_c", "ent_missing"}
	got, err := db.CountMemoryLinksInBulk(ids)
	if err != nil {
		t.Fatalf("CountMemoryLinksInBulk: %v", err)
	}

	// Bulk result matches the per-id method for every id.
	for _, id := range ids {
		want, err := db.CountMemoryLinksIn(id)
		if err != nil {
			t.Fatalf("CountMemoryLinksIn(%s): %v", id, err)
		}
		if got[id] != want {
			t.Errorf("bulk[%s] = %d, per-id = %d", id, got[id], want)
		}
	}
	if got["ent_a"] != 2 {
		t.Errorf("ent_a links-in = %d, want 2 (b + c, self and tombstone excluded)", got["ent_a"])
	}
	if got["ent_b"] != 1 {
		t.Errorf("ent_b links-in = %d, want 1 (c)", got["ent_b"])
	}
	if _, ok := got["ent_missing"]; !ok {
		t.Error("an unseen id must still get a (zero) entry")
	}
}
```

- [ ] **Step 6: full build/test sanity + commit**

Run: `go build ./... && go vet ./... > /tmp/vet.log 2>&1; echo "vet exit: $?"; go test ./internal/memory/... ./internal/db/... > /tmp/full-test.log 2>&1; echo "test exit: $?"`
Expected: both exits `0`. `go vet`/`go build` confirm `CountMemoryLinksInBulk` had no other callers (if one existed, this step fails loudly with an undefined-symbol build error — investigate before deleting further).

```bash
git add internal/memory/worldmap.go internal/memory/worldmap_test.go internal/db/memory.go internal/db/memory_test.go
git commit -m "feat(memory): map.md ranks top entities by importance_score, not links-in (Slice D)

Deletes CountMemoryLinksInBulk (internal/db) as dead code — its only call
site was this ranking."
```

---

### Task 3: Swift — `importanceScore` in the list + `MemorySort`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Models/MemoryModels.swift` (`MemoryNodeListItem`, new `MemorySort` enum)
- Modify: `WatchtowerDesktop/Sources/Database/Queries/MemoryQueries.swift` (`fetchNodes`, `fetchNode`)
- Test: `WatchtowerDesktop/Tests/MemoryQueriesTests.swift`

**Interfaces:**
- Produces: `MemorySort` enum (`.recent` / `.important`, `Hashable`) — consumed by Task 4's `MemoryViewModel`/`MemoryView`. `MemoryNodeListItem.importanceScore: Double` — consumed by Task 6/7's detail view.

- [ ] **Step 1: write the failing tests** — add to `WatchtowerDesktop/Tests/MemoryQueriesTests.swift`, in a new `// MARK: - Sort` section after `testFetchTitle`:

```swift
    // MARK: - Sort

    func testFetchNodesSortRecentIsUnchangedDefault() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", indexedAt: "2026-07-17T11:00:00Z", importanceScore: 1.0)
            try TestDatabase.insertMemoryNode(db, id: "ep_B", type: "episode", title: "Incident", indexedAt: "2026-07-17T10:00:00Z", importanceScore: 9.0)
        }
        try dbQueue.read { db in
            let all = try MemoryQueries.fetchNodes(db)
            XCTAssertEqual(all.map(\.id), ["ent_A", "ep_B"], "default sort stays newest-indexed-first, unaffected by importance")
        }
    }

    func testFetchNodesSortImportantOrdersByImportanceScoreDesc() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", indexedAt: "2026-07-17T11:00:00Z", importanceScore: 1.0)
            try TestDatabase.insertMemoryNode(db, id: "ep_B", type: "episode", title: "Incident", indexedAt: "2026-07-17T10:00:00Z", importanceScore: 9.0)
        }
        try dbQueue.read { db in
            let all = try MemoryQueries.fetchNodes(db, sort: .important)
            XCTAssertEqual(all.map(\.id), ["ep_B", "ent_A"], "highest importance_score first, even though it's the older-indexed node")
            XCTAssertEqual(all[0].importanceScore, 9.0)
        }
    }
```

- [ ] **Step 2: run it — expect a build failure**

Run: `cd WatchtowerDesktop && swift test --filter MemoryQueriesTests > /tmp/swift-test.log 2>&1; echo "exit: $?"`
Expected: non-zero exit, build error — `MemorySort` doesn't exist yet, `fetchNodes(db, sort:)` has no such overload, and `MemoryNodeListItem` has no `importanceScore` member.

- [ ] **Step 3: implement** — three edits.

In `MemoryModels.swift`, add the new sort enum near the top (after the file-level doc comment, before `MemoryNodeListItem`):

```swift
/// Master-list ordering for the Memory tab: `.recent` (today's default,
/// newest-indexed first) or `.important` (highest `importance_score` first).
enum MemorySort: Hashable {
    case recent
    case important
}
```

Add `importanceScore` to `MemoryNodeListItem` (both the stored property and its `init(row:)` population):

```swift
struct MemoryNodeListItem: FetchableRecord, Identifiable, Equatable {
    let id: String
    let type: String // entity | episode | rollup | belief
    let tier: String // short | long
    let status: String // active | closed | shaken | retired
    let title: String
    let path: String // vault-relative file path
    let indexedAt: String
    let subject: String // belief subject entity id, "" otherwise
    let confidence: Double // belief confidence 0..1, 0 otherwise
    let importanceScore: Double // merged override-or-computed importance
    let disputeReason: String? // non-nil when a dispute flag is pending

    init(row: Row) {
        id = row["id"]
        type = row["type"] ?? ""
        tier = row["tier"] ?? ""
        status = row["status"] ?? ""
        title = row["title"] ?? ""
        path = row["path"] ?? ""
        indexedAt = row["indexed_at"] ?? ""
        subject = row["subject"] ?? ""
        confidence = row["confidence"] ?? 0
        importanceScore = row["importance_score"] ?? 0
        disputeReason = row["dispute_reason"]
    }

    var isBelief: Bool { type == "belief" }
    var isDisputed: Bool { disputeReason != nil }

    /// Falls back to the id for nodes whose body has no H1 yet.
    var displayTitle: String { title.isEmpty ? id : title }
}
```

In `MemoryQueries.swift`, update `fetchNodes` and `fetchNode` to select `importance_score`, and give `fetchNodes` its `sort` parameter:

```swift
    /// Browser list: all non-tombstone nodes, joined with the dispute side
    /// table, ordered per `sort` (`.recent` — today's default, newest-indexed
    /// first — or `.important` — highest `importance_score` first). Type
    /// filtering happens in-memory (the vault is a few hundred nodes);
    /// redirect tombstones and the mechanical map/index pages never appear
    /// (they are not nodes).
    static func fetchNodes(_ db: Database, sort: MemorySort = .recent) throws -> [MemoryNodeListItem] {
        let orderClause: String
        switch sort {
        case .recent:
            orderClause = "n.indexed_at DESC, n.id"
        case .important:
            orderClause = "n.importance_score DESC, n.indexed_at DESC, n.id"
        }
        return try MemoryNodeListItem.fetchAll(
            db,
            sql: """
                SELECT n.id, n.type, n.tier, n.status, n.title, n.path, n.indexed_at,
                       n.subject, n.confidence, n.importance_score, d.reason AS dispute_reason
                FROM memory_nodes n
                LEFT JOIN memory_dispute_flags d ON d.node_id = n.id
                WHERE n.status != 'tombstone'
                ORDER BY \(orderClause)
                """
        )
    }

    static func fetchNode(_ db: Database, id: String) throws -> MemoryNodeListItem? {
        try MemoryNodeListItem.fetchOne(
            db,
            sql: """
                SELECT n.id, n.type, n.tier, n.status, n.title, n.path, n.indexed_at,
                       n.subject, n.confidence, n.importance_score, d.reason AS dispute_reason
                FROM memory_nodes n
                LEFT JOIN memory_dispute_flags d ON d.node_id = n.id
                WHERE n.id = ?
                """,
            arguments: [id]
        )
    }
```

- [ ] **Step 4: run it — expect green**

Run: `cd WatchtowerDesktop && swift test --filter MemoryQueriesTests > /tmp/swift-test.log 2>&1; echo "exit: $?"`
Expected: `exit: 0`, all `MemoryQueriesTests` PASS, including the pre-existing `testFetchNodesExcludesTombstonesNewestFirst` (unaffected — it doesn't pass `sort:`, so it uses the unchanged default).

- [ ] **Step 5: full build/test sanity + commit**

Run: `cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "build exit: $?"; swift test > /tmp/swift-test-full.log 2>&1; echo "test exit: $?"`
Expected: both exits `0`.

```bash
cd WatchtowerDesktop
git add Sources/Models/MemoryModels.swift Sources/Database/Queries/MemoryQueries.swift Tests/MemoryQueriesTests.swift
git commit -m "feat(memory-tab): importance_score in the node list + MemorySort (Slice D foundation)"
```

---

### Task 4: Swift — sort toggle wiring (ViewModel + View)

**Depends on:** Task 3 (`MemorySort`, `fetchNodes(_:sort:)`).

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/MemoryViewModel.swift` (`refresh()`, new `sort` property)
- Modify: `WatchtowerDesktop/Sources/Views/Memory/MemoryView.swift` (`listColumn`, new `sortBar`)
- Test: `WatchtowerDesktop/Tests/MemoryViewModelTests.swift`

**Interfaces:**
- Consumes: `MemorySort`, `MemoryQueries.fetchNodes(_:sort:)` (Task 3).
- Produces: `MemoryViewModel.sort: MemorySort` (published, default `.recent`).

- [ ] **Step 1: write the failing test** — add to `WatchtowerDesktop/Tests/MemoryViewModelTests.swift`, after `testVaultMissingReportsNotInitialized`:

```swift
    func testRefreshSortTogglesNodeOrder() async throws {
        let vm = try makeVM()
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", indexedAt: "2026-07-17T11:00:00Z", importanceScore: 1.0)
            try TestDatabase.insertMemoryNode(db, id: "ep_B", type: "episode", title: "Incident", indexedAt: "2026-07-17T10:00:00Z", importanceScore: 9.0)
        }
        await vm.refresh()
        XCTAssertEqual(vm.nodes.map(\.id), ["ent_A", "ep_B"], "default .recent sort: newest indexed first")

        vm.sort = .important
        await vm.refresh()
        XCTAssertEqual(vm.nodes.map(\.id), ["ep_B", "ent_A"], ".important sort: highest importance_score first")
    }
```

- [ ] **Step 2: run it — expect a build failure**

Run: `cd WatchtowerDesktop && swift test --filter MemoryViewModelTests > /tmp/swift-test.log 2>&1; echo "exit: $?"`
Expected: non-zero exit, build error — `MemoryViewModel` has no `sort` member yet.

- [ ] **Step 3: implement** — ViewModel then View.

In `MemoryViewModel.swift`, add the published property (near the other simple published properties, e.g. right after `var typeFilter: String?`):

```swift
    var sort: MemorySort = .recent
```

Change `refresh()` to capture and pass it:

```swift
    func refresh() async {
        do {
            let (nodes, counts, beliefs) = try await dbPool.read { [sort] db in
                (try MemoryQueries.fetchNodes(db, sort: sort),
                 try MemoryQueries.fetchTypeCounts(db),
                 try MemoryQueries.fetchBeliefs(db))
            }
            self.nodes = nodes
            self.typeCounts = counts
            self.beliefs = beliefs
            self.error = nil
        } catch {
            self.error = "Failed to load memory index: \(error.localizedDescription)"
        }
        await rebuildBacklinkGraph()
        if let selectedID, detail == nil {
            await select(id: selectedID)
        }
    }
```

In `MemoryView.swift`, add a `sortBar` and splice it into `listColumn` (only shown outside search, since it has no effect on `searchHits`):

```swift
    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            typeFilterBar
            if !vm.isSearching {
                sortBar
            }
            Divider()
            if vm.isSearching {
                searchResultsList
            } else {
                nodeList
            }
        }
    }

    private var sortBar: some View {
        Picker("Sort", selection: Binding(
            get: { vm.sort },
            set: { newValue in
                vm.sort = newValue
                Task { await vm.refresh() }
            }
        )) {
            Text("Recent").tag(MemorySort.recent)
            Text("Important").tag(MemorySort.important)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
```

- [ ] **Step 4: run it — expect green**

Run: `cd WatchtowerDesktop && swift test --filter MemoryViewModelTests > /tmp/swift-test.log 2>&1; echo "exit: $?"`
Expected: `exit: 0`, all pass.

- [ ] **Step 5: full build/test sanity, confirm the app still builds with the new toolbar control, then commit**

Run: `cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "build exit: $?"; swift test > /tmp/swift-test-full.log 2>&1; echo "test exit: $?"`
Expected: both exits `0`.

```bash
cd WatchtowerDesktop
git add Sources/ViewModels/MemoryViewModel.swift Sources/Views/Memory/MemoryView.swift Tests/MemoryViewModelTests.swift
git commit -m "feat(memory-tab): Recent/Important sort toggle in the master list (Slice D)"
```

---

### Task 5: Swift — `MemoryMarkdown` frontmatter helpers for `importance_override`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Utilities/MemoryMarkdown.swift`
- Test: `WatchtowerDesktop/Tests/MemoryMarkdownTests.swift`

**Interfaces:**
- Produces: `MemoryMarkdown.patchImportanceOverride(frontmatter:value:) -> String`, `MemoryMarkdown.currentImportanceOverride(frontmatter:) -> Double?` — both consumed by Task 6.

- [ ] **Step 1: write the failing tests** — add to `WatchtowerDesktop/Tests/MemoryMarkdownTests.swift`, as a new `// MARK: - importance_override` section at the end of the file (before the closing `}`):

```swift
    // MARK: - importance_override

    func testPatchImportanceOverrideInsertsWhenAbsent() {
        let fm = "id: ent_A\ntype: entity"
        let out = MemoryMarkdown.patchImportanceOverride(frontmatter: fm, value: 5.0)
        XCTAssertEqual(out, "id: ent_A\ntype: entity\nimportance_override: 5.0")
    }

    func testPatchImportanceOverrideReplacesExistingValueInPlace() {
        let fm = "id: ent_A\nimportance_override: 2.0\ntype: entity"
        let out = MemoryMarkdown.patchImportanceOverride(frontmatter: fm, value: 7.5)
        XCTAssertEqual(out, "id: ent_A\nimportance_override: 7.5\ntype: entity")
    }

    func testPatchImportanceOverrideRemovesWhenValueIsNil() {
        let fm = "id: ent_A\nimportance_override: 2.0\ntype: entity"
        let out = MemoryMarkdown.patchImportanceOverride(frontmatter: fm, value: nil)
        XCTAssertEqual(out, "id: ent_A\ntype: entity")
    }

    func testPatchImportanceOverrideNoOpWhenAbsentAndNil() {
        let fm = "id: ent_A\ntype: entity"
        let out = MemoryMarkdown.patchImportanceOverride(frontmatter: fm, value: nil)
        XCTAssertEqual(out, fm)
    }

    func testCurrentImportanceOverrideParsesValue() {
        XCTAssertEqual(MemoryMarkdown.currentImportanceOverride(frontmatter: "id: ent_A\nimportance_override: 3.5"), 3.5)
    }

    func testCurrentImportanceOverrideNilWhenAbsent() {
        XCTAssertNil(MemoryMarkdown.currentImportanceOverride(frontmatter: "id: ent_A"))
    }

    func testCurrentImportanceOverrideNilWhenUnparsable() {
        XCTAssertNil(MemoryMarkdown.currentImportanceOverride(frontmatter: "id: ent_A\nimportance_override: not-a-number"))
    }
```

- [ ] **Step 2: run it — expect a build failure**

Run: `cd WatchtowerDesktop && swift test --filter MemoryMarkdownTests > /tmp/swift-test.log 2>&1; echo "exit: $?"`
Expected: non-zero exit — `patchImportanceOverride`/`currentImportanceOverride` don't exist yet.

- [ ] **Step 3: implement** — add both functions to `MemoryMarkdown.swift`, right after `splitFrontmatter`:

```swift
    /// Inserts, replaces (in place), or removes the `importance_override:`
    /// line in a node's frontmatter text (the fence contents `splitFrontmatter`
    /// returns — no fences). `value == nil` removes the line if present and is
    /// a no-op if already absent (never rewrites a file that has nothing to
    /// change). A present value replaces an existing line's value in place, or
    /// appends a new line when none exists yet.
    static func patchImportanceOverride(frontmatter: String, value: Double?) -> String {
        let prefix = "importance_override:"
        var lines = frontmatter.isEmpty ? [] : frontmatter.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { $0.hasPrefix(prefix) }) {
            if let value {
                lines[idx] = "\(prefix) \(value)"
            } else {
                lines.remove(at: idx)
            }
        } else if let value {
            lines.append("\(prefix) \(value)")
        }
        return lines.joined(separator: "\n")
    }

    /// The current `importance_override:` value in a node's frontmatter text,
    /// or nil when unset or unparsable (a hand-edited malformed value degrades
    /// to "no override shown" rather than crashing).
    static func currentImportanceOverride(frontmatter: String) -> Double? {
        let prefix = "importance_override:"
        guard let line = frontmatter.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        let raw = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return Double(raw)
    }
```

- [ ] **Step 4: run it — expect green**

Run: `cd WatchtowerDesktop && swift test --filter MemoryMarkdownTests > /tmp/swift-test.log 2>&1; echo "exit: $?"`
Expected: `exit: 0`, all pass.

- [ ] **Step 5: full build/test sanity + commit**

Run: `cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "build exit: $?"; swift test > /tmp/swift-test-full.log 2>&1; echo "test exit: $?"`
Expected: both exits `0`.

```bash
cd WatchtowerDesktop
git add Sources/Utilities/MemoryMarkdown.swift Tests/MemoryMarkdownTests.swift
git commit -m "feat(memory-tab): patchImportanceOverride/currentImportanceOverride pure helpers (Slice D)"
```

---

### Task 6: Swift — `MemoryViewModel.saveImportanceOverride` + detail-model exposure

**Depends on:** Task 3 (`MemoryNodeListItem.importanceScore`), Task 5 (`patchImportanceOverride`/`currentImportanceOverride`).

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/MemoryViewModel.swift` — `MemoryNodeDetail` (gains `importanceOverride`/`canEditImportance`; this struct is defined in this file, not `MemoryModels.swift`), `select` (reset `importanceError`, seed `importanceOverrideInput`), new `importanceOverrideInput`/`importanceError` published state, new `saveImportanceOverride`
- Test: `WatchtowerDesktop/Tests/MemoryViewModelTests.swift`

**Interfaces:**
- Consumes: `MemoryMarkdown.splitFrontmatter`, `patchImportanceOverride`, `currentImportanceOverride` (Task 5).
- Produces: `MemoryNodeDetail.importanceOverride: Double?`, `MemoryNodeDetail.canEditImportance: Bool`, `MemoryViewModel.importanceOverrideInput: Double`, `MemoryViewModel.importanceError: String?`, `MemoryViewModel.saveImportanceOverride(value: Double?) async` — all consumed by Task 7's view.

- [ ] **Step 1: write the failing tests** — add to `WatchtowerDesktop/Tests/MemoryViewModelTests.swift`, after `testUnreadableFileDisablesEditingAndNeverOverwrites`:

```swift
    func testSaveImportanceOverrideSetsValue() async throws {
        let vm = try makeVM()
        try writeVaultFile("entities/ent_A.md", "---\nid: ent_A\ntype: entity\ntier: long\nstatus: active\n---\n# Alice\n")
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", path: "entities/ent_A.md")
        }
        await vm.refresh()
        await vm.select(id: "ent_A")
        XCTAssertNil(vm.detail?.importanceOverride)

        await vm.saveImportanceOverride(value: 5.0)

        XCTAssertNil(vm.importanceError)
        XCTAssertEqual(vm.detail?.importanceOverride, 5.0)
        let onDisk = try String(contentsOfFile: vaultDir + "/entities/ent_A.md", encoding: .utf8)
        XCTAssertTrue(onDisk.contains("importance_override: 5.0"))
    }

    func testSaveImportanceOverrideClearsValue() async throws {
        let vm = try makeVM()
        try writeVaultFile("entities/ent_A.md", "---\nid: ent_A\ntype: entity\ntier: long\nstatus: active\nimportance_override: 5.0\n---\n# Alice\n")
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", path: "entities/ent_A.md")
        }
        await vm.refresh()
        await vm.select(id: "ent_A")
        XCTAssertEqual(vm.detail?.importanceOverride, 5.0)

        await vm.saveImportanceOverride(value: nil)

        XCTAssertNil(vm.importanceError)
        XCTAssertNil(vm.detail?.importanceOverride)
        let onDisk = try String(contentsOfFile: vaultDir + "/entities/ent_A.md", encoding: .utf8)
        XCTAssertFalse(onDisk.contains("importance_override"))
    }

    func testSaveImportanceOverrideFailsWhileMemoryRunHoldsLock() async throws {
        let vm = try makeVM()
        try writeVaultFile("entities/ent_A.md", "---\nid: ent_A\ntype: entity\ntier: long\nstatus: active\n---\n# Alice\n")
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", path: "entities/ent_A.md")
        }
        await vm.refresh()
        await vm.select(id: "ent_A")

        let lockPath = workspaceDir + "/memory.lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        await vm.saveImportanceOverride(value: 5.0)

        XCTAssertNotNil(vm.importanceError)
        let onDisk = try String(contentsOfFile: vaultDir + "/entities/ent_A.md", encoding: .utf8)
        XCTAssertFalse(onDisk.contains("importance_override"))
    }

    func testSaveImportanceOverrideDisabledOnMalformedFrontmatter() async throws {
        let vm = try makeVM()
        // No closing fence — splitFrontmatter degrades to ("", raw).
        try writeVaultFile("entities/ent_A.md", "---\nid: ent_A\nno closing fence")
        try await pool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_A", type: "entity", title: "Alice", path: "entities/ent_A.md")
        }
        await vm.refresh()
        await vm.select(id: "ent_A")

        XCTAssertFalse(vm.detail?.canEditImportance ?? true)
        await vm.saveImportanceOverride(value: 5.0) // guarded no-op
        let onDisk = try String(contentsOfFile: vaultDir + "/entities/ent_A.md", encoding: .utf8)
        XCTAssertEqual(onDisk, "---\nid: ent_A\nno closing fence", "malformed frontmatter — nothing written")
    }
```

- [ ] **Step 2: run it — expect a build failure**

Run: `cd WatchtowerDesktop && swift test --filter MemoryViewModelTests > /tmp/swift-test.log 2>&1; echo "exit: $?"`
Expected: non-zero exit — `MemoryNodeDetail.importanceOverride`/`canEditImportance` and `MemoryViewModel.saveImportanceOverride`/`importanceError` don't exist yet.

- [ ] **Step 3: implement** — `MemoryNodeDetail` additions, then the rest of `MemoryViewModel`.

In `MemoryViewModel.swift`, add two computed properties to `MemoryNodeDetail` (the struct at the top of this file, right after the file's `// MARK: - Memory browser ViewModel` header comment):

```swift
struct MemoryNodeDetail: Equatable {
    let node: MemoryNodeListItem
    /// Raw vault file contents (frontmatter included) — what the editor edits.
    let raw: String
    /// Non-nil when the vault file could not be read. The body area shows it
    /// and editing is disabled — a failed read must never round-trip into an
    /// empty overwrite of the real file.
    let fileReadError: String?
    let renderedBody: String // body with [[links]] converted to tappable URLs
    let aliases: [String]
    let backlinks: [MemoryBacklink]
    /// Belief subject entity, resolved for the header link ("" / nil otherwise).
    let subjectID: String?
    let subjectTitle: String
    var history: [MemoryCommit] = [] // filled asynchronously

    var isEditable: Bool { fileReadError == nil }

    /// Manual importance override parsed from the raw file's frontmatter, nil
    /// when unset (the merged `node.importanceScore` is the computed value in
    /// that case) or when the frontmatter fence itself can't be parsed.
    var importanceOverride: Double? {
        MemoryMarkdown.currentImportanceOverride(frontmatter: MemoryMarkdown.splitFrontmatter(raw).frontmatter)
    }

    /// The Importance section is only editable when the file has a real
    /// frontmatter fence to patch — same degrade-not-guess rule as `isEditable`.
    var canEditImportance: Bool {
        isEditable && !MemoryMarkdown.splitFrontmatter(raw).frontmatter.isEmpty
    }
}
```

In `MemoryViewModel.swift`, add two published properties near the existing editor state (`isEditing`/`editorText`/`editorError`):

```swift
    // Importance override state (a separate, smaller edit path from the
    // whole-file editor above — see saveImportanceOverride).
    var importanceOverrideInput: Double = 0
    var importanceError: String?
```

In `select(id:)`, reset `importanceError` alongside the existing `editorError` reset near the top of the function:

```swift
    func select(id: String) async {
        selectedID = id
        isEditing = false
        editorError = nil
        importanceError = nil
        historyTask?.cancel()
```

Still inside `select(id:)`, immediately after the line that assigns `detail = MemoryNodeDetail(...)`, seed the input buffer from the freshly-loaded detail:

```swift
            detail = MemoryNodeDetail(
                node: node,
                raw: raw,
                fileReadError: fileReadError,
                renderedBody: rendered,
                aliases: aliases,
                backlinks: backlinkItems,
                subjectID: subjectID,
                subjectTitle: subjectTitle
            )
            importanceOverrideInput = detail?.importanceOverride ?? 0
            error = nil
            loadHistory(for: node)
```

Add the new method at the end of the `// MARK: - Editing (MEM-03 owner edits)` section, after `saveEdit()`:

```swift
    /// Sets or clears the node's manual importance override by patching just
    /// the `importance_override:` frontmatter line — unlike `saveEdit`, this
    /// never opens the whole-file editor sheet. Same MEM-03 contract: the
    /// write is the whole owner edit, the next pipeline run commits it and (on
    /// a clear) recomputes `memory_nodes.importance_score` from scratch —
    /// `detail.node.importanceScore` won't reflect a clear/set until then.
    /// `value == nil` clears the override.
    func saveImportanceOverride(value: Double?) async {
        guard let detail, detail.canEditImportance else { return }
        let (frontmatter, body) = MemoryMarkdown.splitFrontmatter(detail.raw)
        let patched = MemoryMarkdown.patchImportanceOverride(frontmatter: frontmatter, value: value)
        let newRaw = "---\n\(patched)\n---\n\(body)"
        guard newRaw != detail.raw else { return } // no-op: nothing actually changed
        let fileURL = vaultURL.appendingPathComponent(detail.node.path)
        let lockPath = lockURL.path

        let writeError: String? = await Task.detached(priority: .userInitiated) {
            let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else {
                return "Cannot open memory lock: \(String(cString: strerror(errno)))"
            }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                return "A memory run is in progress — try again in a moment."
            }
            defer { flock(fd, LOCK_UN) }
            do {
                try newRaw.write(to: fileURL, atomically: true, encoding: .utf8)
                return nil
            } catch {
                return "Save failed: \(error.localizedDescription)"
            }
        }.value

        if let writeError {
            importanceError = writeError
            return
        }
        importanceError = nil
        await select(id: detail.node.id)
    }
```

- [ ] **Step 4: run it — expect green**

Run: `cd WatchtowerDesktop && swift test --filter MemoryViewModelTests > /tmp/swift-test.log 2>&1; echo "exit: $?"`
Expected: `exit: 0`, all pass, including the pre-existing `testSaveEditWritesFile`/`testSaveEditFailsWhileMemoryRunHoldsLock` (unaffected — different method, different lock-holder path, same lock file).

- [ ] **Step 5: full build/test sanity + commit**

Run: `cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "build exit: $?"; swift test > /tmp/swift-test-full.log 2>&1; echo "test exit: $?"`
Expected: both exits `0`.

```bash
cd WatchtowerDesktop
git add Sources/ViewModels/MemoryViewModel.swift Tests/MemoryViewModelTests.swift
git commit -m "feat(memory-tab): saveImportanceOverride — targeted frontmatter patch, not the whole-file editor (Slice D)"
```

---

### Task 7: Swift — Importance section in `MemoryNodeDetailView`

**Depends on:** Task 6 (`MemoryNodeDetail.importanceOverride`/`canEditImportance`, `MemoryViewModel.importanceOverrideInput`/`importanceError`/`saveImportanceOverride`).

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Memory/MemoryNodeDetailView.swift`

**Interfaces:**
- Consumes: everything Task 6 produced. No new logic here — pure SwiftUI composition, so this task has no new pure-logic unit test (all the logic it displays is already covered by Task 6's `MemoryViewModelTests`); verification is a build + manual sanity check.

- [ ] **Step 1: implement** — add the section to `MemoryNodeDetailView`'s `body`, right after the existing `disputeBanner` conditional and before `Divider()`:

```swift
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if detail.node.isDisputed {
                    disputeBanner
                }
                importanceSection
                Divider()
                if let readError = detail.fileReadError {
                    Label(readError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    MarkdownText(text: detail.renderedBody)
                }
                if !detail.backlinks.isEmpty {
                    backlinksSection
                }
                if !detail.history.isEmpty {
                    historySection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
```

Add the two new private computed views, e.g. right after the existing `disputeBanner` (before `// MARK: - Backlinks`):

```swift
    // MARK: - Importance

    private var importanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Importance")
            HStack(spacing: 8) {
                Text(String(format: "%.1f", detail.node.importanceScore))
                    .font(.callout)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if detail.importanceOverride != nil {
                    Text("manual override")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if detail.canEditImportance {
                importanceEditor
            } else {
                Text("Malformed frontmatter — importance override disabled for this node.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = vm.importanceError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 4)
    }

    private var importanceEditor: some View {
        HStack(spacing: 8) {
            TextField("Override", value: $vm.importanceOverrideInput, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Button("Save") {
                Task { await vm.saveImportanceOverride(value: vm.importanceOverrideInput) }
            }
            .disabled(vm.importanceOverrideInput < 0)
            if detail.importanceOverride != nil {
                Button("Clear override") {
                    Task { await vm.saveImportanceOverride(value: nil) }
                }
            }
        }
    }
```

- [ ] **Step 2: build sanity**

Run: `cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "build exit: $?"`
Expected: `exit: 0`.

- [ ] **Step 3: full test suite + manual sanity, then commit**

Run: `cd WatchtowerDesktop && swift test > /tmp/swift-test-full.log 2>&1; echo "test exit: $?"`
Expected: `exit: 0`, every existing test still passes (this task added no new logic, only view composition over Task 6's already-tested state).

Manual sanity (per this repo's UI-change convention — start the dev build and exercise the golden path before declaring done): `make app-dev`, open the Memory tab, select an entity node, confirm the Importance section shows a score, set an override, confirm "manual override" appears and the value round-trips after switching away and back to the node, clear it, confirm it disappears.

```bash
cd WatchtowerDesktop
git add Sources/Views/Memory/MemoryNodeDetailView.swift
git commit -m "feat(memory-tab): Importance section in the node detail view (Slice D)"
```

---

## Task Dependency Summary

- **Independent, can start immediately in parallel:** Task 1 (Go index annotation), Task 3 (Swift model/query), Task 5 (Swift Markdown helpers).
- **Task 2** depends on Task 1.
- **Task 4** depends on Task 3.
- **Task 6** depends on Task 3 and Task 5.
- **Task 7** depends on Task 6.

Go tasks (1, 2) and Swift tasks (3, 4, 5, 6, 7) touch entirely disjoint files and can run on two parallel subagent tracks throughout.
