# Secretary Memory — Slice B: Unified Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task is sized for one focused agent session; obey the stated dependencies. Read `docs/superpowers/specs/2026-07-20-memory-slice-b-unified-retrieval-design.md` (the whole thing — it's short) **first**, plus `docs/inventory/memory.md`'s MEM-01/02/05/06/07/09/11/12/14/15/16 entries (the write-time-validation, provenance, dark-compare-mode, and importance-score precedents this slice extends).

**Goal:** Replace three unrelated ad hoc ranking heuristics — `memory_recall`'s pure FTS5 rank, meeting-prep's `ORDER BY confidence DESC`, briefing's unranked encounter-order notable-revision filter — with one shared importance × relevance primitive (`RankByImportance`) and three focused retrieval functions built on it. Land each behind an independent dark compare-mode flag, verify the new ranking against real production data (the WhiteBit workspace), and — evidence permitting, per surface — retire the corresponding legacy selection code as this same slice's final step.

**Architecture:** `internal/memory/retrieve.go` holds `RankByImportance` (the one place `importance_score` and relevance combine) plus `RetrieveByQuery`/`RetrieveBySubject`/`RetrieveRevisions` (Tasks 1–6, pure/uncalled-by-anything-live foundation). A schema extension (`memory_provenance.sender_id`, migration `00028`) lets subject-based short-term retrieval find "what recently happened involving this person" without a runtime join. Tasks 7–11 wire all three retrieval functions in behind independent `memory.retrieve.{recall_compare,briefing_compare,meeting_prep_compare}` flags (all dark by default), mirroring this repo's `digest_compare.go` precedent: legacy stays authoritative, the new path runs alongside it, and both are diffed into a new `memory_retrieve_shadow` table. Task 12 is the standard final-verification gate. Task 13 is a runbook, not a TDD task: run `watchtower memory retrieve-compare` against a safe, already-prepared snapshot of the real, live WhiteBit workspace (2,062 memory nodes, 465k messages — never the live database itself), evaluate each surface's diff metrics independently against an objective bar, and — per surface, only where the bar is met — retire that surface's legacy selection code in this same slice (13a/13b/13c).

**Tech Stack:** Go 1.25, `modernc.org/sqlite`, goose migrations, `testify` (`assert`/`require`), the existing `internal/memory` test harness (`newTestVault`/`newTestDB`/`writeNodes`/`writeAndIndex`), `internal/db`'s (`openTestDB`/`memTestNode`).

## Global Constraints

- Before each commit: `gofmt -l`, `go vet ./...`, `go build ./...`, and the affected package tests green — verify the real exit code, never by piping through `tail` alone (redirect to a log file and check `$?`, or rely on `go test`'s own PASS/FAIL summary plus its exit status).
- **Tasks 1–6 wire nothing live.** No consumer (`internal/mcp/`, `internal/meeting/`, `internal/briefing/memory_revisions.go`'s `gatherMemoryRevisions`) changes behavior until Task 8/9/10 add dark, flagged wiring — and even then the flag defaults false and the live response/journal/context is proven byte-identical regardless of the flag.
- **`internal/memory` must never import `internal/briefing`.** `internal/briefing` already imports `internal/memory` (for `OpenExistingVault`, `Node`, `ParseHistory`, `HistoryBullet`) — Task 6 widens that existing, correctly-directed dependency (relocating `notableRevision` into `internal/memory` as exported `NotableRevision`), never the reverse.
- **Never weaken a guard.** MEM-01/02/05/06/07/09/11/12/14/15/16 stay exactly as they read today. The MEM-01 write-time validation (`validateRefs`/`provenanceRegistry`) is completely separate from the new `senderResolver` (Task 3) — a sender lookup miss or error never drops a provenance ref or fails a write; it only leaves `SenderID` empty for that one ref.
- **`SearchMemoryFTS` is unchanged** in Tasks 1–12 — it stays `memory_recall`'s live, legacy, sole-authoritative path until (and unless) Task 13a's evidence-gated switch retires it. `SearchMemoryFTSCandidates` is a new sibling, not a modification.
- **Compare-mode never touches a live response.** Every dark-wiring task (8/9/10) proves, with its own test, that the surface's actual returned response/journal/context is byte-identical whether its flag is on or off — the only observable side effect of the flag being on is one new `memory_retrieve_shadow` row.
- **The evidence-gated switch (Task 13) is part of THIS slice**, not deferred to a later one — unlike the `digest_compare` precedent. Each of the three surfaces (recall/briefing/meeting-prep) is decided independently against its own objective diff metrics; an ambiguous or unmet bar for one surface does not block switching another, and does not block finishing this slice.
- English docs/comments, matching the file's existing comment density and cross-referencing style (`MEM-NN`, migration numbers, "Slice B").

## File Structure

- `internal/memory/retrieve.go` (new) + `internal/memory/retrieve_test.go` (new) — `ScoredCandidate`, `RankByImportance`, `RetrieveByQuery`, `RetrieveBySubject`, `RetrieveRevisions` (Tasks 1, 5, 6).
- `internal/db/migrations/00028_memory_provenance_sender.sql` (new), `internal/db/migrations/00029_memory_retrieve_shadow.sql` (new) + `internal/db/schema.sql` (modify) + `internal/db/testdata/schema_v73.golden` (regenerated) + `internal/db/db_test.go` (new migration tests) — Tasks 2, 7.
- `internal/db/memory.go` (modify) — `ProvenanceRow.SenderID`, `MessageSender`, `GmailMessageSender`, `ListShortTierEpisodesForAliases`, `SearchMemoryFTSCandidates` (+ `MemoryFTSCandidate`), `ListBeliefsForSubjects`, `MemoryRetrieveShadowRow`, `InsertMemoryRetrieveShadow`, `ListMemoryRetrieveShadow` — Tasks 3, 4, 5, 6, 7.
- `internal/memory/dedupe.go` (modify) — `senderResolver`/`dbSenderResolver`, `provenanceRows` gains a resolver parameter — Task 3.
- `internal/memory/index.go`, `internal/memory/merge.go` (modify) — the two production call sites of `provenanceRows(` — Task 3.
- `internal/memory/beliefs.go` (modify) — `NotableRevision`/`RevisionNotability` relocated from `internal/briefing` — Task 6.
- `internal/briefing/memory_revisions.go` (modify) — calls `memory.NotableRevision` (Task 6), then gains dark retrieval-compare wiring (Task 9).
- `internal/memory/retrieve_compare.go` (+ `_test.go`) — `CompareRecall`/`CompareRevisions`/`CompareSubject`, `RecordRetrieveShadow` — Task 7.
- `internal/mcp/server.go`, `internal/mcp/memory.go` (modify) — `WithMemoryRetrieveCompare`, dark wiring for `memory_recall` — Task 8.
- `internal/meeting/memory_context.go` (modify) — dark wiring for meeting-prep — Task 10.
- `internal/memory/retrieve_compare_cli.go` (+ `_test.go`) — `RunRetrieveCompare`, `RenderRetrieveCompareReport` — Task 11.
- `cmd/memory.go` (modify) — `watchtower memory retrieve-compare` subcommand — Task 11.
- `docs/inventory/memory.md` (modify) — new contract entry — Task 11.

---

## Task 1: `RankByImportance` — the shared ranking primitive

**Depends on:** nothing. **Blocks:** Tasks 5, 6 (both retrieval functions that produce importance-ranked output funnel through this).

**Files:**
- Create: `internal/memory/retrieve.go`, `internal/memory/retrieve_test.go`

**Interfaces:**
- Consumes: nothing (pure function over `db.MemoryNodeRow`, which already exists with `ImportanceScore` from Slice A).
- Produces: `type ScoredCandidate struct { Row db.MemoryNodeRow; Relevance float64 }` and `func RankByImportance(candidates []ScoredCandidate, limit int) []db.MemoryNodeRow` — consumed by Task 5's `RetrieveByQuery` and Task 6's `RetrieveBySubject`/`RetrieveRevisions`.

This is genuinely new code (no "current code" to quote) — the design spec (`docs/superpowers/specs/2026-07-20-memory-slice-b-unified-retrieval-design.md` §1) specifies the signature and the "zero-importance sorts last" characteristic; two decisions the spec leaves to the implementer, resolved here:

1. **Stability.** Go's `sort.Slice` explicitly does **not** guarantee equal elements keep their relative order; `sort.SliceStable` does, at a modest cost. The design spec's own test-plan bullet ("ties broken by original order stability") requires a deterministic tie order, so a test asserting one would be flaky under `sort.Slice`. **Decision: `sort.SliceStable`.** (Precedent: `internal/memory/gmail_extract.go:102` and `internal/memory/pipeline.go:914` already use `sort.SliceStable` in this exact package for the same reason.)
2. **`limit <= 0`.** Unlike `db.ListDisputePendingBeliefs`/`db.SearchMemoryFTS` (where `<= 0` conventionally means "unbounded" — a *query* convention), `RankByImportance` is a pure post-fetch truncation primitive: the caller already decided how many results it wants. **Decision: `limit <= 0` returns `nil`** (zero results, not "unlimited") — the opposite of the query-layer convention, because inverting it here would make "give me 0" silently mean "give me everything," a landmine for a function named `limit`.

- [ ] **Step 1: write the failing tests** — create `internal/memory/retrieve_test.go`:

```go
package memory

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

// candRow returns a minimal MemoryNodeRow carrying only the fields
// RankByImportance reads (id + importance_score) — everything else is
// irrelevant to this pure function.
func candRow(id string, importance float64) db.MemoryNodeRow {
	return db.MemoryNodeRow{ID: id, ImportanceScore: importance}
}

// TestRankByImportance_ImportanceOnlyOrdering: equal relevance, ordering
// follows importance_score descending.
func TestRankByImportance_ImportanceOnlyOrdering(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("low", 1), Relevance: 1.0},
		{Row: candRow("high", 5), Relevance: 1.0},
		{Row: candRow("mid", 3), Relevance: 1.0},
	}
	got := RankByImportance(cands, 3)
	require := []string{"high", "mid", "low"}
	for i, want := range require {
		assert.Equal(t, want, got[i].ID)
	}
}

// TestRankByImportance_RelevanceOnlyOrdering: equal importance, ordering
// follows relevance descending — the "same node kind, different match
// strength" case RetrieveByQuery relies on.
func TestRankByImportance_RelevanceOnlyOrdering(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("weak", 2), Relevance: 0.1},
		{Row: candRow("strong", 2), Relevance: 0.9},
		{Row: candRow("mid", 2), Relevance: 0.5},
	}
	got := RankByImportance(cands, 3)
	require := []string{"strong", "mid", "weak"}
	for i, want := range require {
		assert.Equal(t, want, got[i].ID)
	}
}

// TestRankByImportance_ZeroImportanceSortsLast: a freshly-seeded node with no
// importance signal yet scores 0 regardless of relevance and sorts behind
// every nonzero-importance node — an accepted characteristic (design spec
// §1), not a bug.
func TestRankByImportance_ZeroImportanceSortsLast(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("fresh", 0), Relevance: 1.0}, // max relevance, zero importance
		{Row: candRow("aged", 1), Relevance: 0.1},   // min relevance, nonzero importance
	}
	got := RankByImportance(cands, 2)
	assert.Equal(t, "aged", got[0].ID)
	assert.Equal(t, "fresh", got[1].ID)
}

// TestRankByImportance_TieOrderIsStable: two candidates with identical scores
// keep their input order — this is what makes sort.SliceStable (not
// sort.Slice) the correct choice; the assertion would be flaky under
// sort.Slice, which is explicitly allowed to reorder equal elements.
func TestRankByImportance_TieOrderIsStable(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("first", 2), Relevance: 1.0},
		{Row: candRow("second", 2), Relevance: 1.0},
		{Row: candRow("third", 2), Relevance: 1.0},
	}
	got := RankByImportance(cands, 3)
	require := []string{"first", "second", "third"}
	for i, want := range require {
		assert.Equal(t, want, got[i].ID, "equal-scoring candidates must keep input order")
	}
}

// TestRankByImportance_LimitTruncatesSmaller: limit below len(candidates)
// keeps only the top-limit by score.
func TestRankByImportance_LimitTruncatesSmaller(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("a", 1), Relevance: 1.0},
		{Row: candRow("b", 2), Relevance: 1.0},
		{Row: candRow("c", 3), Relevance: 1.0},
	}
	got := RankByImportance(cands, 1)
	assert.Len(t, got, 1)
	assert.Equal(t, "c", got[0].ID)
}

// TestRankByImportance_LimitLargerThanInputIsNoop: limit above
// len(candidates) returns every candidate, sorted, no error/panic.
func TestRankByImportance_LimitLargerThanInputIsNoop(t *testing.T) {
	cands := []ScoredCandidate{
		{Row: candRow("a", 1), Relevance: 1.0},
		{Row: candRow("b", 2), Relevance: 1.0},
	}
	got := RankByImportance(cands, 50)
	assert.Len(t, got, 2)
	assert.Equal(t, "b", got[0].ID)
}

// TestRankByImportance_LimitZeroOrNegativeReturnsEmpty: a pure-truncation
// primitive treats limit<=0 as "exactly that many" (0), never "unlimited" —
// the opposite of db.ListDisputePendingBeliefs's <=0-means-unbounded query
// convention, deliberately, since inverting it here would silently turn
// "give me 0" into "give me everything."
func TestRankByImportance_LimitZeroOrNegativeReturnsEmpty(t *testing.T) {
	cands := []ScoredCandidate{{Row: candRow("a", 1), Relevance: 1.0}}
	assert.Empty(t, RankByImportance(cands, 0))
	assert.Empty(t, RankByImportance(cands, -1))
}
```

- [ ] **Step 2: run it — expect a build failure** (the symbols don't exist yet):

```
$ go test ./internal/memory/ -run 'TestRankByImportance' -v
# watchtower/internal/memory [watchtower/internal/memory.test]
./retrieve_test.go:16:16: undefined: ScoredCandidate
./retrieve_test.go:23:9: undefined: RankByImportance
FAIL	watchtower/internal/memory [build failed]
```

- [ ] **Step 3: write the minimal implementation** — create `internal/memory/retrieve.go`:

```go
package memory

import (
	"sort"

	"watchtower/internal/db"
)

// ScoredCandidate pairs an indexed node with a caller-computed relevance
// signal (0..1, semantics owned by the caller) for one RankByImportance call
// (Slice B of the memory-retrieval redesign,
// docs/superpowers/specs/2026-07-20-memory-slice-b-unified-retrieval-design.md).
type ScoredCandidate struct {
	Row       db.MemoryNodeRow
	Relevance float64
}

// RankByImportance is the ONE place importance_score and relevance combine:
// score = Row.ImportanceScore * Relevance, sorted descending, truncated to
// limit. Every retrieval function in this package funnels its own relevance
// signal through this single combiner instead of inventing its own ranking
// (RetrieveByQuery's FTS-rank-derived relevance, RetrieveBySubject's flat 1.0
// exact-match relevance, RetrieveRevisions's confidence-delta magnitude).
//
// A node with ImportanceScore == 0 (no override, no organic signal yet — the
// common case for a freshly-seeded entity) scores 0 regardless of relevance
// and sorts last; this is an accepted characteristic, not a bug (design spec
// §1) — a brand-new, untouched node genuinely has no importance signal yet.
//
// limit <= 0 returns nil (zero results) — this is a pure post-fetch
// truncation primitive, not a "fetch N or unbounded" query helper (unlike,
// say, db.ListDisputePendingBeliefs's <=0-means-unlimited convention): the
// caller already decided how many results it wants, so 0 or negative means
// exactly that many. limit >= len(candidates) is a no-op truncation (every
// candidate survives the cut, just sorted).
//
// sort.SliceStable (not sort.Slice) is deliberate: two candidates can score
// identically (e.g. two freshly-seeded, zero-importance nodes, or two exact
// RetrieveBySubject matches with equal importance), and callers may rely on
// encounter order as the tie-break. Go's sort.Slice is explicitly permitted
// to reorder equal elements; only SliceStable guarantees they keep their
// input order (precedent: gmail_extract.go, pipeline.go already use
// SliceStable in this package for the identical reason).
func RankByImportance(candidates []ScoredCandidate, limit int) []db.MemoryNodeRow {
	if limit <= 0 {
		return nil
	}
	ranked := make([]ScoredCandidate, len(candidates))
	copy(ranked, candidates)
	sort.SliceStable(ranked, func(i, j int) bool {
		return ranked[i].Row.ImportanceScore*ranked[i].Relevance >
			ranked[j].Row.ImportanceScore*ranked[j].Relevance
	})
	if limit > len(ranked) {
		limit = len(ranked)
	}
	out := make([]db.MemoryNodeRow, limit)
	for i := 0; i < limit; i++ {
		out[i] = ranked[i].Row
	}
	return out
}
```

- [ ] **Step 4: run it — expect green:**

```
$ go test ./internal/memory/ -run 'TestRankByImportance' -v
=== RUN   TestRankByImportance_ImportanceOnlyOrdering
--- PASS: TestRankByImportance_ImportanceOnlyOrdering (0.00s)
=== RUN   TestRankByImportance_RelevanceOnlyOrdering
--- PASS: TestRankByImportance_RelevanceOnlyOrdering (0.00s)
=== RUN   TestRankByImportance_ZeroImportanceSortsLast
--- PASS: TestRankByImportance_ZeroImportanceSortsLast (0.00s)
=== RUN   TestRankByImportance_TieOrderIsStable
--- PASS: TestRankByImportance_TieOrderIsStable (0.00s)
=== RUN   TestRankByImportance_LimitTruncatesSmaller
--- PASS: TestRankByImportance_LimitTruncatesSmaller (0.00s)
=== RUN   TestRankByImportance_LimitLargerThanInputIsNoop
--- PASS: TestRankByImportance_LimitLargerThanInputIsNoop (0.00s)
=== RUN   TestRankByImportance_LimitZeroOrNegativeReturnsEmpty
--- PASS: TestRankByImportance_LimitZeroOrNegativeReturnsEmpty (0.00s)
PASS
ok  	watchtower/internal/memory	0.2s
```

- [ ] **Step 5: full package sanity + commit:**

```
$ go vet ./internal/memory/... && go build ./...
$ go test ./internal/memory/ 2>&1 | tail -5
ok  	watchtower/internal/memory	0.4s
$ git add internal/memory/retrieve.go internal/memory/retrieve_test.go
$ git commit -m "feat(memory): RankByImportance shared ranking primitive (Slice B foundation)

The one place importance_score x relevance combine, funneled through by
every Slice B retrieval function. Pure, no DB access. sort.SliceStable for
deterministic tie order; limit<=0 returns nil (a truncation primitive, not
a query — the opposite of the <=0-means-unbounded query convention)."
```

---

## Task 2: Migration `00028_memory_provenance_sender.sql`

**Depends on:** nothing. **Blocks:** Task 3 (the Go-level `SenderID` wiring needs the column), Task 4 (the alias query filters on it).

**Files:**
- Create: `internal/db/migrations/00028_memory_provenance_sender.sql`
- Modify: `internal/db/schema.sql` (the `memory_provenance` table, currently lines 1291–1299), `internal/db/testdata/schema_v73.golden` (regenerated, not hand-edited)
- Test: `internal/db/db_test.go` (new `TestMigration00028MemoryProvenanceSender`, inserted after the most recent migration test — verify the exact anchor at implementation time via `grep -n 'func TestMigration' internal/db/db_test.go | tail -3`)

**Interfaces:**
- Consumes: nothing.
- Produces: the `memory_provenance.sender_id TEXT NOT NULL DEFAULT ''` column + `idx_memory_provenance_sender` index — consumed by Task 3's Go-level wiring and Task 4's `ListShortTierEpisodesForAliases`.

Latest migration on this branch is `internal/db/migrations/00027_memory_importance_score.sql` (Slice A — additive `ALTER TABLE ... ADD COLUMN ... DEFAULT 0`, no CHECK involved). This slice's column is the same shape: a plain additive column plus one new index, no CHECK constraint, no table-recreation dance.

Current `internal/db/schema.sql` `memory_provenance` table (lines 1291–1299):

```sql
CREATE TABLE IF NOT EXISTS memory_provenance (
    node_id     TEXT NOT NULL REFERENCES memory_nodes(id),
    scheme      TEXT NOT NULL DEFAULT '',
    channel_id  TEXT NOT NULL,
    ts_raw      TEXT NOT NULL,
    ts_unix     REAL NOT NULL,
    PRIMARY KEY (node_id, channel_id, ts_raw)
);
CREATE INDEX IF NOT EXISTS idx_memory_provenance_window ON memory_provenance(channel_id, ts_unix);
```

becomes:

```sql
CREATE TABLE IF NOT EXISTS memory_provenance (
    node_id     TEXT NOT NULL REFERENCES memory_nodes(id),
    scheme      TEXT NOT NULL DEFAULT '',
    channel_id  TEXT NOT NULL,
    ts_raw      TEXT NOT NULL,
    ts_unix     REAL NOT NULL,
    sender_id   TEXT NOT NULL DEFAULT '',    -- per-message sender (Slack user_id / Gmail from_email); '' for cal:/chat:/act: schemes (see 00028, Slice B)
    PRIMARY KEY (node_id, channel_id, ts_raw)
);
CREATE INDEX IF NOT EXISTS idx_memory_provenance_window ON memory_provenance(channel_id, ts_unix);
CREATE INDEX IF NOT EXISTS idx_memory_provenance_sender ON memory_provenance(sender_id);
```

House pattern for verifying an INDEX exists in a test (there is no existing precedent for this in `internal/db/*_test.go` — every prior migration test checks a TABLE via `sqlite_master WHERE type='table'`, e.g. `db_test.go:148`/`gmail_migration_test.go:11`; this is the first COLUMN migration to also add an index, so the test below extends that exact query shape to `type='index'`).

- [ ] **Step 1: write the failing test** — add to `internal/db/db_test.go` immediately after the last existing `TestMigration...` function (confirm the real insertion point with `grep -n 'func TestMigration' internal/db/db_test.go` at implementation time — Slice A's `TestMigration00027MemoryImportanceScore` is the most recent as of this plan):

```go
// TestMigration00028MemoryProvenanceSender: memory_provenance.sender_id
// (Slice B of the memory-retrieval redesign) is additive, defaults '', a
// plain insert that omits it still succeeds, and its index exists.
func TestMigration00028MemoryProvenanceSender(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	var n int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('memory_provenance') WHERE name = 'sender_id'`).Scan(&n)
	if err != nil || n != 1 {
		t.Fatalf("memory_provenance.sender_id missing (count=%d err=%v)", n, err)
	}

	var idxCount int
	if err := database.QueryRow(
		`SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_memory_provenance_sender'`).Scan(&idxCount); err != nil || idxCount != 1 {
		t.Fatalf("idx_memory_provenance_sender missing (count=%d err=%v)", idxCount, err)
	}

	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, path, content_hash, indexed_at)
		 VALUES ('ep_sender_x', 'episode', 'short', 'episodes/x.md', 'h', '2026-07-20T00:00:00Z')`); err != nil {
		t.Fatalf("inserting memory node: %v", err)
	}
	if _, err := database.Exec(
		`INSERT INTO memory_provenance (node_id, channel_id, ts_raw, ts_unix)
		 VALUES ('ep_sender_x', 'C0AAA', '100.000100', 100.0001)`); err != nil {
		t.Fatalf("inserting provenance row without sender_id: %v", err)
	}
	var sender string
	if err := database.QueryRow(
		`SELECT sender_id FROM memory_provenance WHERE node_id = 'ep_sender_x'`).Scan(&sender); err != nil {
		t.Fatalf("reading sender_id default: %v", err)
	}
	if sender != "" {
		t.Fatalf("sender_id default = %q, want empty string", sender)
	}
}
```

- [ ] **Step 2: run it — expect failure** (the column/index do not exist yet):

```
$ go test ./internal/db/ -run TestMigration00028MemoryProvenanceSender -v
=== RUN   TestMigration00028MemoryProvenanceSender
    db_test.go:XXX: memory_provenance.sender_id missing (count=0 err=<nil>)
--- FAIL: TestMigration00028MemoryProvenanceSender (0.01s)
FAIL
```

- [ ] **Step 3: write the minimal implementation** — create `internal/db/migrations/00028_memory_provenance_sender.sql`:

```sql
-- +goose Up
-- Secretary memory retrieval (Slice B of the memory-retrieval redesign,
-- docs/superpowers/specs/2026-07-20-memory-slice-b-unified-retrieval-design.md).
-- Persists the per-message sender for a provenance ref so RetrieveBySubject's
-- short-term half (ListShortTierEpisodesForAliases) can find "what recently
-- happened involving this person/channel" without a runtime join back to
-- messages/gmail_messages at query time. Populated only for schemes with a
-- genuine per-message sender: Slack (messages.user_id) and Gmail
-- (gmail_messages.from_email); left '' for cal:/chat:/act: schemes (weaker
-- or always-owner-authored — no discriminating value there). No
-- migration-time backfill — memory_provenance is fully vault-derived and
-- converges via Reconcile/`watchtower memory reindex` (the importance_score
-- 00027 precedent). Additive, no CHECK constraint — a plain ADD COLUMN
-- suffices (the 00017/00026/00027 ALTER TABLE precedent).
ALTER TABLE memory_provenance ADD COLUMN sender_id TEXT NOT NULL DEFAULT '';
CREATE INDEX idx_memory_provenance_sender ON memory_provenance(sender_id);

-- +goose Down
DROP INDEX idx_memory_provenance_sender;
ALTER TABLE memory_provenance DROP COLUMN sender_id;
```

Modify `internal/db/schema.sql`'s `memory_provenance` table (lines 1291–1299) to the "becomes" block shown above.

- [ ] **Step 4: run it — expect green, then regenerate the golden snapshot:**

```
$ go test ./internal/db/ -run TestMigration00028MemoryProvenanceSender -v
=== RUN   TestMigration00028MemoryProvenanceSender
--- PASS: TestMigration00028MemoryProvenanceSender (0.01s)
PASS
ok  	watchtower/internal/db	0.2s

$ go test ./internal/db/ -run TestSchemaGolden -update
    schema_snapshot_test.go:43: wrote testdata/schema_v73.golden (NNNNN bytes)
ok  	watchtower/internal/db	0.1s

$ go test ./internal/db/ -run 'TestSchemaGolden|TestAllTablesExist|TestMigration' -v 2>&1 | tail -20
--- PASS: TestSchemaGolden (0.05s)
--- PASS: TestAllTablesExist (0.02s)
--- PASS: TestMigration00028MemoryProvenanceSender (0.01s)
PASS
ok  	watchtower/internal/db	0.5s
```

- [ ] **Step 5: commit:**

```
$ git add internal/db/migrations/00028_memory_provenance_sender.sql internal/db/schema.sql internal/db/testdata/schema_v73.golden internal/db/db_test.go
$ git commit -m "feat(db): memory_provenance.sender_id column + index (00028, Slice B foundation)

Additive ALTER TABLE ADD COLUMN, no CHECK change. Populated only for Slack/
Gmail refs (Go-level wiring in a later task); mirrors into schema.sql,
golden snapshot regenerated."
```

---

## Task 3: `senderResolver` + wire into `provenanceRows`

**Depends on:** Task 2 (the column must exist for the INSERT to carry it). **Blocks:** Task 4 (the alias query has nothing to filter on until this populates `sender_id`).

**Files:**
- Modify: `internal/db/memory.go` — `ProvenanceRow` struct (lines 56–62), `UpsertMemoryNode`'s provenance INSERT (lines 127–133); new `MessageSender`/`GmailMessageSender` methods
- Modify: `internal/memory/dedupe.go` — `provenanceRows` (lines 227–268); new `senderResolver` interface + `dbSenderResolver` + `resolveSenderID`
- Modify: `internal/memory/index.go` (line 248, inside `reconcilePass.file()`), `internal/memory/merge.go` (line 168, inside `upsertIndexNode`) — the two production call sites
- Modify: `internal/memory/digest_compare_test.go` (line 31, inside `indexEpisodeWithProvenance`), `internal/memory/provenance_test.go` (lines 314, 329, inside `TestProvenanceRows`) — the two test call sites
- Test: `internal/db/memory_test.go` (new `MessageSender`/`GmailMessageSender` round-trip tests), `internal/memory/provenance_test.go` (extend `TestProvenanceRows` with sender population + add a lookup-miss-is-not-fatal case)

**Interfaces:**
- Consumes: `memory_provenance.sender_id` (Task 2).
- Produces: `db.ProvenanceRow.SenderID string`, `db.DB.MessageSender`/`GmailMessageSender`, `memory.senderResolver`/`dbSenderResolver` — consumed by Task 4's `ListShortTierEpisodesForAliases` (reads the populated column) and by nothing else in this half (no consumer beyond the index-population path itself).

Every real call site of `provenanceRows(` (verified via `grep -rn "provenanceRows(" internal/memory/`):

```
internal/memory/index.go:248:      if err := p.database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, p.logf)...); err != nil {
internal/memory/merge.go:168:      if err := database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, nil)...); err != nil {
internal/memory/dedupe.go:239:     func provenanceRows(n Node, logf func(string, ...any)) []db.ProvenanceRow {   (the definition itself)
internal/memory/digest_compare_test.go:31:  }, n.Body, n.Aliases, provenanceRows(n, nil)...))
internal/memory/provenance_test.go:314:    rows := provenanceRows(n, nil)
internal/memory/provenance_test.go:329:    assert.Nil(t, provenanceRows(plain, nil))
```

Every one of these updates in this task — two production call sites, two test call sites, plus the definition.

Current `db.ProvenanceRow` (`internal/db/memory.go` lines 56–62):

```go
type ProvenanceRow struct {
	NodeID    string
	Scheme    string // "" (Slack), "mail", "cal", "chat", "act"
	ChannelID string // the raw ref channel_id, e.g. "C0AAA" or "mail:<id>"
	TSRaw     string // the ref ts verbatim as rendered in ## Provenance
	TSUnix    float64
}
```

Current `UpsertMemoryNode`'s provenance insert loop (lines 127–133):

```go
	for _, p := range provenance {
		if _, err := tx.Exec(`INSERT INTO memory_provenance
			(node_id, scheme, channel_id, ts_raw, ts_unix) VALUES (?, ?, ?, ?, ?)`,
			row.ID, p.Scheme, p.ChannelID, p.TSRaw, p.TSUnix); err != nil {
			return fmt.Errorf("inserting provenance %s/%s for %s: %w", p.ChannelID, p.TSRaw, row.ID, err)
		}
	}
```

Current `internal/memory/dedupe.go`'s `provenanceRows` (lines 227–268, in full):

```go
// provenanceRows builds the db-layer memory_provenance index rows for a node
// from its ## Provenance section — the single parse site the derived
// provenance index flows through (parseProvenance → classify scheme →
// decode ts), keeping the db layer a dumb store (one parse site in memory,
// one write site in db.UpsertMemoryNode, one transaction). Each ref is
// classified by schemeOf (a bare Slack channel_id is scheme "", mail:/cal:/
// chat:/act: carry their prefix) and its ts decoded to a unix float for
// windowed lookup; a ref whose ts is not numeric cannot be windowed and is
// skipped (logged when logf is non-nil). Refs are deduped by
// (channel_id, ts_raw) so the wholesale insert cannot collide on the
// memory_provenance primary key. A node with no ## Provenance section (every
// non-episode/rollup type) yields nil.
func provenanceRows(n Node, logf func(string, ...any)) []db.ProvenanceRow {
	refs := parseProvenance(n.Body)
	if len(refs) == 0 {
		return nil
	}
	seen := make(map[string]bool, len(refs))
	var rows []db.ProvenanceRow
	for _, r := range refs {
		key := r.ChannelID + "\x00" + r.TS
		if seen[key] {
			continue
		}
		seen[key] = true
		tsUnix, err := strconv.ParseFloat(strings.TrimSpace(r.TS), 64)
		if err != nil {
			if logf != nil {
				logf("memory: provenance ref %s %s on %s skipped (non-numeric ts, not windowable)", r.ChannelID, r.TS, n.ID)
			}
			continue
		}
		rows = append(rows, db.ProvenanceRow{
			NodeID:    n.ID,
			Scheme:    schemeOf(r.ChannelID),
			ChannelID: r.ChannelID,
			TSRaw:     r.TS,
			TSUnix:    tsUnix,
		})
	}
	return rows
}
```

- [ ] **Step 1: write the failing tests.**

`internal/db/memory_test.go` — add near the other single-purpose lookup tests (e.g. after `TestMessageExists`-style tests; confirm anchor with `grep -n 'func TestMessageExists\|func TestGmailMessageExists' internal/db/memory_test.go` at implementation time):

```go
func TestMessageSender(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1SND', '100.000100', 'U9', 'hi')`); err != nil {
		t.Fatalf("seeding message: %v", err)
	}

	sender, err := d.MessageSender("C1SND", "100.000100")
	if err != nil {
		t.Fatalf("MessageSender: %v", err)
	}
	if sender != "U9" {
		t.Errorf("MessageSender = %q, want U9", sender)
	}

	if _, err := d.MessageSender("C1SND", "nonexistent"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("MessageSender on missing message = %v, want sql.ErrNoRows", err)
	}
}

func TestGmailMessageSender(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`INSERT INTO gmail_messages (id, from_email) VALUES ('gm1', 'sender@example.com')`); err != nil {
		t.Fatalf("seeding gmail message: %v", err)
	}

	sender, err := d.GmailMessageSender("gm1")
	if err != nil {
		t.Fatalf("GmailMessageSender: %v", err)
	}
	if sender != "sender@example.com" {
		t.Errorf("GmailMessageSender = %q, want sender@example.com", sender)
	}

	if _, err := d.GmailMessageSender("nonexistent"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("GmailMessageSender on missing message = %v, want sql.ErrNoRows", err)
	}
}
```

`internal/memory/provenance_test.go` — replace the two existing `provenanceRows(` calls (lines 314, 329) with the new 3-arg shape and extend the assertions, plus add a new resolver-error-is-not-fatal test:

```go
// fakeSenderResolver is a scriptable senderResolver for tests: each method
// looks up its argument in a map and returns the mapped error otherwise.
type fakeSenderResolver struct {
	slack map[string]string // "channelID ts" -> sender
	mail  map[string]string // messageID -> sender
	err   error             // when set, every lookup returns ("", err) instead
}

func (f fakeSenderResolver) SlackSender(channelID, ts string) (string, error) {
	if f.err != nil {
		return "", f.err
	}
	return f.slack[channelID+" "+ts], nil
}

func (f fakeSenderResolver) MailSender(messageID string) (string, error) {
	if f.err != nil {
		return "", f.err
	}
	return f.mail[messageID], nil
}

// TestProvenanceRows builds the db-layer index rows from a node's ## Provenance
// section: each ref is classified by scheme and its ts decoded to a unix float;
// a ref whose ts is not numeric is skipped (it cannot be windowed), and a node
// with no ## Provenance section yields nil. SenderID is populated for Slack and
// Gmail refs via the resolver (Slice B); every other scheme stays "".
func TestProvenanceRows(t *testing.T) {
	body := "# Ep\n\n## Story\nstuff\n\n## Provenance\n" +
		"- C0AAA 1700000000.000100\n" +
		"- mail:abc 1700000500\n" +
		"- notanumber whoops\n"
	n := Node{ID: "ep_1", Type: "episode", Body: body}

	resolver := fakeSenderResolver{
		slack: map[string]string{"C0AAA 1700000000.000100": "U1"},
		mail:  map[string]string{"abc": "sender@example.com"},
	}
	rows := provenanceRows(n, resolver, nil)
	require.Len(t, rows, 2, "the non-numeric ts ref is skipped")

	assert.Equal(t, "ep_1", rows[0].NodeID)
	assert.Equal(t, "", rows[0].Scheme)
	assert.Equal(t, "C0AAA", rows[0].ChannelID)
	assert.Equal(t, "1700000000.000100", rows[0].TSRaw)
	assert.InDelta(t, 1700000000.0001, rows[0].TSUnix, 1e-6)
	assert.Equal(t, "U1", rows[0].SenderID)

	assert.Equal(t, "mail", rows[1].Scheme)
	assert.Equal(t, "mail:abc", rows[1].ChannelID)
	assert.InDelta(t, 1700000500.0, rows[1].TSUnix, 1e-6)
	assert.Equal(t, "sender@example.com", rows[1].SenderID)

	// A node with no provenance section yields nil.
	plain := Node{ID: "ent_1", Type: "entity", Body: "# Entity\n\n## What\nA thing.\n"}
	assert.Nil(t, provenanceRows(plain, resolver, nil))

	// A nil resolver (e.g. merge.go's historical call before Task 3, or any
	// caller that doesn't need sender population) leaves every SenderID "".
	rowsNoResolver := provenanceRows(n, nil, nil)
	require.Len(t, rowsNoResolver, 2)
	assert.Equal(t, "", rowsNoResolver[0].SenderID)
	assert.Equal(t, "", rowsNoResolver[1].SenderID)
}

// TestProvenanceRows_SenderLookupErrorIsNotFatal: a sender-lookup error (or a
// clean not-found) never drops the ref or fails the whole row — it only
// leaves SenderID empty for that one ref (this is index-population plumbing
// downstream of MEM-01's write-time validation, not a second validation
// gate; a genuinely invalid ref was already rejected before it was ever
// written).
func TestProvenanceRows_SenderLookupErrorIsNotFatal(t *testing.T) {
	body := "# Ep\n\n## Story\nstuff\n\n## Provenance\n- C0AAA 1700000000.000100\n"
	n := Node{ID: "ep_1", Type: "episode", Body: body}

	var logged []string
	logf := func(format string, args ...any) { logged = append(logged, fmt.Sprintf(format, args...)) }

	rows := provenanceRows(n, fakeSenderResolver{err: errors.New("boom")}, logf)
	require.Len(t, rows, 1, "a sender lookup failure must not drop the ref")
	assert.Equal(t, "", rows[0].SenderID)
	assert.NotEmpty(t, logged, "the lookup failure is logged")
}
```

(`errors` and `fmt` must already be imported in `provenance_test.go`, or added — verify with `head -15 internal/memory/provenance_test.go` at implementation time.)

- [ ] **Step 2: run it — expect a build failure** (new field/params don't exist yet):

```
$ go test ./internal/memory/ ./internal/db/ -run 'TestProvenanceRows|TestMessageSender|TestGmailMessageSender' -v
# watchtower/internal/memory [watchtower/internal/memory.test]
./provenance_test.go:XXX: too many arguments in call to provenanceRows
./provenance_test.go:XXX: rows[0].SenderID undefined (type db.ProvenanceRow has no field or method SenderID)
# watchtower/internal/db [watchtower/internal/db.test]
./memory_test.go:XXX: d.MessageSender undefined (type *DB has no field or method MessageSender)
./memory_test.go:XXX: d.GmailMessageSender undefined (type *DB has no field or method GmailMessageSender)
FAIL	watchtower/internal/memory [build failed]
FAIL	watchtower/internal/db [build failed]
```

- [ ] **Step 3: write the minimal implementation.**

In `internal/db/memory.go`, change `ProvenanceRow` to:

```go
type ProvenanceRow struct {
	NodeID    string
	Scheme    string // "" (Slack), "mail", "cal", "chat", "act"
	ChannelID string // the raw ref channel_id, e.g. "C0AAA" or "mail:<id>"
	TSRaw     string // the ref ts verbatim as rendered in ## Provenance
	TSUnix    float64
	// SenderID is the per-message sender (Slack messages.user_id, Gmail
	// gmail_messages.from_email), populated only for those two schemes —
	// "" for cal:/chat:/act: refs (Slice B, migration 00028). The recency-
	// ordered "what recently happened involving X" query
	// (ListShortTierEpisodesForAliases) filters on this.
	SenderID string
}
```

Change the provenance insert loop to:

```go
	for _, p := range provenance {
		if _, err := tx.Exec(`INSERT INTO memory_provenance
			(node_id, scheme, channel_id, ts_raw, ts_unix, sender_id) VALUES (?, ?, ?, ?, ?, ?)`,
			row.ID, p.Scheme, p.ChannelID, p.TSRaw, p.TSUnix, p.SenderID); err != nil {
			return fmt.Errorf("inserting provenance %s/%s for %s: %w", p.ChannelID, p.TSRaw, row.ID, err)
		}
	}
```

Add two new methods to `internal/db/memory.go` (near `MessageExists`/`GmailMessageExists`):

```go
// MessageSender returns messages.user_id for (channelID, ts) — the Slack
// half of memory_provenance.sender_id population (Slice B). Returns
// sql.ErrNoRows when no such message exists (e.g. deleted since extraction);
// the memory package logs and leaves SenderID empty rather than failing the
// whole provenance row — this is index-population plumbing that runs after
// MessageExists (MEM-01) already validated the ref at write time, not a
// second validation gate.
func (db *DB) MessageSender(channelID, ts string) (string, error) {
	var userID string
	err := db.QueryRow(`SELECT user_id FROM messages WHERE channel_id = ? AND ts = ?`, channelID, ts).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if err != nil {
		return "", fmt.Errorf("getting message sender %s/%s: %w", channelID, ts, err)
	}
	return userID, nil
}

// GmailMessageSender returns gmail_messages.from_email for id — the Gmail
// half of memory_provenance.sender_id population (Slice B). Returns
// sql.ErrNoRows when no such message exists, mirroring MessageSender.
func (db *DB) GmailMessageSender(id string) (string, error) {
	var fromEmail string
	err := db.QueryRow(`SELECT from_email FROM gmail_messages WHERE id = ?`, id).Scan(&fromEmail)
	if errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if err != nil {
		return "", fmt.Errorf("getting gmail message sender %s: %w", id, err)
	}
	return fromEmail, nil
}
```

In `internal/memory/dedupe.go`, add the resolver interface + implementation right before `provenanceRows`, and update `provenanceRows` itself:

```go
// senderResolver resolves a provenance ref's per-message sender id for
// memory_provenance.sender_id (Slice B of the memory-retrieval redesign) —
// mirrors the messageChecker/mailChecker seam (provenance.go) so a resolver
// can be faked in tests without a live database. Only Slack (scheme "") and
// Gmail (scheme "mail") refs have a genuine per-message sender;
// provenanceRows never calls this for any other scheme.
type senderResolver interface {
	SlackSender(channelID, ts string) (string, error)
	MailSender(messageID string) (string, error)
}

// dbSenderResolver is the production senderResolver, backed directly by
// *db.DB. Every real caller of provenanceRows already carries a *db.DB, so
// each call site wraps it inline (dbSenderResolver{database}) — no
// standalone constructor needed.
type dbSenderResolver struct{ db *db.DB }

func (r dbSenderResolver) SlackSender(channelID, ts string) (string, error) {
	return r.db.MessageSender(channelID, ts)
}

func (r dbSenderResolver) MailSender(messageID string) (string, error) {
	return r.db.GmailMessageSender(messageID)
}

// provenanceRows builds the db-layer memory_provenance index rows for a node
// from its ## Provenance section — the single parse site the derived
// provenance index flows through (parseProvenance → classify scheme →
// decode ts → resolve sender), keeping the db layer a dumb store (one parse
// site in memory, one write site in db.UpsertMemoryNode, one transaction).
// Each ref is classified by schemeOf (a bare Slack channel_id is scheme "",
// mail:/cal:/chat:/act: carry their prefix) and its ts decoded to a unix
// float for windowed lookup; a ref whose ts is not numeric cannot be
// windowed and is skipped (logged when logf is non-nil). Refs are deduped by
// (channel_id, ts_raw) so the wholesale insert cannot collide on the
// memory_provenance primary key. A node with no ## Provenance section (every
// non-episode/rollup type) yields nil.
//
// resolver populates SenderID (Slice B) for Slack/Gmail refs only; a nil
// resolver (or a lookup miss/error) leaves SenderID "" for that ref WITHOUT
// dropping it or failing the row — this runs strictly after MEM-01's
// write-time validation already accepted the ref, so a miss here just means
// the source row was deleted afterward, never that the ref was invented.
func provenanceRows(n Node, resolver senderResolver, logf func(string, ...any)) []db.ProvenanceRow {
	refs := parseProvenance(n.Body)
	if len(refs) == 0 {
		return nil
	}
	if logf == nil {
		logf = func(string, ...any) {}
	}
	seen := make(map[string]bool, len(refs))
	var rows []db.ProvenanceRow
	for _, r := range refs {
		key := r.ChannelID + "\x00" + r.TS
		if seen[key] {
			continue
		}
		seen[key] = true
		tsUnix, err := strconv.ParseFloat(strings.TrimSpace(r.TS), 64)
		if err != nil {
			logf("memory: provenance ref %s %s on %s skipped (non-numeric ts, not windowable)", r.ChannelID, r.TS, n.ID)
			continue
		}
		scheme := schemeOf(r.ChannelID)
		rows = append(rows, db.ProvenanceRow{
			NodeID:    n.ID,
			Scheme:    scheme,
			ChannelID: r.ChannelID,
			TSRaw:     r.TS,
			TSUnix:    tsUnix,
			SenderID:  resolveSenderID(resolver, scheme, r, logf, n.ID),
		})
	}
	return rows
}

// resolveSenderID looks up the per-message sender for a Slack or Gmail ref
// (Slice B, memory_provenance.sender_id); every other scheme stays "" and
// never calls resolver. See provenanceRows's doc for the not-fatal policy.
func resolveSenderID(resolver senderResolver, scheme string, r episodeRef, logf func(string, ...any), nodeID string) string {
	if resolver == nil {
		return ""
	}
	var sender string
	var err error
	switch scheme {
	case "":
		sender, err = resolver.SlackSender(r.ChannelID, r.TS)
	case "mail":
		sender, err = resolver.MailSender(strings.TrimPrefix(r.ChannelID, mailRefPrefix))
	default:
		return ""
	}
	if err != nil {
		logf("memory: provenance ref %s %s on %s: sender lookup: %v (left empty)", r.ChannelID, r.TS, nodeID, err)
		return ""
	}
	return sender
}
```

Update the two production call sites:

`internal/memory/index.go:248` — from:

```go
	if err := p.database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, p.logf)...); err != nil {
```

to:

```go
	if err := p.database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, dbSenderResolver{p.database}, p.logf)...); err != nil {
```

`internal/memory/merge.go:168` — from:

```go
	if err := database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, nil)...); err != nil {
```

to:

```go
	if err := database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, dbSenderResolver{database}, nil)...); err != nil {
```

Update the one remaining test call site not already covered by Step 1's rewrite of `provenance_test.go`: `internal/memory/digest_compare_test.go:31` — from:

```go
	}, n.Body, n.Aliases, provenanceRows(n, nil)...))
```

to:

```go
	}, n.Body, n.Aliases, provenanceRows(n, nil, nil)...))
```

(This helper, `indexEpisodeWithProvenance`, has a `*db.DB` in scope as `d` and could pass `dbSenderResolver{d}` for a more faithful test — but its existing tests don't assert on `SenderID`, so passing `nil, nil` is the minimal, behavior-preserving change; a resolver can be added later if a digest-compare test starts asserting on sender.)

- [ ] **Step 4: run it — expect green:**

```
$ go test ./internal/memory/ -run 'TestProvenanceRows' -v
=== RUN   TestProvenanceRows
--- PASS: TestProvenanceRows (0.00s)
=== RUN   TestProvenanceRows_SenderLookupErrorIsNotFatal
--- PASS: TestProvenanceRows_SenderLookupErrorIsNotFatal (0.00s)
PASS
ok  	watchtower/internal/memory	0.2s

$ go test ./internal/db/ -run 'TestMessageSender|TestGmailMessageSender' -v
=== RUN   TestMessageSender
--- PASS: TestMessageSender (0.01s)
=== RUN   TestGmailMessageSender
--- PASS: TestGmailMessageSender (0.01s)
PASS
ok  	watchtower/internal/db	0.2s
```

- [ ] **Step 5: full package + whole-branch guard sanity (MEM-01/02/07/12 must stay green), then commit:**

```
$ go vet ./internal/memory/... ./internal/db/... && go build ./...
$ go test ./internal/memory/ ./internal/db/ 2>&1 | tail -10
ok  	watchtower/internal/db	1.1s
ok  	watchtower/internal/memory	3.8s
$ git add internal/db/memory.go internal/db/memory_test.go internal/memory/dedupe.go internal/memory/index.go internal/memory/merge.go internal/memory/digest_compare_test.go internal/memory/provenance_test.go
$ git commit -m "feat(memory): senderResolver populates memory_provenance.sender_id (Slice B foundation)

provenanceRows gains a senderResolver parameter (mirroring the
messageChecker/mailChecker seam), populated for Slack/Gmail refs only. A
lookup miss or error never drops the ref or fails the row — logged and left
empty, since this runs strictly after MEM-01's write-time validation. Every
call site (index.go, merge.go, and both test call sites) updated."
```

---

## Task 4: `ListShortTierEpisodesForAliases` DB query

**Depends on:** Task 3 (needs `sender_id` populated to have anything to filter on; needs the column to exist at all, which is Task 2). **Blocks:** Task 6 (`RetrieveBySubject`'s short-term half calls it directly).

**Files:**
- Modify: `internal/db/memory.go` — new `ListShortTierEpisodesForAliases`, placed near `ListEpisodesForChannelWindow` (its closest existing precedent)
- Test: `internal/db/memory_test.go` — new `TestListShortTierEpisodesForAliases`

**Interfaces:**
- Consumes: `memory_provenance.sender_id` (Task 3), `memoryNodeSelectCols`/`scanMemoryNodeRow` (existing).
- Produces: `func (db *DB) ListShortTierEpisodesForAliases(aliases []string, limit int) ([]MemoryNodeRow, error)` — consumed by Task 6's `RetrieveBySubject`.

Precedent, current `ListEpisodesForChannelWindow` (`internal/db/memory.go` lines 170–200, in full — the closest existing shape: a `memory_provenance` → `memory_nodes` join, tombstones excluded):

```go
// ListEpisodesForChannelWindow returns the distinct node ids whose
// `## Provenance` refs for channelID fall in the half-open window (fromUnix,
// toUnix] — the episode-window substrate the digest render (Phase-5 5B) queries
// to ask "which episodes cover Slack channel C in [t0,t1]?". Tombstones are
// excluded (a redirected/merged node is not a real episode). Because a Slack
// channel_id carries scheme "" while mail:/cal:/chat:/act: refs carry their
// prefix in channel_id, passing a bare Slack channel_id naturally excludes the
// prefixed-scheme refs. The bound is exclusive-low / inclusive-high so adjacent
// windows tile without double-counting the boundary second.
func (db *DB) ListEpisodesForChannelWindow(channelID string, fromUnix, toUnix float64) ([]string, error) {
	rows, err := db.Query(`SELECT DISTINCT p.node_id
		FROM memory_provenance p
		JOIN memory_nodes n ON n.id = p.node_id
		WHERE p.channel_id = ? AND p.ts_unix > ? AND p.ts_unix <= ?
		  AND n.status != 'tombstone'
		ORDER BY p.node_id`, channelID, fromUnix, toUnix)
	if err != nil {
		return nil, fmt.Errorf("listing episodes for channel %s window (%v,%v]: %w", channelID, fromUnix, toUnix, err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning episode window row: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
```

The new query needs full `MemoryNodeRow`s (not bare ids), a `sender_id IN (...)` filter, dedup-by-node-id (a node can carry multiple matching provenance refs), and `ORDER BY` recency. `ListDisputePendingBeliefs` (lines 333–357) is the precedent for reusing `memoryNodeSelectCols`/`scanMemoryNodeRow` unaliased against a bare `memory_nodes` table joined to something else — that shape is reused here via a derived table that pre-aggregates the max `ts_unix` per node (GROUP BY, chosen over `SELECT DISTINCT` because it also carries the recency-ordering key out of the join in one pass, avoiding a second aggregate step).

- [ ] **Step 1: write the failing test** — add to `internal/db/memory_test.go` after `TestMemoryNodeImportanceScoreRoundTrip` (or wherever Task 3's new tests landed — confirm the real anchor at implementation time):

```go
// seedProvenance is a small test helper: inserts one memory_provenance row
// directly (bypassing the memory package's provenanceRows), for tests that
// only need the DB-layer index populated, not a real vault file.
func seedProvenanceRow(t *testing.T, d *DB, nodeID, channelID, tsRaw string, tsUnix float64, senderID string) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO memory_provenance (node_id, scheme, channel_id, ts_raw, ts_unix, sender_id)
		VALUES (?, '', ?, ?, ?, ?)`, nodeID, channelID, tsRaw, tsUnix, senderID); err != nil {
		t.Fatalf("seeding provenance row for %s: %v", nodeID, err)
	}
}

// TestListShortTierEpisodesForAliases: recency-ordered short-tier episodes
// whose provenance sender_id matches one of the given aliases (Slice B).
// Long-tier episodes, tombstones, and episodes with no matching sender are
// excluded; a node with multiple matching provenance rows appears once,
// ordered by its MOST RECENT matching ref.
func TestListShortTierEpisodesForAliases(t *testing.T) {
	d := openTestDB(t)

	mustUpsert := func(row MemoryNodeRow) {
		t.Helper()
		if err := d.UpsertMemoryNode(row, row.ID+" body", nil); err != nil {
			t.Fatalf("UpsertMemoryNode %s: %v", row.ID, err)
		}
	}
	mustUpsert(memTestNode("ep_recent", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "short" }))
	mustUpsert(memTestNode("ep_older", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "short" }))
	mustUpsert(memTestNode("ep_long_tier", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "long" }))
	mustUpsert(memTestNode("ep_tombstoned", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "short"; r.Status = "tombstone" }))
	mustUpsert(memTestNode("ep_other_sender", func(r *MemoryNodeRow) { r.Type = "episode"; r.Tier = "short" }))

	seedProvenanceRow(t, d, "ep_recent", "C1", "200.0", 200.0, "U1")
	seedProvenanceRow(t, d, "ep_older", "C1", "100.0", 100.0, "U1")
	// ep_recent also has an OLDER ref from the same sender — must still be
	// deduped to one row, ordered by its most recent ref.
	seedProvenanceRow(t, d, "ep_recent", "C1", "50.0", 50.0, "U1")
	seedProvenanceRow(t, d, "ep_long_tier", "C1", "300.0", 300.0, "U1")     // wrong tier, excluded
	seedProvenanceRow(t, d, "ep_tombstoned", "C1", "400.0", 400.0, "U1")   // tombstone, excluded
	seedProvenanceRow(t, d, "ep_other_sender", "C1", "500.0", 500.0, "U2") // wrong sender, excluded

	got, err := d.ListShortTierEpisodesForAliases([]string{"U1"}, 10)
	if err != nil {
		t.Fatalf("ListShortTierEpisodesForAliases: %v", err)
	}
	var ids []string
	for _, r := range got {
		ids = append(ids, r.ID)
	}
	if len(ids) != 2 || ids[0] != "ep_recent" || ids[1] != "ep_older" {
		t.Fatalf("ListShortTierEpisodesForAliases ids = %v, want [ep_recent ep_older] in that order", ids)
	}

	// Empty aliases: no query, clean empty result.
	empty, err := d.ListShortTierEpisodesForAliases(nil, 10)
	if err != nil || len(empty) != 0 {
		t.Fatalf("ListShortTierEpisodesForAliases(nil) = (%v, %v), want (empty, nil)", empty, err)
	}

	// Limit truncates to the most recent.
	limited, err := d.ListShortTierEpisodesForAliases([]string{"U1"}, 1)
	if err != nil || len(limited) != 1 || limited[0].ID != "ep_recent" {
		t.Fatalf("ListShortTierEpisodesForAliases limit=1 = %+v, want just ep_recent", limited)
	}
}
```

- [ ] **Step 2: run it — expect a build failure** (the method doesn't exist yet):

```
$ go test ./internal/db/ -run TestListShortTierEpisodesForAliases -v
# watchtower/internal/db [watchtower/internal/db.test]
./memory_test.go:XXX: d.ListShortTierEpisodesForAliases undefined (type *DB has no field or method ListShortTierEpisodesForAliases)
FAIL	watchtower/internal/db [build failed]
```

- [ ] **Step 3: write the minimal implementation** — add to `internal/db/memory.go`, near `ListEpisodesForChannelWindow`:

```go
// ListShortTierEpisodesForAliases returns short-tier, non-tombstone episode
// rows whose memory_provenance.sender_id matches one of aliases, ordered by
// each node's MOST RECENT matching ref (recency, not importance — a
// short-tier episode's value here is "what recently happened," see Slice B
// design spec §3). A node with multiple matching provenance rows (e.g. two
// refs from the same Slack user) appears once via the per-node MAX(ts_unix)
// derived table, mirroring ListDisputePendingBeliefs's unaliased
// memoryNodeSelectCols-against-bare-memory_nodes shape. Empty aliases is a
// clean empty read (nil, nil) — no query runs.
func (db *DB) ListShortTierEpisodesForAliases(aliases []string, limit int) ([]MemoryNodeRow, error) {
	if len(aliases) == 0 {
		return nil, nil
	}
	if limit <= 0 {
		limit = -1 // SQLite: LIMIT -1 is unbounded (ListDisputePendingBeliefs precedent)
	}
	placeholders, args := inClause(aliases)
	args = append(args, limit)
	rows, err := db.Query(`SELECT `+memoryNodeSelectCols+`
		FROM memory_nodes
		JOIN (
			SELECT node_id, MAX(ts_unix) AS max_ts
			FROM memory_provenance
			WHERE sender_id IN (`+placeholders+`)
			GROUP BY node_id
		) latest ON latest.node_id = memory_nodes.id
		WHERE memory_nodes.tier = 'short' AND memory_nodes.status != 'tombstone'
		ORDER BY latest.max_ts DESC
		LIMIT ?`, args...)
	if err != nil {
		return nil, fmt.Errorf("listing short-tier episodes for aliases: %w", err)
	}
	defer rows.Close()

	var out []MemoryNodeRow
	for rows.Next() {
		row, err := scanMemoryNodeRow(rows.Scan)
		if err != nil {
			return nil, fmt.Errorf("scanning short-tier episode for aliases: %w", err)
		}
		out = append(out, row)
	}
	return out, rows.Err()
}
```

- [ ] **Step 4: run it — expect green:**

```
$ go test ./internal/db/ -run TestListShortTierEpisodesForAliases -v
=== RUN   TestListShortTierEpisodesForAliases
--- PASS: TestListShortTierEpisodesForAliases (0.01s)
PASS
ok  	watchtower/internal/db	0.2s
```

- [ ] **Step 5: full package sanity + commit:**

```
$ go vet ./internal/db/... && go build ./...
$ go test ./internal/db/ 2>&1 | tail -5
ok  	watchtower/internal/db	1.2s
$ git add internal/db/memory.go internal/db/memory_test.go
$ git commit -m "feat(db): ListShortTierEpisodesForAliases (Slice B foundation)

Recency-ordered short-tier episodes by memory_provenance.sender_id,
deduped per node via a MAX(ts_unix) derived table. Empty aliases is a
clean no-query read."
```

---

## Task 5: `RetrieveByQuery`

**Depends on:** Task 1 (`RankByImportance`). **Blocks:** nothing further in this half (Task 6 is independent of Task 5, though both live in `retrieve.go`).

**Files:**
- Modify: `internal/db/memory.go` — new `MemoryFTSCandidate` type + `SearchMemoryFTSCandidates`, placed right after `SearchMemoryFTS` (lines 412–445)
- Modify: `internal/memory/retrieve.go` — new `RetrieveByQuery` + `normalizeFTSRank`
- Test: `internal/db/memory_test.go` (new `TestSearchMemoryFTSCandidates`), `internal/memory/retrieve_test.go` (new `TestRetrieveByQuery*`, `TestNormalizeFTSRank*`)

**Interfaces:**
- Consumes: `RankByImportance` (Task 1), `memoryNodeSelectCols`/`scanMemoryNodeRow` (existing).
- Produces: `db.MemoryFTSCandidate`, `db.SearchMemoryFTSCandidates`, `memory.RetrieveByQuery` — consumed by nothing outside this half's own tests (the MCP wiring is a later task).

Current `SearchMemoryFTS` (`internal/db/memory.go` lines 412–445, in full — **left completely unchanged**, quoted only as the sibling this task's new function mirrors):

```go
// SearchMemoryFTS runs a full-text search over node titles and bodies,
// excluding tombstones. The query is sanitized the same way as message search
// (each term double-quoted) so user input cannot inject FTS5 operators.
func (db *DB) SearchMemoryFTS(query string, limit int) ([]MemoryHit, error) {
	sanitized := sanitizeFTS5Query(query)
	if sanitized == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 20
	}

	rows, err := db.Query(`SELECT n.id, n.title, n.type,
			snippet(memory_fts, -1, '', '', '…', 12)
		FROM memory_fts fts
		JOIN memory_nodes n ON n.id = fts.id
		WHERE memory_fts MATCH ? AND n.status != 'tombstone'
		ORDER BY rank
		LIMIT ?`, sanitized, limit)
	if err != nil {
		return nil, fmt.Errorf("searching memory fts: %w", err)
	}
	defer rows.Close()

	var hits []MemoryHit
	for rows.Next() {
		var h MemoryHit
		if err := rows.Scan(&h.ID, &h.Title, &h.Type, &h.Snippet); err != nil {
			return nil, fmt.Errorf("scanning memory hit: %w", err)
		}
		hits = append(hits, h)
	}
	return hits, rows.Err()
}
```

**Design decision (why a new function, not extending `SearchMemoryFTS`):** `SearchMemoryFTS` returns `MemoryHit` — a UI/MCP-shaped projection (id/title/type/snippet) that `memory_recall` still needs unchanged in this half (it stays the legacy, live path — MEM-05/14 precedent from `digest_compare.go`: the compare is additive, never a modification of what's authoritative). `RetrieveByQuery` needs the FULL row (`importance_score` for `RankByImportance`) plus the raw rank — a structurally different shape. Bolting both onto one function via an extra bool/option param would blur "the legacy path" and "the Slice-B candidate path" together, exactly the anti-pattern the design spec's Non-Goals section rules out ("A general-purpose plugin/selector architecture... YAGNI"). A sibling function, `SearchMemoryFTSCandidates`, is the cleaner fix — same sanitize + `MATCH`, different SELECT list, reusing `scanMemoryNodeRow` via a closure that appends the extra `rank` scan target.

- [ ] **Step 1: write the failing tests.**

`internal/db/memory_test.go` (after `TestUpsertMemoryNodeRoundTrip`'s FTS assertions or near any existing `SearchMemoryFTS` test — confirm anchor with `grep -n 'func TestSearchMemoryFTS' internal/db/memory_test.go`):

```go
// TestSearchMemoryFTSCandidates: same sanitized MATCH as SearchMemoryFTS, but
// returns full MemoryNodeRows (importance_score included) plus the raw rank,
// best-match-first — SearchMemoryFTS itself is untouched (still
// memory_recall's legacy path).
func TestSearchMemoryFTSCandidates(t *testing.T) {
	d := openTestDB(t)

	strong := memTestNode("ent_strong", func(r *MemoryNodeRow) { r.ImportanceScore = 1 })
	weak := memTestNode("ent_weak", func(r *MemoryNodeRow) { r.ImportanceScore = 9 })
	if err := d.UpsertMemoryNode(strong, "deployments deployments deployments rollout", nil); err != nil {
		t.Fatalf("UpsertMemoryNode strong: %v", err)
	}
	if err := d.UpsertMemoryNode(weak, "deployments happened once, briefly", nil); err != nil {
		t.Fatalf("UpsertMemoryNode weak: %v", err)
	}

	cands, err := d.SearchMemoryFTSCandidates("deployments", 10)
	if err != nil {
		t.Fatalf("SearchMemoryFTSCandidates: %v", err)
	}
	if len(cands) != 2 {
		t.Fatalf("SearchMemoryFTSCandidates returned %d candidates, want 2", len(cands))
	}
	// Best FTS match (more mentions of the term) ranks first, REGARDLESS of
	// importance_score — this function does not re-rank; RetrieveByQuery does.
	if cands[0].Row.ID != "ent_strong" {
		t.Errorf("cands[0].Row.ID = %q, want ent_strong (strongest FTS match)", cands[0].Row.ID)
	}
	if cands[0].Row.ImportanceScore != 1 {
		t.Errorf("cands[0].Row.ImportanceScore = %v, want 1 (the full row, not just id/title)", cands[0].Row.ImportanceScore)
	}
	// A better match has a MORE NEGATIVE (smaller) rank.
	if !(cands[0].Rank < cands[1].Rank) {
		t.Errorf("cands[0].Rank = %v, cands[1].Rank = %v; want cands[0] (better match) more negative", cands[0].Rank, cands[1].Rank)
	}
}
```

`internal/memory/retrieve_test.go` (append):

```go
// TestNormalizeFTSRank: SQLite FTS5's default rank is bm25-style — more
// NEGATIVE is a BETTER match. normalizeFTSRank must map that into a
// Relevance that INCREASES with match quality, staying in [0, 1).
func TestNormalizeFTSRank(t *testing.T) {
	strongMatch := normalizeFTSRank(-8.0) // very negative = strong match
	weakMatch := normalizeFTSRank(-1.0)   // mildly negative = weak match
	noMatch := normalizeFTSRank(0.0)      // degenerate edge case

	assert.Greater(t, strongMatch, weakMatch, "a more negative rank must normalize to a HIGHER relevance")
	assert.Greater(t, weakMatch, noMatch, "any negative rank beats the zero-rank edge case")
	assert.Zero(t, noMatch)
	assert.Less(t, strongMatch, 1.0, "relevance must stay bounded below 1")
	assert.GreaterOrEqual(t, weakMatch, 0.0)

	// Concrete worked values, so a future refactor can't silently invert the
	// sign again: rank=-1 -> x=1 -> 1/2 = 0.5; rank=-8 -> x=8 -> 8/9 = 0.8889.
	assert.InDelta(t, 0.5, weakMatch, 1e-9)
	assert.InDelta(t, 8.0/9.0, strongMatch, 1e-9)
}

func TestRetrieveByQuery(t *testing.T) {
	d := newTestDB(t)

	important := memTestNodeMemory("ent_important", func(r *db.MemoryNodeRow) { r.ImportanceScore = 10 })
	trivial := memTestNodeMemory("ent_trivial", func(r *db.MemoryNodeRow) { r.ImportanceScore = 0.1 })
	// Give the TRIVIAL node the stronger raw FTS match (more term repetition)
	// so a pure-rank ordering would put it first — RetrieveByQuery must not,
	// because importance x relevance favors the important node once both are
	// inside the candidate window.
	require.NoError(t, d.UpsertMemoryNode(important, "widget rollout status update", nil))
	require.NoError(t, d.UpsertMemoryNode(trivial, "widget widget widget widget", nil))

	got, err := RetrieveByQuery(d, "widget", 2)
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "ent_important", got[0].ID, "importance x relevance must outrank a purely stronger keyword match")
}
```

`memTestNodeMemory` is a small local helper this test file needs (mirroring `internal/db/memory_test.go`'s `memTestNode`, since `internal/memory`'s tests build `db.MemoryNodeRow` values directly too, e.g. via `newTestDB`'s callers) — add it once, next to `candRow` in `retrieve_test.go`:

```go
// memTestNodeMemory is retrieve_test.go's own memTestNode-equivalent (the
// helper itself is internal/db-scoped and cannot be imported), building a
// minimal valid entity row for RetrieveByQuery/RetrieveBySubject tests.
func memTestNodeMemory(id string, mutate func(*db.MemoryNodeRow)) db.MemoryNodeRow {
	row := db.MemoryNodeRow{
		ID: id, Type: "entity", Tier: "long", Status: "active",
		Title: "Test " + id, Path: "entities/" + id + ".md",
		ContentHash: "hash-" + id, IndexedAt: "2026-07-20T00:00:00Z",
	}
	if mutate != nil {
		mutate(&row)
	}
	return row
}
```

- [ ] **Step 2: run it — expect a build failure:**

```
$ go test ./internal/db/ ./internal/memory/ -run 'TestSearchMemoryFTSCandidates|TestNormalizeFTSRank|TestRetrieveByQuery' -v
# watchtower/internal/db [watchtower/internal/db.test]
./memory_test.go:XXX: d.SearchMemoryFTSCandidates undefined (type *DB has no field or method SearchMemoryFTSCandidates)
# watchtower/internal/memory [watchtower/internal/memory.test]
./retrieve_test.go:XXX: undefined: normalizeFTSRank
./retrieve_test.go:XXX: undefined: RetrieveByQuery
FAIL	watchtower/internal/db [build failed]
FAIL	watchtower/internal/memory [build failed]
```

- [ ] **Step 3: write the minimal implementation.**

In `internal/db/memory.go`, add right after `SearchMemoryFTS`:

```go
// MemoryFTSCandidate is one full-text search candidate carrying its full
// indexed row (importance_score included) plus the raw FTS5 rank — the
// wider candidate window RetrieveByQuery (Slice B) re-ranks through
// RankByImportance. Sibling of MemoryHit, which stays the shape
// SearchMemoryFTS/memory_recall use unchanged.
type MemoryFTSCandidate struct {
	Row  MemoryNodeRow
	Rank float64
}

// SearchMemoryFTSCandidates runs the same sanitized FTS5 MATCH as
// SearchMemoryFTS but returns full MemoryNodeRows plus the raw rank,
// best-match-first (ORDER BY rank ascending — SQLite FTS5's bm25-style rank
// is more negative for a better match, the same convention SearchMemoryFTS
// already relies on). SearchMemoryFTS itself is UNCHANGED — this is a new
// sibling, not a modification, so memory_recall's legacy path is untouched
// in this half (Slice B, RetrieveByQuery).
func (db *DB) SearchMemoryFTSCandidates(query string, limit int) ([]MemoryFTSCandidate, error) {
	sanitized := sanitizeFTS5Query(query)
	if sanitized == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 20
	}

	rows, err := db.Query(`SELECT `+memoryNodeSelectCols+`, fts.rank
		FROM memory_fts fts
		JOIN memory_nodes ON memory_nodes.id = fts.id
		WHERE memory_fts MATCH ? AND memory_nodes.status != 'tombstone'
		ORDER BY fts.rank
		LIMIT ?`, sanitized, limit)
	if err != nil {
		return nil, fmt.Errorf("searching memory fts candidates: %w", err)
	}
	defer rows.Close()

	var out []MemoryFTSCandidate
	for rows.Next() {
		var rank float64
		row, err := scanMemoryNodeRow(func(dest ...any) error {
			return rows.Scan(append(dest, &rank)...)
		})
		if err != nil {
			return nil, fmt.Errorf("scanning memory fts candidate: %w", err)
		}
		out = append(out, MemoryFTSCandidate{Row: row, Rank: rank})
	}
	return out, rows.Err()
}
```

In `internal/memory/retrieve.go`, add:

```go
// candidateWindowMultiplier widens the FTS candidate pool before importance
// re-ranking (Slice B): fetching only `limit` best-bm25-rank rows would
// never give a high-importance-but-slightly-weaker-match node a chance to
// outrank a trivially-better-ranked but unimportant one, because it would
// never make the window at all. maxCandidateWindow caps the widened window
// (mirrors internal/mcp/server.go's maxListLimit=200 — a single query should
// never scan an effectively unbounded result set).
const candidateWindowMultiplier = 4
const maxCandidateWindow = 200

// RetrieveByQuery replaces memory_recall's pure-FTS-rank ordering with
// importance x relevance (Slice B): it fetches a wider candidate window
// (limit*4, capped at 200) via SearchMemoryFTSCandidates, normalizes each
// row's raw rank into a Relevance via normalizeFTSRank, and re-ranks through
// RankByImportance.
//
// The exact-alias-match short-circuit stays memory_recall's own concern
// (recallAliasHit, internal/mcp/memory.go) — a LATER task wires the MCP
// handler to prepend that hit ahead of this function's results, exactly as
// it prepends today ahead of SearchMemoryFTS's results. This function is
// pure FTS ranking; it knows nothing about aliases.
func RetrieveByQuery(database *db.DB, query string, limit int) ([]db.MemoryNodeRow, error) {
	window := limit * candidateWindowMultiplier
	if window <= 0 || window > maxCandidateWindow {
		window = maxCandidateWindow
	}
	cands, err := database.SearchMemoryFTSCandidates(query, window)
	if err != nil {
		return nil, fmt.Errorf("memory: retrieve by query: %w", err)
	}
	scored := make([]ScoredCandidate, len(cands))
	for i, c := range cands {
		scored[i] = ScoredCandidate{Row: c.Row, Relevance: normalizeFTSRank(c.Rank)}
	}
	return RankByImportance(scored, limit), nil
}

// normalizeFTSRank maps SQLite FTS5's default rank (== bm25(): more NEGATIVE
// is a BETTER match; SearchMemoryFTS's plain `ORDER BY rank` already relies
// on this ascending-is-best convention) into a Relevance in [0, 1),
// monotonically INCREASING with match quality.
//
// The naive `1/(1+rank)` the design spec floated is WRONG: for a strong
// match rank is very negative (e.g. -8), giving 1/(1-8) = 1/-7 — a NEGATIVE
// relevance that also flips sign relative to a weak match's 1/(1-1)=0.5,
// inverting the whole ranking. The correct transform operates on
// x := -rank (>= 0 for every real match; a STRONGER match has a LARGER x):
//
//	relevance = x / (1 + x)
//
// This is monotonically increasing in x, bounded in [0, 1), and never
// negative. rank == 0 (a degenerate edge case FTS5's real bm25 output should
// never actually produce for a MATCHing row) yields relevance 0 — sorting
// last, consistent with RankByImportance's own zero-relevance floor.
func normalizeFTSRank(rank float64) float64 {
	x := -rank
	if x < 0 {
		x = 0 // defensive: a positive rank must never be treated as "better than a match"
	}
	return x / (1 + x)
}
```

Add `"fmt"` to `internal/memory/retrieve.go`'s imports (used by `RetrieveByQuery`'s error wrap) alongside the existing `"sort"` and `"watchtower/internal/db"`.

- [ ] **Step 4: run it — expect green:**

```
$ go test ./internal/db/ ./internal/memory/ -run 'TestSearchMemoryFTSCandidates|TestNormalizeFTSRank|TestRetrieveByQuery' -v
=== RUN   TestSearchMemoryFTSCandidates
--- PASS: TestSearchMemoryFTSCandidates (0.01s)
PASS
ok  	watchtower/internal/db	0.2s
=== RUN   TestNormalizeFTSRank
--- PASS: TestNormalizeFTSRank (0.00s)
=== RUN   TestRetrieveByQuery
--- PASS: TestRetrieveByQuery (0.01s)
PASS
ok  	watchtower/internal/memory	0.3s
```

- [ ] **Step 5: full package sanity + commit:**

```
$ go vet ./internal/db/... ./internal/memory/... && go build ./...
$ go test ./internal/db/ ./internal/memory/ 2>&1 | tail -10
ok  	watchtower/internal/db	1.3s
ok  	watchtower/internal/memory	4.1s
$ git add internal/db/memory.go internal/db/memory_test.go internal/memory/retrieve.go internal/memory/retrieve_test.go
$ git commit -m "feat(memory): RetrieveByQuery — importance x relevance over FTS (Slice B foundation)

SearchMemoryFTSCandidates is a new sibling of SearchMemoryFTS (full rows +
raw rank, not the MemoryHit projection); SearchMemoryFTS itself is
unchanged and stays memory_recall's live path. normalizeFTSRank maps
FTS5's more-negative-is-better rank into an increasing (0,1) Relevance —
the naive 1/(1+rank) the design spec floated would have inverted the sign
for a strong (very negative) match; documented with worked values.
Not wired into memory_recall yet (a later task)."
```

---

## Task 6: `RetrieveBySubject` and `RetrieveRevisions`

**Depends on:** Task 1 (`RankByImportance`), Task 4 (`ListShortTierEpisodesForAliases`, for `RetrieveBySubject`'s short-term half). **Blocks:** nothing further in this half.

**Files:**
- Modify: `internal/db/memory.go` — new `ListBeliefsForSubjects`, placed near `ListDisputePendingBeliefs`
- Modify: `internal/memory/beliefs.go` — new exported `NotableRevision`/`RevisionNotability` + relocated (now-unexported, in this package) `historyEntriesSince`/`describeChange`/`confidenceNotableDelta`; `"math"` added to imports
- Modify: `internal/briefing/memory_revisions.go` — deletes the four relocated symbols, calls `memory.NotableRevision` instead; `gatherMemoryRevisions` itself keeps its exact current logic/output
- Modify: `internal/memory/retrieve.go` — new `RetrieveBySubject`, `RetrieveRevisions`
- Test: `internal/db/memory_test.go` (new `TestListBeliefsForSubjects`), `internal/memory/beliefs_test.go` (**this file already exists** — `package memory`, already imports `testing`/`time`/`assert`/`require`; APPEND the new `TestNotableRevision*` tests to it, do not create a new file or re-declare its package/imports), `internal/memory/retrieve_test.go` (new `TestRetrieveBySubject*`, `TestRetrieveRevisions*`)

**Interfaces:**
- Consumes: `RankByImportance` (Task 1), `ListShortTierEpisodesForAliases` (Task 4), `ParseHistory`/`HistoryBullet` (existing, `beliefs.go`).
- Produces: `func RetrieveBySubject(database *db.DB, subjects []string, limitLong, limitShort int) (longTerm, shortTerm []db.MemoryNodeRow, err error)`, `func RetrieveRevisions(database *db.DB, v *Vault, sinceTS float64, limit int) ([]db.MemoryNodeRow, error)`, `type RevisionNotability struct{ Line string; Magnitude float64 }`, `func NotableRevision(node Node, since time.Time) (RevisionNotability, bool)` — consumed by nothing outside this half's own tests (meeting-prep/briefing wiring is a later task).

### 6a. Relocating `notableRevision` — the import-direction check

**Verification (done during research for this plan, re-verify at implementation time with the same commands):**

```
$ grep -rln "internal/briefing" internal/memory/
(no output — internal/memory does NOT import internal/briefing today)

$ grep -n '"watchtower/internal/memory"' internal/briefing/memory_revisions.go
10:	"watchtower/internal/memory"
```

So `internal/briefing` already imports `internal/memory` (for `memory.OpenExistingVault`, `memory.Node`, `memory.ParseHistory`, `memory.HistoryBullet`) and `internal/memory` imports nothing from `internal/briefing`. **Moving `notableRevision` (+ its three private helpers) INTO `internal/memory` and having `briefing` call the exported version is therefore the only direction that doesn't introduce a cycle** — it widens an existing, correctly-directed dependency rather than adding a new one. The reverse (leaving the logic in `briefing`, having `memory` call into it) is impossible without breaking the existing direction, and duplicating the logic would let the two copies drift — explicitly rejected by the task brief.

Current `internal/briefing/memory_revisions.go` (relevant excerpt, lines 19–27 and 107–189, in full — everything that moves):

```go
// confidenceNotableDelta is the |confidence| move within the window that makes a
// non-status revision worth surfacing. Beliefs move in 0.1 steps, so this is two
// net steps in one direction.
const confidenceNotableDelta = 0.2
```

```go
// notableRevision inspects one belief's ## History for entries dated on or after
// since and, when the aggregate change is notable, renders a single journal line:
//
//	<belief title> — <what changed> — because <evidence digest>
//
// Notability (code-side filter): any status transition (shake/retire) or belief
// creation always qualifies; otherwise a summed |confidence| move of >=0.2 across
// the window's confirm/weaken entries qualifies. Returns ok=false when no in-
// window entry is notable.
func notableRevision(node memory.Node, since time.Time) (string, bool) {
	entries := historyEntriesSince(node.Body, since)
	if len(entries) == 0 {
		return "", false
	}

	statusNotable := false
	confDelta := 0.0
	for _, e := range entries {
		switch e.Cause {
		case "shake", "retire", "created", "propose-new":
			statusNotable = true
		case "confirm":
			confDelta += 0.1
		case "weaken":
			confDelta -= 0.1
		}
	}

	if !statusNotable && math.Abs(confDelta) < confidenceNotableDelta {
		return "", false
	}

	tail := entries[len(entries)-1]
	title := strings.TrimSpace(node.Title)
	if title == "" {
		title = node.ID
	}
	digest := tail.Rationale
	if digest == "" {
		digest = "recent evidence"
	}
	return title + " — " + describeChange(tail.Cause, confDelta) + " — because " + digest, true
}

// historyEntriesSince returns the belief ## History bullets dated on or after
// since, in file order (oldest first). It delegates parsing to the single
// memory.ParseHistory reader (the counterpart of memory.historyLine) and only
// filters by date; date comparison is day-granular via lexical YYYY-MM-DD
// ordering.
func historyEntriesSince(body string, since time.Time) []memory.HistoryBullet {
	sinceDate := since.Format("2006-01-02")
	var entries []memory.HistoryBullet
	for _, b := range memory.ParseHistory(body) {
		if b.Date >= sinceDate {
			entries = append(entries, b)
		}
	}
	return entries
}

// describeChange renders the human "what changed" clause for a journal line.
func describeChange(cause string, confDelta float64) string {
	switch cause {
	case "shake":
		return "belief shaken — evidence now conflicts"
	case "retire":
		return "belief retired"
	case "created", "propose-new":
		return "new belief formed"
	case "confirm":
		return "confidence strengthened"
	case "weaken":
		return "confidence weakened"
	default:
		if confDelta > 0 {
			return "confidence strengthened"
		}
		if confDelta < 0 {
			return "confidence weakened"
		}
		return "belief revised"
	}
}
```

And the one call site inside `gatherMemoryRevisions` (lines 71–76) that must keep behaving identically:

```go
		if line, ok := notableRevision(node, since); ok {
			lines = append(lines, line)
			if len(lines) >= maxMemoryRevisions {
				break
			}
		}
```

### 6b. Steps

- [ ] **Step 1: write the failing tests.**

First, confirm `notableRevision`/`historyEntriesSince`/`describeChange` have no direct unit tests in `internal/briefing` today (only indirect coverage via `gatherMemoryRevisions`'s tests, which stay in place and keep passing unchanged):

```
$ grep -rn "func Test" internal/briefing/memory_revisions_test.go
126:func TestGatherMemoryRevisions_StatusTransitionSurfaces(t *testing.T) {
141:func TestGatherMemoryRevisions_SubThresholdConfidenceWiggleOmitted(t *testing.T) {
156:func TestGatherMemoryRevisions_CapsAtFive(t *testing.T) {
177:func TestGatherMemoryRevisions_GateOffRendersPlaceholder(t *testing.T) {
192:func TestBriefingDailyVersionBumpedToSix(t *testing.T) {
```

Confirmed: every existing test targets `gatherMemoryRevisions` itself (the function that is NOT moving), not `notableRevision` directly — so nothing needs relocating from `internal/briefing`, only fresh direct tests need adding for the newly-exported `NotableRevision`.

**`internal/memory/beliefs_test.go` already exists** (478 lines, `package memory`, already imports `"testing"`, `"time"`, `assert`, `require` — do not re-declare the package or add a second import block). Append these new tests to it:

```go
// beliefBodyWithHistory builds a minimal belief body with a ## History
// section from raw "YYYY-MM-DD: cause[ — rationale]" lines, for
// NotableRevision tests.
func beliefBodyWithHistory(lines ...string) string {
	body := "# Test Belief\n\n## History\n"
	for _, l := range lines {
		body += "- " + l + "\n"
	}
	return body
}

func TestNotableRevision_StatusTransitionIsAlwaysNotable(t *testing.T) {
	since := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	node := Node{ID: "bel_x", Title: "X", Body: beliefBodyWithHistory("2026-07-10: shake — new conflicting evidence")}

	nr, ok := NotableRevision(node, since)
	require.True(t, ok)
	assert.Equal(t, 1.0, nr.Magnitude, "a status transition is unconditionally maximal relevance")
	assert.Contains(t, nr.Line, "X")
	assert.Contains(t, nr.Line, "shaken")
}

func TestNotableRevision_ConfidenceDeltaBelowThresholdIsNotNotable(t *testing.T) {
	since := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	node := Node{ID: "bel_x", Title: "X", Body: beliefBodyWithHistory("2026-07-10: confirm — more evidence")}

	_, ok := NotableRevision(node, since)
	assert.False(t, ok, "a single 0.1 confirm is below the 0.2 notability threshold")
}

func TestNotableRevision_ConfidenceDeltaMagnitudeFeedsRelevance(t *testing.T) {
	since := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	node := Node{ID: "bel_x", Title: "X", Body: beliefBodyWithHistory(
		"2026-07-10: confirm — evidence A",
		"2026-07-11: confirm — evidence B",
		"2026-07-12: confirm — evidence C",
	)}

	nr, ok := NotableRevision(node, since)
	require.True(t, ok)
	assert.InDelta(t, 0.3, nr.Magnitude, 1e-9, "three 0.1 confirms sum to a 0.3 magnitude, not clamped to 1.0")
}

func TestNotableRevision_NoEntriesInWindowIsNotNotable(t *testing.T) {
	since := time.Date(2026, 7, 15, 0, 0, 0, 0, time.UTC)
	node := Node{ID: "bel_x", Title: "X", Body: beliefBodyWithHistory("2026-07-01: confirm — stale evidence")}

	_, ok := NotableRevision(node, since)
	assert.False(t, ok, "an entry before the window start does not count")
}
```

`internal/db/memory_test.go` (near `TestMemoryNodeSubjectConfidenceRoundTrip`/`ListDisputePendingBeliefs`'s tests):

```go
func TestListBeliefsForSubjects(t *testing.T) {
	d := openTestDB(t)

	mustUpsert := func(row MemoryNodeRow) {
		t.Helper()
		if err := d.UpsertMemoryNode(row, "body", nil); err != nil {
			t.Fatalf("UpsertMemoryNode %s: %v", row.ID, err)
		}
	}
	mustUpsert(memTestNode("bel_active", func(r *MemoryNodeRow) { r.Type = "belief"; r.Subject = "ent_alice"; r.Status = "active" }))
	mustUpsert(memTestNode("bel_shaken", func(r *MemoryNodeRow) { r.Type = "belief"; r.Subject = "ent_alice"; r.Status = "shaken" }))
	mustUpsert(memTestNode("bel_retired", func(r *MemoryNodeRow) { r.Type = "belief"; r.Subject = "ent_alice"; r.Status = "retired" }))
	mustUpsert(memTestNode("bel_other_subject", func(r *MemoryNodeRow) { r.Type = "belief"; r.Subject = "ent_bob"; r.Status = "active" }))
	mustUpsert(memTestNode("ent_alice", func(r *MemoryNodeRow) { r.Type = "entity" }))

	got, err := d.ListBeliefsForSubjects([]string{"ent_alice"})
	if err != nil {
		t.Fatalf("ListBeliefsForSubjects: %v", err)
	}
	var ids []string
	for _, r := range got {
		ids = append(ids, r.ID)
	}
	if len(ids) != 2 {
		t.Fatalf("ListBeliefsForSubjects = %v, want exactly [bel_active bel_shaken] (retired excluded, other-subject excluded, entity excluded)", ids)
	}
	for _, want := range []string{"bel_active", "bel_shaken"} {
		found := false
		for _, id := range ids {
			found = found || id == want
		}
		if !found {
			t.Errorf("ListBeliefsForSubjects missing %s", want)
		}
	}
}
```

`internal/memory/retrieve_test.go` (append):

```go
func TestRetrieveBySubject(t *testing.T) {
	d := newTestDB(t)

	important := memTestNodeMemory("bel_important", func(r *db.MemoryNodeRow) {
		r.Type, r.Subject, r.Status, r.ImportanceScore = "belief", "ent_x", "active", 10
	})
	trivial := memTestNodeMemory("bel_trivial", func(r *db.MemoryNodeRow) {
		r.Type, r.Subject, r.Status, r.ImportanceScore = "belief", "ent_x", "shaken", 0.1
	})
	require.NoError(t, d.UpsertMemoryNode(important, "body", nil))
	require.NoError(t, d.UpsertMemoryNode(trivial, "body", nil))

	longTerm, shortTerm, err := RetrieveBySubject(d, []string{"ent_x"}, 5, 5)
	require.NoError(t, err)
	require.Len(t, longTerm, 2)
	assert.Equal(t, "bel_important", longTerm[0].ID, "exact-subject relevance is flat 1.0 — importance alone breaks the tie")
	assert.Empty(t, shortTerm, "no short-tier episodes were seeded for ent_x")
}

func TestRetrieveRevisions(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	since := time.Now().Add(-24 * time.Hour)
	historyLine := since.Add(time.Hour).Format("2006-01-02") + ": shake — conflicting evidence"

	important := Node{ID: "bel_important", Type: "belief", Tier: "long", Status: "shaken", Title: "Important",
		Body: "# Important\n\n## History\n- " + historyLine + "\n"}
	trivial := Node{ID: "bel_trivial", Type: "belief", Tier: "long", Status: "shaken", Title: "Trivial",
		Body: "# Trivial\n\n## History\n- " + historyLine + "\n"}
	writeAndIndex(t, v, d, important)
	writeAndIndex(t, v, d, trivial)
	require.NoError(t, d.UpdateMemoryNodeImportanceScore("bel_important", 10))
	require.NoError(t, d.UpdateMemoryNodeImportanceScore("bel_trivial", 0.1))

	got, err := RetrieveRevisions(d, v, float64(since.Unix()), 5)
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "bel_important", got[0].ID, "same-magnitude (status transition) revisions rank by importance")
}
```

- [ ] **Step 2: run it — expect a build failure:**

```
$ go test ./internal/db/ ./internal/memory/ -run 'TestNotableRevision|TestListBeliefsForSubjects|TestRetrieveBySubject|TestRetrieveRevisions' -v
# watchtower/internal/memory [watchtower/internal/memory.test]
./beliefs_test.go:XXX: undefined: NotableRevision
./retrieve_test.go:XXX: undefined: RetrieveBySubject
./retrieve_test.go:XXX: undefined: RetrieveRevisions
# watchtower/internal/db [watchtower/internal/db.test]
./memory_test.go:XXX: d.ListBeliefsForSubjects undefined (type *DB has no field or method ListBeliefsForSubjects)
FAIL	watchtower/internal/memory [build failed]
FAIL	watchtower/internal/db [build failed]
```

- [ ] **Step 3: write the minimal implementation.**

In `internal/db/memory.go`, add near `ListDisputePendingBeliefs`:

```go
// ListBeliefsForSubjects returns belief nodes whose subject is one of
// subjects and whose status is 'active' or 'shaken' — a retired or
// tombstoned belief is not live evidence. This is RetrieveBySubject's
// long-term candidate set (Slice B), replacing meeting-prep's ad hoc
// encounter-order filter (beliefLinesFor); ordering here is arbitrary (by
// id) since RankByImportance imposes the real order. Empty subjects is a
// clean empty read (nil, nil) — no query runs.
func (db *DB) ListBeliefsForSubjects(subjects []string) ([]MemoryNodeRow, error) {
	if len(subjects) == 0 {
		return nil, nil
	}
	placeholders, args := inClause(subjects)
	rows, err := db.Query(`SELECT `+memoryNodeSelectCols+`
		FROM memory_nodes
		WHERE memory_nodes.type = 'belief' AND memory_nodes.subject IN (`+placeholders+`)
		  AND memory_nodes.status IN ('active','shaken')
		ORDER BY memory_nodes.id`, args...)
	if err != nil {
		return nil, fmt.Errorf("listing beliefs for subjects: %w", err)
	}
	defer rows.Close()

	var out []MemoryNodeRow
	for rows.Next() {
		row, err := scanMemoryNodeRow(rows.Scan)
		if err != nil {
			return nil, fmt.Errorf("scanning belief for subject: %w", err)
		}
		out = append(out, row)
	}
	return out, rows.Err()
}
```

In `internal/memory/beliefs.go`, add `"math"` to the import block and append (near `ParseHistory`):

```go
// RevisionNotability is NotableRevision's result: the rendered journal line
// and the magnitude to feed RankByImportance's Relevance (Slice B of the
// memory-retrieval redesign) — a status transition is unconditionally
// maximal relevance (1.0); otherwise the summed |confidence delta|, already
// >= confidenceNotableDelta by construction whenever ok is true.
type RevisionNotability struct {
	Line      string
	Magnitude float64
}

// confidenceNotableDelta is the |confidence| move within the window that
// makes a non-status revision worth surfacing. Beliefs move in 0.1 steps, so
// this is two net steps in one direction. Relocated verbatim from
// internal/briefing/memory_revisions.go (Slice B) — internal/briefing
// already imports internal/memory (OpenExistingVault, Node, ParseHistory,
// HistoryBullet); internal/memory must never import internal/briefing, so
// this shared notability logic lives here and briefing calls in, not the
// reverse.
const confidenceNotableDelta = 0.2

// NotableRevision inspects one belief's ## History for entries dated on or
// after since and, when the aggregate change is notable, renders a single
// journal line:
//
//	<belief title> — <what changed> — because <evidence digest>
//
// Notability (code-side filter, UNCHANGED by Slice B — MEM-11, this slice
// never revisits what counts as notable): any status transition
// (shake/retire) or belief creation always qualifies; otherwise a summed
// |confidence| move of >=0.2 across the window's confirm/weaken entries
// qualifies. Returns ok=false when no in-window entry is notable.
//
// Relocated verbatim from internal/briefing/memory_revisions.go's
// notableRevision (Slice B) — briefing's gatherMemoryRevisions now calls
// this exported version and reads .Line for its exact prior behavior;
// .Magnitude is new, consumed only by RetrieveRevisions (retrieve.go).
func NotableRevision(node Node, since time.Time) (RevisionNotability, bool) {
	entries := historyEntriesSince(node.Body, since)
	if len(entries) == 0 {
		return RevisionNotability{}, false
	}

	statusNotable := false
	confDelta := 0.0
	for _, e := range entries {
		switch e.Cause {
		case "shake", "retire", "created", "propose-new":
			statusNotable = true
		case "confirm":
			confDelta += 0.1
		case "weaken":
			confDelta -= 0.1
		}
	}

	if !statusNotable && math.Abs(confDelta) < confidenceNotableDelta {
		return RevisionNotability{}, false
	}

	tail := entries[len(entries)-1]
	title := strings.TrimSpace(node.Title)
	if title == "" {
		title = node.ID
	}
	digest := tail.Rationale
	if digest == "" {
		digest = "recent evidence"
	}
	magnitude := 1.0 // a status transition is unconditionally maximal relevance
	if !statusNotable {
		magnitude = math.Abs(confDelta)
	}
	return RevisionNotability{
		Line:      title + " — " + describeChange(tail.Cause, confDelta) + " — because " + digest,
		Magnitude: magnitude,
	}, true
}

// historyEntriesSince returns the belief ## History bullets dated on or
// after since, in file order (oldest first). Relocated verbatim from
// internal/briefing/memory_revisions.go (Slice B).
func historyEntriesSince(body string, since time.Time) []HistoryBullet {
	sinceDate := since.Format("2006-01-02")
	var entries []HistoryBullet
	for _, b := range ParseHistory(body) {
		if b.Date >= sinceDate {
			entries = append(entries, b)
		}
	}
	return entries
}

// describeChange renders the human "what changed" clause for a journal
// line. Relocated verbatim from internal/briefing/memory_revisions.go
// (Slice B).
func describeChange(cause string, confDelta float64) string {
	switch cause {
	case "shake":
		return "belief shaken — evidence now conflicts"
	case "retire":
		return "belief retired"
	case "created", "propose-new":
		return "new belief formed"
	case "confirm":
		return "confidence strengthened"
	case "weaken":
		return "confidence weakened"
	default:
		if confDelta > 0 {
			return "confidence strengthened"
		}
		if confDelta < 0 {
			return "confidence weakened"
		}
		return "belief revised"
	}
}
```

In `internal/briefing/memory_revisions.go`, delete `confidenceNotableDelta`, `notableRevision`, `historyEntriesSince`, and `describeChange` in their entirety (lines 23–27 and 107–189), remove the now-unused `"math"` import, and change `gatherMemoryRevisions`'s call site from:

```go
		if line, ok := notableRevision(node, since); ok {
			lines = append(lines, line)
			if len(lines) >= maxMemoryRevisions {
				break
			}
		}
```

to:

```go
		if nr, ok := memory.NotableRevision(node, since); ok {
			lines = append(lines, nr.Line)
			if len(lines) >= maxMemoryRevisions {
				break
			}
		}
```

(`memory` is already imported in this file — no import change needed beyond dropping `"math"`.)

In `internal/memory/retrieve.go`, append:

```go
// RetrieveBySubject replaces meeting-prep's ad hoc encounter-order belief
// filter (beliefLinesFor) with importance-ranked selection (Slice B):
// longTerm is every active-or-shaken belief on subjects, ranked by
// RankByImportance with a flat Relevance of 1.0 (an exact subject match has
// no gradation — there is no "how well does this belief match the subject,"
// only yes/no). shortTerm is the recency-ordered short-tier episodes whose
// provenance sender matches a subject (ListShortTierEpisodesForAliases,
// Task 4) — NOT re-ranked by importance: a short-tier episode's value here
// is "what recently happened," not "how important is this in general"
// (design spec §3).
func RetrieveBySubject(database *db.DB, subjects []string, limitLong, limitShort int) (longTerm, shortTerm []db.MemoryNodeRow, err error) {
	if len(subjects) == 0 {
		return nil, nil, nil
	}
	beliefs, err := database.ListBeliefsForSubjects(subjects)
	if err != nil {
		return nil, nil, fmt.Errorf("memory: retrieve by subject: %w", err)
	}
	scored := make([]ScoredCandidate, len(beliefs))
	for i, b := range beliefs {
		scored[i] = ScoredCandidate{Row: b, Relevance: 1.0}
	}
	longTerm = RankByImportance(scored, limitLong)

	shortTerm, err = database.ListShortTierEpisodesForAliases(subjects, limitShort)
	if err != nil {
		return nil, nil, fmt.Errorf("memory: retrieve by subject (short-tier): %w", err)
	}
	return longTerm, shortTerm, nil
}

// RetrieveRevisions replaces briefing's encounter-order-capped notable-
// revision selection (Slice B): every belief node is checked for notability
// via NotableRevision (UNCHANGED filter — MEM-11, this slice never revisits
// what counts as notable), then ranked through RankByImportance so a
// notable change on a high-importance belief surfaces before the
// same-magnitude change on a low-importance one. v is required because
// notability is computed from the live vault body's ## History, which is
// not mirrored into the SQLite index.
func RetrieveRevisions(database *db.DB, v *Vault, sinceTS float64, limit int) ([]db.MemoryNodeRow, error) {
	since := time.Unix(int64(sinceTS), 0).UTC()
	nodes, err := database.ListMemoryNodes()
	if err != nil {
		return nil, fmt.Errorf("memory: retrieve revisions: %w", err)
	}
	var scored []ScoredCandidate
	for _, row := range nodes {
		if row.Type != "belief" {
			continue
		}
		node, err := v.ReadNode(row.ID)
		if err != nil {
			continue // index/vault drift (file removed since indexing) — skip, matching gatherMemoryRevisions's existing tolerance
		}
		nr, ok := NotableRevision(node, since)
		if !ok {
			continue
		}
		scored = append(scored, ScoredCandidate{Row: row, Relevance: nr.Magnitude})
	}
	return RankByImportance(scored, limit), nil
}
```

Add `"time"` to `internal/memory/retrieve.go`'s imports (now needed by `RetrieveRevisions`), alongside `"fmt"`, `"sort"`, `"watchtower/internal/db"`.

- [ ] **Step 4: run it — expect green, including the untouched briefing behavior:**

```
$ go test ./internal/memory/ -run 'TestNotableRevision|TestRetrieveBySubject|TestRetrieveRevisions' -v
=== RUN   TestNotableRevision_StatusTransitionIsAlwaysNotable
--- PASS: TestNotableRevision_StatusTransitionIsAlwaysNotable (0.00s)
=== RUN   TestNotableRevision_ConfidenceDeltaBelowThresholdIsNotNotable
--- PASS: TestNotableRevision_ConfidenceDeltaBelowThresholdIsNotNotable (0.00s)
=== RUN   TestNotableRevision_ConfidenceDeltaMagnitudeFeedsRelevance
--- PASS: TestNotableRevision_ConfidenceDeltaMagnitudeFeedsRelevance (0.00s)
=== RUN   TestNotableRevision_NoEntriesInWindowIsNotNotable
--- PASS: TestNotableRevision_NoEntriesInWindowIsNotNotable (0.00s)
=== RUN   TestRetrieveBySubject
--- PASS: TestRetrieveBySubject (0.01s)
=== RUN   TestRetrieveRevisions
--- PASS: TestRetrieveRevisions (0.02s)
PASS
ok  	watchtower/internal/memory	0.5s

$ go test ./internal/db/ -run TestListBeliefsForSubjects -v
=== RUN   TestListBeliefsForSubjects
--- PASS: TestListBeliefsForSubjects (0.01s)
PASS
ok  	watchtower/internal/db	0.2s

$ go test ./internal/briefing/ -run TestGatherMemoryRevisions -v 2>&1 | tail -10
--- PASS: TestGatherMemoryRevisions (0.03s)
PASS
ok  	watchtower/internal/briefing	0.4s
```

- [ ] **Step 5: whole-repo sanity (this task touches three packages) + commit:**

```
$ gofmt -l internal/memory internal/db internal/briefing
$ go vet ./... && go build ./...
$ go test ./internal/memory/ ./internal/db/ ./internal/briefing/ 2>&1 | tail -15
ok  	watchtower/internal/briefing	1.0s
ok  	watchtower/internal/db	1.4s
ok  	watchtower/internal/memory	4.6s
$ git add internal/db/memory.go internal/db/memory_test.go internal/memory/beliefs.go internal/memory/beliefs_test.go internal/memory/retrieve.go internal/memory/retrieve_test.go internal/briefing/memory_revisions.go
$ git commit -m "feat(memory): RetrieveBySubject + RetrieveRevisions (Slice B foundation)

NotableRevision (+ its private helpers) relocates from internal/briefing
into internal/memory verbatim, exported, gaining a Magnitude alongside its
existing Line — briefing already imports memory (the only cycle-safe
direction), so gatherMemoryRevisions now calls memory.NotableRevision
instead of a local notableRevision, unchanged otherwise. RetrieveBySubject
replaces meeting-prep's ad hoc belief filter with importance ranking (flat
1.0 relevance — exact subject match has no gradation) plus a direct,
un-reranked recency read for short-tier episodes. RetrieveRevisions ranks
briefing's notable-revision candidates by importance x confidence-delta
magnitude. Neither is wired into a live consumer yet (a later task)."
```

---

### Checkpoint: end of foundation (Tasks 1–6)

At this point: `RankByImportance` exists and is fully unit-tested; `memory_provenance.sender_id` exists, is populated for Slack/Gmail refs by every real write path, and is read by `ListShortTierEpisodesForAliases`; all three retrieval functions (`RetrieveByQuery`, `RetrieveBySubject`, `RetrieveRevisions`) exist, are fully tested against real SQLite-backed fixtures, and are **called by nothing outside their own tests** — `memory_recall`, meeting-prep's attendee context, and the briefing revisions journal all still run their legacy selection, byte-identical to before this plan. Tasks 7–13 below wire each behind its own dark `memory.retrieve.*_compare` flag, add the `memory_retrieve_shadow` table + `watchtower memory retrieve-compare` CLI, run the WhiteBit real-data verification, and — evidence permitting, per surface — retire the corresponding legacy selection as this same slice's final step.

## Task 7: `memory_retrieve_shadow` migration + shared compare-run infrastructure

**Depends on:** Tasks 1–6 (needs `ScoredCandidate`/`RankByImportance`/`RetrieveByQuery`/`RetrieveBySubject`/`RetrieveRevisions`, `ListShortTierEpisodesForAliases`, and the `memory_provenance.sender_id` migration already landed). **Blocks:** Tasks 8, 9, 10.

**Files:**
- Create: `internal/db/migrations/00029_memory_retrieve_shadow.sql` (verify the real next-available number first — see Step 0 below; Tasks 1–6's own migration landed as `00028`)
- Modify: `internal/db/schema.sql` (append the new table, mirroring `memory_digest_shadow`'s placement), `internal/db/testdata/schema_v73.golden` (regenerated), `internal/db/db_test.go` (new `TestMigration00029MemoryRetrieveShadow`, and add `"memory_retrieve_shadow"` to `TestAllTablesExist`'s enumerated list)
- Modify: `internal/db/memory.go` — new `MemoryRetrieveShadowRow` struct, `InsertMemoryRetrieveShadow`, `ListMemoryRetrieveShadow`
- Modify: `internal/config/config.go` — new `MemoryRetrieveConfig` struct + `MemoryConfig.Retrieve` field
- Create: `internal/memory/retrieve_compare.go` + `internal/memory/retrieve_compare_test.go` — the three shared `Compare*` entry points (`CompareRecall`, `CompareRevisions`, `CompareSubject`) plus `RecordRetrieveShadow`, consumed by Tasks 8–10's inline wiring and Task 11's CLI batch runner alike.

**Interfaces:**
- Consumes: `ScoredCandidate`/`RankByImportance`/`RetrieveByQuery`/`RetrieveBySubject`/`RetrieveRevisions` (Tasks 1–6), `db.MemoryNodeRow`.
- Produces:
  ```go
  // internal/db/memory.go
  type MemoryRetrieveShadowRow struct {
      ID              int64
      Surface         string // "recall" | "briefing" | "meeting_prep"
      QueryKey        string // surface-specific: the recall query text, the briefing since-ts, the meeting-prep subject entity id
      OldResultJSON   string
      NewResultJSON   string
      DiffMetricsJSON string
      TS              string // RFC3339
  }
  func (db *DB) InsertMemoryRetrieveShadow(row MemoryRetrieveShadowRow) error
  func (db *DB) ListMemoryRetrieveShadow(surface string, since time.Time) ([]MemoryRetrieveShadowRow, error)

  // internal/memory/retrieve_compare.go
  type RecallDiff struct {
      Query             string
      OldIDs, NewIDs    []string
      CoverageOK        bool    // every old id present in new (no silent loss of an exact-keyword hit)
      MeanImportanceOld float64
      MeanImportanceNew float64
  }
  func CompareRecall(readDB, shadowDB *db.DB, query string, legacyIDs []string, limit int) (RecallDiff, error)

  type RevisionDiff struct {
      SinceTS      float64
      OldIDs       []string // legacy notable-revision order, already capped
      NewIDs       []string // RetrieveRevisions' order, same cap
      Intersection int      // |old intersect new|
  }
  func CompareRevisions(readDB, shadowDB *db.DB, vault *Vault, sinceTS float64, legacyIDs []string, limit int) (RevisionDiff, error)

  type SubjectDiff struct {
      Subject         string
      OldBeliefIDs    []string
      NewBeliefIDs    []string
      NewSupersetOK   bool     // old belief set subset-of new belief set
      NewShortTermIDs []string // additive, spot-check only — no legacy equivalent exists
  }
  func CompareSubject(readDB, shadowDB *db.DB, subject string, legacyBeliefIDs []string, limitLong, limitShort int) (SubjectDiff, error)

  func RecordRetrieveShadow(shadowDB *db.DB, surface, queryKey string, oldResult, newResult, diff any) error
  ```
  Consumed by Tasks 8/9/10 (inline, per-request) and Task 11 (CLI batch, offline snapshot run).

- [ ] **Step 0: verify the real next migration number before writing the file:**

```
$ ls internal/db/migrations/ | tail -3
```

Expected (assuming Tasks 1–6 landed their `memory_provenance.sender_id` migration as `00028`):
```
00027_memory_importance_score.sql
00028_memory_provenance_sender.sql
```
If Tasks 1–6 used a different number, replace every `00029` in this task with the actual next-available number.

- [ ] **Step 1: write the failing test** — add to `internal/db/db_test.go` immediately after `TestMigration00028MemoryProvenanceSender`:

```go
// TestMigration00029MemoryRetrieveShadow: memory_retrieve_shadow (Slice B
// Task 7, dark retrieval compare-mode) is additive, has no FK onto
// memory_nodes (a shadow row must survive even if the compared node is later
// deleted — it is pure telemetry, not derived state), and a plain insert
// with all five payload columns succeeds.
func TestMigration00029MemoryRetrieveShadow(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	var n int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='memory_retrieve_shadow'`).Scan(&n)
	if err != nil || n != 1 {
		t.Fatalf("memory_retrieve_shadow table missing (count=%d err=%v)", n, err)
	}

	_, err = database.Exec(
		`INSERT INTO memory_retrieve_shadow (surface, query_key, old_result_json, new_result_json, diff_metrics_json, ts)
		 VALUES ('recall', 'billing', '["ent_1"]', '["ent_1","ent_2"]', '{"coverage_ok":true}', '2026-07-20T00:00:00Z')`)
	if err != nil {
		t.Fatalf("inserting memory_retrieve_shadow row: %v", err)
	}

	var surface string
	if err := database.QueryRow(`SELECT surface FROM memory_retrieve_shadow WHERE query_key = 'billing'`).Scan(&surface); err != nil {
		t.Fatalf("reading back inserted row: %v", err)
	}
	if surface != "recall" {
		t.Errorf("surface = %q, want recall", surface)
	}
}
```

- [ ] **Step 2: run it — expect failure** (table doesn't exist yet):

```
$ go test ./internal/db/ -run TestMigration00029MemoryRetrieveShadow -v
=== RUN   TestMigration00029MemoryRetrieveShadow
    db_test.go:XXX: memory_retrieve_shadow table missing (count=0 err=<nil>)
--- FAIL: TestMigration00029MemoryRetrieveShadow (0.01s)
FAIL
```

- [ ] **Step 3: write the migration** — create `internal/db/migrations/00029_memory_retrieve_shadow.sql`:

```sql
-- +goose Up
-- Secretary memory Phase-5 Slice B, Task 7: dark retrieval-compare telemetry
-- table, mirroring memory_digest_shadow's role for the digest-render compare
-- (see docs/superpowers/specs/2026-07-20-memory-slice-b-unified-retrieval-design.md
-- Section 6). Unlike memory_digest_shadow (keyed by channel/period, self-
-- overwriting), each row here is one point-in-time comparison of a live
-- surface call (memory_recall / briefing / meeting-prep) against the new
-- RankByImportance-based retrieval — an append-only audit trail, not a
-- snapshot, because the three surfaces are called ad hoc rather than on a
-- fixed per-window schedule. No FK onto memory_nodes: a shadow row is pure
-- telemetry that must survive independently of the compared node's later
-- eviction/deletion.
CREATE TABLE IF NOT EXISTS memory_retrieve_shadow (
    id                INTEGER PRIMARY KEY,
    surface           TEXT NOT NULL CHECK (surface IN ('recall','briefing','meeting_prep')),
    query_key         TEXT NOT NULL DEFAULT '', -- recall's query text / briefing's since-ts / meeting-prep's subject entity id
    old_result_json   TEXT NOT NULL,
    new_result_json   TEXT NOT NULL,
    diff_metrics_json TEXT NOT NULL,
    ts                TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_memory_retrieve_shadow_surface ON memory_retrieve_shadow(surface, ts);

-- +goose Down
DROP TABLE IF EXISTS memory_retrieve_shadow;
```

Append to `internal/db/schema.sql`, immediately after the `memory_digest_shadow` table definition:

```sql
CREATE TABLE IF NOT EXISTS memory_retrieve_shadow (
    id                INTEGER PRIMARY KEY,
    surface           TEXT NOT NULL CHECK (surface IN ('recall','briefing','meeting_prep')),
    query_key         TEXT NOT NULL DEFAULT '',
    old_result_json   TEXT NOT NULL,
    new_result_json   TEXT NOT NULL,
    diff_metrics_json TEXT NOT NULL,
    ts                TEXT NOT NULL
);
```

Add `"memory_retrieve_shadow"` to the table-name list in `TestAllTablesExist` (`internal/db/db_test.go`), right after `"memory_digest_shadow"`.

- [ ] **Step 4: run it — expect green, then regenerate the golden snapshot:**

```
$ go test ./internal/db/ -run TestMigration00029MemoryRetrieveShadow -v
--- PASS: TestMigration00029MemoryRetrieveShadow (0.01s)
PASS

$ go test ./internal/db/ -run TestSchemaGolden -update
    schema_snapshot_test.go:43: wrote testdata/schema_v73.golden (NNNNN bytes)

$ go test ./internal/db/ -run 'TestSchemaGolden|TestAllTablesExist|TestMigration' -v 2>&1 | tail -15
--- PASS: TestSchemaGolden (0.05s)
--- PASS: TestAllTablesExist (0.02s)
--- PASS: TestMigration00029MemoryRetrieveShadow (0.01s)
PASS
```

- [ ] **Step 5: DB-layer round-trip** — write the failing test first, in `internal/db/memory_test.go`, after the last Slice-A/Tasks-1-6 memory test:

```go
func TestMemoryRetrieveShadowRoundTrip(t *testing.T) {
	database := openTestDB(t)

	err := database.InsertMemoryRetrieveShadow(MemoryRetrieveShadowRow{
		Surface: "recall", QueryKey: "billing",
		OldResultJSON: `["ent_1"]`, NewResultJSON: `["ent_1","ent_2"]`,
		DiffMetricsJSON: `{"coverage_ok":true}`, TS: "2026-07-20T00:00:00Z",
	})
	if err != nil {
		t.Fatalf("InsertMemoryRetrieveShadow: %v", err)
	}
	// A second surface must not collide with the first.
	if err := database.InsertMemoryRetrieveShadow(MemoryRetrieveShadowRow{
		Surface: "briefing", QueryKey: "1721433600",
		OldResultJSON: `[]`, NewResultJSON: `[]`, DiffMetricsJSON: `{}`, TS: "2026-07-20T01:00:00Z",
	}); err != nil {
		t.Fatalf("second insert: %v", err)
	}

	rows, err := database.ListMemoryRetrieveShadow("recall", time.Time{})
	if err != nil {
		t.Fatalf("ListMemoryRetrieveShadow: %v", err)
	}
	if len(rows) != 1 || rows[0].QueryKey != "billing" {
		t.Fatalf("ListMemoryRetrieveShadow(recall) = %+v, want one billing row", rows)
	}
}
```

Run — expect a build failure (`InsertMemoryRetrieveShadow undefined`) — then implement in `internal/db/memory.go`, right after `UpsertDigestShadow`:

```go
// InsertMemoryRetrieveShadow appends one Slice-B retrieval-compare telemetry
// row (Task 7). Append-only — unlike UpsertDigestShadow, there is no natural
// dedup key (a surface is called ad hoc, not per fixed window), so repeat
// comparisons simply accumulate as an audit trail.
func (db *DB) InsertMemoryRetrieveShadow(row MemoryRetrieveShadowRow) error {
	_, err := db.Exec(`INSERT INTO memory_retrieve_shadow
		(surface, query_key, old_result_json, new_result_json, diff_metrics_json, ts)
		VALUES (?, ?, ?, ?, ?, ?)`,
		row.Surface, row.QueryKey, row.OldResultJSON, row.NewResultJSON, row.DiffMetricsJSON, row.TS)
	if err != nil {
		return fmt.Errorf("inserting memory retrieve shadow row: %w", err)
	}
	return nil
}

// ListMemoryRetrieveShadow returns surface's shadow rows created at or after
// since (zero time = all), newest first — the CLI report's read path.
func (db *DB) ListMemoryRetrieveShadow(surface string, since time.Time) ([]MemoryRetrieveShadowRow, error) {
	rows, err := db.Query(`SELECT id, surface, query_key, old_result_json, new_result_json, diff_metrics_json, ts
		FROM memory_retrieve_shadow WHERE surface = ? AND ts >= ? ORDER BY id DESC`,
		surface, since.UTC().Format(time.RFC3339))
	if err != nil {
		return nil, fmt.Errorf("listing memory retrieve shadow: %w", err)
	}
	defer rows.Close()
	var out []MemoryRetrieveShadowRow
	for rows.Next() {
		var r MemoryRetrieveShadowRow
		if err := rows.Scan(&r.ID, &r.Surface, &r.QueryKey, &r.OldResultJSON, &r.NewResultJSON, &r.DiffMetricsJSON, &r.TS); err != nil {
			return nil, fmt.Errorf("scanning memory retrieve shadow row: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
```

```
$ go test ./internal/db/ -run TestMemoryRetrieveShadowRoundTrip -v
--- PASS: TestMemoryRetrieveShadowRoundTrip (0.01s)
```

- [ ] **Step 6: config flags.** Add to `internal/config/config.go`, immediately after `MemoryRendersConfig`:

```go
// MemoryRetrieveConfig gates the Phase-5 Slice-B dark retrieval-compare mode
// independently per surface — each is a no-op when its flag is off, mirroring
// Renders.DigestCompare's precedent. All default false (dark by default).
// Unlike Renders.DigestCompare (one daemon-tail batch job), these three run
// inline at each surface's own live call site (memory_recall's MCP handler,
// briefing's gatherMemoryRevisions, meeting-prep's gatherMemoryContext) —
// there is no cost concern requiring a daemon-cycle gate, since none of the
// three retrieval functions makes an AI call.
type MemoryRetrieveConfig struct {
	RecallCompare      bool `mapstructure:"recall_compare"`       // memory_recall MCP tool also runs RetrieveByQuery and shadow-diffs against the legacy FTS ranking (default: false)
	BriefingCompare    bool `mapstructure:"briefing_compare"`     // briefing's Memory revisions journal also runs RetrieveRevisions and shadow-diffs against the legacy notable-revision order (default: false)
	MeetingPrepCompare bool `mapstructure:"meeting_prep_compare"` // meeting-prep's attendee memory context also runs RetrieveBySubject and shadow-diffs against the legacy confidence-ordered belief selection (default: false)
}
```

Add the field to `MemoryConfig` (right after `Renders`):

```go
	Retrieve             MemoryRetrieveConfig `mapstructure:"retrieve"`                // Phase-5 Slice B dark retrieval-compare (recall/briefing/meeting_prep), each dark by default
```

- [ ] **Step 7: the three shared compare functions + the infra guard test.** Create `internal/memory/retrieve_compare.go`:

```go
package memory

// This file is Slice B's Task 7 shared dark-compare infrastructure — the same
// role digest_compare.go plays for the channel-digest render, but lighter:
// none of RetrieveByQuery/RetrieveBySubject/RetrieveRevisions makes an AI
// call, so there is no per-item cost to isolate or skip-if-fresh. Each
// Compare* function is called from exactly two places: inline, once per live
// request, from the surface's own call site (mcp/memory.go, briefing's
// gatherMemoryRevisions, meeting's gatherMemoryContext — Tasks 8-10) and, in
// a loop, from the offline CLI batch runner (RunRetrieveCompare, Task 11)
// against a snapshot. Both paths get identical diff math because both call
// the SAME function — the live inline call is not a separate, drifting copy.
//
// Every Compare* function takes readDB (the connection it computes the new
// retrieval result from — read-only is fine, these are pure SELECTs) and
// shadowDB (the connection it writes the one telemetry row to) SEPARATELY.
// The split exists because memory_recall's MCP connection is deliberately
// read-only (internal/mcp's package doc: "every registered tool is a read
// surface") — Task 8 passes a second, narrowly-scoped writable handle as
// shadowDB there; Tasks 9/10 and Task 11's CLI runner pass the SAME *db.DB
// for both (their connections are ordinarily writable already).

import (
	"encoding/json"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// RecallDiff is CompareRecall's diff-metrics payload (also the report row).
type RecallDiff struct {
	Query             string   `json:"query"`
	OldIDs            []string `json:"old_ids"`
	NewIDs            []string `json:"new_ids"`
	CoverageOK        bool     `json:"coverage_ok"` // every old id present in new — no silent loss of an exact-keyword hit
	MeanImportanceOld float64  `json:"mean_importance_old"`
	MeanImportanceNew float64  `json:"mean_importance_new"`
}

// CompareRecall runs RetrieveByQuery against readDB, diffs it against the
// caller's already-computed legacy result ids (memory_recall's combined
// alias+FTS hit list, in its returned order), writes one memory_retrieve_shadow
// row to shadowDB, and returns the diff. A retrieval or write error is
// returned to the caller, which — per MEM-05/14's "compare mode never touches
// the live response" precedent — must log it and continue returning the
// legacy result regardless (Task 8 enforces this at the call site, not here).
func CompareRecall(readDB, shadowDB *db.DB, query string, legacyIDs []string, limit int) (RecallDiff, error) {
	newRows, err := RetrieveByQuery(readDB, query, limit)
	if err != nil {
		return RecallDiff{}, fmt.Errorf("memory: compare recall: retrieve: %w", err)
	}
	newIDs := nodeIDs(newRows)
	diff := RecallDiff{
		Query:             query,
		OldIDs:            legacyIDs,
		NewIDs:            newIDs,
		CoverageOK:        idsSubsetOf(legacyIDs, newIDs),
		MeanImportanceNew: meanImportance(newRows),
	}
	oldRows, err := loadNodesByID(readDB, legacyIDs)
	if err != nil {
		return RecallDiff{}, fmt.Errorf("memory: compare recall: loading legacy nodes: %w", err)
	}
	diff.MeanImportanceOld = meanImportance(oldRows)

	if err := recordShadow(shadowDB, "recall", query, legacyIDs, newIDs, diff); err != nil {
		return diff, err
	}
	return diff, nil
}

// RevisionDiff is CompareRevisions' diff-metrics payload.
type RevisionDiff struct {
	SinceTS      float64  `json:"since_ts"`
	OldIDs       []string `json:"old_ids"`
	NewIDs       []string `json:"new_ids"`
	Intersection int      `json:"intersection"`
}

// CompareRevisions runs RetrieveRevisions against readDB/vault, diffs it
// against briefing's already-selected legacy notable-revision node ids (same
// cap, same order), writes one shadow row, and returns the diff.
func CompareRevisions(readDB, shadowDB *db.DB, vault *Vault, sinceTS float64, legacyIDs []string, limit int) (RevisionDiff, error) {
	newRows, err := RetrieveRevisions(readDB, vault, sinceTS, limit)
	if err != nil {
		return RevisionDiff{}, fmt.Errorf("memory: compare revisions: retrieve: %w", err)
	}
	newIDs := nodeIDs(newRows)
	diff := RevisionDiff{
		SinceTS:      sinceTS,
		OldIDs:       legacyIDs,
		NewIDs:       newIDs,
		Intersection: idsIntersectionCount(legacyIDs, newIDs),
	}
	queryKey := fmt.Sprintf("%.0f", sinceTS)
	if err := recordShadow(shadowDB, "briefing", queryKey, legacyIDs, newIDs, diff); err != nil {
		return diff, err
	}
	return diff, nil
}

// SubjectDiff is CompareSubject's diff-metrics payload.
type SubjectDiff struct {
	Subject         string   `json:"subject"`
	OldBeliefIDs    []string `json:"old_belief_ids"`
	NewBeliefIDs    []string `json:"new_belief_ids"`
	NewSupersetOK   bool     `json:"new_superset_ok"` // old belief set subset-of new belief set
	NewShortTermIDs []string `json:"new_short_term_ids"` // additive — no legacy equivalent; spot-check only (design spec §6)
}

// CompareSubject runs RetrieveBySubject for one entity subject against
// readDB, diffs the belief half against meeting-prep's already-selected
// legacy belief ids (same subject, same cap), records the shortTerm episode
// ids for manual spot-check (there is no automatable "plausible" metric —
// design spec §6), writes one shadow row, and returns the diff.
func CompareSubject(readDB, shadowDB *db.DB, subject string, legacyBeliefIDs []string, limitLong, limitShort int) (SubjectDiff, error) {
	longTerm, shortTerm, err := RetrieveBySubject(readDB, []string{subject}, limitLong, limitShort)
	if err != nil {
		return SubjectDiff{}, fmt.Errorf("memory: compare subject %s: retrieve: %w", subject, err)
	}
	newBeliefIDs := nodeIDs(longTerm)
	diff := SubjectDiff{
		Subject:         subject,
		OldBeliefIDs:    legacyBeliefIDs,
		NewBeliefIDs:    newBeliefIDs,
		NewSupersetOK:   idsSubsetOf(legacyBeliefIDs, newBeliefIDs),
		NewShortTermIDs: nodeIDs(shortTerm),
	}
	if err := recordShadow(shadowDB, "meeting_prep", subject, legacyBeliefIDs, newBeliefIDs, diff); err != nil {
		return diff, err
	}
	return diff, nil
}

// recordShadow marshals old/new/diff and calls RecordRetrieveShadow — the
// one place all three Compare* functions touch the DB for a write.
func recordShadow(shadowDB *db.DB, surface, queryKey string, oldIDs, newIDs []string, diff any) error {
	return RecordRetrieveShadow(shadowDB, surface, queryKey, oldIDs, newIDs, diff)
}

// RecordRetrieveShadow marshals oldResult/newResult/diff to JSON and inserts
// one memory_retrieve_shadow row via shadowDB. The ONLY write any of this
// file makes — matching MEM-05/14's "memory writes only memory-owned side
// tables" precedent, extended to Slice B's third telemetry table.
func RecordRetrieveShadow(shadowDB *db.DB, surface, queryKey string, oldResult, newResult, diff any) error {
	oldJSON, err := json.Marshal(oldResult)
	if err != nil {
		return fmt.Errorf("memory: marshal old result for %s shadow: %w", surface, err)
	}
	newJSON, err := json.Marshal(newResult)
	if err != nil {
		return fmt.Errorf("memory: marshal new result for %s shadow: %w", surface, err)
	}
	diffJSON, err := json.Marshal(diff)
	if err != nil {
		return fmt.Errorf("memory: marshal diff metrics for %s shadow: %w", surface, err)
	}
	return shadowDB.InsertMemoryRetrieveShadow(db.MemoryRetrieveShadowRow{
		Surface:         surface,
		QueryKey:        queryKey,
		OldResultJSON:   string(oldJSON),
		NewResultJSON:   string(newJSON),
		DiffMetricsJSON: string(diffJSON),
		TS:              time.Now().UTC().Format(time.RFC3339),
	})
}

// nodeIDs projects a []db.MemoryNodeRow to its ids, in order.
func nodeIDs(rows []db.MemoryNodeRow) []string {
	ids := make([]string, len(rows))
	for i, r := range rows {
		ids[i] = r.ID
	}
	return ids
}

// idsSubsetOf reports whether every id in old is present in new — the
// "nothing is silently lost, only reordered/added" coverage check shared by
// all three surfaces (design spec §6).
func idsSubsetOf(old, new []string) bool {
	present := make(map[string]bool, len(new))
	for _, id := range new {
		present[id] = true
	}
	for _, id := range old {
		if !present[id] {
			return false
		}
	}
	return true
}

// idsIntersectionCount counts ids present in both slices.
func idsIntersectionCount(a, b []string) int {
	inA := make(map[string]bool, len(a))
	for _, id := range a {
		inA[id] = true
	}
	n := 0
	for _, id := range b {
		if inA[id] {
			n++
		}
	}
	return n
}

// meanImportance is the arithmetic mean of rows' ImportanceScore, 0 for an
// empty slice (never NaN — an empty legacy/new set reads as 0, not undefined).
func meanImportance(rows []db.MemoryNodeRow) float64 {
	if len(rows) == 0 {
		return 0
	}
	var sum float64
	for _, r := range rows {
		sum += r.ImportanceScore
	}
	return sum / float64(len(rows))
}

// loadNodesByID fetches each id's current MemoryNodeRow (best-effort — a
// stale/deleted legacy id is skipped, never an error, since the legacy
// caller already resolved it once and this is only needed for the mean-
// importance metric, not a correctness-critical read).
func loadNodesByID(readDB *db.DB, ids []string) ([]db.MemoryNodeRow, error) {
	var rows []db.MemoryNodeRow
	for _, id := range ids {
		row, err := readDB.GetMemoryNode(id)
		if err != nil {
			continue
		}
		rows = append(rows, row)
	}
	return rows, nil
}
```

- [ ] **Step 8: the pure-reader infra guard test** — create `internal/memory/retrieve_compare_test.go`:

```go
package memory

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestRetrieveCompare_LegacyTablesByteIdentical is the MEM-05/14-precedent
// pure-reader guard, adapted from TestDigestCompare_LegacyTablesByteIdentical:
// all three Compare* functions read memory_nodes/memory_fts (and, for
// CompareRevisions, the vault) and write ONLY memory_retrieve_shadow — never
// mutating a memory_nodes row, never touching the vault git log. Tasks 8-10
// each add a further, surface-specific guard proving their LIVE caller's
// actual returned response/journal/context is unchanged; this test proves
// the shared infrastructure itself never mutates anything but the shadow
// table, independent of any specific caller.
func TestRetrieveCompare_LegacyTablesByteIdentical(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5TG01", "entity", "Target")
	writeNodes(t, v, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	before := dumpMemoryNodesTable(t, d)
	beforeHead := memGitHeadCountForTest(t, v.path)

	_, err = CompareRecall(d, d, "target", []string{target.ID}, 10)
	require.NoError(t, err)
	_, err = CompareRevisions(d, d, v, 0, nil, 5)
	require.NoError(t, err)
	_, err = CompareSubject(d, d, target.ID, nil, 3, 5)
	require.NoError(t, err)

	after := dumpMemoryNodesTable(t, d)
	assert.Equal(t, before, after, "memory_nodes must be byte-identical across all three compare calls")
	assert.Equal(t, beforeHead, memGitHeadCountForTest(t, v.path), "the vault git log must not move")

	rows, err := d.ListMemoryRetrieveShadow("recall", time.Time{})
	require.NoError(t, err)
	assert.Len(t, rows, 1, "exactly one recall shadow row written")
}
```

`dumpMemoryNodesTable`/`memGitHeadCountForTest` are small new local test helpers in this new test file — a `SELECT * FROM memory_nodes ORDER BY id` string dump (query `memoryNodeSelectCols` plus a stable field-join into one comparable string per row) and a `git -C <path> rev-list --count HEAD` wrapper via `os/exec`.

- [ ] **Step 9: run the full new set — expect green:**

```
$ go test ./internal/memory/ -run 'TestRetrieveCompare' -v
--- PASS: TestRetrieveCompare_LegacyTablesByteIdentical (0.04s)
PASS

$ go test ./internal/db/... ./internal/memory/... 2>&1 | tail -5
ok  	watchtower/internal/db	0.6s
ok  	watchtower/internal/memory	1.4s
```

- [ ] **Step 10: commit:**

```
$ git add internal/db/migrations/00029_memory_retrieve_shadow.sql internal/db/schema.sql \
    internal/db/testdata/schema_v73.golden internal/db/db_test.go internal/db/memory.go \
    internal/db/memory_test.go internal/config/config.go \
    internal/memory/retrieve_compare.go internal/memory/retrieve_compare_test.go
$ git commit -m "feat(memory): memory_retrieve_shadow table + shared retrieval-compare infra (Slice B Task 7)

New migration 00029 adds the append-only memory_retrieve_shadow telemetry
table (mirrors memory_digest_shadow's role, no FK, surface/query_key/old/new/
diff/ts). Three shared Compare{Recall,Revisions,Subject} functions in the new
internal/memory/retrieve_compare.go run the new RankByImportance-based
retrieval, diff it against a caller-supplied legacy result, and write one
shadow row — consumed inline by Tasks 8-10's live surfaces and by Task 11's
offline CLI batch runner alike, so both paths share one diff implementation.
Three new dark config flags (Memory.Retrieve.{RecallCompare,BriefingCompare,
MeetingPrepCompare}), all default false."
```

---

## Task 8: Dark wiring for `memory_recall`

**Depends on:** Task 7. **Blocks:** Task 11 (the CLI's recall surface needs this wiring's `CompareRecall` call convention proven first), Task 12.

**Files:**
- Modify: `internal/mcp/server.go` — new `WithMemoryRetrieveCompare` option, `Server.retrieveShadowDB` field, `NewServer`/`registerMemory` threading, package doc comment
- Modify: `internal/mcp/memory.go` — `memoryRecallHandler`'s signature and body
- Modify: `cmd/mcp.go`, `cmd/tools.go` — open the second writable handle and pass the new option when `cfg.Memory.Retrieve.RecallCompare` is on
- Test: `internal/mcp/memory_test.go` — new tests after `TestMemoryRecallLimit`

**Interfaces:**
- Consumes: `memory.CompareRecall` (Task 7).
- Produces: `WithMemoryRetrieveCompare(shadowDB *db.DB) ServerOption` — a new wiring seam, not consumed elsewhere in this plan.

**The architectural wrinkle:** `memory_recall`'s `database` handle is `PRAGMA query_only=ON` by the time `NewServer` runs (`internal/mcp/server.go`'s package doc: "Package mcp implements a read-only Model Context Protocol server... every registered tool is a read surface"; both real call sites, `cmd/mcp.go` and `cmd/tools.go`, call `database.SetReadOnly()` before `NewServer` even runs). `CompareRecall`'s read half (`RetrieveByQuery`) works fine on it; its write half (`RecordRetrieveShadow`) does not — any `INSERT` on that connection errors (`TestSetReadOnlyBlocksWrites`, `internal/db/db_test.go`, confirms this). **Resolution:** a second, narrowly-scoped writable `*db.DB` handle — opened the ordinary way (`db.Open(dbPath)`, no `SetReadOnly()`), held only for this one telemetry write, never exposed to any other handler — threaded through a new `WithMemoryRetrieveCompare(shadowDB *db.DB)` `ServerOption` (mirrors `WithMemoryVault`'s optional-wiring shape: presence = enabled). This keeps every other tool byte-identical read-only and confines the one new deliberate write to exactly the same telemetry side table MEM-05 already carves out an exception for.

Current `internal/mcp/server.go` (relevant excerpt):

```go
// Server wraps the SDK server so callers (cmd, tests) do not import the SDK.
type Server struct {
	s *mcpsdk.Server

	// memoryVaultPath is the workspace memory vault directory; empty when
	// memory is disabled — the memory_ tools then answer "not initialized".
	memoryVaultPath string
}

// ServerOption customizes NewServer additively, so existing call sites keep
// compiling as new dependencies are introduced.
type ServerOption func(*Server)

// WithMemoryVault points the memory_ tools at the workspace memory vault
// directory (WorkspaceDir()/memory). Callers pass it only when memory is
// enabled; without it the tools report memory as not initialized.
func WithMemoryVault(path string) ServerOption {
	return func(srv *Server) { srv.memoryVaultPath = path }
}

// NewServer builds an MCP server over the given database and registers every
// domain tool.
func NewServer(database *db.DB, opts ...ServerOption) *Server {
	srv := &Server{s: mcpsdk.NewServer(&mcpsdk.Implementation{
		Name:    "watchtower",
		Title:   "Watchtower",
		Version: version,
	}, nil)}
	for _, opt := range opts {
		opt(srv)
	}

	registerTargets(srv.s, database)
	registerDigests(srv.s, database)
	registerPeople(srv.s, database)
	registerJira(srv.s, database)
	registerMessages(srv.s, database)
	registerTranscripts(srv.s, database)
	registerMemory(srv.s, database, srv.memoryVaultPath)

	return srv
}
```

- [ ] **Step 1: write the failing test** — add to `internal/mcp/memory_test.go`, after `TestMemoryRecallLimit`:

```go
// newMemorySessionCompare is newMemorySession plus a writable shadowDB
// wired via WithMemoryRetrieveCompare — the Task 8 dark-wiring seam.
func newMemorySessionCompare(t *testing.T, database, shadowDB *db.DB, vaultPath string) *mcpsdk.ClientSession {
	t.Helper()
	ctx := context.Background()
	srv := NewServer(database, WithMemoryVault(vaultPath), WithMemoryRetrieveCompare(shadowDB))
	client := mcpsdk.NewClient(&mcpsdk.Implementation{Name: "test", Version: "v0"}, nil)
	st, ct := mcpsdk.NewInMemoryTransports()
	if _, err := srv.s.Connect(ctx, st, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	cs, err := client.Connect(ctx, ct, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { cs.Close() })
	return cs
}

// TestMemoryRecallCompare_ShadowWrittenResponseUnchanged: with
// memory.retrieve.recall_compare wired on (via a second writable handle),
// memory_recall ALSO runs the new RetrieveByQuery-based ranking and writes
// one memory_retrieve_shadow row with sane diff metrics — but the actual MCP
// response returned to the caller is BYTE-IDENTICAL to the flag-off legacy
// response (the single most important behavioral guarantee this task adds).
func TestMemoryRecallCompare_ShadowWrittenResponseUnchanged(t *testing.T) {
	database := seedDB(t)
	_, vaultPath := seedMemoryFixture(t, database)

	// Baseline: flag off, capture the legacy response bytes.
	csOff := newMemorySession(t, database, vaultPath)
	resOff, err := csOff.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "memory_recall", Arguments: map[string]any{"query": "Pay-Svc"},
	})
	if err != nil || resOff.IsError {
		t.Fatalf("baseline call failed: err=%v res=%+v", err, resOff)
	}
	baseline := textContent(t, resOff)

	// Compare mode on: same query, same DB/vault state.
	csOn := newMemorySessionCompare(t, database, database, vaultPath)
	resOn, err := csOn.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "memory_recall", Arguments: map[string]any{"query": "Pay-Svc"},
	})
	if err != nil || resOn.IsError {
		t.Fatalf("compare-mode call failed: err=%v res=%+v", err, resOn)
	}
	if got := textContent(t, resOn); got != baseline {
		t.Fatalf("compare mode changed the live response:\n legacy: %s\n got:    %s", baseline, got)
	}

	rows, err := database.ListMemoryRetrieveShadow("recall", time.Time{})
	if err != nil {
		t.Fatalf("ListMemoryRetrieveShadow: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected exactly one recall shadow row, got %d", len(rows))
	}
	var diff memory.RecallDiff
	if err := json.Unmarshal([]byte(rows[0].DiffMetricsJSON), &diff); err != nil {
		t.Fatalf("unmarshaling diff metrics: %v", err)
	}
	if !diff.CoverageOK {
		t.Errorf("expected coverage_ok on an identical-vault comparison, got false (diff=%+v)", diff)
	}
}

// TestMemoryRecallCompare_GateOffWritesNoShadow: without
// WithMemoryRetrieveCompare, memory_recall never touches memory_retrieve_shadow
// — byte-identical to before this task existed.
func TestMemoryRecallCompare_GateOffWritesNoShadow(t *testing.T) {
	database := seedDB(t)
	_, vaultPath := seedMemoryFixture(t, database)
	cs := newMemorySession(t, database, vaultPath) // no compare option

	_, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "memory_recall", Arguments: map[string]any{"query": "Pay-Svc"},
	})
	if err != nil {
		t.Fatalf("call memory_recall: %v", err)
	}
	rows, err := database.ListMemoryRetrieveShadow("recall", time.Time{})
	if err != nil {
		t.Fatalf("ListMemoryRetrieveShadow: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected no shadow rows with the option absent, got %d", len(rows))
	}
}
```

- [ ] **Step 2: run — expect a build failure:**

```
$ go test ./internal/mcp/ -run TestMemoryRecallCompare -v
# watchtower/internal/mcp [watchtower/internal/mcp.test]
./memory_test.go:XXX: undefined: WithMemoryRetrieveCompare
FAIL	watchtower/internal/mcp [build failed]
```

- [ ] **Step 3: implement.** In `internal/mcp/server.go`, update the package doc comment:

```go
// Package mcp implements a read-only Model Context Protocol server that
// exposes Watchtower's curated product data to MCP clients. Every registered
// tool is a read surface; the deliberate writes are memory_open's best-effort
// usage-stats bump (telemetry, not domain data) and, when
// WithMemoryRetrieveCompare is supplied, memory_recall's dark retrieval-
// compare shadow row (also telemetry — Slice B Task 8, memory_retrieve_shadow
// only, never the tool's own response).
package mcp
```

Add the field, option, and threading:

```go
// Server wraps the SDK server so callers (cmd, tests) do not import the SDK.
type Server struct {
	s *mcpsdk.Server

	// memoryVaultPath is the workspace memory vault directory; empty when
	// memory is disabled — the memory_ tools then answer "not initialized".
	memoryVaultPath string

	// retrieveShadowDB is a SEPARATE, ordinarily-writable *db.DB handle used
	// ONLY for memory_recall's dark retrieval-compare shadow write (Slice B
	// Task 8). The server's main `database` handle is deliberately
	// PRAGMA query_only=ON at the call sites (cmd/mcp.go, cmd/tools.go) so
	// no tool handler can write; this field is the one narrow, explicit
	// exception, threaded in only when memory.retrieve.recall_compare is on.
	// nil means the flag is off — memory_recall behaves byte-identically to
	// before this field existed.
	retrieveShadowDB *db.DB
}

// WithMemoryVault points the memory_ tools at the workspace memory vault
// directory (WorkspaceDir()/memory). Callers pass it only when memory is
// enabled; without it the tools report memory as not initialized.
func WithMemoryVault(path string) ServerOption {
	return func(srv *Server) { srv.memoryVaultPath = path }
}

// WithMemoryRetrieveCompare enables memory_recall's dark retrieval-compare
// mode (Slice B Task 8, memory.retrieve.recall_compare): shadowDB must be an
// ordinarily-writable *db.DB (NOT the server's read-only main handle) used
// exclusively for the one memory_retrieve_shadow insert per call. Absent
// (nil) or never called, memory_recall never touches that table.
func WithMemoryRetrieveCompare(shadowDB *db.DB) ServerOption {
	return func(srv *Server) { srv.retrieveShadowDB = shadowDB }
}

// NewServer builds an MCP server over the given database and registers every
// domain tool.
func NewServer(database *db.DB, opts ...ServerOption) *Server {
	srv := &Server{s: mcpsdk.NewServer(&mcpsdk.Implementation{
		Name:    "watchtower",
		Title:   "Watchtower",
		Version: version,
	}, nil)}
	for _, opt := range opts {
		opt(srv)
	}

	registerTargets(srv.s, database)
	registerDigests(srv.s, database)
	registerPeople(srv.s, database)
	registerJira(srv.s, database)
	registerMessages(srv.s, database)
	registerTranscripts(srv.s, database)
	registerMemory(srv.s, database, srv.memoryVaultPath, srv.retrieveShadowDB)

	return srv
}
```

In `internal/mcp/memory.go`, update `registerMemory` and `memoryRecallHandler`:

```go
func registerMemory(s *mcpsdk.Server, database *db.DB, vaultPath string, retrieveShadowDB *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "memory_map",
		Description: "Read the hot memory world map (map.md — a compact at-a-glance summary; use memory_recall or memory_open for anything not shown) plus node counts by type and tier.",
	}, memoryMapHandler(database, vaultPath))

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "memory_open",
		Description: "Open one memory node by id, alias, or a stale (tombstoned) id; returns the canonical node with body, aliases, and outgoing links.",
	}, memoryOpenHandler(database, vaultPath))

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "memory_recall",
		Description: "Full-text search over memory nodes; an exact alias match ranks first. Returns id, title, type, snippet per hit.",
	}, memoryRecallHandler(database, vaultPath, retrieveShadowDB))
}
```

```go
func memoryRecallHandler(database *db.DB, vaultPath string, retrieveShadowDB *db.DB) func(context.Context, *mcpsdk.CallToolRequest, memoryRecallArgs) (*mcpsdk.CallToolResult, any, error) {
	return func(ctx context.Context, req *mcpsdk.CallToolRequest, args memoryRecallArgs) (*mcpsdk.CallToolResult, any, error) {
		if res := memoryUnavailable(vaultPath); res != nil {
			return res, nil, nil
		}
		query := strings.TrimSpace(args.Query)
		if query == "" {
			return errResult("query is required"), nil, nil
		}
		limit := args.Limit
		switch {
		case limit <= 0:
			limit = defaultRecallLimit
		case limit > maxListLimit:
			limit = maxListLimit
		}

		// An exact alias match (case-insensitive) ranks first: aliases are
		// curated synonyms, so hitting one is a stronger signal than any FTS
		// rank. Recall never bumps stats — browsing is not use; only
		// memory_open counts.
		hits, errRes := recallAliasHit(database, query)
		if errRes != nil {
			return errRes, nil, nil
		}

		ftsHits, err := database.SearchMemoryFTS(query, limit)
		if err != nil {
			return errResult("searching memory: " + err.Error()), nil, nil
		}
		for _, h := range ftsHits {
			if len(hits) > 0 && hits[0].ID == h.ID {
				continue // already present as the alias hit
			}
			hits = append(hits, memoryHitResult{ID: h.ID, Title: h.Title, Type: h.Type, Snippet: h.Snippet})
		}
		if len(hits) > limit {
			hits = hits[:limit]
		}

		// Slice B Task 8 dark retrieval-compare (memory.retrieve.recall_compare):
		// runs RetrieveByQuery and shadow-diffs it against `hits` above — the
		// EXACT combined legacy result this handler is about to return. The
		// comparison result is discarded; the response below is unaffected
		// regardless of the flag. A compare failure is skipped silently here
		// (no logger threaded into this handler today) — it must never fail
		// or alter the actual tool call.
		if retrieveShadowDB != nil {
			legacyIDs := make([]string, len(hits))
			for i, h := range hits {
				legacyIDs[i] = h.ID
			}
			_, _ = memory.CompareRecall(database, retrieveShadowDB, query, legacyIDs, limit)
		}

		return jsonListResult(hits)
	}
}
```

Update `cmd/mcp.go` (near where `internalmcp.WithMemoryVault` is already appended to `opts`):

```go
	var opts []internalmcp.ServerOption
	if cfg.Memory.Enabled {
		opts = append(opts, internalmcp.WithMemoryVault(memoryVaultPath(cfg)))
		if cfg.Memory.Retrieve.RecallCompare {
			shadowDB, err := db.Open(dbPath)
			if err != nil {
				return fmt.Errorf("opening retrieve-compare shadow handle: %w", err)
			}
			defer shadowDB.Close()
			opts = append(opts, internalmcp.WithMemoryRetrieveCompare(shadowDB))
		}
	}
	return internalmcp.NewServer(database, opts...).ServeStdio(cmd.Context())
```

Update `cmd/tools.go` the same way, opening the second handle before `NewServer(...).ConnectLocal(...)`.

- [ ] **Step 4: run — expect green:**

```
$ go test ./internal/mcp/ -run 'TestMemoryRecall' -v 2>&1 | tail -20
--- PASS: TestMemoryRecallAliasFirstNoBump (0.00s)
--- PASS: TestMemoryRecallDedupesAliasHit (0.00s)
--- PASS: TestMemoryRecallLimit (0.00s)
--- PASS: TestMemoryRecallCompare_ShadowWrittenResponseUnchanged (0.01s)
--- PASS: TestMemoryRecallCompare_GateOffWritesNoShadow (0.00s)
PASS

$ go build ./... && go test ./internal/mcp/... ./cmd/... 2>&1 | tail -10
ok  	watchtower/internal/mcp	0.4s
ok  	watchtower/internal/cmd	...
```

- [ ] **Step 5: commit:**

```
$ git add internal/mcp/server.go internal/mcp/memory.go internal/mcp/memory_test.go cmd/mcp.go cmd/tools.go
$ git commit -m "feat(memory): dark retrieval-compare wiring for memory_recall (Slice B Task 8)

memory.retrieve.recall_compare (default false) adds a second, ordinarily-
writable *db.DB handle (WithMemoryRetrieveCompare) alongside the MCP
server's deliberately read-only main connection, used ONLY for the one
memory_retrieve_shadow insert memory_recall's compare path writes. The
tool's returned response is unaffected by the flag in every case, proven by
TestMemoryRecallCompare_ShadowWrittenResponseUnchanged."
```

---

## Task 9: Dark wiring for briefing

**Depends on:** Task 7. **Blocks:** Task 12.

**Files:**
- Modify: `internal/briefing/memory_revisions.go` — `gatherMemoryRevisions`
- Test: `internal/briefing/memory_revisions_test.go` — new tests after `TestGatherMemoryRevisions_GateOffRendersPlaceholder`

**Interfaces:**
- Consumes: `memory.CompareRevisions` (Task 7).
- Produces: nothing new — this task only wires an existing function.

Briefing's `Pipeline` (`p.db *db.DB`) already runs on the daemon/CLI's ordinarily-writable DB — no second-connection wrinkle here.

**Current `gatherMemoryRevisions`, AFTER Task 6's relocation of `notableRevision` into `memory.NotableRevision`** (Task 6 already rewrote this function's loop to call `memory.NotableRevision(node, since)` — a `(RevisionNotability, bool)` return, not the old package-local `notableRevision`'s `(string, bool)` — this is the real current state Task 9 builds on, not the pre-Task-6 shape):

```go
func (p *Pipeline) gatherMemoryRevisions(userID, date string) string {
	if !p.cfg.Memory.Surfaces.Briefing {
		return noNotableRevisions
	}

	since := p.revisionWindowStart(userID, date)

	vault, err := memory.OpenExistingVault(filepath.Join(p.cfg.WorkspaceDir(), "memory"))
	if err != nil {
		if !errors.Is(err, memory.ErrVaultNotInitialized) {
			p.logger.Printf("briefing: opening memory vault for revisions: %v", err)
		}
		return noNotableRevisions
	}

	nodes, err := p.db.ListMemoryNodes()
	if err != nil {
		p.logger.Printf("briefing: error listing memory nodes: %v", err)
		return noNotableRevisions
	}

	var lines []string
	for _, n := range nodes {
		if n.Type != "belief" {
			continue
		}
		node, err := vault.ReadNode(n.ID)
		if err != nil {
			continue
		}
		if nr, ok := memory.NotableRevision(node, since); ok {
			lines = append(lines, nr.Line)
			if len(lines) >= maxMemoryRevisions {
				break
			}
		}
	}

	if len(lines) == 0 {
		return noNotableRevisions
	}
	return strings.Join(lines, "\n")
}
```

- [ ] **Step 1: write the failing test** — add to `internal/briefing/memory_revisions_test.go`, after `TestGatherMemoryRevisions_GateOffRendersPlaceholder`:

```go
// TestGatherMemoryRevisions_CompareShadowWrittenJournalUnchanged: with
// memory.retrieve.briefing_compare on, gatherMemoryRevisions ALSO runs
// RetrieveRevisions and writes one memory_retrieve_shadow row — but the
// rendered "Memory revisions" journal text is byte-identical to the flag-off
// legacy render (the single most important behavioral guarantee).
func TestGatherMemoryRevisions_CompareShadowWrittenJournalUnchanged(t *testing.T) {
	database, cfg, vaultPath := setupBriefingWithVault(t)
	today := time.Now().UTC().Format("2006-01-02")
	writeBelief(t, database, vaultPath, "bel_shaken", "Bob prefers async reviews", "shaken", 0.4,
		"- 2020-01-01: created — first observed\n- "+today+": shake — evidence now conflicts\n")

	baseline := runBriefingCapturing(t, database, cfg)
	baselineSection := memoryRevisionsSection(t, baseline)

	cfg.Memory.Retrieve.BriefingCompare = true
	compared := runBriefingCapturing(t, database, cfg)
	comparedSection := memoryRevisionsSection(t, compared)

	require.Equal(t, baselineSection, comparedSection, "compare mode must not change the rendered journal")

	rows, err := database.ListMemoryRetrieveShadow("briefing", time.Time{})
	require.NoError(t, err)
	require.Len(t, rows, 1, "exactly one briefing shadow row from the compare-mode run")

	var diff memory.RevisionDiff
	require.NoError(t, json.Unmarshal([]byte(rows[0].DiffMetricsJSON), &diff))
	assert.Contains(t, diff.OldIDs, "bel_shaken")
}

// TestGatherMemoryRevisions_CompareGateOffWritesNoShadow: without the flag,
// no memory_retrieve_shadow row is ever written — byte-identical to before
// this task existed.
func TestGatherMemoryRevisions_CompareGateOffWritesNoShadow(t *testing.T) {
	database, cfg, vaultPath := setupBriefingWithVault(t)
	today := time.Now().UTC().Format("2006-01-02")
	writeBelief(t, database, vaultPath, "bel_shaken", "Bob prefers async reviews", "shaken", 0.4,
		"- "+today+": shake — evidence conflicts\n")

	runBriefingCapturing(t, database, cfg)

	rows, err := database.ListMemoryRetrieveShadow("briefing", time.Time{})
	require.NoError(t, err)
	assert.Empty(t, rows)
}
```

- [ ] **Step 2: run — expect a compile pass but assertion failure** (the flag has no effect yet, so no shadow row is written even with it on):

```
$ go test ./internal/briefing/ -run TestGatherMemoryRevisions_CompareShadowWrittenJournalUnchanged -v
=== RUN   TestGatherMemoryRevisions_CompareShadowWrittenJournalUnchanged
    memory_revisions_test.go:XXX: expected exactly one briefing shadow row, got 0
--- FAIL: TestGatherMemoryRevisions_CompareShadowWrittenJournalUnchanged (0.02s)
FAIL
```

- [ ] **Step 3: implement.** Replace `gatherMemoryRevisions`'s loop to also capture ids, and add the compare call after the loop:

```go
func (p *Pipeline) gatherMemoryRevisions(userID, date string) string {
	if !p.cfg.Memory.Surfaces.Briefing {
		return noNotableRevisions
	}

	since := p.revisionWindowStart(userID, date)

	vault, err := memory.OpenExistingVault(filepath.Join(p.cfg.WorkspaceDir(), "memory"))
	if err != nil {
		if !errors.Is(err, memory.ErrVaultNotInitialized) {
			p.logger.Printf("briefing: opening memory vault for revisions: %v", err)
		}
		return noNotableRevisions
	}

	nodes, err := p.db.ListMemoryNodes()
	if err != nil {
		p.logger.Printf("briefing: error listing memory nodes: %v", err)
		return noNotableRevisions
	}

	var lines, ids []string
	for _, n := range nodes {
		if n.Type != "belief" {
			continue
		}
		node, err := vault.ReadNode(n.ID)
		if err != nil {
			continue
		}
		if nr, ok := memory.NotableRevision(node, since); ok {
			lines = append(lines, nr.Line)
			ids = append(ids, n.ID)
			if len(lines) >= maxMemoryRevisions {
				break
			}
		}
	}

	// Slice B Task 9 dark retrieval-compare (memory.retrieve.briefing_compare):
	// runs RetrieveRevisions and shadow-diffs it against `ids` — the EXACT
	// legacy notable-revision selection above, same cap. The rendered journal
	// text below is unaffected by the flag in every case.
	if p.cfg.Memory.Retrieve.BriefingCompare {
		sinceTS := float64(since.Unix())
		if _, err := memory.CompareRevisions(p.db, p.db, vault, sinceTS, ids, maxMemoryRevisions); err != nil {
			p.logger.Printf("briefing: retrieve compare: %v", err)
		}
	}

	if len(lines) == 0 {
		return noNotableRevisions
	}
	return strings.Join(lines, "\n")
}
```

- [ ] **Step 4: run — expect green:**

```
$ go test ./internal/briefing/ -run 'TestGatherMemoryRevisions' -v 2>&1 | tail -15
--- PASS: TestGatherMemoryRevisions_StatusTransitionSurfaces (0.01s)
--- PASS: TestGatherMemoryRevisions_SubThresholdConfidenceWiggleOmitted (0.01s)
--- PASS: TestGatherMemoryRevisions_CapsAtFive (0.02s)
--- PASS: TestGatherMemoryRevisions_GateOffRendersPlaceholder (0.01s)
--- PASS: TestGatherMemoryRevisions_CompareShadowWrittenJournalUnchanged (0.02s)
--- PASS: TestGatherMemoryRevisions_CompareGateOffWritesNoShadow (0.01s)
PASS

$ go test ./internal/briefing/... 2>&1 | tail -5
ok  	watchtower/internal/briefing	1.1s
```

- [ ] **Step 5: commit:**

```
$ git add internal/briefing/memory_revisions.go internal/briefing/memory_revisions_test.go
$ git commit -m "feat(memory): dark retrieval-compare wiring for briefing (Slice B Task 9)

memory.retrieve.briefing_compare (default false) runs RetrieveRevisions
alongside gatherMemoryRevisions' existing notable-revision selection and
shadow-diffs the two — the rendered 'Memory revisions' journal text stays
byte-identical regardless of the flag, proven by
TestGatherMemoryRevisions_CompareShadowWrittenJournalUnchanged."
```

---

## Task 10: Dark wiring for meeting-prep

**Depends on:** Task 7. **Blocks:** Task 12.

**Files:**
- Modify: `internal/meeting/memory_context.go` — `gatherMemoryContext`, `beliefLinesFor`
- Test: `internal/meeting/memory_context_test.go` — new tests after `TestGatherMemoryContext_Capped`

**Interfaces:**
- Consumes: `memory.CompareSubject` (Task 7).
- Produces: nothing new.

Meeting's `Pipeline` (`p.db *db.DB`) also runs on an ordinarily-writable DB — no second-connection wrinkle.

Current `gatherMemoryContext`'s per-attendee loop body ends with:

```go
		for _, line := range beliefLinesFor(nodes, node.ID) {
			if !add(line) {
				break
			}
		}
	}
```

and `beliefLinesFor`:

```go
func beliefLinesFor(nodes []db.MemoryNodeRow, entityID string) []string {
	var lines []string
	for _, n := range nodes {
		if n.Type != "belief" || n.Subject != entityID {
			continue
		}
		if n.Status != "active" && n.Status != "shaken" {
			continue
		}
		title := strings.TrimSpace(n.Title)
		if title == "" {
			title = n.ID
		}
		lines = append(lines, fmt.Sprintf("- belief: %s (confidence %.1f, %s)", title, n.Confidence, n.Status))
		if len(lines) >= maxAttendeeBeliefs {
			break
		}
	}
	return lines
}
```

**Design decision (matching the diff apples-to-apples):** `CompareSubject`'s `limitLong` is set to `maxAttendeeBeliefs` (3) — the SAME cap `beliefLinesFor` already applies — so the comparison is against what would actually be shown, not an uncapped candidate set that would generate spurious "coverage broken" noise from beliefs the legacy path never surfaces either.

- [ ] **Step 1: write the failing test** — add to `internal/meeting/memory_context_test.go`, after `TestGatherMemoryContext_Capped`:

```go
// TestGatherMemoryContext_CompareShadowWrittenContextUnchanged: with
// memory.retrieve.meeting_prep_compare on, gatherMemoryContext ALSO runs
// RetrieveBySubject per attendee and writes a memory_retrieve_shadow row —
// but the rendered ATTENDEE MEMORY block is byte-identical to the flag-off
// legacy render (the single most important behavioral guarantee).
func TestGatherMemoryContext_CompareShadowWrittenContextUnchanged(t *testing.T) {
	cfg := memCtxCfg(t, true)
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", []string{"prefers async comms"}, []string{"U123", "alice@example.com"})
	writeBelief(t, d, vp, "bel_a1", "Alice dislikes long meetings", "ent_alice", "active", 0.6)

	p := New(d, cfg, &mockGenerator{}, nil)
	baseline := p.gatherMemoryContext(aliceAttendees())

	cfg.Memory.Retrieve.MeetingPrepCompare = true
	compared := p.gatherMemoryContext(aliceAttendees())

	require.Equal(t, baseline, compared, "compare mode must not change the rendered attendee memory block")

	rows, err := d.ListMemoryRetrieveShadow("meeting_prep", time.Time{})
	require.NoError(t, err)
	require.Len(t, rows, 1, "one shadow row for the one attendee with a resolved entity (Bob has none)")

	var diff memory.SubjectDiff
	require.NoError(t, json.Unmarshal([]byte(rows[0].DiffMetricsJSON), &diff))
	assert.Equal(t, "ent_alice", diff.Subject)
	assert.Contains(t, diff.OldBeliefIDs, "bel_a1")
}

// TestGatherMemoryContext_CompareGateOffWritesNoShadow: without the flag, no
// memory_retrieve_shadow row is ever written.
func TestGatherMemoryContext_CompareGateOffWritesNoShadow(t *testing.T) {
	cfg := memCtxCfg(t, true) // meeting_prep surface on, retrieve-compare off
	vp := initMemVault(t, cfg)
	d := openTestDB(t)
	writePersonEntity(t, d, vp, "ent_alice", "Alice", "Backend lead", "Owns the migration", nil, []string{"U123"})

	p := New(d, cfg, &mockGenerator{}, nil)
	p.gatherMemoryContext(aliceAttendees())

	rows, err := d.ListMemoryRetrieveShadow("meeting_prep", time.Time{})
	require.NoError(t, err)
	assert.Empty(t, rows)
}
```

- [ ] **Step 2: run — expect an assertion failure** (no shadow row written yet):

```
$ go test ./internal/meeting/ -run TestGatherMemoryContext_CompareShadowWrittenContextUnchanged -v
=== RUN   TestGatherMemoryContext_CompareShadowWrittenContextUnchanged
    memory_context_test.go:XXX: one shadow row for the one attendee with a resolved entity (Bob has none)
        expected: 1
        actual  : 0
--- FAIL: TestGatherMemoryContext_CompareShadowWrittenContextUnchanged (0.01s)
FAIL
```

- [ ] **Step 3: implement.** Extract the legacy belief-id list alongside the rendered lines, and add the compare call. `beliefLinesFor` stays untouched (its output is still what's rendered); a new sibling helper captures the ids:

```go
// beliefIDsFor returns the same subset+cap beliefLinesFor renders, as bare
// ids — the legacy side of Task 10's retrieval compare. Kept in lockstep
// with beliefLinesFor's filter (type=belief, subject match, active/shaken,
// same maxAttendeeBeliefs cap) by construction: both walk the same nodes
// slice with the same predicate, so the two can never silently drift.
func beliefIDsFor(nodes []db.MemoryNodeRow, entityID string) []string {
	var ids []string
	for _, n := range nodes {
		if n.Type != "belief" || n.Subject != entityID {
			continue
		}
		if n.Status != "active" && n.Status != "shaken" {
			continue
		}
		ids = append(ids, n.ID)
		if len(ids) >= maxAttendeeBeliefs {
			break
		}
	}
	return ids
}

// meetingPrepShortTermSampleLimit bounds CompareSubject's shortTerm episode
// sample — purely additive telemetry with no legacy equivalent to size
// against, so this is just a reasonable exercise cap, not a rendered limit.
const meetingPrepShortTermSampleLimit = 5
```

and in `gatherMemoryContext`'s attendee loop, right after the existing `beliefLinesFor` block:

```go
		for _, line := range beliefLinesFor(nodes, node.ID) {
			if !add(line) {
				break
			}
		}

		// Slice B Task 10 dark retrieval-compare (memory.retrieve.meeting_prep_compare):
		// runs RetrieveBySubject for this attendee and shadow-diffs it against
		// beliefIDsFor's legacy selection above (same cap). The rendered
		// ATTENDEE MEMORY block is unaffected by the flag in every case.
		if p.cfg.Memory.Retrieve.MeetingPrepCompare {
			legacyIDs := beliefIDsFor(nodes, node.ID)
			if _, err := memory.CompareSubject(p.db, p.db, node.ID, legacyIDs, maxAttendeeBeliefs, meetingPrepShortTermSampleLimit); err != nil {
				p.logger.Printf("meeting: retrieve compare (subject %s): %v", node.ID, err)
			}
		}
	}
```

- [ ] **Step 4: run — expect green:**

```
$ go test ./internal/meeting/ -run 'TestGatherMemoryContext' -v 2>&1 | tail -20
--- PASS: TestGatherMemoryContext_GateOffReturnsSentinel (0.00s)
--- PASS: TestGatherMemoryContext_GateOnRendersPageAndBelief (0.01s)
--- PASS: TestGatherMemoryContext_AttendeeNoEntityAbsenceLine (0.01s)
--- PASS: TestGatherMemoryContext_ShakenBeliefShownAsShaken (0.01s)
--- PASS: TestGatherMemoryContext_EmailFallback (0.01s)
--- PASS: TestGatherMemoryContext_VaultAbsentReturnsSentinel (0.00s)
--- PASS: TestGatherMemoryContext_Capped (0.02s)
--- PASS: TestGatherMemoryContext_CompareShadowWrittenContextUnchanged (0.02s)
--- PASS: TestGatherMemoryContext_CompareGateOffWritesNoShadow (0.01s)
PASS

$ go test ./internal/meeting/... 2>&1 | tail -5
ok  	watchtower/internal/meeting	1.0s
```

- [ ] **Step 5: commit:**

```
$ git add internal/meeting/memory_context.go internal/meeting/memory_context_test.go
$ git commit -m "feat(memory): dark retrieval-compare wiring for meeting-prep (Slice B Task 10)

memory.retrieve.meeting_prep_compare (default false) runs RetrieveBySubject
per attendee and shadow-diffs it against beliefIDsFor's legacy selection
(new sibling of beliefLinesFor, same filter/cap by construction) — the
rendered ATTENDEE MEMORY block stays byte-identical regardless of the flag,
proven by TestGatherMemoryContext_CompareShadowWrittenContextUnchanged."
```

---

## Task 11: `watchtower memory retrieve-compare` CLI command + MEM-inventory docs

**Depends on:** Tasks 7–10. **Blocks:** Task 12, Task 13.

**Files:**
- Create: `internal/memory/retrieve_compare_cli.go` (+ `_test.go`) — `RunRetrieveCompare`, `RenderRetrieveCompareReport`
- Modify: `cmd/memory.go` — new `memoryRetrieveCompareCmd` subcommand, `runMemoryRetrieveCompare`
- Modify: `docs/inventory/memory.md` — new contract **MEM-17** (owner-confirmed 2026-07-20: Slice B is a new mechanism — unified retrieval ranking, not an extension of MEM-16's importance-score foundation — so it gets a new number, per the same-day owner review's own "new number only for a new principle" rule), module/audit-date header, changelog

**Interfaces:**
- Consumes: `memory.CompareRecall`/`CompareRevisions`/`CompareSubject` (Task 7).
- Produces: nothing consumed elsewhere — this is the terminal on-demand entry point.

**Flagged decision — recall's synthetic query sample.** There is no logged history of real `memory_recall` queries to replay offline. This task samples up to `retrieveCompareQuerySample` (30) distinct, non-tombstone node **titles** from `ListMemoryNodes` as synthetic queries — weaker evidence than a real query log, but grounded in real vault content and exercises the FTS/rank path meaningfully. If a better source of real historical queries exists before Task 13's real-data run, prefer supplying it.

- [ ] **Step 1: write the failing test** — create `internal/memory/retrieve_compare_cli_test.go`:

```go
package memory

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestRunRetrieveCompare_AllSurfaces: a single RunRetrieveCompare call
// exercises all three surfaces against a small seeded vault/DB and writes
// one shadow row per surface, without touching memory_nodes.
func TestRunRetrieveCompare_AllSurfaces(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RC01", "entity", "Target Entity")
	writeNodes(t, v, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	stats, err := RunRetrieveCompare(d, v, time.Now().Add(-24*time.Hour), []string{"recall", "briefing", "meeting_prep"})
	require.NoError(t, err)
	assert.GreaterOrEqual(t, stats.RecallCompared, 1)
	assert.Equal(t, 1, stats.BriefingCompared)
	assert.GreaterOrEqual(t, stats.MeetingPrepCompared, 0) // 0 subjects when no beliefs exist yet — a clean, not-failed, run

	for _, surface := range []string{"recall", "briefing"} {
		rows, err := d.ListMemoryRetrieveShadow(surface, time.Time{})
		require.NoError(t, err)
		assert.NotEmpty(t, rows, "surface %s must have written at least one shadow row", surface)
	}
}

// TestRunRetrieveCompare_SurfaceFilter: passing a single surface name runs
// only that surface.
func TestRunRetrieveCompare_SurfaceFilter(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RC02", "entity", "Only Recall")
	writeNodes(t, v, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	stats, err := RunRetrieveCompare(d, v, time.Now().Add(-24*time.Hour), []string{"recall"})
	require.NoError(t, err)
	assert.Equal(t, 0, stats.BriefingCompared)
	assert.Equal(t, 0, stats.MeetingPrepCompared)

	rows, err := d.ListMemoryRetrieveShadow("briefing", time.Time{})
	require.NoError(t, err)
	assert.Empty(t, rows)
}

func TestRenderRetrieveCompareReport(t *testing.T) {
	report := RenderRetrieveCompareReport(RetrieveCompareStats{
		RecallCompared: 3, BriefingCompared: 1, MeetingPrepCompared: 2,
	}, time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC))
	assert.Contains(t, report, "Recall")
	assert.Contains(t, report, "Briefing")
	assert.Contains(t, report, "Meeting prep")
	assert.Contains(t, report, "hand-review")
}
```

- [ ] **Step 2: run — expect a build failure** (`RunRetrieveCompare`/`RenderRetrieveCompareReport` undefined):

```
$ go test ./internal/memory/ -run TestRunRetrieveCompare -v
# watchtower/internal/memory [watchtower/internal/memory.test]
./retrieve_compare_cli_test.go:XXX: undefined: RunRetrieveCompare
FAIL	watchtower/internal/memory [build failed]
```

- [ ] **Step 3: implement.** Create `internal/memory/retrieve_compare_cli.go`:

```go
package memory

// This file is Task 11's offline CLI entry point: it exercises all three
// Task-7 Compare* functions against whatever vault/DB the CLI is pointed at
// — the current live workspace by default, or a read-only snapshot copy for
// Task 13's real-data run — using synthetic-but-grounded inputs for surfaces
// that have no natural batch substrate (recall) and real DB state for those
// that do (briefing's since-window, meeting-prep's actual belief subjects).

import (
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// retrieveCompareQuerySample bounds how many synthetic recall queries a CLI
// run tries — a sample of real node titles, not a real query log (none
// exists; flagged above as weaker evidence than a real sample, should one
// become available before Task 13).
const retrieveCompareQuerySample = 30

// RetrieveCompareStats is RunRetrieveCompare's outcome — the report's input.
type RetrieveCompareStats struct {
	RecallCompared      int
	BriefingCompared    int
	MeetingPrepCompared int
	Failed              int
}

// RunRetrieveCompare exercises the requested surfaces (any of "recall",
// "briefing", "meeting_prep") against database/vault and returns how many
// comparisons were made. A per-item failure (a single query, or one
// attendee subject) is counted in Failed and does not abort the run —
// matching CompareDigests' per-channel isolation precedent. database is used
// for BOTH the read and the shadow write (unlike Task 8's MCP wiring, the
// CLI's own DB handle is ordinarily writable).
func RunRetrieveCompare(database *db.DB, vault *Vault, since time.Time, surfaces []string) (RetrieveCompareStats, error) {
	var stats RetrieveCompareStats
	want := make(map[string]bool, len(surfaces))
	for _, s := range surfaces {
		want[s] = true
	}

	if want["recall"] {
		n, failed, err := runRecallCompareBatch(database)
		if err != nil {
			return stats, err
		}
		stats.RecallCompared = n
		stats.Failed += failed
	}
	if want["briefing"] {
		n, err := runBriefingCompareBatch(database, vault, since)
		if err != nil {
			return stats, err
		}
		stats.BriefingCompared = n
	}
	if want["meeting_prep"] {
		n, failed, err := runMeetingPrepCompareBatch(database)
		if err != nil {
			return stats, err
		}
		stats.MeetingPrepCompared = n
		stats.Failed += failed
	}
	return stats, nil
}

// runRecallCompareBatch samples up to retrieveCompareQuerySample distinct
// non-tombstone node titles as synthetic queries and runs CompareRecall for
// each, using the SAME legacy computation memory_recall's live handler uses
// (recallAliasHit + SearchMemoryFTS) so the CLI's "legacy" side is not a
// re-implementation that could silently drift from the real one.
func runRecallCompareBatch(database *db.DB) (compared, failed int, err error) {
	nodes, err := database.ListMemoryNodes()
	if err != nil {
		return 0, 0, fmt.Errorf("memory: retrieve-compare recall: listing nodes: %w", err)
	}
	seen := make(map[string]bool)
	for _, n := range nodes {
		if n.Status == "tombstone" || n.Title == "" || seen[n.Title] {
			continue
		}
		seen[n.Title] = true
		if len(seen) > retrieveCompareQuerySample {
			break
		}
		legacyIDs, ferr := legacyRecallIDs(database, n.Title, defaultRecallLimit)
		if ferr != nil {
			failed++
			continue
		}
		if _, cerr := CompareRecall(database, database, n.Title, legacyIDs, defaultRecallLimit); cerr != nil {
			failed++
			continue
		}
		compared++
	}
	return compared, failed, nil
}

// legacyRecallIDs reproduces memory_recall's exact legacy combination
// (alias-first, then FTS, deduped, capped) as a bare id list — kept in one
// place so both the live MCP handler (Task 8) and this offline batch runner
// compute "the legacy result" identically; a future drift between them would
// be a real bug, not a design choice, so this helper is the single source.
func legacyRecallIDs(database *db.DB, query string, limit int) ([]string, error) {
	nodeID, err := database.LookupMemoryAlias(query)
	var ids []string
	if err == nil {
		ids = append(ids, nodeID)
	}
	ftsHits, err := database.SearchMemoryFTS(query, limit)
	if err != nil {
		return nil, err
	}
	for _, h := range ftsHits {
		if len(ids) > 0 && ids[0] == h.ID {
			continue
		}
		ids = append(ids, h.ID)
	}
	if len(ids) > limit {
		ids = ids[:limit]
	}
	return ids, nil
}

// runBriefingCompareBatch runs one CompareRevisions call for the whole
// since-window — briefing's own live call is likewise a single call per
// generation, so this is a faithful one-shot exercise, not a sample.
func runBriefingCompareBatch(database *db.DB, vault *Vault, since time.Time) (int, error) {
	sinceTS := float64(since.Unix())
	legacyIDs, err := legacyRevisionIDs(database, vault, since)
	if err != nil {
		return 0, fmt.Errorf("memory: retrieve-compare briefing: legacy selection: %w", err)
	}
	if _, err := CompareRevisions(database, database, vault, sinceTS, legacyIDs, maxRevisionCompareLimit); err != nil {
		return 0, fmt.Errorf("memory: retrieve-compare briefing: %w", err)
	}
	return 1, nil
}

// maxRevisionCompareLimit mirrors internal/briefing's maxMemoryRevisions (5)
// without importing internal/briefing (would be a package cycle) — a code
// const duplicated at the same value, matching digest_render.go's precedent
// of mirroring the legacy digest_topics JSON shape locally rather than
// importing it.
const maxRevisionCompareLimit = 5

// legacyRevisionIDs reproduces briefing's exact notable-revision belief-id
// selection (status transition or |confidence delta| >= 0.2, capped) as a
// bare id list, so the CLI's "legacy" side matches the live one exactly.
// Calls the SAME memory.NotableRevision (Task 6's relocation) briefing
// itself calls — this file is package memory, so no import prefix needed.
func legacyRevisionIDs(database *db.DB, vault *Vault, since time.Time) ([]string, error) {
	nodes, err := database.ListMemoryNodes()
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, n := range nodes {
		if n.Type != "belief" {
			continue
		}
		node, err := vault.ReadNode(n.ID)
		if err != nil {
			continue
		}
		if _, ok := NotableRevision(node, since); ok {
			ids = append(ids, n.ID)
			if len(ids) >= maxRevisionCompareLimit {
				break
			}
		}
	}
	return ids, nil
}

// runMeetingPrepCompareBatch runs one CompareSubject call per distinct
// belief subject entity — a real, non-synthetic sample: every entity that
// has ever been an attendee's resolved memory page in production would have
// exactly this shape.
func runMeetingPrepCompareBatch(database *db.DB) (compared, failed int, err error) {
	nodes, err := database.ListMemoryNodes()
	if err != nil {
		return 0, 0, fmt.Errorf("memory: retrieve-compare meeting-prep: listing nodes: %w", err)
	}
	subjects := make(map[string]bool)
	for _, n := range nodes {
		if n.Type == "belief" && n.Subject != "" && (n.Status == "active" || n.Status == "shaken") {
			subjects[n.Subject] = true
		}
	}
	for subject := range subjects {
		legacyIDs := legacyBeliefIDsForSubject(nodes, subject)
		if _, cerr := CompareSubject(database, database, subject, legacyIDs, meetingPrepCompareLimitLong, meetingPrepCompareLimitShort); cerr != nil {
			failed++
			continue
		}
		compared++
	}
	return compared, failed, nil
}

// meetingPrepCompareLimitLong/Short mirror internal/meeting's
// maxAttendeeBeliefs (3) and Task 10's meetingPrepShortTermSampleLimit (5)
// without importing internal/meeting (a package cycle) — see
// maxRevisionCompareLimit's comment for why this local duplication is the
// house pattern here.
const (
	meetingPrepCompareLimitLong  = 3
	meetingPrepCompareLimitShort = 5
)

// legacyBeliefIDsForSubject reproduces meeting-prep's exact belief selection
// for one subject (active/shaken, capped) as a bare id list.
func legacyBeliefIDsForSubject(nodes []db.MemoryNodeRow, subject string) []string {
	var ids []string
	for _, n := range nodes {
		if n.Type != "belief" || n.Subject != subject {
			continue
		}
		if n.Status != "active" && n.Status != "shaken" {
			continue
		}
		ids = append(ids, n.ID)
		if len(ids) >= meetingPrepCompareLimitLong {
			break
		}
	}
	return ids
}

// RenderRetrieveCompareReport renders the human-readable markdown compare
// report — deterministic (same stats + timestamp -> identical bytes),
// mirroring RenderCompareReport's shape for the digest-compare precedent.
func RenderRetrieveCompareReport(stats RetrieveCompareStats, generatedAt time.Time) string {
	var b strings.Builder
	b.WriteString("# Retrieval compare report (dark compare-mode, Slice B)\n\n")
	fmt.Fprintf(&b, "Generated: %s\n\n", generatedAt.UTC().Format(time.RFC3339))
	b.WriteString("> Auto-generated by `watchtower memory retrieve-compare`. Every legacy selection stays authoritative and byte-untouched; these comparisons live only in `memory_retrieve_shadow`.\n\n")
	fmt.Fprintf(&b, "- Recall: %d compared (%d failed)\n", stats.RecallCompared, stats.Failed)
	fmt.Fprintf(&b, "- Briefing: %d compared\n", stats.BriefingCompared)
	fmt.Fprintf(&b, "- Meeting prep: %d compared\n\n", stats.MeetingPrepCompared)
	b.WriteString("## Hand-review protocol\n\n")
	b.WriteString("Read `memory_retrieve_shadow` per surface: for recall, confirm coverage_ok on most queries and compare mean_importance_old vs new; for briefing, confirm the top-5 intersection is high and note any importance-driven reordering; for meeting-prep, confirm new_superset_ok and spot-check new_short_term_ids for plausibility (not automatable). See Task 13 for the switch go/no-go criteria.\n")
	return b.String()
}
```

- [ ] **Step 4: run — expect green:**

```
$ go test ./internal/memory/ -run 'TestRunRetrieveCompare|TestRenderRetrieveCompareReport' -v
--- PASS: TestRunRetrieveCompare_AllSurfaces (0.03s)
--- PASS: TestRunRetrieveCompare_SurfaceFilter (0.02s)
--- PASS: TestRenderRetrieveCompareReport (0.00s)
PASS
```

- [ ] **Step 5: CLI subcommand.** Add to `cmd/memory.go`, mirroring `memoryDigestCompareCmd`:

```go
var memoryRetrieveCompareCmd = &cobra.Command{
	Use:   "retrieve-compare",
	Short: "Run the Slice B dark retrieval-compare (recall/briefing/meeting_prep) against the current vault/DB",
	Long: "Owner-facing diagnostic for the Phase-5 Slice B unified retrieval ranking. Runs the new\n" +
		"RankByImportance-based retrieval alongside each surface's legacy selection and writes a\n" +
		"per-comparison diff to memory_retrieve_shadow. Every legacy selection (memory_recall's FTS\n" +
		"ranking, briefing's notable-revision order, meeting-prep's confidence order) is a pure read here\n" +
		"— nothing about a live response changes. The report exists for the go/no-go hand-review\n" +
		"before any per-surface switch (see docs/inventory/memory.md).",
	RunE: runMemoryRetrieveCompare,
}

func init() {
	// ... existing AddCommand call, append memoryRetrieveCompareCmd:
	memoryCmd.AddCommand(memoryStatusCmd, memoryReindexCmd, memoryOpenCmd,
		memoryRecallCmd, memoryConsolidateCmd, memorySeedCmd, memoryIndexCmd,
		memoryDigestCompareCmd, memoryRetrieveCompareCmd)

	memoryRetrieveCompareCmd.Flags().Duration("since", 24*time.Hour, "briefing surface: compare notable revisions since this lookback")
	memoryRetrieveCompareCmd.Flags().String("out", "docs/specs/memory-retrieve-compare-report.md", "path to write the markdown compare report")
	memoryRetrieveCompareCmd.Flags().StringSlice("surface", []string{"recall", "briefing", "meeting_prep"}, "which surfaces to compare (recall, briefing, meeting_prep)")
}

func runMemoryRetrieveCompare(cmd *cobra.Command, _ []string) error {
	since, _ := cmd.Flags().GetDuration("since")
	outPath, _ := cmd.Flags().GetString("out")
	surfaces, _ := cmd.Flags().GetStringSlice("surface")
	cfg, database, err := memoryConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	if !cfg.Memory.Enabled {
		fmt.Fprintln(out, "Memory is disabled (memory.enabled = false in config); nothing to compare.")
		return nil
	}

	vault, err := memory.OpenExistingVault(memoryVaultPath(cfg))
	if errors.Is(err, memory.ErrVaultNotInitialized) {
		fmt.Fprintln(out, "Memory vault not initialized; nothing to compare.")
		return nil
	}
	if err != nil {
		return err
	}

	stats, err := memory.RunRetrieveCompare(database, vault, time.Now().Add(-since), surfaces)
	if err != nil {
		return fmt.Errorf("retrieve compare: %w", err)
	}

	report := memory.RenderRetrieveCompareReport(stats, time.Now())
	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		return fmt.Errorf("creating report directory: %w", err)
	}
	if err := os.WriteFile(outPath, []byte(report), 0o644); err != nil {
		return fmt.Errorf("writing compare report to %s: %w", outPath, err)
	}

	fmt.Fprintf(out, "Retrieve compare done: recall %d (failed %d), briefing %d, meeting_prep %d.\n",
		stats.RecallCompared, stats.Failed, stats.BriefingCompared, stats.MeetingPrepCompared)
	fmt.Fprintf(out, "Report written to %s\n", outPath)
	return nil
}
```

- [ ] **Step 6: run — expect green:**

```
$ go build ./... && go test ./cmd/... ./internal/memory/... 2>&1 | tail -10
ok  	watchtower/internal/cmd	...
ok  	watchtower/internal/memory	...
```

- [ ] **Step 7: docs — inventory addendum.** Update `docs/inventory/memory.md` with a new **MEM-17** contract entry, following existing formatting exactly (Observable/Why-locked/Test-guards/Locked-since), plus a changelog entry summarizing: `RankByImportance` as the one place `importance_score`/relevance combine; `RetrieveByQuery`/`RetrieveBySubject`/`RetrieveRevisions` replacing memory_recall's FTS-only rank, meeting-prep's confidence-only order, and briefing's encounter-order selection; dark compare-mode (all three flags default false) with the byte-identical-live-response guarantee proven per surface; the `WithMemoryRetrieveCompare` second-writable-handle exception to `internal/mcp`'s read-only rule; the evidence-gated per-surface switch as Task 13, not automatic. **Before editing**, re-check `docs/inventory/memory.md`'s current state — as of this plan's writing there is an uncommitted, separate 2026-07-20 owner-review pass in the working tree that renumbered/merged MEM-10/14 into MEM-05 and MEM-13 into MEM-01; if that pass has landed (or moved further) by the time this task runs, write MEM-17 against whatever the file's live "last full audit" and highest live MEM number actually are, not against this plan's snapshot of it.

- [ ] **Step 8: commit:**

```
$ git add internal/memory/retrieve_compare_cli.go internal/memory/retrieve_compare_cli_test.go cmd/memory.go docs/inventory/memory.md
$ git commit -m "feat(memory): watchtower memory retrieve-compare CLI + inventory addendum (Slice B Task 11)

New offline batch runner (RunRetrieveCompare) exercises all three Slice B
retrieval-compare surfaces against the CLI's current vault/DB: recall via a
sample of real node titles as synthetic queries (no historical query log
exists — flagged as weaker evidence than a real sample), briefing via a
single since-window pass, meeting-prep via every real belief subject
entity. New watchtower memory retrieve-compare [--since --out --surface]
CLI subcommand mirrors digest-compare's shape."
```

---

## Task 12: Final verification (all-green gate)

**Depends on:** Tasks 7–11. **Blocks:** Task 13.

**Files:** none (verification only).

- [ ] **Step 1: formatting.**

```
$ gofmt -l internal/memory/retrieve_compare.go internal/memory/retrieve_compare_test.go \
    internal/memory/retrieve_compare_cli.go internal/memory/retrieve_compare_cli_test.go \
    internal/mcp/server.go internal/mcp/memory.go internal/mcp/memory_test.go \
    internal/briefing/memory_revisions.go internal/briefing/memory_revisions_test.go \
    internal/meeting/memory_context.go internal/meeting/memory_context_test.go \
    internal/config/config.go internal/db/memory.go internal/db/memory_test.go \
    internal/db/db_test.go cmd/memory.go cmd/mcp.go cmd/tools.go
```

Expected: **no output** (if any `.go` file prints, `gofmt -w` and re-check until silent).

- [ ] **Step 2: vet.**

```
$ go vet ./...
```

Expected: no output, exit 0.

- [ ] **Step 3: build.**

```
$ go build ./... 2>&1 | tee /tmp/build.log; echo "exit=$?"
exit=0
```

- [ ] **Step 4: every directly-touched package, verbose, checking real exit codes (never piped through `tail` alone):**

```
$ go test ./internal/memory/... ./internal/db/... ./internal/mcp/... ./internal/briefing/... ./internal/meeting/... ./cmd/... -v > /tmp/test.log 2>&1; echo "exit=$?"
exit=0

$ grep -E "^--- (PASS|FAIL)" /tmp/test.log | grep -i "retrieve\|Compare"
--- PASS: TestRetrieveCompare_LegacyTablesByteIdentical (0.03s)
--- PASS: TestMemoryRetrieveShadowRoundTrip (0.01s)
--- PASS: TestMigration00029MemoryRetrieveShadow (0.01s)
--- PASS: TestMemoryRecallCompare_ShadowWrittenResponseUnchanged (0.01s)
--- PASS: TestMemoryRecallCompare_GateOffWritesNoShadow (0.00s)
--- PASS: TestGatherMemoryRevisions_CompareShadowWrittenJournalUnchanged (0.02s)
--- PASS: TestGatherMemoryRevisions_CompareGateOffWritesNoShadow (0.01s)
--- PASS: TestGatherMemoryContext_CompareShadowWrittenContextUnchanged (0.02s)
--- PASS: TestGatherMemoryContext_CompareGateOffWritesNoShadow (0.01s)
--- PASS: TestRunRetrieveCompare_AllSurfaces (0.03s)
--- PASS: TestRunRetrieveCompare_SurfaceFilter (0.02s)
--- PASS: TestRenderRetrieveCompareReport (0.00s)

$ grep "^FAIL" /tmp/test.log
(no output)
```

- [ ] **Step 5: full suite, for completeness:**

```
$ go test ./... > /tmp/full-test.log 2>&1; echo "exit=$?"; grep -c "^ok" /tmp/full-test.log; grep "^FAIL" /tmp/full-test.log
exit=0
```

Expected: `exit=0`, no `FAIL` lines.

- [ ] **Step 6: final commit (only if Step 1 needed a `gofmt -w`):**

```
$ git status --short
```

If clean, nothing to commit — Tasks 7–11 already committed everything. Otherwise:

```
$ git add -A
$ git commit -m "chore(memory): gofmt cleanup for Slice B retrieval-compare changes"
```

---

## Task 13: Real-data compare run + evidence-gated switch

**Not a TDD task — a runbook.** This mirrors how Slice A's terminal verification tasks are written: command sequences with expected output and a real go/no-go decision, not red/green test steps.

**Depends on:** Task 12. **Blocks:** nothing further in this plan (13a/13b/13c are independently-gated terminal follow-ups).

- [ ] **Step (a): confirm a safe, read-only snapshot exists — never point this at the live workspace.**

A snapshot is already prepared this session at a scratch location, taken via `sqlite3 .backup` from the live `whitebit` workspace (2,062 memory nodes, 465k messages) — never touching the live daemon's database. Before running anything:

```
$ ls -la <snapshot-dir>/
watchtower-snapshot.db
memory/                    # cloned vault working tree (a git repo)

$ ps aux | grep -i "watchtower.*sync\|watchtower.*daemon" | grep -v grep
```

Expected: the `ps` check returns **nothing** — no live daemon process is running that could be confused with, or accidentally pointed at, this snapshot. If any watchtower process IS running, stop before proceeding — this run must be fully isolated from the live workspace.

Build a scratch config that points at the snapshot, never the real workspace (`db_path`/`workspace_dir` both under the snapshot directory).

- [ ] **Step (b): run `retrieve-compare` against the snapshot for all three surfaces.**

```
$ go run . --config <snapshot-dir>/config.yaml memory retrieve-compare \
    --since 720h \
    --out <snapshot-dir>/retrieve-compare-report.md
Retrieve compare done: recall NN (failed N), briefing 1, meeting_prep MM.
Report written to <snapshot-dir>/retrieve-compare-report.md
```

`--since 720h` (30 days) gives briefing's `RetrieveRevisions` a realistic window against 465k real messages' worth of belief churn; adjust if the workspace's actual belief history is sparser or denser than expected once the report is in hand.

- [ ] **Step (c): read the report and evaluate each surface independently against the spec's bar — "new is not worse and demonstrably better on at least one dimension."**

```
$ cat <snapshot-dir>/retrieve-compare-report.md
```

For a finer-grained read, query the shadow table directly:

```
$ sqlite3 <snapshot-dir>/watchtower-snapshot.db \
  "SELECT query_key, diff_metrics_json FROM memory_retrieve_shadow WHERE surface='recall' ORDER BY id DESC LIMIT 20;"

$ sqlite3 <snapshot-dir>/watchtower-snapshot.db \
  "SELECT diff_metrics_json FROM memory_retrieve_shadow WHERE surface='briefing' ORDER BY id DESC LIMIT 1;"

$ sqlite3 <snapshot-dir>/watchtower-snapshot.db \
  "SELECT query_key, diff_metrics_json FROM memory_retrieve_shadow WHERE surface='meeting_prep' ORDER BY id DESC LIMIT 20;"
```

Evaluate per surface (this is a real decision, not a rubber stamp — record the actual numbers observed, not a template):

- **Recall:** what fraction of sampled queries have `coverage_ok=true`? Is `mean_importance_new` meaningfully higher than `mean_importance_old`? A nonzero `coverage_ok=false` rate needs manual inspection of the specific queries before calling the bar met.
- **Briefing:** what is `Intersection` across a couple of different `--since` reruns? Does the data show new's order promoting a higher-importance belief ahead of a same-magnitude lower one?
- **Meeting-prep:** what fraction of subjects have `new_superset_ok=true`? Manually spot-check a handful of `new_short_term_ids` via `watchtower memory open <id>` against the snapshot and judge plausibility by eye — this one is explicitly not automatable.

- [ ] **Step (d): for each surface where the bar is met, switch that surface's authoritative retrieval path — independently, never bundled.**

### 13a: Switch `memory_recall` (independent, gated on Step (c)'s recall evidence alone)

Only if recall's evidence clears the bar:
- Remove the legacy alias+FTS ranking from `memoryRecallHandler` (`internal/mcp/memory.go`), making `RetrieveByQuery` the sole result-producing call (the alias-exact-match short-circuit stays, since `RetrieveByQuery` already preserves it per the design spec).
- Delete the now-dead `CompareRecall` call site and the `retrieveShadowDB`/`WithMemoryRetrieveCompare` plumbing (Task 8) — once switched, compare mode has no purpose for this surface; recommend deleting it outright (YAGNI) rather than keeping it as a permanent regression-guard toggle.
- Remove `memory.retrieve.recall_compare` from `MemoryRetrieveConfig` (confirm unknown mapstructure keys are ignored, not an error, before assuming this is safe for existing deployed configs).
- Update every affected test (`TestMemoryRecallAliasFirstNoBump` etc. must still pass — the alias-first behavior is preserved by design, only the FTS-ranked tail changes to importance-weighted).
- Update the inventory contract: recall's status moves from "dark compare" to "switched, <date>."

### 13b: Switch briefing (independent, gated on Step (c)'s briefing evidence alone)

Only if briefing's evidence clears the bar: `gatherMemoryRevisions` calls `RetrieveRevisions` directly for the final line selection instead of the current encounter-order loop; delete the `CompareRevisions` call site and `memory.retrieve.briefing_compare`; update `TestGatherMemoryRevisions_*` accordingly; update the inventory contract.

### 13c: Switch meeting-prep (independent, gated on Step (c)'s meeting-prep evidence alone)

Only if meeting-prep's evidence clears the bar: `gatherMemoryContext` calls `RetrieveBySubject` per attendee for both the belief lines (replacing `beliefLinesFor`) and a NEW short-term episode block (net new content, not present in the legacy render at all — needs its own template/prompt-budget consideration inside `memoryContextCap`); delete the `CompareSubject` call site, `beliefIDsFor`, and `memory.retrieve.meeting_prep_compare`; update `TestGatherMemoryContext_*`; update the inventory contract.

**If a surface's bar is NOT met:** leave that surface's flag dark, do not switch it, and record in the branch report exactly why (which metric fell short and by how much) — stop there for that surface. A surface can remain dark indefinitely; nothing about Slice B requires all three to switch together, and an unmet bar is a legitimate, expected outcome for at least one surface on a first real-data pass, not a plan failure.
</content>
