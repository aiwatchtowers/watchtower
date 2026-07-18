# Secretary Memory — Importance Score Foundation (Slice A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each task is sized for one focused agent session; obey the stated dependencies. Read `docs/superpowers/specs/2026-07-18-memory-importance-score-design.md` (the whole thing — it's short) and `docs/inventory/memory.md`'s MEM-01/02/06/07/15 entries (the eviction/quarantine/provenance precedents this slice extends) **first**. **Do not skip Task 0** — it gates which branch every other task's commits land on.

**Goal:** Persist a computed-or-owner-overridden `importance_score` on every memory node, refreshed by `Reconcile`/`Rebuild`, as the pure foundation later slices will use for weight×relevance retrieval ranking — no retrieval, chat, briefing, or meeting-prep change happens in this slice.

**Scope (this plan covers ONLY):** Slice A of the memory-importance-score redesign — a persisted, queryable per-node `importance_score` on `memory_nodes`, refreshed by `Reconcile`/`Rebuild`, plus the one new contract MEM-16. **Everything else is OUT:** Slice B (`RetrieveRelevant` unified retrieval), Slice C (Swift `relevantMemory` reading the column), Slice D (belief-as-decision entities, owner-facing override UX, importance-ordered `index.md`/`map.md`). No new MCP tool, no retrieval ranking change, no chat/briefing/meeting-prep change, no new config flag (this is always-on math, not gated), no new AI prompt.

**Architecture (extends the existing Reconcile/Rebuild pipeline; nothing in `Run`'s step order changes):**
- `internal/memory/importance.go` (new) holds `ImportanceInputs`/`ComputeImportance` — the importance arm extracted verbatim out of `evict.go`'s `RetentionScore`. `RetentionScore` becomes `recency * ComputeImportance(...)`; its signature, `RetentionInputs`, and every existing assertion in `evict_test.go` stay byte-identical (the refactor proof).
- `internal/db/migrations/00027_memory_importance_score.sql` — additive `memory_nodes.importance_score REAL NOT NULL DEFAULT 0` (no CHECK change, no table-recreation dance — unlike 00018's belief-status widening). Mirrored into `schema.sql`; golden snapshot regenerated.
- `node.go`'s `frontmatter`/`Node` gain `ImportanceOverride *float64` (YAML `importance_override`), legal on any node type, `>= 0` when present, pointer all the way through so `0` stays distinguishable from "unset."
- `db.MemoryNodeRow` gains `ImportanceScore float64`; `memoryNodeSelectCols`/`scanMemoryNodeRow`/`UpsertMemoryNode` carry it.
- `index.go`'s `reconcilePass.file()` computes the merged value (override, else `ComputeImportance` fed by `CountMemoryLinksIn`/situation-alias/`OwnerEdited`/`LinkedEntityEngagement` — the exact signal calls `EvictEpisodes` already uses) and writes it into the upserted row. **No recency factor.** A signal-lookup error quarantines that one file (log + count + keep its prior `importance_score`) rather than aborting the pass — `EvictEpisodes` keeps its own live, independent computation and never reads the column (the one hard constraint of this slice).
- `TestMemory02_ReindexEquivalence`'s fixture gains a real link-in so the guard exercises a nonzero `importance_score`, not two zeros.

**Tech Stack:** unchanged. Go 1.25, `modernc.org/sqlite`, goose migrations, `testify` (`assert`/`require`), the existing `internal/memory` test harness (`newTestVault`/`newTestDB`/`writeNodes`/`writeAndIndex`/`linkingEntity` in `resolver_test.go`/`evict_test.go`).

## Global Constraints

- Before each commit: `gofmt -l`, `go vet ./...`, `go build ./...`, and the affected package tests green.
- **Never weaken a guard.** MEM-01..15 stay exactly as they read today. `evict_test.go`'s `TestRetentionScore`/`TestRetentionScoreEngagement` must pass **unchanged** — that is the proof Task 1 is a pure refactor. Do not edit those two functions.
- **`EvictEpisodes` reads nothing new.** It keeps computing `RetentionScore` live per candidate; it never reads `memory_nodes.importance_score`. Collapsing the two is explicitly out of scope and needs owner review (MEM-16).
- **One bad node never bricks the pass.** A `CountMemoryLinksIn`/`OwnerEdited`/`LinkedEntityEngagement` error during `Reconcile`/`Rebuild` quarantines that file (existing `p.quarantine` mechanism) — logged, counted, prior index row (including its `importance_score`) preserved untouched; the rest of the pass continues.
- **No new config gate.** This computation is unconditional inside `Reconcile`/`Rebuild` (which themselves only run when `memory.enabled` is on — that gate is unchanged and out of scope here).
- **Branch.** Slice A's Task 5 calls `database.LinkedEntityEngagement` and reads the `memory_engagement` table — both introduced in Phase 5 slice 1, which lives only on `feature/memory-phase5` (PR #40), **not yet on `main`** (PR #40 is OPEN as of 2026-07-18, not merged). Task 0 gates every other task on being on the correct branch — do not start Task 1 before resolving it.
- English docs/comments, matching the file's existing comment density and cross-referencing style (`MEM-NN`, migration numbers).

## File Structure

- `internal/memory/importance.go` (new) + `internal/memory/importance_test.go` (new) — `ImportanceInputs`, `ComputeImportance`.
- `internal/memory/evict.go` (modify) — `RetentionScore` delegates to `ComputeImportance`; four constants move out.
- `internal/db/migrations/00027_memory_importance_score.sql` (new) + `internal/db/schema.sql` (modify) + `internal/db/testdata/schema_v73.golden` (regenerated) + `internal/db/db_test.go` (new `TestMigration00027MemoryImportanceScore`).
- `internal/memory/node.go` (modify) + `internal/memory/node_test.go` (modify) — `ImportanceOverride` frontmatter field.
- `internal/db/memory.go` (modify) + `internal/db/memory_test.go` (modify) — `MemoryNodeRow.ImportanceScore`, select/scan/upsert wiring.
- `internal/memory/index.go` (modify) + `internal/memory/index_test.go` (modify) — the wiring, the strengthened MEM-02 fixture, the override-wins/quarantine guard tests.
- `docs/inventory/memory.md` (modify) — new contract MEM-16, module/audit-date header bump, changelog entry, one cross-reference fix to a now-stale limitations bullet.

---

## Task 0: Branch precondition — owner-approved exception, resolved 2026-07-18

**Depends on:** nothing. **Blocks:** Tasks 1, 2, 3 (everything else).

**Files:** none (git operations only).

**Interfaces:** none — this task only confirms which branch the rest of the plan commits to.

**Resolved.** Slice A's `computeImportance` (Task 5) calls `database.LinkedEntityEngagement` and reads `RetentionInputs`/`memory_engagement`-style engagement signals — all introduced in Phase 5 slice 1, which exists only on `feature/memory-phase5` (PR #40, still OPEN as of 2026-07-18). The design spec's Rollout section calls for Slice A to land on its own branch cut from `main` after PR #40 merges — but the owner explicitly decided **not to wait**: Slice A is implemented now, stacked on top of `feature/memory-phase5`, as a documented exception. Record this in the eventual PR description: *"Slice A lands stacked on feature/memory-phase5 rather than a fresh branch off main, per the owner's explicit 2026-07-18 direction — main doesn't yet have Phase 5 slice 1's `LinkedEntityEngagement`/`memory_engagement`, which this slice's computeImportance depends on."*

- [ ] **Step 1: confirm the working tree is on `feature/memory-phase5` before starting Task 1:**

```
$ git branch --show-current
```

Expected: `feature/memory-phase5`. If it's anything else, `git checkout feature/memory-phase5` first — do not branch off `main` or create a new branch for this slice.

## Task 1: Extract `ComputeImportance` from `RetentionScore`

**Depends on:** Task 0 (must be on the correct branch first). **Blocks:** Tasks 5, 6, 7.

**Files:**
- Create: `internal/memory/importance.go`, `internal/memory/importance_test.go`
- Modify: `internal/memory/evict.go` (lines 1–83 — the top of the file, through the end of `RetentionScore`; `EvictEpisodes` and everything below, lines 85–326, is untouched)
- Test: `internal/memory/evict_test.go` — **do not modify**; its existing `TestRetentionScore`/`TestRetentionScoreEngagement` (lines 15–57) are the byte-identical proof and must pass with zero edits.

**Interfaces:**
- Consumes: nothing new (pure extraction of existing math).
- Produces: `type ImportanceInputs struct { LinksIn int; SituationOrigin bool; OwnerTouched bool; Engagement int }` and `func ComputeImportance(in ImportanceInputs) float64` — consumed by Task 5's `computeImportance` and by `evict.go`'s refactored `RetentionScore`.

Today `internal/memory/evict.go` reads (in full, lines 1–83):

```go
package memory

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// RetentionInputs are the file-derived signals behind a node's retention score.
// Access stats are deliberately absent: the counters are write-dead in
// production (spec §Retention), so they never enter the formula in Phase 3.
type RetentionInputs struct {
	LastEventAgeDays float64 // age of the newest provenance event, in days
	LinksIn          int     // live nodes linking to this one
	SituationOrigin  bool    // node carries a situation:<id> alias
	OwnerTouched     bool    // file was ever touched by a memory(owner-edit) commit
	// Engagement is the NET owner-engagement of the entities linking this episode
	// (engaged_count − dismissed_count summed over its linking entities, Phase-5
	// 5D memory_engagement). Only a positive net raises importance — a dismissed
	// or never-touched episode gets no bonus and never scores below the
	// un-engaged baseline. The net is CLAMPED to [-engagementNetClamp,
	// +engagementNetClamp] before scoring so one heavily-engaged entity cannot
	// pin an episode in memory forever (a runaway counter is bounded).
	Engagement int
}

// engagementNetClamp bounds the net-engagement contribution to importance: a
// net beyond ±3 is clamped, so no single entity's counter can dominate the
// retention score. A code const like the other retention weights.
const engagementNetClamp = 3

// Retention constants live in code, not config (mirrors belief_math.go): one
// auditable place for the eviction math.
const (
	retentionRecencyHorizonDays = 180.0 // recency decays to the floor over this span
	retentionRecencyFloor       = 0.25  // ancient nodes keep a little recency so links-in still protect them
	retentionSituationBonus     = 1.0
	retentionOwnerBonus         = 2.0 // owner-touched outweighs the situation bonus
	// retentionEngagementWeight scales net owner-engagement into importance: an
	// entity the owner actively engages with (👍, converts, resolves — Phase-5 5D)
	// resists eviction on par with an owner-touched file. This is the first LIVE,
	// writable feed for Phase-3's stubbed retention-importance input — NOT the
	// write-dead memory_node_stats access counters (still dead this slice).
	retentionEngagementWeight = 2.0
)

// RetentionScore is the pure retention formula: recency(last event) ×
// importance, where importance = links-in + situation-origin bonus +
// owner-touch bonus + engagement bonus. A cold, unreferenced, un-touched,
// un-engaged episode scores 0 (importance 0) and is always evictable; links-in,
// an owner edit, or positive owner-engagement lift it above a positive
// threshold. Side-effect free and exhaustively unit-tested.
func RetentionScore(in RetentionInputs) float64 {
	recency := 1.0 - in.LastEventAgeDays/retentionRecencyHorizonDays
	if recency < retentionRecencyFloor {
		recency = retentionRecencyFloor
	}
	if recency > 1.0 {
		recency = 1.0
	}
	importance := float64(in.LinksIn)
	if in.SituationOrigin {
		importance += retentionSituationBonus
	}
	if in.OwnerTouched {
		importance += retentionOwnerBonus
	}
	net := in.Engagement
	if net > engagementNetClamp {
		net = engagementNetClamp
	} else if net < -engagementNetClamp {
		net = -engagementNetClamp
	}
	if net > 0 { // only positive net raises importance (a dismissed entity never scores below baseline)
		importance += retentionEngagementWeight * float64(net)
	}
	return recency * importance
}
```

`engagementNetClamp`, `retentionSituationBonus`, `retentionOwnerBonus`, and `retentionEngagementWeight` are used **only** inside this function (verified: `grep -rn "retentionSituationBonus\|retentionOwnerBonus\|retentionEngagementWeight\|engagementNetClamp" internal/` hits only `evict.go` itself and one `evict_test.go` reference to the untouched `retentionRecencyFloor`) — safe to move.

- [ ] **Step 1: write the failing test** — create `internal/memory/importance_test.go`:

```go
package memory

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestComputeImportance: pure-math cases for the importance formula extracted
// from RetentionScore (Slice A of the memory-importance-score redesign,
// docs/superpowers/specs/2026-07-18-memory-importance-score-design.md). Each
// case mirrors one of evict_test.go's pre-existing RetentionScore assertions,
// retargeted at the importance half directly — no recency factor here.
func TestComputeImportance(t *testing.T) {
	// A cold, unreferenced, un-touched, un-engaged node scores 0.
	assert.Zero(t, ComputeImportance(ImportanceInputs{}))

	// Links-in lift the score linearly.
	assert.Equal(t, 3.0, ComputeImportance(ImportanceInputs{LinksIn: 3}))

	// Situation-origin adds its own bonus; owner-touch outweighs it.
	situation := ComputeImportance(ImportanceInputs{SituationOrigin: true})
	owner := ComputeImportance(ImportanceInputs{OwnerTouched: true})
	assert.Equal(t, importanceSituationBonus, situation)
	assert.Equal(t, importanceOwnerBonus, owner)
	assert.Greater(t, owner, situation)
}

// TestComputeImportanceEngagement: positive net owner-engagement raises
// importance; zero or negative net adds no bonus and never lowers the score
// below the un-engaged baseline; the net is clamped in both directions
// (retargeted from evict_test.go's TestRetentionScoreEngagement).
func TestComputeImportanceEngagement(t *testing.T) {
	base := ImportanceInputs{LinksIn: 1}
	engaged := base
	engaged.Engagement = 2
	assert.Greater(t, ComputeImportance(engaged), ComputeImportance(base), "engagement raises importance")

	zero := base
	zero.Engagement = 0
	assert.Equal(t, ComputeImportance(base), ComputeImportance(zero), "zero net adds no bonus")

	negative := base
	negative.Engagement = -5
	assert.Equal(t, ComputeImportance(base), ComputeImportance(negative),
		"a net-dismissed entity never scores below the un-engaged baseline")

	more := base
	more.Engagement = 4
	assert.Greater(t, ComputeImportance(more), ComputeImportance(engaged), "score rises with engagement")

	// The clamp bounds the contribution: net beyond ±engagementNetClamp scores
	// the same as exactly the clamp value.
	atClamp := base
	atClamp.Engagement = engagementNetClamp
	beyondClamp := base
	beyondClamp.Engagement = engagementNetClamp + 10
	assert.Equal(t, ComputeImportance(atClamp), ComputeImportance(beyondClamp),
		"net beyond the clamp scores the same as the clamp")
}
```

- [ ] **Step 2: run it — expect a build failure** (the symbols don't exist yet):

```
$ go test ./internal/memory/ -run 'TestComputeImportance' -v
# watchtower/internal/memory [watchtower/internal/memory.test]
./importance_test.go:12:23: undefined: ComputeImportance
./importance_test.go:12:40: undefined: ImportanceInputs
FAIL	watchtower/internal/memory [build failed]
```

- [ ] **Step 3: write the minimal implementation** — create `internal/memory/importance.go`:

```go
package memory

// ImportanceInputs are the file-derived signals behind a node's importance:
// how many live nodes reference it, whether it originated from a dashboard
// situation, whether the owner ever touched its file, and its linked
// entities' net owner-engagement. Extracted from evict.go's RetentionScore
// (Slice A of the memory-importance-score redesign, MEM-16) so a value can be
// computed independent of eviction's recency factor.
type ImportanceInputs struct {
	LinksIn         int  // live nodes linking to this one
	SituationOrigin bool // node carries a situation:<id> alias
	OwnerTouched    bool // file was ever touched by a memory(owner-edit) commit
	// Engagement is the NET owner-engagement of the entities linking this node
	// (engaged_count − dismissed_count summed over its linking entities, Phase-5
	// 5D memory_engagement). Only a positive net raises importance — a dismissed
	// or never-touched node gets no bonus and never scores below the un-engaged
	// baseline. Clamped to [-engagementNetClamp, +engagementNetClamp] before
	// scoring so one heavily-engaged entity cannot dominate importance.
	Engagement int
}

// engagementNetClamp bounds the net-engagement contribution to importance: a
// net beyond ±3 is clamped, so no single entity's counter can dominate the
// score. Moved here verbatim from evict.go (Slice A) — same value, same
// meaning, now shared by ComputeImportance and (via it) RetentionScore.
const engagementNetClamp = 3

// Importance constants live in code, not config (mirrors belief_math.go /
// evict.go's recency constants): one auditable place for the importance math.
// Moved here verbatim from evict.go (Slice A) — same values.
const (
	importanceSituationBonus = 1.0
	importanceOwnerBonus     = 2.0 // owner-touched outweighs the situation bonus
	// importanceEngagementWeight scales net owner-engagement into importance: an
	// entity the owner actively engages with (👍, converts, resolves — Phase-5 5D)
	// resists eviction/decay on par with an owner-touched file.
	importanceEngagementWeight = 2.0
)

// ComputeImportance is the pure importance formula: links-in + situation-
// origin bonus + owner-touch bonus + clamped net-engagement bonus. A cold,
// unreferenced, un-touched, un-engaged node scores 0 and is always evictable;
// links-in, an owner edit, or positive owner-engagement lift it above zero.
// Side-effect free and exhaustively unit-tested (importance_test.go).
// Extracted from RetentionScore (evict.go), which now delegates here for its
// importance half — recency stays eviction-specific and is applied only by
// RetentionScore, never here. The merged (owner-override-or-computed) result
// of this function is what Reconcile/Rebuild persist into
// memory_nodes.importance_score (index.go, MEM-16) — a periodic snapshot,
// distinct from RetentionScore's always-live recomputation.
func ComputeImportance(in ImportanceInputs) float64 {
	importance := float64(in.LinksIn)
	if in.SituationOrigin {
		importance += importanceSituationBonus
	}
	if in.OwnerTouched {
		importance += importanceOwnerBonus
	}
	net := in.Engagement
	if net > engagementNetClamp {
		net = engagementNetClamp
	} else if net < -engagementNetClamp {
		net = -engagementNetClamp
	}
	if net > 0 { // only positive net raises importance (a dismissed entity never scores below baseline)
		importance += importanceEngagementWeight * float64(net)
	}
	return importance
}
```

Now replace `internal/memory/evict.go` lines 1–83 (everything through the end of `RetentionScore`) with:

```go
package memory

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
)

// RetentionInputs are the file-derived signals behind a node's retention score.
// Access stats are deliberately absent: the counters are write-dead in
// production (spec §Retention), so they never enter the formula in Phase 3.
type RetentionInputs struct {
	LastEventAgeDays float64 // age of the newest provenance event, in days
	LinksIn          int     // live nodes linking to this one
	SituationOrigin  bool    // node carries a situation:<id> alias
	OwnerTouched     bool    // file was ever touched by a memory(owner-edit) commit
	// Engagement is the NET owner-engagement of the entities linking this episode
	// (engaged_count − dismissed_count summed over its linking entities, Phase-5
	// 5D memory_engagement). Only a positive net raises importance — a dismissed
	// or never-touched episode gets no bonus and never scores below the
	// un-engaged baseline. The net is CLAMPED (see importance.go's
	// engagementNetClamp) before scoring so one heavily-engaged entity cannot
	// pin an episode in memory forever (a runaway counter is bounded).
	Engagement int
}

// Retention constants live in code, not config (mirrors belief_math.go): one
// auditable place for the eviction math. The importance-half constants
// (situation/owner/engagement bonuses, the engagement clamp) moved into
// importance.go/ComputeImportance (Slice A of the memory-importance-score
// redesign, MEM-16) — only the recency constants stay here.
const (
	retentionRecencyHorizonDays = 180.0 // recency decays to the floor over this span
	retentionRecencyFloor       = 0.25  // ancient nodes keep a little recency so links-in still protect them
)

// RetentionScore is the pure retention formula: recency(last event) ×
// importance, where importance = ComputeImportance's links-in + situation-
// origin bonus + owner-touch bonus + engagement bonus (importance.go). A cold,
// unreferenced, un-touched, un-engaged episode scores 0 (importance 0) and is
// always evictable; links-in, an owner edit, or positive owner-engagement lift
// it above a positive threshold. Side-effect free and exhaustively unit-tested.
// This is a pure refactor (Slice A extracted the importance arm into
// ComputeImportance) — the formula and every pre-existing assertion below are
// byte-identical to before the extraction.
func RetentionScore(in RetentionInputs) float64 {
	recency := 1.0 - in.LastEventAgeDays/retentionRecencyHorizonDays
	if recency < retentionRecencyFloor {
		recency = retentionRecencyFloor
	}
	if recency > 1.0 {
		recency = 1.0
	}
	importance := ComputeImportance(ImportanceInputs{
		LinksIn:         in.LinksIn,
		SituationOrigin: in.SituationOrigin,
		OwnerTouched:    in.OwnerTouched,
		Engagement:      in.Engagement,
	})
	return recency * importance
}
```

(Lines 85–326 — `EvictEpisodes` and everything below — are unchanged; do not touch them.)

- [ ] **Step 4: run it — expect green, including the untouched proof file:**

```
$ go test ./internal/memory/ -run 'TestComputeImportance|TestRetentionScore' -v
=== RUN   TestComputeImportance
--- PASS: TestComputeImportance (0.00s)
=== RUN   TestComputeImportanceEngagement
--- PASS: TestComputeImportanceEngagement (0.00s)
=== RUN   TestRetentionScore
--- PASS: TestRetentionScore (0.00s)
=== RUN   TestRetentionScoreEngagement
--- PASS: TestRetentionScoreEngagement (0.00s)
PASS
ok  	watchtower/internal/memory	0.3s
```

- [ ] **Step 5: full package sanity + commit:**

```
$ go test ./internal/memory/ 2>&1 | tail -5
ok  	watchtower/internal/memory	(cached)
$ git add internal/memory/importance.go internal/memory/importance_test.go internal/memory/evict.go
$ git commit -m "refactor(memory): extract ComputeImportance from RetentionScore (Slice A, MEM-16)

RetentionScore's importance arm moves into a standalone
ComputeImportance(ImportanceInputs) in a new importance.go; RetentionScore
now delegates to it. Pure refactor — evict_test.go's RetentionScore
assertions are byte-unchanged."
```

---

## Task 2: Migration `00027_memory_importance_score.sql`

**Depends on:** Task 0 (must be on the correct branch first). **Blocks:** Task 4.

**Files:**
- Create: `internal/db/migrations/00027_memory_importance_score.sql`
- Modify: `internal/db/schema.sql` (the `memory_nodes` table, currently lines 1209–1221), `internal/db/testdata/schema_v73.golden` (regenerated, not hand-edited)
- Test: `internal/db/db_test.go` (new `TestMigration00027MemoryImportanceScore`, inserted after `TestMigration00019MemorySurfaces`, which ends at line 343)

**Interfaces:**
- Consumes: nothing.
- Produces: the `memory_nodes.importance_score REAL NOT NULL DEFAULT 0` column — consumed by Task 4's Go-level wiring.

Latest migration on this branch is `internal/db/migrations/00026_situation_feedback_floor.sql` (a plain `ALTER TABLE workspace ADD COLUMN ... DEFAULT 0`). This slice's column touches no `CHECK` constraint, so — unlike `00018`'s belief-status widening (which needed the `PRAGMA foreign_keys=OFF` / recreate-table dance) — a plain additive `ALTER TABLE ADD COLUMN` suffices, matching `00017`'s `workspace.memory_last_extracted_ts` precedent.

- [ ] **Step 1: write the failing test** — add to `internal/db/db_test.go` immediately after `TestMigration00019MemorySurfaces`'s closing brace (line 343):

```go
// TestMigration00027MemoryImportanceScore: memory_nodes.importance_score
// (Slice A of the memory-importance-score redesign, MEM-16) is additive,
// defaults 0, and a plain insert that omits it still succeeds.
func TestMigration00027MemoryImportanceScore(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	var n int
	err := database.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('memory_nodes') WHERE name = 'importance_score'`).Scan(&n)
	if err != nil || n != 1 {
		t.Fatalf("memory_nodes.importance_score missing (count=%d err=%v)", n, err)
	}

	if _, err := database.Exec(
		`INSERT INTO memory_nodes (id, type, tier, path, content_hash, indexed_at)
		 VALUES ('ent_importance_x', 'entity', 'long', 'entities/x.md', 'h', '2026-07-18T00:00:00Z')`); err != nil {
		t.Fatalf("inserting memory node without importance_score: %v", err)
	}
	var score float64
	if err := database.QueryRow(
		`SELECT importance_score FROM memory_nodes WHERE id = 'ent_importance_x'`).Scan(&score); err != nil {
		t.Fatalf("reading importance_score default: %v", err)
	}
	if score != 0 {
		t.Fatalf("importance_score default = %v, want 0", score)
	}
}
```

- [ ] **Step 2: run it — expect failure** (the column does not exist yet, so the `pragma_table_info` count is 0):

```
$ go test ./internal/db/ -run TestMigration00027MemoryImportanceScore -v
=== RUN   TestMigration00027MemoryImportanceScore
    db_test.go:XXX: memory_nodes.importance_score missing (count=0 err=<nil>)
--- FAIL: TestMigration00027MemoryImportanceScore (0.01s)
FAIL
```

- [ ] **Step 3: write the minimal implementation** — create `internal/db/migrations/00027_memory_importance_score.sql`:

```sql
-- +goose Up
-- Secretary memory importance score (Slice A of the memory-importance-score
-- redesign, docs/superpowers/specs/2026-07-18-memory-importance-score-design.md,
-- MEM-16). Persists the merged (owner-override-or-computed) importance value
-- Reconcile/Rebuild refresh per node — a periodic snapshot future retrieval
-- ranking will read, distinct from evict.go's always-live RetentionScore.
-- A simple additive column: unlike 00018's belief-status CHECK-widening
-- dance, this touches no CHECK constraint, so a plain ADD COLUMN suffices
-- (the 00017/00026 ALTER TABLE precedent).
ALTER TABLE memory_nodes ADD COLUMN importance_score REAL NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE memory_nodes DROP COLUMN importance_score;
```

Modify `internal/db/schema.sql`'s `memory_nodes` table (currently lines 1209–1221):

```sql
CREATE TABLE IF NOT EXISTS memory_nodes (
    id            TEXT PRIMARY KEY,             -- ent_*/ep_*/sum_*/bel_*
    type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
    tier          TEXT NOT NULL CHECK (tier IN ('short','long')),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone','shaken','retired')),  -- shaken/retired are belief-only (see 00018)
    redirect_to   TEXT,
    title         TEXT NOT NULL DEFAULT '',
    path          TEXT NOT NULL,                -- vault-relative file path
    content_hash  TEXT NOT NULL,                -- sha256 of file bytes at last index
    indexed_at    TEXT NOT NULL,
    subject       TEXT NOT NULL DEFAULT '',     -- belief subject entity id, '' for non-beliefs; file-derived (see 00019)
    confidence    REAL NOT NULL DEFAULT 0       -- belief confidence 0..1, 0 for non-beliefs; file-derived (see 00019)
);
```

becomes:

```sql
CREATE TABLE IF NOT EXISTS memory_nodes (
    id            TEXT PRIMARY KEY,             -- ent_*/ep_*/sum_*/bel_*
    type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
    tier          TEXT NOT NULL CHECK (tier IN ('short','long')),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone','shaken','retired')),  -- shaken/retired are belief-only (see 00018)
    redirect_to   TEXT,
    title         TEXT NOT NULL DEFAULT '',
    path          TEXT NOT NULL,                -- vault-relative file path
    content_hash  TEXT NOT NULL,                -- sha256 of file bytes at last index
    indexed_at    TEXT NOT NULL,
    subject       TEXT NOT NULL DEFAULT '',     -- belief subject entity id, '' for non-beliefs; file-derived (see 00019)
    confidence    REAL NOT NULL DEFAULT 0,      -- belief confidence 0..1, 0 for non-beliefs; file-derived (see 00019)
    importance_score REAL NOT NULL DEFAULT 0    -- merged override-or-computed importance snapshot, refreshed by Reconcile/Rebuild (see 00027, MEM-16)
);
```

`TestAllTablesExist` (`internal/db/db_test.go`, lines 93–120) enumerates table **names** only, not columns — verified via `grep -n "pragma_table_info"` across `internal/db/`, which found only the per-migration column tests (`TestMigration00019MemorySurfaces`, and now this one). **No edit needed there.**

- [ ] **Step 4: run it — expect green, then regenerate the golden snapshot:**

```
$ go test ./internal/db/ -run TestMigration00027MemoryImportanceScore -v
=== RUN   TestMigration00027MemoryImportanceScore
--- PASS: TestMigration00027MemoryImportanceScore (0.01s)
PASS
ok  	watchtower/internal/db	0.2s

$ go test ./internal/db/ -run TestSchemaGolden -update
    schema_snapshot_test.go:43: wrote testdata/schema_v73.golden (NNNNN bytes)
ok  	watchtower/internal/db	0.1s

$ go test ./internal/db/ -run 'TestSchemaGolden|TestAllTablesExist|TestMigration' -v 2>&1 | tail -20
--- PASS: TestSchemaGolden (0.05s)
--- PASS: TestAllTablesExist (0.02s)
--- PASS: TestMigration00027MemoryImportanceScore (0.01s)
PASS
ok  	watchtower/internal/db	0.4s
```

- [ ] **Step 5: commit:**

```
$ git add internal/db/migrations/00027_memory_importance_score.sql internal/db/schema.sql internal/db/testdata/schema_v73.golden internal/db/db_test.go
$ git commit -m "feat(db): memory_nodes.importance_score column (00027, Slice A / MEM-16 foundation)

Additive ALTER TABLE ADD COLUMN, no CHECK change. Mirrors into schema.sql;
golden snapshot regenerated."
```

---

## Task 3: Frontmatter `importance_override` field

**Depends on:** Task 0 (must be on the correct branch first). **Blocks:** Task 5.

**Files:**
- Modify: `internal/memory/node.go` — `Node` struct (lines 21–40), `frontmatter` struct (lines 52–66), `ParseNode` validation (after line 137) and construction (lines 139–158), `Render` (lines 174–178)
- Test: `internal/memory/node_test.go` — new tests inserted after `TestParseNodeRejectsRedirectOnNonTombstone` (ends line 151), before `TestLinks` (line 153)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Node.ImportanceOverride *float64` — consumed by Task 5's `computeImportance` (`n.ImportanceOverride != nil` short-circuit).

Current `Node` struct (`node.go` lines 21–40):

```go
type Node struct {
	ID         string
	Type       string // entity | episode | rollup | belief
	Tier       string // short | long
	Status     string // active | closed | tombstone; beliefs also shaken | retired
	RedirectTo string // tombstones only
	// Belief-only frontmatter (type: belief). Confidence is 0..1, Stability is
	// a confirmation count (>=0), Subject is the entity id the belief is about.
	// Carried as plain values; Render emits them only for beliefs.
	Confidence float64
	Stability  int
	Subject    string
	Title      string // first H1 in Body, "" when absent
	Aliases    []string
	Refs       struct {
		PeopleCard int64
		Targets    []int64
	}
	Body string // markdown below the frontmatter, H1 included
}
```

Current `frontmatter` struct (lines 52–66):

```go
type frontmatter struct {
	ID         string `yaml:"id"`
	Type       string `yaml:"type"`
	Tier       string `yaml:"tier"`
	Status     string `yaml:"status"`
	RedirectTo string `yaml:"redirect_to"`
	// Belief-only keys — structurally known (so KnownFields accepts them) but
	// legal only for type: belief; a post-decode type gate rejects them on any
	// other type. Pointers so absence is distinguishable from a zero value.
	Confidence *float64  `yaml:"confidence"`
	Stability  *int      `yaml:"stability"`
	Subject    string    `yaml:"subject"`
	Aliases    []string  `yaml:"aliases"`
	Refs       *nodeRefs `yaml:"refs"`
}
```

Current `ParseNode` validation around Stability (lines 135–137) and construction (lines 139–158):

```go
	if fm.Stability != nil && *fm.Stability < 0 {
		return Node{}, fmt.Errorf("memory: belief %s stability %d is negative", fm.ID, *fm.Stability)
	}

	n := Node{
		ID:         fm.ID,
		Type:       fm.Type,
		Tier:       fm.Tier,
		Status:     fm.Status,
		RedirectTo: fm.RedirectTo,
		Subject:    fm.Subject,
		Aliases:    fm.Aliases,
		Body:       string(body),
	}
```

Current `Render` around the redirect/belief block (lines 174–178):

```go
	if n.RedirectTo != "" {
		fmt.Fprintf(&b, "redirect_to: %s\n", n.RedirectTo)
	}
	if n.Type == "belief" {
```

- [ ] **Step 1: write the failing tests** — insert into `internal/memory/node_test.go` after line 151 (`TestParseNodeRejectsRedirectOnNonTombstone`'s closing brace), before `TestLinks`:

```go
func TestParseNodeImportanceOverrideRoundTrip(t *testing.T) {
	raw := "---\nid: ent_x\ntype: entity\ntier: long\nstatus: active\nimportance_override: 4.5\n---\n# X\n"
	n, err := ParseNode([]byte(raw))
	require.NoError(t, err)
	require.NotNil(t, n.ImportanceOverride)
	assert.Equal(t, 4.5, *n.ImportanceOverride)

	rendered := n.Render()
	assert.Contains(t, string(rendered), "importance_override: 4.5\n")

	again, err := ParseNode(rendered)
	require.NoError(t, err)
	assert.Equal(t, n, again)
}

// TestParseNodeImportanceOverrideZeroIsNotUnset: 0 is a legitimate override
// ("this matters least") and must stay distinguishable from "unset" — unlike
// Confidence/Stability, which collapse to concrete zero values.
func TestParseNodeImportanceOverrideZeroIsNotUnset(t *testing.T) {
	raw := "---\nid: ent_x\ntype: entity\ntier: long\nstatus: active\nimportance_override: 0\n---\n# X\n"
	n, err := ParseNode([]byte(raw))
	require.NoError(t, err)
	require.NotNil(t, n.ImportanceOverride, "an explicit 0 must not collapse to unset (nil)")
	assert.Zero(t, *n.ImportanceOverride)
}

func TestParseNodeImportanceOverrideAbsentIsNil(t *testing.T) {
	raw := "---\nid: ent_x\ntype: entity\ntier: long\nstatus: active\n---\n# X\n"
	n, err := ParseNode([]byte(raw))
	require.NoError(t, err)
	assert.Nil(t, n.ImportanceOverride)
}

func TestParseNodeRejectsNegativeImportanceOverride(t *testing.T) {
	raw := "---\nid: ent_x\ntype: entity\ntier: long\nstatus: active\nimportance_override: -1\n---\n# X\n"
	_, err := ParseNode([]byte(raw))
	require.Error(t, err)
}

// TestParseNodeImportanceOverrideLegalOnBelief: no belief-only gate — unlike
// confidence/stability/subject, importance_override is legal on any type,
// belief included.
func TestParseNodeImportanceOverrideLegalOnBelief(t *testing.T) {
	raw := "---\nid: bel_x\ntype: belief\ntier: long\nstatus: active\nconfidence: 0.5\nstability: 0\nsubject: ent_y\nimportance_override: 2\n---\n# B\n"
	n, err := ParseNode([]byte(raw))
	require.NoError(t, err)
	require.NotNil(t, n.ImportanceOverride)
	assert.Equal(t, 2.0, *n.ImportanceOverride)
}
```

- [ ] **Step 2: run it — expect a build failure:**

```
$ go test ./internal/memory/ -run TestParseNodeImportanceOverride -v
# watchtower/internal/memory [watchtower/internal/memory.test]
./node_test.go:XXX: n.ImportanceOverride undefined (type Node has no field or method ImportanceOverride)
FAIL	watchtower/internal/memory [build failed]
```

- [ ] **Step 3: write the minimal implementation.** In `node.go`, change the `Node` struct to:

```go
type Node struct {
	ID         string
	Type       string // entity | episode | rollup | belief
	Tier       string // short | long
	Status     string // active | closed | tombstone; beliefs also shaken | retired
	RedirectTo string // tombstones only
	// Belief-only frontmatter (type: belief). Confidence is 0..1, Stability is
	// a confirmation count (>=0), Subject is the entity id the belief is about.
	// Carried as plain values; Render emits them only for beliefs.
	Confidence float64
	Stability  int
	Subject    string
	// ImportanceOverride is the owner's manual importance value (>= 0), legal
	// on ANY node type (no belief-only gate). nil means unset, so the merged
	// memory_nodes.importance_score falls back to ComputeImportance(...)
	// (index.go). A pointer all the way through Node — unlike
	// Confidence/Stability, which collapse to concrete zero values — so 0
	// stays distinguishable from "unset": 0 is a legitimate override ("this
	// matters least") (Slice A of the memory-importance-score redesign,
	// MEM-16).
	ImportanceOverride *float64
	Title              string // first H1 in Body, "" when absent
	Aliases            []string
	Refs               struct {
		PeopleCard int64
		Targets    []int64
	}
	Body string // markdown below the frontmatter, H1 included
}
```

Change the `frontmatter` struct to:

```go
type frontmatter struct {
	ID         string `yaml:"id"`
	Type       string `yaml:"type"`
	Tier       string `yaml:"tier"`
	Status     string `yaml:"status"`
	RedirectTo string `yaml:"redirect_to"`
	// Belief-only keys — structurally known (so KnownFields accepts them) but
	// legal only for type: belief; a post-decode type gate rejects them on any
	// other type. Pointers so absence is distinguishable from a zero value.
	Confidence *float64  `yaml:"confidence"`
	Stability  *int      `yaml:"stability"`
	Subject    string    `yaml:"subject"`
	Aliases    []string  `yaml:"aliases"`
	Refs       *nodeRefs `yaml:"refs"`
	// ImportanceOverride is legal on any node type (no belief-only gate) — see
	// Node.ImportanceOverride.
	ImportanceOverride *float64 `yaml:"importance_override"`
}
```

In `ParseNode`, add the validation right after the Stability check:

```go
	if fm.Stability != nil && *fm.Stability < 0 {
		return Node{}, fmt.Errorf("memory: belief %s stability %d is negative", fm.ID, *fm.Stability)
	}
	if fm.ImportanceOverride != nil && *fm.ImportanceOverride < 0 {
		return Node{}, fmt.Errorf("memory: node %s importance_override %v is negative", fm.ID, *fm.ImportanceOverride)
	}
```

and change the node construction to:

```go
	n := Node{
		ID:                 fm.ID,
		Type:               fm.Type,
		Tier:               fm.Tier,
		Status:             fm.Status,
		RedirectTo:         fm.RedirectTo,
		Subject:            fm.Subject,
		Aliases:            fm.Aliases,
		ImportanceOverride: fm.ImportanceOverride,
		Body:               string(body),
	}
```

In `Render`, add the emission right after `redirect_to`, before the belief-only block:

```go
	if n.RedirectTo != "" {
		fmt.Fprintf(&b, "redirect_to: %s\n", n.RedirectTo)
	}
	if n.ImportanceOverride != nil {
		fmt.Fprintf(&b, "importance_override: %s\n", strconv.FormatFloat(*n.ImportanceOverride, 'g', -1, 64))
	}
	if n.Type == "belief" {
```

- [ ] **Step 4: run it — expect green, and confirm the pre-existing golden round-trips are untouched:**

```
$ go test ./internal/memory/ -run 'TestParseNode|TestRender|TestBelief' -v 2>&1 | tail -30
--- PASS: TestParseNodeGolden (0.00s)
--- PASS: TestRenderGoldenRoundTrip (0.00s)
--- PASS: TestRenderMinimalRoundTrip (0.00s)
--- PASS: TestRenderTombstoneRoundTrip (0.00s)
--- PASS: TestParseNodeImportanceOverrideRoundTrip (0.00s)
--- PASS: TestParseNodeImportanceOverrideZeroIsNotUnset (0.00s)
--- PASS: TestParseNodeImportanceOverrideAbsentIsNil (0.00s)
--- PASS: TestParseNodeRejectsNegativeImportanceOverride (0.00s)
--- PASS: TestParseNodeImportanceOverrideLegalOnBelief (0.00s)
--- PASS: TestBeliefGoldenRoundTrip (0.00s)
--- PASS: TestBeliefWithoutOptionalFieldsRoundTrips (0.00s)
PASS
ok  	watchtower/internal/memory	0.2s
```

- [ ] **Step 5: commit:**

```
$ git add internal/memory/node.go internal/memory/node_test.go
$ git commit -m "feat(memory): importance_override frontmatter field (Slice A, MEM-16)

Legal on any node type, >= 0 when present, pointer throughout so 0 stays
distinguishable from unset."
```

---

## Task 4: DB layer — `MemoryNodeRow.ImportanceScore`

**Depends on:** Task 2 (the column must exist for the SQL to run). **Blocks:** Task 5.

**Files:**
- Modify: `internal/db/memory.go` — `MemoryNodeRow` struct (lines 14–32), `UpsertMemoryNode`'s INSERT (lines 71–89), `memoryNodeSelectCols`/`scanMemoryNodeRow` (lines 268–282)
- Test: `internal/db/memory_test.go` — new test inserted after `TestMemoryNodeSubjectConfidenceRoundTrip` (ends line 256), before `TestMemoryNodeSubjectConfidenceDefaults` (line 260)

**Interfaces:**
- Consumes: the `importance_score` column (Task 2).
- Produces: `db.MemoryNodeRow.ImportanceScore float64` — consumed by Task 5 (`row.ImportanceScore = importance`) and Task 6's tests (`d.GetMemoryNode(id).ImportanceScore`).

Current `MemoryNodeRow` (lines 14–32):

```go
type MemoryNodeRow struct {
	ID          string // ent_*/ep_*/sum_*/bel_*
	Type        string // entity|episode|rollup|belief
	Tier        string // short|long
	Status      string // active|closed|tombstone
	RedirectTo  string // target node ID when Status == tombstone, else empty
	Title       string
	Path        string // vault-relative file path
	ContentHash string // sha256 of file bytes at last index
	IndexedAt   string
	Subject     string  // belief subject entity id, "" for non-beliefs; file-derived (Node.Subject, see 00019)
	Confidence  float64 // belief confidence 0..1, 0 for non-beliefs; file-derived (Node.Confidence, see 00019)
	// DisputePending mirrors presence in the memory_dispute_flags SIDE TABLE
	// (see 00019) — runtime state, never written by UpsertMemoryNode. Read-only
	// here; set via SetDisputePending and cleared by the inbox watchtower
	// detector's same-transaction DELETE when it mints a dispute item
	// (mintDisputeItem) — the only clear path, so a dispute surfaces exactly once.
	DisputePending bool
}
```

Current `UpsertMemoryNode`'s INSERT (lines 71–89):

```go
	_, err = tx.Exec(`INSERT INTO memory_nodes
		(id, type, tier, status, redirect_to, title, path, content_hash, indexed_at, subject, confidence)
		VALUES (?, ?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			type = excluded.type,
			tier = excluded.tier,
			status = excluded.status,
			redirect_to = excluded.redirect_to,
			title = excluded.title,
			path = excluded.path,
			content_hash = excluded.content_hash,
			indexed_at = excluded.indexed_at,
			subject = excluded.subject,
			confidence = excluded.confidence`,
		row.ID, row.Type, row.Tier, row.Status, row.RedirectTo,
		row.Title, row.Path, row.ContentHash, row.IndexedAt, row.Subject, row.Confidence)
	if err != nil {
		return fmt.Errorf("upserting memory node %s: %w", row.ID, err)
	}
```

Current `memoryNodeSelectCols`/`scanMemoryNodeRow` (lines 268–282):

```go
const memoryNodeSelectCols = `id, type, tier, status, COALESCE(redirect_to, ''),
		title, path, content_hash, indexed_at, subject, confidence,
		EXISTS(SELECT 1 FROM memory_dispute_flags f WHERE f.node_id = memory_nodes.id)`

func scanMemoryNodeRow(scan func(...any) error) (MemoryNodeRow, error) {
	var row MemoryNodeRow
	err := scan(&row.ID, &row.Type, &row.Tier, &row.Status, &row.RedirectTo,
		&row.Title, &row.Path, &row.ContentHash, &row.IndexedAt,
		&row.Subject, &row.Confidence, &row.DisputePending)
	return row, err
}
```

- [ ] **Step 1: write the failing test** — insert into `internal/db/memory_test.go` after line 256 (`TestMemoryNodeSubjectConfidenceRoundTrip`'s closing brace), before `TestMemoryNodeSubjectConfidenceDefaults`:

```go
// TestMemoryNodeImportanceScoreRoundTrip: memory_nodes.importance_score
// (Slice A, migration 00027, MEM-16) round-trips through
// UpsertMemoryNode/GetMemoryNode/ListMemoryNodes.
func TestMemoryNodeImportanceScoreRoundTrip(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("ent_importance", func(r *MemoryNodeRow) {
		r.ImportanceScore = 6.5
	})
	if err := db.UpsertMemoryNode(row, "importance body", nil); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}

	got, err := db.GetMemoryNode("ent_importance")
	if err != nil {
		t.Fatalf("GetMemoryNode: %v", err)
	}
	if got.ImportanceScore != 6.5 {
		t.Errorf("GetMemoryNode.ImportanceScore = %v, want 6.5", got.ImportanceScore)
	}

	rows, err := db.ListMemoryNodes()
	if err != nil {
		t.Fatalf("ListMemoryNodes: %v", err)
	}
	if len(rows) != 1 || rows[0].ImportanceScore != 6.5 {
		t.Fatalf("ListMemoryNodes = %+v, want one row with importance_score 6.5", rows)
	}

	// A re-upsert with a different score replaces it (not additive).
	row.ImportanceScore = 1.0
	row.ContentHash = "hash-2"
	if err := db.UpsertMemoryNode(row, "importance body v2", nil); err != nil {
		t.Fatalf("second upsert: %v", err)
	}
	got, err = db.GetMemoryNode("ent_importance")
	if err != nil {
		t.Fatalf("GetMemoryNode after re-upsert: %v", err)
	}
	if got.ImportanceScore != 1.0 {
		t.Errorf("GetMemoryNode.ImportanceScore after re-upsert = %v, want 1.0", got.ImportanceScore)
	}
}
```

- [ ] **Step 2: run it — expect a build failure** (the field doesn't exist yet):

```
$ go test ./internal/db/ -run TestMemoryNodeImportanceScoreRoundTrip -v
# watchtower/internal/db [watchtower/internal/db.test]
./memory_test.go:XXX: r.ImportanceScore undefined (type *MemoryNodeRow has no field or method ImportanceScore)
FAIL	watchtower/internal/db [build failed]
```

- [ ] **Step 3: write the minimal implementation.** Change `MemoryNodeRow` to:

```go
type MemoryNodeRow struct {
	ID          string // ent_*/ep_*/sum_*/bel_*
	Type        string // entity|episode|rollup|belief
	Tier        string // short|long
	Status      string // active|closed|tombstone
	RedirectTo  string // target node ID when Status == tombstone, else empty
	Title       string
	Path        string // vault-relative file path
	ContentHash string // sha256 of file bytes at last index
	IndexedAt   string
	Subject     string  // belief subject entity id, "" for non-beliefs; file-derived (Node.Subject, see 00019)
	Confidence  float64 // belief confidence 0..1, 0 for non-beliefs; file-derived (Node.Confidence, see 00019)
	// ImportanceScore is the merged (owner-override-or-computed) importance
	// snapshot Reconcile/Rebuild refresh per node — override when the node's
	// frontmatter carries one, else ComputeImportance(...)'s live signal read
	// (internal/memory/index.go). A periodic snapshot for future retrieval
	// ranking, distinct from evict.go's always-live RetentionScore (Slice A of
	// the memory-importance-score redesign, MEM-16; migration 00027).
	ImportanceScore float64
	// DisputePending mirrors presence in the memory_dispute_flags SIDE TABLE
	// (see 00019) — runtime state, never written by UpsertMemoryNode. Read-only
	// here; set via SetDisputePending and cleared by the inbox watchtower
	// detector's same-transaction DELETE when it mints a dispute item
	// (mintDisputeItem) — the only clear path, so a dispute surfaces exactly once.
	DisputePending bool
}
```

Change `UpsertMemoryNode`'s INSERT to:

```go
	_, err = tx.Exec(`INSERT INTO memory_nodes
		(id, type, tier, status, redirect_to, title, path, content_hash, indexed_at, subject, confidence, importance_score)
		VALUES (?, ?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			type = excluded.type,
			tier = excluded.tier,
			status = excluded.status,
			redirect_to = excluded.redirect_to,
			title = excluded.title,
			path = excluded.path,
			content_hash = excluded.content_hash,
			indexed_at = excluded.indexed_at,
			subject = excluded.subject,
			confidence = excluded.confidence,
			importance_score = excluded.importance_score`,
		row.ID, row.Type, row.Tier, row.Status, row.RedirectTo,
		row.Title, row.Path, row.ContentHash, row.IndexedAt, row.Subject, row.Confidence, row.ImportanceScore)
	if err != nil {
		return fmt.Errorf("upserting memory node %s: %w", row.ID, err)
	}
```

Change `memoryNodeSelectCols`/`scanMemoryNodeRow` to:

```go
const memoryNodeSelectCols = `id, type, tier, status, COALESCE(redirect_to, ''),
		title, path, content_hash, indexed_at, subject, confidence, importance_score,
		EXISTS(SELECT 1 FROM memory_dispute_flags f WHERE f.node_id = memory_nodes.id)`

func scanMemoryNodeRow(scan func(...any) error) (MemoryNodeRow, error) {
	var row MemoryNodeRow
	err := scan(&row.ID, &row.Type, &row.Tier, &row.Status, &row.RedirectTo,
		&row.Title, &row.Path, &row.ContentHash, &row.IndexedAt,
		&row.Subject, &row.Confidence, &row.ImportanceScore, &row.DisputePending)
	return row, err
}
```

- [ ] **Step 4: run it — expect green, plus the full package (this touches every `MemoryNodeRow` consumer):**

```
$ go test ./internal/db/ -run TestMemoryNodeImportanceScoreRoundTrip -v
=== RUN   TestMemoryNodeImportanceScoreRoundTrip
--- PASS: TestMemoryNodeImportanceScoreRoundTrip (0.01s)
PASS
ok  	watchtower/internal/db	0.2s

$ go build ./... && go test ./internal/db/... ./internal/memory/... ./internal/inbox/... 2>&1 | tail -10
ok  	watchtower/internal/db	0.4s
ok  	watchtower/internal/memory	0.6s
ok  	watchtower/internal/inbox	0.3s
```

(The `go build ./...` + broader test sweep is because `MemoryNodeRow` is a public struct consumed outside `internal/db`/`internal/memory` too — e.g. `internal/inbox`'s watchtower detector calls `ListDisputePendingBeliefs`, which returns `[]MemoryNodeRow`. Adding a field is additive and every existing struct-literal construction in the codebase uses named fields, so nothing else needs to change — this step is the confirmation.)

- [ ] **Step 5: commit:**

```
$ git add internal/db/memory.go internal/db/memory_test.go
$ git commit -m "feat(db): MemoryNodeRow.ImportanceScore column wiring (Slice A, MEM-16)

select/scan/upsert carry memory_nodes.importance_score."
```

---

## Task 5: Wire the computation into `index.go`'s Reconcile/Rebuild

**Depends on:** Tasks 1, 3, 4. **Blocks:** Task 6.

**Files:**
- Modify: `internal/memory/index.go` — `(p *reconcilePass) file()` (lines 141–167), new `(p *reconcilePass) computeImportance` method
- Test: `internal/memory/index_test.go` — new test appended after `TestReconcileSkipsNonNodeFiles` (ends line 285), before `TestReconcileQuarantinesMalformedFile` (line 291)

**Interfaces:**
- Consumes: `ComputeImportance`/`ImportanceInputs` (Task 1), `Node.ImportanceOverride` (Task 3), `db.MemoryNodeRow.ImportanceScore` (Task 4), and the pre-existing `database.CountMemoryLinksIn(id) (int, error)`, `v.OwnerEdited(rel) (bool, error)`, `database.LinkedEntityEngagement(id) (engaged, dismissed int, err error)`, `hasSituationAlias(aliases []string) bool` (all already used by `EvictEpisodes` in `evict.go`).
- Produces: `func (p *reconcilePass) computeImportance(n Node, rel string) (float64, error)` — consumed only inside `index.go`'s own `file()`; not exported, no other task depends on its exact name, only on the *behavior* (verified by Task 6's tests).

Current `file()` (lines 141–167):

```go
	n, err := ParseNode(raw)
	if err != nil {
		p.quarantine(rel, err)
		return nil
	}
	if n.ID != id {
		p.quarantine(rel, fmt.Errorf("frontmatter id %q does not match filename", n.ID))
		return nil
	}

	row := db.MemoryNodeRow{
		ID:          n.ID,
		Type:        n.Type,
		Tier:        n.Tier,
		Status:      n.Status,
		RedirectTo:  n.RedirectTo,
		Title:       n.Title,
		Path:        rel,
		ContentHash: hash,
		IndexedAt:   p.now,
		Subject:     n.Subject,    // file-derived (belief-only; "" otherwise), see 00019
		Confidence:  n.Confidence, // file-derived (belief-only; 0 otherwise), see 00019
	}
	if err := p.database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, p.logf)...); err != nil {
		p.quarantine(rel, err)
		return nil
	}
	if wasIndexed {
		p.stats.Updated++
	} else {
		p.stats.Added++
	}
	return nil
}
```

- [ ] **Step 1: write the failing test** — append to `internal/memory/index_test.go` after `TestReconcileSkipsNonNodeFiles` (line 285), before `TestReconcileQuarantinesMalformedFile`:

```go
// TestReconcileComputesImportanceScore: a fixture exercising all four
// ComputeImportance signals together — links-in, situation-origin,
// owner-touch, net engagement — proves Reconcile persists the SAME value
// ComputeImportance would compute directly, with no recency factor (Slice A,
// MEM-16).
func TestReconcileComputesImportanceScore(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	ep := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5RC1", "episode", "Warm story")
	ep.Aliases = []string{"situation:77"}
	writeNodes(t, v, ep)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	linker := linkingEntity(t, "ent_01ARZ3NDEKTSV4RRFFQ69G5RC2", "Linker", ep.ID)
	writeNodes(t, v, linker)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	require.NoError(t, d.BumpEngagement(linker.ID, true, "2026-07-18T10:00:00Z"))

	// Simulate an owner edit on ep, then touch it once more so it gets
	// reparsed NOW THAT the link (and the engagement bump) are already
	// committed.
	rel, err := nodeRelPath(ep.ID)
	require.NoError(t, err)
	edited := ep
	edited.Body = ep.Body + "\nOwner annotation.\n"
	require.NoError(t, os.WriteFile(filepath.Join(v.path, filepath.FromSlash(rel)), edited.Render(), 0o644))
	committed, err := v.CommitOwnerEdits()
	require.NoError(t, err)
	require.True(t, committed)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	require.Equal(t, 1, stats.Updated, "the owner-edited episode is reparsed")

	row, err := d.GetMemoryNode(ep.ID)
	require.NoError(t, err)

	want := ComputeImportance(ImportanceInputs{
		LinksIn:         1,
		SituationOrigin: true,
		OwnerTouched:    true,
		Engagement:      1,
	})
	assert.Equal(t, want, row.ImportanceScore, "importance_score matches ComputeImportance with no recency applied")
}
```

- [ ] **Step 2: run it — expect an assertion failure** (`file()` never sets `row.ImportanceScore`, so it defaults to 0):

```
$ go test ./internal/memory/ -run TestReconcileComputesImportanceScore -v
=== RUN   TestReconcileComputesImportanceScore
    index_test.go:XXX:
        	Error Trace:	index_test.go:XXX
        	Error:      	Not equal:
        	            	expected: 6
        	            	actual  : 0
        	Test:       	TestReconcileComputesImportanceScore
        	Messages:   	importance_score matches ComputeImportance with no recency applied
--- FAIL: TestReconcileComputesImportanceScore (0.02s)
FAIL
```

- [ ] **Step 3: write the minimal implementation.** Change `file()`'s tail to:

```go
	n, err := ParseNode(raw)
	if err != nil {
		p.quarantine(rel, err)
		return nil
	}
	if n.ID != id {
		p.quarantine(rel, fmt.Errorf("frontmatter id %q does not match filename", n.ID))
		return nil
	}

	importance, err := p.computeImportance(n, rel)
	if err != nil {
		p.quarantine(rel, fmt.Errorf("computing importance: %w", err))
		return nil
	}

	row := db.MemoryNodeRow{
		ID:              n.ID,
		Type:            n.Type,
		Tier:            n.Tier,
		Status:          n.Status,
		RedirectTo:      n.RedirectTo,
		Title:           n.Title,
		Path:            rel,
		ContentHash:     hash,
		IndexedAt:       p.now,
		Subject:         n.Subject,    // file-derived (belief-only; "" otherwise), see 00019
		Confidence:      n.Confidence, // file-derived (belief-only; 0 otherwise), see 00019
		ImportanceScore: importance,   // merged override-or-computed snapshot, see 00027 (MEM-16)
	}
	if err := p.database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, p.logf)...); err != nil {
		p.quarantine(rel, err)
		return nil
	}
	if wasIndexed {
		p.stats.Updated++
	} else {
		p.stats.Added++
	}
	return nil
}

// computeImportance returns node n's merged importance value: its
// frontmatter override when set, else ComputeImportance's live read of
// links-in, situation-origin, owner-touch, and net linked-entity engagement —
// the same signal calls EvictEpisodes uses. No recency factor (MEM-16;
// recency is eviction-specific and stays in RetentionScore only). rel is the
// node's vault-relative path (for the OwnerEdited git-log check). A signal
// lookup error propagates so file() can quarantine the node and keep its
// prior importance_score untouched rather than persist a half-failed read
// (design §6) — an override, by contrast, needs none of these lookups and so
// can never fail this way.
func (p *reconcilePass) computeImportance(n Node, rel string) (float64, error) {
	if n.ImportanceOverride != nil {
		return *n.ImportanceOverride, nil
	}
	linksIn, err := p.database.CountMemoryLinksIn(n.ID)
	if err != nil {
		return 0, err
	}
	ownerTouched, err := p.v.OwnerEdited(rel)
	if err != nil {
		return 0, err
	}
	engaged, dismissed, err := p.database.LinkedEntityEngagement(n.ID)
	if err != nil {
		return 0, err
	}
	return ComputeImportance(ImportanceInputs{
		LinksIn:         linksIn,
		SituationOrigin: hasSituationAlias(n.Aliases),
		OwnerTouched:    ownerTouched,
		Engagement:      engaged - dismissed,
	}), nil
}
```

- [ ] **Step 4: run it — expect green, plus the whole Reconcile suite (to confirm nothing else regressed — `Stats` shape is unchanged, so every pre-existing `assert.Equal(t, Stats{...}, stats)` still holds):**

```
$ go test ./internal/memory/ -run 'TestReconcile|TestMemory02' -v 2>&1 | tail -25
--- PASS: TestReconcileIndexesNewNodes (0.01s)
--- PASS: TestReconcileIndexesBeliefSubjectConfidence (0.01s)
--- PASS: TestReconcileReparsesHashClearedBelief (0.01s)
--- PASS: TestReconcileUpdatesEditedFile (0.01s)
--- PASS: TestReconcileDeletesRemovedFile (0.01s)
--- PASS: TestReconcileSkipsNonNodeFiles (0.01s)
--- PASS: TestReconcileComputesImportanceScore (0.02s)
--- PASS: TestReconcileQuarantinesMalformedFile (0.01s)
--- PASS: TestReconcileQuarantinesDuplicateAlias (0.01s)
--- PASS: TestMemory02_ReindexEquivalence (0.02s)
PASS
ok  	watchtower/internal/memory	0.4s
```

- [ ] **Step 5: run the whole package + evict suite (proves `EvictEpisodes` truly never reads the new column):**

```
$ go test ./internal/memory/ -v 2>&1 | tail -5
PASS
ok  	watchtower/internal/memory	1.1s
```

```
$ git add internal/memory/index.go internal/memory/index_test.go
$ git commit -m "feat(memory): compute+persist memory_nodes.importance_score in Reconcile/Rebuild (Slice A, MEM-16)

Override wins when the node's frontmatter carries one; otherwise
ComputeImportance reads live links-in/situation/owner-touch/engagement
signals — no recency factor. A signal-lookup error quarantines the one file
(prior importance_score preserved) rather than aborting the pass.
EvictEpisodes is untouched and never reads the column."
```

---

## Task 5b: Extend importance computation to `upsertIndexNode` (all non-Reconcile write paths)

**Added mid-execution, 2026-07-18.** Task 5's implementer discovered (and correctly did not silently fix) a real gap: `internal/memory/merge.go`'s `upsertIndexNode` — a second, separate index-write helper called from ~15 places across the package (`aging.go`, `action_ingest.go`, `beliefs.go`, `calendar_ingest.go`, `dedupe.go`, `concepts.go`, `evict.go` ×2, `gmail_extract.go`, `ingest.go`, `merge.go` itself, `mirror_ingest.go`, `pipeline.go`, `reflect.go`, `rewrite.go`) whenever a node is written directly to the vault outside the batch `Reconcile`/`Rebuild` pass — never sets `ImportanceScore`, so it silently defaults to 0 and (via `UpsertMemoryNode`'s `ON CONFLICT DO UPDATE SET importance_score = excluded.importance_score`, added in Task 4) clobbers any previously-computed value. Owner decision (2026-07-18): fix this for real by extending importance computation to `upsertIndexNode` itself, rather than accepting staleness as a documented limitation or narrowly patching only `evict.go`'s two call sites.

**Depends on:** Task 5 (needs `ComputeImportance`, `Node.ImportanceOverride`, `db.MemoryNodeRow.ImportanceScore`, and the reference logic in `index.go`'s `computeImportance`). **Blocks:** Task 6 (Task 6's final "full package, expect green" step depends on `TestEvictReindexEquivalence` passing again).

**Files:**
- Modify: `internal/memory/importance.go` (new shared function `computeNodeImportance`)
- Modify: `internal/memory/index.go` — remove `(p *reconcilePass) computeImportance`, change `file()`'s call site to use the shared function
- Modify: `internal/memory/merge.go` — `upsertIndexNode`'s signature gains a `*Vault` parameter, computes and sets `ImportanceScore`
- Modify (one-line call-site update each, adding the already-in-scope vault variable as an argument): `internal/memory/aging.go:77`, `internal/memory/action_ingest.go:303`, `internal/memory/beliefs.go:210`, `internal/memory/calendar_ingest.go:268`, `internal/memory/dedupe.go:163`, `internal/memory/concepts.go:91`, `internal/memory/evict.go:201` and `:206`, `internal/memory/gmail_extract.go:331`, `internal/memory/ingest.go:166`, `internal/memory/merge.go:77` (inside `Merge`), `internal/memory/mirror_ingest.go:168`, `internal/memory/pipeline.go:1021`, `internal/memory/seed.go:135`, `internal/memory/reflect.go:190`, `internal/memory/rewrite.go:168`
- Test: `internal/memory/merge_test.go` (new test for `upsertIndexNode` computing/preserving importance), `internal/memory/evict_test.go` (no code change — `TestEvictReindexEquivalence` must pass again as-is, this is the regression proof)

**Interfaces:**
- Consumes: `ComputeImportance`/`ImportanceInputs` (Task 1), `Node.ImportanceOverride` (Task 3), `db.MemoryNodeRow.ImportanceScore` (Task 4), `nodeRelPath(id string) (string, error)` (existing, `vault.go:320`), `database.CountMemoryLinksIn`/`v.OwnerEdited`/`database.LinkedEntityEngagement`/`hasSituationAlias` (existing, already used by Task 5's `reconcilePass.computeImportance`).
- Produces: `func computeNodeImportance(database *db.DB, v *Vault, n Node, rel string) (float64, error)` — a package-level function consumed by both `index.go`'s `file()` and `merge.go`'s `upsertIndexNode`. `upsertIndexNode`'s new signature `func upsertIndexNode(database *db.DB, v *Vault, n Node, indexedAt string) error` is consumed by all 15 call sites listed above (this is the one breaking signature change in this task — every call site must be updated in the same commit or the package will not build).

Current `upsertIndexNode` (`internal/memory/merge.go:137-151`):

```go
func upsertIndexNode(database *db.DB, n Node, indexedAt string) error {
	rel, err := nodeRelPath(n.ID)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(n.Render())
	row := db.MemoryNodeRow{
		ID: n.ID, Type: n.Type, Tier: n.Tier, Status: n.Status, RedirectTo: n.RedirectTo,
		Title: n.Title, Path: rel, ContentHash: hex.EncodeToString(sum[:]), IndexedAt: indexedAt,
		Subject: n.Subject, Confidence: n.Confidence,
	}
	if err := database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, nil)...); err != nil {
		return fmt.Errorf("memory: index %s: %w", n.ID, err)
	}
	return nil
}
```

Current `reconcilePass.computeImportance` (`internal/memory/index.go:193-215`, the reference logic to extract):

```go
func (p *reconcilePass) computeImportance(n Node, rel string) (float64, error) {
	if n.ImportanceOverride != nil {
		return *n.ImportanceOverride, nil
	}
	linksIn, err := p.database.CountMemoryLinksIn(n.ID)
	if err != nil {
		return 0, err
	}
	ownerTouched, err := p.v.OwnerEdited(rel)
	if err != nil {
		return 0, err
	}
	engaged, dismissed, err := p.database.LinkedEntityEngagement(n.ID)
	if err != nil {
		return 0, err
	}
	return ComputeImportance(ImportanceInputs{
		LinksIn:         linksIn,
		SituationOrigin: hasSituationAlias(n.Aliases),
		OwnerTouched:    ownerTouched,
		Engagement:      engaged - dismissed,
	}), nil
}
```

- [ ] **Step 1: write the failing test** — add to `internal/memory/merge_test.go` (after the existing tests, matching the file's `package memory` / `newTestVault`/`newTestDB`/`writeNodes` idiom):

```go
// TestUpsertIndexNodeComputesImportance: upsertIndexNode (the non-Reconcile
// index-write path used by eviction/dedupe/concepts/beliefs/aging/mirrors/
// ingest/reflect/seed) must compute a real importance_score via the same
// ComputeImportance logic Reconcile uses, not silently persist 0 (Slice A
// follow-up, added 2026-07-18: upsertIndexNode previously clobbered any
// prior importance_score to 0 via UpsertMemoryNode's unconditional
// ON CONFLICT SET).
func TestUpsertIndexNodeComputesImportance(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	linker := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5UI1", "entity", "Linker")
	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5UI2", "entity", "Target")
	linker.Body = "# Linker\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5UI2]] for background.\n"
	writeNodes(t, v, linker, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// target now has LinksIn == 1 in the index. Re-write it via
	// upsertIndexNode directly (the non-Reconcile path) and confirm the
	// persisted importance_score reflects that link, not a reset to 0.
	require.NoError(t, upsertIndexNode(d, v, target, "2026-07-18T00:00:00Z"))

	row, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	want := ComputeImportance(ImportanceInputs{LinksIn: 1})
	assert.Equal(t, want, row.ImportanceScore, "upsertIndexNode must compute importance like Reconcile, not persist 0")
}

// TestUpsertIndexNodeImportanceOverrideWins: an ImportanceOverride short-
// circuits upsertIndexNode's computation exactly as it does in Reconcile.
func TestUpsertIndexNodeImportanceOverrideWins(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	override := 9.0
	n := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5UI3", "entity", "Overridden")
	n.ImportanceOverride = &override

	require.NoError(t, upsertIndexNode(d, v, n, "2026-07-18T00:00:00Z"))

	row, err := d.GetMemoryNode(n.ID)
	require.NoError(t, err)
	assert.Equal(t, 9.0, row.ImportanceScore)
}
```

- [ ] **Step 2: run it — expect a build failure** (the two-argument `upsertIndexNode(d, v, target, ...)` call doesn't match the current three-argument signature):

```
$ go test ./internal/memory/ -run TestUpsertIndexNodeComputesImportance -v
# watchtower/internal/memory [watchtower/internal/memory.test]
./merge_test.go:XXX: too many arguments in call to upsertIndexNode
FAIL	watchtower/internal/memory [build failed]
```

- [ ] **Step 3: add the shared function to `internal/memory/importance.go`** (append after `ComputeImportance`):

```go
// computeNodeImportance is the merged (owner-override-or-computed)
// importance value for node n at vault-relative path rel: n's
// ImportanceOverride if set, else ComputeImportance fed by live
// links-in/situation-origin/owner-touch/engagement reads. Shared by
// index.go's Reconcile/Rebuild path and merge.go's upsertIndexNode (every
// non-Reconcile write path) so both persist a mutually consistent value for
// the same file — MEM-16, Slice A follow-up (added 2026-07-18: upsertIndexNode
// previously never set this field).
func computeNodeImportance(database *db.DB, v *Vault, n Node, rel string) (float64, error) {
	if n.ImportanceOverride != nil {
		return *n.ImportanceOverride, nil
	}
	linksIn, err := database.CountMemoryLinksIn(n.ID)
	if err != nil {
		return 0, err
	}
	ownerTouched, err := v.OwnerEdited(rel)
	if err != nil {
		return 0, err
	}
	engaged, dismissed, err := database.LinkedEntityEngagement(n.ID)
	if err != nil {
		return 0, err
	}
	return ComputeImportance(ImportanceInputs{
		LinksIn:         linksIn,
		SituationOrigin: hasSituationAlias(n.Aliases),
		OwnerTouched:    ownerTouched,
		Engagement:      engaged - dismissed,
	}), nil
}
```

`importance.go` does not currently import `internal/db` — add `"watchtower/internal/db"` to its import block (check the existing import block first; `index.go` already imports it under the same path, use the identical import string).

- [ ] **Step 4: remove `reconcilePass.computeImportance` from `index.go` and call the shared function instead.** Delete the method (`index.go:193-215` per the quoted block above). Change `file()`'s call site from:

```go
	importance, err := p.computeImportance(n, rel)
```

to:

```go
	importance, err := computeNodeImportance(p.database, p.v, n, rel)
```

(No other change to `file()` — the quarantine-on-error handling immediately below is untouched.)

- [ ] **Step 5: update `upsertIndexNode` in `merge.go`:**

```go
func upsertIndexNode(database *db.DB, v *Vault, n Node, indexedAt string) error {
	rel, err := nodeRelPath(n.ID)
	if err != nil {
		return err
	}
	importance, err := computeNodeImportance(database, v, n, rel)
	if err != nil {
		return fmt.Errorf("memory: computing importance for %s: %w", n.ID, err)
	}
	sum := sha256.Sum256(n.Render())
	row := db.MemoryNodeRow{
		ID: n.ID, Type: n.Type, Tier: n.Tier, Status: n.Status, RedirectTo: n.RedirectTo,
		Title: n.Title, Path: rel, ContentHash: hex.EncodeToString(sum[:]), IndexedAt: indexedAt,
		Subject: n.Subject, Confidence: n.Confidence, ImportanceScore: importance,
	}
	if err := database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, nil)...); err != nil {
		return fmt.Errorf("memory: index %s: %w", n.ID, err)
	}
	return nil
}
```

This is a deliberate behavior addition: an `upsertIndexNode` call can now fail for a NEW reason (an importance signal lookup error) in addition to its existing failure modes. Every one of the 15 callers already has a policy for handling an `upsertIndexNode` error (7 abort-and-propagate, 5 log-and-continue via `p.logf`/self-heal-next-Reconcile, 1 tail-call propagation in `dedupe.go`, `Merge` itself, and the 2 in `evict.go`) — this task does not change any caller's error-handling policy, only adds one more error source flowing through the same existing channel.

- [ ] **Step 6: update all 15 call sites**, adding the vault variable already in scope at each (per the research: a bare `v` parameter at `aging.go:77`, `dedupe.go:163`, `concepts.go:91`, `evict.go:201`/`206`, `ingest.go:166`, `seed.go:135`, and `merge.go:77`; the `p.vault` struct field at `action_ingest.go:303`, `beliefs.go:210`, `calendar_ingest.go:268`, `gmail_extract.go:331`, `mirror_ingest.go:168`, `pipeline.go:1021`, `reflect.go:190`, `rewrite.go:168`). Example (`aging.go:77`):

```go
		if err := upsertIndexNode(database, v, n, nowStr); err != nil {
```

Example (`action_ingest.go:303`, a `Pipeline` method):

```go
			if ierr := upsertIndexNode(p.db, p.vault, n, now); ierr != nil {
```

Apply the equivalent one-argument insertion at every other listed call site — each is a single-line change (add `v,` or `p.vault,` as the second argument), no other logic in these functions changes.

- [ ] **Step 7: run it — expect green:**

```
$ go test ./internal/memory/ -run 'TestUpsertIndexNodeComputesImportance|TestUpsertIndexNodeImportanceOverrideWins' -v
=== RUN   TestUpsertIndexNodeComputesImportance
--- PASS: TestUpsertIndexNodeComputesImportance (0.02s)
=== RUN   TestUpsertIndexNodeImportanceOverrideWins
--- PASS: TestUpsertIndexNodeImportanceOverrideWins (0.01s)
PASS
ok  	watchtower/internal/memory	0.3s
```

- [ ] **Step 8: confirm the regression is fixed — run the previously-failing guard test and the full package:**

```
$ go test ./internal/memory/ -run TestEvictReindexEquivalence -v
=== RUN   TestEvictReindexEquivalence
--- PASS: TestEvictReindexEquivalence (0.05s)
PASS
ok  	watchtower/internal/memory	0.2s

$ go build ./... && go test -count=1 ./internal/memory/... -v 2>&1 | tail -10
ok  	watchtower/internal/memory	9.4s
```

Expected: **zero** failures anywhere in the package — this is the load-bearing proof that extending `computeNodeImportance` to all 15 `upsertIndexNode` call sites actually closed the gap Task 5 surfaced, not just silenced one test.

- [ ] **Step 9: broader blast-radius check** (every one of the 15 call sites lives in `internal/memory`, but confirm nothing outside the package calls `upsertIndexNode` directly — it is unexported — and that no other package's tests regressed):

```
$ go vet ./... && go build ./...
$ go test ./internal/db/... ./internal/inbox/... ./internal/daemon/... 2>&1 | tail -10
```

- [ ] **Step 10: commit:**

```
$ git add internal/memory/importance.go internal/memory/index.go internal/memory/merge.go internal/memory/merge_test.go internal/memory/aging.go internal/memory/action_ingest.go internal/memory/beliefs.go internal/memory/calendar_ingest.go internal/memory/dedupe.go internal/memory/concepts.go internal/memory/evict.go internal/memory/gmail_extract.go internal/memory/ingest.go internal/memory/mirror_ingest.go internal/memory/pipeline.go internal/memory/seed.go internal/memory/reflect.go internal/memory/rewrite.go
$ git commit -m "fix(memory): extend importance computation to upsertIndexNode, all non-Reconcile write paths (Slice A follow-up, MEM-16)

Task 5 wired importance_score into Reconcile/Rebuild only. upsertIndexNode
(merge.go) — the second index-write path used by eviction/dedupe/concepts/
beliefs/aging/mirrors/gmail/calendar/action-ingest/seed/ingest/reflect/
rewrite — never set the field, silently clobbering any prior value to 0 via
UpsertMemoryNode's unconditional ON CONFLICT SET (added in Task 4). Extracted
the shared computeNodeImportance from index.go's former reconcilePass method;
upsertIndexNode now computes the same merged override-or-computed value.
Fixes the TestEvictReindexEquivalence regression Task 5 surfaced (owner
decision 2026-07-18: fix for real across all 15 call sites, not a narrow
evict.go-only patch or a documented staleness limitation)."
```

---

## Task 5c: Two-phase Reconcile — importance refinement pass for scan-order independence

**Added mid-execution, 2026-07-18.** Task 6's implementer found (correctly did not fix or paper over) a second real gap, this time in `Reconcile`/`Rebuild`'s core wiring from Task 5 itself: `Reconcile` walks `vaultSubdirs` (`{"entities", "episodes", "rollups", "beliefs"}`) in a fixed order, and `computeNodeImportance`'s `CountMemoryLinksIn` reads live DB state **at the moment each file is processed** — so within a single Reconcile/Rebuild call, a link from a later-scanned directory (e.g. a rollup) to an earlier-scanned one (e.g. an entity) is invisible when the earlier node is processed, even though it becomes visible moments later once the later directory is walked. A full `Rebuild` — which processes the entire vault in one `Reconcile` call — therefore does NOT reliably reproduce the same `importance_score` an accumulated history of separate incremental `Reconcile` calls converges to, for any link pointing "backward" in scan order (rollup→entity and episode→entity are the common real cases, since rollups/episodes routinely reference the entities they're about). This is a genuine MEM-02 violation for `importance_score` specifically — not an edge case, and not something Task 6's test-only scope may fix. Owner decision (2026-07-18): fix `Reconcile`/`Rebuild` properly (a second, order-independent refinement pass), not accept it as a documented limitation.

**Depends on:** Task 5b (needs `computeNodeImportance` to exist as the shared function this task calls a second time). **Blocks:** Task 6 (whose `TestMemory02_ReindexEquivalence` fixture strengthening — already written, currently stashed uncommitted at `git stash list` entry `task-6-wip-strengthened-mem02-fixture` — fails against today's code and is expected to pass once this task lands; do not modify that stashed diff, just `git stash pop` after this task's fix is committed and re-verify).

**The fix:** split `Reconcile`'s importance handling into two phases within one call. Phase A (unchanged): `file()` computes and writes an initial `importance_score` exactly as Task 5 built it — this preserves the already-approved `TestReconcileImportanceQuarantineOnSignalError` behavior (a signal-lookup error still quarantines the file in phase A, exactly as before). Phase B (new): after the entire `vaultSubdirs` walk completes — so every file touched this run has been fully upserted, and the link graph for this run is complete — recompute `computeNodeImportance` a second time for every successfully-indexed file from this run, and write the corrected value with a narrow single-column UPDATE. This makes the final `importance_score` order-independent within one Reconcile/Rebuild call: it no longer matters whether a node's linkers were scanned before or after it, because phase B always sees the fully-populated graph from phase A. Cost is bounded: phase B only re-touches files that phase A itself already decided to reparse (unchanged files are skipped in phase A and never enter phase B), so it adds work proportional to the size of the current sync/reindex batch, not the whole vault — for an ordinary incremental `Reconcile` this is typically small; for a full `Rebuild` it doubles the importance-signal-read cost for the whole vault, on top of the already-documented "Known risk" perf note in the design spec.

**Files:**
- Modify: `internal/db/memory.go` (new method `UpdateMemoryNodeImportanceScore`)
- Modify: `internal/memory/index.go` (`reconcilePass` struct, `file()`, `Reconcile`)
- Test: `internal/memory/index_test.go` (new test proving the fix — this is a SEPARATE addition from Task 6's stashed MEM-02 fixture work; do not touch or unstash Task 6's changes as part of this task)
- Test: `internal/db/memory_test.go` (new test for `UpdateMemoryNodeImportanceScore`)

**Interfaces:**
- Consumes: `computeNodeImportance(database *db.DB, v *Vault, n Node, rel string) (float64, error)` (Task 5b, unchanged signature).
- Produces: `func (db *DB) UpdateMemoryNodeImportanceScore(id string, score float64) error` (new DB method) and a new unexported `touchedNode` type in `internal/memory/index.go` — both are internal to this fix, no other task depends on their exact shape, only on the corrected end-to-end behavior (verified by this task's own test and consumed implicitly by Task 6 once resumed).

- [ ] **Step 1: write the failing test** — add to `internal/db/memory_test.go` (after the existing `TestMemoryNodeImportanceScoreRoundTrip`, matching its `openTestDB`/`memTestNode` idiom):

```go
// TestUpdateMemoryNodeImportanceScore: a narrow single-column update that
// changes only importance_score, leaving every other field (content_hash,
// title, etc.) untouched — the primitive Reconcile's phase-B refinement
// pass uses to correct a node's importance after the whole vaultSubdirs
// walk completes (Slice A follow-up, added 2026-07-18, MEM-16).
func TestUpdateMemoryNodeImportanceScore(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("ent_importance_narrow", func(r *MemoryNodeRow) {
		r.ImportanceScore = 1.0
		r.Title = "Original Title"
	})
	if err := db.UpsertMemoryNode(row, "body", nil); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}

	if err := db.UpdateMemoryNodeImportanceScore("ent_importance_narrow", 7.0); err != nil {
		t.Fatalf("UpdateMemoryNodeImportanceScore: %v", err)
	}

	got, err := db.GetMemoryNode("ent_importance_narrow")
	if err != nil {
		t.Fatalf("GetMemoryNode: %v", err)
	}
	if got.ImportanceScore != 7.0 {
		t.Errorf("ImportanceScore = %v, want 7.0", got.ImportanceScore)
	}
	if got.Title != "Original Title" {
		t.Errorf("Title = %q, want unchanged %q — this must be a NARROW update", got.Title, "Original Title")
	}
}
```

- [ ] **Step 2: run it — expect a build failure** (the method doesn't exist yet):

```
$ go test ./internal/db/ -run TestUpdateMemoryNodeImportanceScore -v
# watchtower/internal/db [watchtower/internal/db.test]
./memory_test.go:XXX: db.UpdateMemoryNodeImportanceScore undefined (type *DB has no field or method UpdateMemoryNodeImportanceScore)
FAIL	watchtower/internal/db [build failed]
```

- [ ] **Step 3: implement `UpdateMemoryNodeImportanceScore`** — add to `internal/db/memory.go` immediately after `SetDisputePending` (matching its exact error-wrapping style):

```go
// UpdateMemoryNodeImportanceScore narrows-updates just the importance_score
// column for an already-indexed node, without touching its content hash,
// body/FTS, aliases, or provenance rows. Used by Reconcile's phase-B
// refinement pass (internal/memory/index.go, MEM-16) to correct a node's
// importance_score once the whole vaultSubdirs walk has completed, so a
// link from a later-scanned directory (e.g. rollups) to an earlier-scanned
// one (e.g. entities) is reflected even within a single Reconcile/Rebuild
// call.
func (db *DB) UpdateMemoryNodeImportanceScore(id string, score float64) error {
	_, err := db.Exec(`UPDATE memory_nodes SET importance_score = ? WHERE id = ?`, score, id)
	if err != nil {
		return fmt.Errorf("updating importance_score for %s: %w", id, err)
	}
	return nil
}
```

- [ ] **Step 4: run it — expect green:**

```
$ go test ./internal/db/ -run TestUpdateMemoryNodeImportanceScore -v
=== RUN   TestUpdateMemoryNodeImportanceScore
--- PASS: TestUpdateMemoryNodeImportanceScore (0.01s)
PASS
ok  	watchtower/internal/db	0.2s
```

- [ ] **Step 5: write the failing regression test for the actual bug** — add to `internal/memory/index_test.go` (after `TestReconcileImportanceQuarantineOnSignalError`, which Task 6 already added — read the file first to find its actual current end, since Task 6's stashed changes are NOT present in the working tree right now; insert after whatever is currently the last `TestReconcile*` test before `TestMemory02_ReindexEquivalence`):

```go
// TestReconcileImportanceOrderIndependent: a rollup and the entity it links
// to are BOTH touched within the SAME Reconcile call (the rollup is newly
// created, the entity's body is edited) — entities is scanned before
// rollups (vaultSubdirs order), so a single-pass computation would compute
// the entity's LinksIn before the rollup's link is indexed, understating its
// importance_score. The phase-B refinement pass must correct this within
// the same call, without requiring a later, separate Reconcile call to
// re-touch the entity (Slice A follow-up, added 2026-07-18, MEM-16 — the
// bug Task 6's implementer found while strengthening the MEM-02 fixture).
func TestReconcileImportanceOrderIndependent(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5OI1", "entity", "Target")
	writeNodes(t, v, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	baseline, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	require.Zero(t, baseline.ImportanceScore, "sanity: no links yet")

	// Edit target's body (so it gets reparsed THIS call) and, in the SAME
	// Reconcile call, add a rollup linking to it. entities is scanned before
	// rollups, so a single-pass computation would see LinksIn=0 for target;
	// the refinement pass must correct it to 1 before Reconcile returns.
	target.Body = "# Target\n\nRevision one.\n"
	rollup := vaultTestNode("sum_01ARZ3NDEKTSV4RRFFQ69G5OI2", "rollup", "Summary")
	rollup.Body = "# Summary\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5OI1]] for background.\n"
	writeNodes(t, v, target, rollup)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	row, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	want := ComputeImportance(ImportanceInputs{LinksIn: 1})
	assert.Equal(t, want, row.ImportanceScore,
		"target's importance must reflect rollup's link within the SAME Reconcile call, not just after a later separate call")
}
```

- [ ] **Step 6: run it — expect the assertion failure that proves the bug** (before implementing phase B):

```
$ go test ./internal/memory/ -run TestReconcileImportanceOrderIndependent -v
=== RUN   TestReconcileImportanceOrderIndependent
    index_test.go:XXX:
        	Error Trace:	.../index_test.go:XXX
        	Error:      	Not equal:
        	            	expected: 1
        	            	actual  : 0
        	Test:       	TestReconcileImportanceOrderIndependent
--- FAIL: TestReconcileImportanceOrderIndependent (0.02s)
FAIL
```

- [ ] **Step 7: implement the two-phase fix in `internal/memory/index.go`.** Add a `touchedNode` type and a `touched` field to `reconcilePass` (near the top of the file, after the `Stats` struct):

```go
// touchedNode records one successfully-indexed file from the current
// Reconcile pass so its importance can be refined in phase B, once the
// whole vaultSubdirs walk completes — see refineImportance. A link from a
// later-scanned directory to an earlier one is otherwise invisible to
// CountMemoryLinksIn during phase A's processing of the earlier node
// (Slice A follow-up, added 2026-07-18, MEM-16).
type touchedNode struct {
	n   Node
	rel string
}
```

Add `touched []touchedNode` to the `reconcilePass` struct:

```go
type reconcilePass struct {
	v        *Vault
	database *db.DB
	logf     func(string, ...any)
	indexed  map[string]db.MemoryNodeRow
	onDisk   map[string]bool
	now      string
	stats    *Stats
	touched  []touchedNode
}
```

In `file()`, immediately after the successful `UpsertMemoryNode` call (right before the `if wasIndexed { ... } else { ... }` stats block), append to `p.touched`:

```go
	if err := p.database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, p.logf)...); err != nil {
		p.quarantine(rel, err)
		return nil
	}
	p.touched = append(p.touched, touchedNode{n: n, rel: rel})
	if wasIndexed {
		p.stats.Updated++
	} else {
		p.stats.Added++
	}
	return nil
}
```

Add a new `refineImportance` method right after `file()`:

```go
// refineImportance is Reconcile's phase B: after the whole vaultSubdirs walk
// completes, recompute importance for every file this pass successfully
// indexed, now that the run's full link graph is populated — correcting
// phase A's scan-order-dependent initial value. A recompute error is logged
// and that node's phase-A value is kept (not escalated to an abort or a
// quarantine — the file's content was already successfully indexed in phase
// A; only its importance may be transiently stale, which is an accepted
// characteristic elsewhere in this design). Slice A follow-up, added
// 2026-07-18, MEM-16.
func (p *reconcilePass) refineImportance() error {
	for _, tn := range p.touched {
		importance, err := computeNodeImportance(p.database, p.v, tn.n, tn.rel)
		if err != nil {
			p.logf("memory: reconcile: refining importance for %s failed (keeping first-pass value): %v", tn.n.ID, err)
			continue
		}
		if err := p.database.UpdateMemoryNodeImportanceScore(tn.n.ID, importance); err != nil {
			return fmt.Errorf("memory: reconcile: refining importance for %s: %w", tn.n.ID, err)
		}
	}
	return nil
}
```

In `Reconcile`, call it right after the per-file loop, before the deletion loop:

```go
	for _, sub := range vaultSubdirs {
		entries, err := os.ReadDir(filepath.Join(v.path, sub))
		if err != nil {
			return stats, fmt.Errorf("memory: reconcile: read %s: %w", sub, err)
		}
		for _, entry := range entries {
			if err := pass.file(sub, entry); err != nil {
				return stats, err
			}
		}
	}

	if err := pass.refineImportance(); err != nil {
		return stats, err
	}

	for _, row := range existing {
```

(The rest of `Reconcile` — the deletion loop and its return — is unchanged.)

- [ ] **Step 8: run it — expect green:**

```
$ go test ./internal/memory/ -run TestReconcileImportanceOrderIndependent -v
=== RUN   TestReconcileImportanceOrderIndependent
--- PASS: TestReconcileImportanceOrderIndependent (0.03s)
PASS
ok  	watchtower/internal/memory	0.2s
```

- [ ] **Step 9: run the full `internal/memory` and `internal/db` suites — confirm zero regressions**, including the three already-approved Task 5/6a/6b tests (`TestReconcileComputesImportanceScore`, `TestReconcileImportanceOverrideWins`, `TestReconcileImportanceQuarantineOnSignalError`) and `TestEvictReindexEquivalence`:

```
$ go build ./... && go test -count=1 ./internal/memory/... ./internal/db/... -v 2>&1 | tail -40
```

Expected: every test passes, including all of the above by name.

- [ ] **Step 10: commit — this task's commit touches ONLY `internal/db/memory.go`, `internal/db/memory_test.go`, and `internal/memory/index.go`, plus the ONE new test this task adds to `internal/memory/index_test.go`. Task 6's separately-stashed changes to the same test file must NOT be part of this commit** (they are not in the working tree right now — you stashed them before this task began; leave them stashed):

```
$ git status --short
```

Confirm the status shows only this task's files before committing (no unexpected `index_test.go` hunks beyond the one new test you just added).

```
$ git add internal/db/memory.go internal/db/memory_test.go internal/memory/index.go internal/memory/index_test.go
$ git commit -m "fix(memory): two-phase Reconcile — importance refinement pass for scan-order independence (Slice A follow-up, MEM-16)

Reconcile walked vaultSubdirs in a fixed order and computed importance
per-file inline, so a link from a later-scanned directory (rollups) to an
earlier one (entities) was invisible within a single Reconcile/Rebuild call
— a real MEM-02 violation Task 6's implementer found while strengthening
the reindex-equivalence guard. Phase A (file()) is unchanged; a new phase B
(refineImportance) recomputes importance for every file touched this run
once the whole walk completes, via a narrow UpdateMemoryNodeImportanceScore
column update, making the result order-independent within one call."
```

---

## Task 6 (resume): Strengthen the MEM-02 guard + add override/quarantine regression tests

**This task's implementer already wrote all three test changes and reported BLOCKED** because `TestMemory02_ReindexEquivalence`'s strengthened fixture correctly caught the scan-order bug Task 5c just fixed. The changes are stashed (`git stash list` should show `task-6-wip-strengthened-mem02-fixture`). Resume by restoring the stash and re-verifying, not by re-writing the tests from scratch.

**Depends on:** Task 5c (the scan-order fix must be committed first). **Blocks:** Task 7.

**Files:**
- Test only: `internal/memory/index_test.go` — modify `TestMemory02_ReindexEquivalence` (lines 352–393); add two new tests after `TestReconcileQuarantinesDuplicateAlias` (ends line 346), before `TestMemory02_ReindexEquivalence` (line 348)

**Interfaces:**
- Consumes: everything from Tasks 1–5 (`ComputeImportance`, `Node.ImportanceOverride`, `db.MemoryNodeRow.ImportanceScore`, the `computeImportance`-wired `Reconcile`).
- Produces: three named guard tests — `TestReconcileImportanceOverrideWins`, `TestReconcileImportanceQuarantineOnSignalError`, and the strengthened `TestMemory02_ReindexEquivalence` — consumed by Task 7's MEM-16 "Test guards" list (must use these exact names).

> **Note on TDD shape:** unlike Tasks 1–5, these three tests exercise behavior Task 5 **already fully implemented** (the override short-circuit and the quarantine-on-error path are both already live in `computeImportance`/`file()`). They are regression/contract guards, not red→green feature work — each is expected to **pass on first run**. That is itself the point: they lock down behavior that already works so a future change can't silently break it. Where a step says "run it — expect green," that is not a mistake.

### 6a. Override-wins-through-Reconcile test

- [ ] **Step 1: write the test** — insert into `internal/memory/index_test.go` after line 346 (`TestReconcileQuarantinesDuplicateAlias`'s closing brace), before `TestMemory02_ReindexEquivalence`:

```go
// TestReconcileImportanceOverrideWins: a node whose frontmatter carries
// importance_override persists exactly that value through Reconcile, even
// though every organic signal (links-in, situation-origin, owner-touch,
// engagement) is zero — proving the override short-circuits
// computeImportance rather than being blended with the computed value
// (Slice A, MEM-16).
func TestReconcileImportanceOverrideWins(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)
	override := 7.5
	n := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5OV1", "entity", "Manually Important")
	n.ImportanceOverride = &override
	writeNodes(t, v, n)

	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	row, err := d.GetMemoryNode(n.ID)
	require.NoError(t, err)
	assert.Equal(t, 7.5, row.ImportanceScore, "the override wins over the (zero) computed signals")
}
```

- [ ] **Step 2: run it — expect green immediately** (Task 5 already implements the override short-circuit):

```
$ go test ./internal/memory/ -run TestReconcileImportanceOverrideWins -v
=== RUN   TestReconcileImportanceOverrideWins
--- PASS: TestReconcileImportanceOverrideWins (0.01s)
PASS
ok  	watchtower/internal/memory	0.2s
```

### 6b. Quarantine-on-signal-error test

- [ ] **Step 3: write the test** — insert immediately after `TestReconcileImportanceOverrideWins`:

```go
// TestReconcileImportanceQuarantineOnSignalError: when a node's importance
// signal lookup fails (LinkedEntityEngagement here, via a dropped
// memory_engagement table), that ONE file is quarantined — its prior
// importance_score (and the rest of its row) stays untouched — while the
// rest of the pass completes normally. A brand-new node carrying its own
// importance_override never calls the broken lookup at all, proving the
// failure is isolated rather than pass-wide (Slice A, design §6, MEM-16).
func TestReconcileImportanceQuarantineOnSignalError(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	// A linking entity gives A a nonzero baseline importance BEFORE anything
	// breaks, so "prior importance_score untouched" below is a real
	// assertion, not a vacuous 0 == 0.
	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5QI1", "entity", "Linked Target")
	writeNodes(t, v, a)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	linker := linkingEntity(t, "ent_01ARZ3NDEKTSV4RRFFQ69G5QI2", "Linker", a.ID)
	writeNodes(t, v, linker)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Touch A again so it gets reparsed now that the link is already
	// committed (CountMemoryLinksIn only sees a link once its source file is
	// indexed).
	a.Body = "# Linked Target\n\nRevision one.\n"
	writeNodes(t, v, a)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	baseline, err := d.GetMemoryNode(a.ID)
	require.NoError(t, err)
	require.Equal(t, 1.0, baseline.ImportanceScore, "sanity: A already reflects the link-in bonus")

	// Break LinkedEntityEngagement's lookup for every node that has no
	// override.
	_, err = d.Exec(`DROP TABLE memory_engagement`)
	require.NoError(t, err)

	// Touch A once more (forces a reparse into the now-broken lookup) and add
	// a brand-new node carrying an importance_override, which never calls the
	// broken signal lookups at all.
	a.Body = "# Linked Target\n\nRevision two.\n"
	overrideVal := 3.0
	fresh := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5QI3", "entity", "Fresh Override")
	fresh.ImportanceOverride = &overrideVal
	writeNodes(t, v, a, fresh)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err, "a signal-lookup failure must not abort the pass")
	assert.Equal(t, 1, stats.Added, "the override-carrying node is still indexed")
	assert.Equal(t, 1, stats.Quarantined)
	assert.Equal(t, []string{"entities/" + a.ID + ".md"}, stats.QuarantinedPaths)

	after, err := d.GetMemoryNode(a.ID)
	require.NoError(t, err)
	assert.Equal(t, baseline.ImportanceScore, after.ImportanceScore, "prior importance_score untouched")
	assert.Equal(t, baseline.ContentHash, after.ContentHash, "quarantine keeps the whole prior row, not just the score")

	freshRow, err := d.GetMemoryNode(fresh.ID)
	require.NoError(t, err)
	assert.Equal(t, 3.0, freshRow.ImportanceScore)
}
```

- [ ] **Step 4: run it — expect green immediately** (Task 5 already routes signal-lookup errors through the existing `p.quarantine`):

```
$ go test ./internal/memory/ -run TestReconcileImportanceQuarantineOnSignalError -v
=== RUN   TestReconcileImportanceQuarantineOnSignalError
--- PASS: TestReconcileImportanceQuarantineOnSignalError (0.03s)
PASS
ok  	watchtower/internal/memory	0.2s
```

### 6c. Strengthen `TestMemory02_ReindexEquivalence`

Current fixture (lines 352–393):

```go
func TestMemory02_ReindexEquivalence(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	// Pass 1: two fresh nodes. Episode B carries a ## Provenance section so the
	// derived memory_provenance index is exercised by the reindex-equivalence
	// comparison (MEM-02 extension, Phase-5 slice-3).
	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5IXA", "entity", "Alpha")
	a.Aliases = []string{"alpha", "C0AAAAAAA"}
	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5IXB", "episode", "Beta")
	b.Body = "# Beta\n\n## Story\nA thing happened.\n\n## Provenance\n" +
		"- C0AAAAAAA 1700000000.000100\n- mail:abc123 1700000500\n"
	writeNodes(t, v, a, b)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Pass 2: edit A (title + aliases), add C.
	a.Title = "Alpha Prime"
	a.Aliases = []string{"alpha-prime"}
	a.Body = "# Alpha Prime\n\nRewritten body.\n"
	c := vaultTestNode("sum_01ARZ3NDEKTSV4RRFFQ69G5IXC", "rollup", "Q3 rollup")
	writeNodes(t, v, a, c)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	// Pass 3: delete B (its provenance rows must vanish with it), edit C and give
	// it a surviving ## Provenance section so a live node's provenance is compared.
	require.NoError(t, os.Remove(filepath.Join(v.path, "episodes", b.ID+".md")))
	c.Body = "# Q3 rollup\n\nCollapsed episodes live here.\n\n## Provenance\n" +
		"- C0AAAAAAA 1700100000.000200\n"
	writeNodes(t, v, c)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	incremental := dumpIndex(t, d)
	require.Len(t, incremental.Nodes, 2, "sanity: A and C survive")

	_, err = Rebuild(v, d, t.Logf)
	require.NoError(t, err)
	rebuilt := dumpIndex(t, d)

	assert.Equal(t, incremental, rebuilt)
}
```

The `indexDump`/`dumpIndex` comparison (lines 36–86) already compares whole `db.MemoryNodeRow` structs, so `ImportanceScore` automatically rides inside this comparison with **no code change** to `dumpIndex` itself. But today every node in this fixture has `LinksIn == 0` throughout, so `importance_score` trivially compares `0 == 0` on both sides — a bug that always persisted `0` would slip past unnoticed. Fix: make C link to A in pass 2, and touch A again in pass 3 (**after** C's link is already committed) so A's persisted `importance_score` picks it up — because `Reconcile`'s incremental path only reparses a file whose own content changed, so A must itself be re-touched to see a link that appeared elsewhere.

- [ ] **Step 5: modify the fixture.** Change pass 2 to (add the link to C's body):

```go
	// Pass 2: edit A (title + aliases), add C — C links to A so LinksIn (and
	// therefore importance_score) actually differs between fixtures instead of
	// comparing two zeros (Slice A, MEM-16 extension of this guard).
	a.Title = "Alpha Prime"
	a.Aliases = []string{"alpha-prime"}
	a.Body = "# Alpha Prime\n\nRewritten body.\n"
	c := vaultTestNode("sum_01ARZ3NDEKTSV4RRFFQ69G5IXC", "rollup", "Q3 rollup")
	c.Body = "# Q3 rollup\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5IXA]] for background.\n"
	writeNodes(t, v, a, c)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)
```

Change pass 3 to (keep the link in C's body, and touch A once more):

```go
	// Pass 3: delete B (its provenance rows must vanish with it), edit C —
	// keep its link to A alongside a surviving ## Provenance section — and
	// touch A once more (a trivial body edit) so A gets reparsed NOW THAT C's
	// link to it is already committed (pass 2): this is what makes A's
	// persisted importance_score reflect LinksIn=1 by the end of the
	// incremental history, matching what a fresh Rebuild computes from the
	// FINAL vault state.
	require.NoError(t, os.Remove(filepath.Join(v.path, "episodes", b.ID+".md")))
	c.Body = "# Q3 rollup\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5IXA]] for background.\n\n## Provenance\n" +
		"- C0AAAAAAA 1700100000.000200\n"
	a.Body = "# Alpha Prime\n\nRewritten body, revision two.\n"
	writeNodes(t, v, c, a)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)
```

Change the sanity block right after `incremental := dumpIndex(t, d)` to also assert the nonzero score:

```go
	incremental := dumpIndex(t, d)
	require.Len(t, incremental.Nodes, 2, "sanity: A and C survive")
	for _, row := range incremental.Nodes {
		if row.ID == a.ID {
			require.Equal(t, 1.0, row.ImportanceScore,
				"sanity: A's persisted importance reflects C's link-in, not a trivial zero")
		}
	}

	_, err = Rebuild(v, d, t.Logf)
	require.NoError(t, err)
	rebuilt := dumpIndex(t, d)

	assert.Equal(t, incremental, rebuilt)
}
```

- [ ] **Step 6: run it — expect green** (this is the load-bearing assertion: without Task 5's implementation this fixture would have failed to compile/assert against `ImportanceScore`; with it correctly wired, incremental and rebuilt now agree on a genuinely nonzero value):

```
$ go test ./internal/memory/ -run TestMemory02_ReindexEquivalence -v
=== RUN   TestMemory02_ReindexEquivalence
--- PASS: TestMemory02_ReindexEquivalence (0.03s)
PASS
ok  	watchtower/internal/memory	0.2s
```

- [ ] **Step 7: full package run + commit:**

```
$ go test ./internal/memory/ -v 2>&1 | tail -5
PASS
ok  	watchtower/internal/memory	1.2s

$ git add internal/memory/index_test.go
$ git commit -m "test(memory): strengthen MEM-02 fixture + override/quarantine guards for importance_score (Slice A, MEM-16)

TestMemory02_ReindexEquivalence's fixture now introduces a real link-in so
importance_score is compared at a nonzero value, not two zeros. New guards:
TestReconcileImportanceOverrideWins, TestReconcileImportanceQuarantineOnSignalError."
```

---

## Task 7: MEM-16 inventory addendum

**Depends on:** Task 6 (needs the final test names). **Blocks:** Task 8 (documentation-only, but keep it in sequence).

**Files:**
- Modify: `docs/inventory/memory.md` — header (lines 12–13), new MEM-16 section (inserted between line 251 and line 253), one cross-reference fix to a now-partially-stale limitations bullet (line 265), and a new changelog entry (inserted right after line 295's `## Changelog` heading, before the `2026-07-17` entry at line 297)

**Interfaces:**
- Consumes: the exact test names from Task 6 (`TestReconcileImportanceOverrideWins`, `TestReconcileImportanceQuarantineOnSignalError`, the strengthened `TestMemory02_ReindexEquivalence`) and Task 1 (`TestComputeImportance`, `TestComputeImportanceEngagement`).
- Produces: nothing code-facing — this is the documentation contract itself.

This task is documentation-only; there is no failing-test/passing-test cycle. Each step below is a direct content edit, self-verified by re-reading the result.

- [ ] **Step 1: update the module header.** Current line 12:

```
**Module:** `internal/memory/` (vault, index, resolver, seed, ingest, extract, pipeline; Phase 3: `belief_math.go`, `beliefs.go`, `rewrite.go`, `dedupe.go`, `concepts.go`, `evict.go`, `worldmap.go`; Phase 4: `chat_ingest.go`, `reflect.go`; Phase 5 slice 1: `provenance.go` (resolver registry), `gmail_extract.go` (Gmail source), `action_ingest.go` (mechanical interaction ingest); Phase 5 slice 2: `calendar_ingest.go` (mechanical calendar source), `chat_ingest.go` generalized to target/track subjects + the "remember this" command, `provenance.go`'s `cal` resolver; Phase 5 slice 3: `digest_render.go` (channel-digest render from episodes, MEM-13), `digest_compare.go` (dark compare-mode runner + diff metrics + report), `provenance.go`'s `parseProvenanceRefs`; Phase 5 slice 4: `mirror_ingest.go` (mechanical target/track entity mirrors, MEM-14), `chat_ingest.go`'s target/track self-mirror subject mapping, `beliefs.go`'s gated OWNER ACTIONS block (preference beliefs)) + `internal/db/memory.go` (incl. `memory_entity_hints`, ingest floor, `memory_dispute_flags`, chat-turn floor, Gmail-extract watermark, interaction floor, `memory_engagement`, calendar-extract watermark, context-typed chat-turn helpers, `memory_provenance` window index, `memory_digest_shadow`, the slice-4 bounded mirror read helpers) + `internal/dayplan/gather.go` (open-loops read surface, `memory.surfaces.day_plan`) + `internal/meeting/pipeline.go` (attendee memory-context read surface, `memory.surfaces.meeting_prep`) + `internal/briefing/memory_revisions.go` (revision journal) + `internal/inbox/watchtower_detector.go` (dispute detector) + `internal/daemon/daemon.go` (`phaseMemory`) + `internal/mcp/memory.go` (`memory_map`/`memory_open`/`memory_recall`) + `WatchtowerDesktop/.../SituationChatViewModel.swift` (Discuss MEMORY block) + `cmd/memory.go`
```

Replace the two parenthetical lists' closing sections:

- The `internal/memory/` parenthetical: change `...beliefs.go's gated OWNER ACTIONS block (preference beliefs))` to `...beliefs.go's gated OWNER ACTIONS block (preference beliefs); Slice A (memory-importance-score foundation): importance.go (ComputeImportance/ImportanceInputs, MEM-16), evict.go's RetentionScore delegating to it, index.go's Reconcile/Rebuild persisting memory_nodes.importance_score)`
- The `internal/db/memory.go` parenthetical: change `...the slice-4 bounded mirror read helpers)` to `...the slice-4 bounded mirror read helpers, memory_nodes.importance_score (Slice A, MEM-16))`

Replace line 13:

```
**Last full audit:** 2026-07-17 (Phase 5 slice 4: target/track entity mirrors — `mirror_ingest.go` behind `memory.sources.operational`, MEM-14 mirror-don't-absorb; the day-plan/meeting-prep read surfaces behind `memory.surfaces.{day_plan,meeting_prep}` — `day_plan.generate` v3 / `meeting.prep` v4; preference beliefs via the gated OWNER ACTIONS belief-pass block, `memory.semantic.preferences`)
```

with:

```
**Last full audit:** 2026-07-18 (Slice A of the memory-importance-score redesign: `ComputeImportance` extracted from `RetentionScore` into `importance.go`; `memory_nodes.importance_score` persisted by `Reconcile`/`Rebuild`, MEM-16 — see `docs/superpowers/specs/2026-07-18-memory-importance-score-design.md`)
```

- [ ] **Step 2: insert the MEM-16 section.** Between line 251 (`**Locked since:** 2026-07-17` — the end of MEM-14) and line 253 (`## Known v1 limitations...`), insert:

```markdown

## MEM-16 — Importance snapshot vs live retention score

**Status:** Enforced

**Observable:** `memory_nodes.importance_score` is a periodically-refreshed snapshot (via `Reconcile`/`Rebuild`) of `ComputeImportance`'s output-or-owner-override, used by future retrieval ranking. It is distinct from `evict.go`'s `RetentionScore`, which always recomputes importance live per eviction candidate and never reads the persisted column. The two must not be collapsed into one without owner review — they answer different questions ("is this worth surfacing now" vs "is this worth compressing").

**Why locked:** `RetentionScore` and `importance_score` share the same importance arm (`ComputeImportance`) but serve different consumers with different freshness requirements: eviction needs a live number for a small, bounded candidate set every run, while future retrieval ranking needs a persisted number it can sort/filter over without recomputing per-node signals for the whole vault on every read. Merging them into a single stored value would either make eviction stale (scoring against a snapshot that lags the current link graph) or make every `Reconcile` pass pay eviction's live-computation cost across the whole vault. Keeping them independent, sharing only the pure `ComputeImportance` primitive, preserves both.

**Test guards:**
- `internal/memory/importance_test.go::TestComputeImportance` / `TestComputeImportanceEngagement` (the extracted primitive, exhaustively unit-tested — retargeted from the pre-existing `RetentionScore` cases)
- `internal/memory/evict_test.go::TestRetentionScore` / `TestRetentionScoreEngagement` (byte-identical after the extraction — the refactor proof)
- `internal/memory/index_test.go::TestReconcileComputesImportanceScore` (computed path: a known links/situation/owner/engagement fixture → `importance_score` equals `ComputeImportance(...)`, no recency applied)
- `internal/memory/index_test.go::TestReconcileImportanceOverrideWins` (a node's `importance_override` persists exactly through Reconcile over zero organic signals)
- `internal/memory/index_test.go::TestReconcileImportanceQuarantineOnSignalError` (a forced signal-lookup error quarantines the file and leaves its prior `importance_score` untouched; the pass does not abort)
- `internal/memory/index_test.go::TestMemory02_ReindexEquivalence` (strengthened fixture: a pass introduces a node linking to an existing one, so `importance_score` differs from a trivial zero across the incremental-vs-rebuilt comparison)

**Locked since:** 2026-07-18
```

- [ ] **Step 3: fix the now-stale limitations bullet.** Current line 265:

```
- **Retention/eviction does not use access stats.** Phase 3 retention scoring (`RetentionScore`) intentionally excludes `memory_node_stats` access counters (write-dead in production, per the access-stats limitation above): importance is `links-in + situation-origin bonus + owner-touch bonus`, where owner-touch is computed lazily from `git log` for the bounded eviction-candidate set only. No score is stored in a file or column — it is recomputed on demand from the index, keeping MEM-02 clean.
```

Replace with:

```
- **Retention/eviction does not use access stats.** Phase 3 retention scoring (`RetentionScore`) intentionally excludes `memory_node_stats` access counters (write-dead in production, per the access-stats limitation above): importance is `links-in + situation-origin bonus + owner-touch bonus`, where owner-touch is computed lazily from `git log` for the bounded eviction-candidate set only. `RetentionScore` itself is still recomputed on demand, never stored — but see **MEM-16**: since Slice A of the memory-importance-score redesign, the SAME importance arm (`ComputeImportance`) is separately persisted as `memory_nodes.importance_score` for future retrieval ranking, refreshed by `Reconcile`/`Rebuild` rather than recomputed live. The two are deliberately independent; do not read this bullet as contradicting MEM-16.
```

- [ ] **Step 4: add the changelog entry.** Immediately after line 295 (`## Changelog`), before the `2026-07-17` bullet (line 297), insert:

```markdown

- 2026-07-18 (Slice A of the memory-importance-score redesign — importance-score foundation): one new contract, **MEM-16** (importance snapshot vs live retention score). `RetentionScore`'s importance arm extracted into a standalone `ComputeImportance(ImportanceInputs)` (`internal/memory/importance.go`); `RetentionScore` now delegates to it for a byte-identical retention formula (proof: every pre-existing `TestRetentionScore*` assertion passes unchanged). New frontmatter field `importance_override` (`Node`/`frontmatter`, pointer throughout so `0` stays distinguishable from unset, `>= 0` validated, legal on any node type — no belief-only gate). New column `memory_nodes.importance_score REAL NOT NULL DEFAULT 0` (migration 00027, additive `ALTER TABLE ADD COLUMN`, no CHECK change) persists the merged owner-override-or-computed value, refreshed by `Reconcile`/`Rebuild`'s per-node path using the same link/situation/owner/engagement signal calls `EvictEpisodes` already uses — but with **no recency factor** (MEM-16: this is a distinct primitive from `RetentionScore`, which keeps recomputing live for eviction and never reads the column). A per-node signal-lookup error quarantines that file (log + count + keep its prior `importance_score`) rather than aborting the whole `Reconcile` pass — the existing quarantine philosophy, extended. `TestMemory02_ReindexEquivalence`'s fixture strengthened (a pass introduces a node linking to an existing one) so the guard actually exercises a nonzero `importance_score` instead of comparing two zeros. No new config flag (always-on), no new AI prompt, no Swift change (deferred to Slice C) — pure foundation for the later retrieval-ranking slices (`docs/superpowers/specs/2026-07-18-memory-importance-score-design.md`).
```

- [ ] **Step 5: re-read the whole file and sanity-check it renders correctly** (headings still nest, no orphaned bullets, MEM-16 sits between MEM-14 and "Known v1 limitations"):

```
$ grep -n "^## MEM-\|^## Known v1\|^## Changelog" docs/inventory/memory.md | head -20
```

Expected: `MEM-16` appears once, immediately after the last `MEM-14` line and before `## Known v1 limitations`.

- [ ] **Step 6: commit:**

```
$ git add docs/inventory/memory.md
$ git commit -m "docs(memory): MEM-16 — importance snapshot vs live retention score (Slice A)

New contract for memory_nodes.importance_score; module/audit-date header
bumped; cross-referenced the now-partially-stale 'no score is stored'
limitations bullet so it no longer reads as a silent contradiction."
```

---

## Task 8: Final verification

**Depends on:** Tasks 1–7. **Blocks:** nothing (terminal task).

**Files:** none (verification only).

**Interfaces:** consumes everything; produces nothing new — this is the acceptance gate for the whole slice.

- [ ] **Step 1: formatting.**

```
$ gofmt -l internal/memory/importance.go internal/memory/importance_test.go internal/memory/evict.go internal/memory/node.go internal/memory/node_test.go internal/memory/index.go internal/memory/index_test.go internal/db/memory.go internal/db/memory_test.go internal/db/db_test.go internal/db/schema.sql
```

Expected: **no output** (schema.sql is not Go, ignore any tool complaint about it — gofmt only checks `.go` files; if any `.go` file above prints, run `gofmt -w <file>` and re-check until silent).

- [ ] **Step 2: vet.**

```
$ go vet ./...
```

Expected: **no output**, exit code 0.

- [ ] **Step 3: build.**

```
$ go build ./... 2>&1 | tee /tmp/build.log; echo "exit=$?"
exit=0
```

- [ ] **Step 4: the two directly-touched packages, verbose.**

```
$ go test ./internal/memory/... ./internal/db/... -v 2>&1 | tee /tmp/test.log; echo "exit=$?"
...
--- PASS: TestComputeImportance (0.00s)
--- PASS: TestComputeImportanceEngagement (0.00s)
--- PASS: TestRetentionScore (0.00s)
--- PASS: TestRetentionScoreEngagement (0.00s)
--- PASS: TestParseNodeImportanceOverrideRoundTrip (0.00s)
--- PASS: TestParseNodeImportanceOverrideZeroIsNotUnset (0.00s)
--- PASS: TestParseNodeImportanceOverrideAbsentIsNil (0.00s)
--- PASS: TestParseNodeRejectsNegativeImportanceOverride (0.00s)
--- PASS: TestParseNodeImportanceOverrideLegalOnBelief (0.00s)
--- PASS: TestReconcileComputesImportanceScore (0.02s)
--- PASS: TestReconcileImportanceOverrideWins (0.01s)
--- PASS: TestReconcileImportanceQuarantineOnSignalError (0.03s)
--- PASS: TestMemory02_ReindexEquivalence (0.03s)
--- PASS: TestMemoryNodeImportanceScoreRoundTrip (0.01s)
--- PASS: TestMigration00027MemoryImportanceScore (0.01s)
--- PASS: TestSchemaGolden (0.05s)
--- PASS: TestAllTablesExist (0.02s)
PASS
ok  	watchtower/internal/memory	1.3s
ok  	watchtower/internal/db	0.6s
exit=0
```

Check the real exit code explicitly (per house convention — never pipe a verification command through something that masks it):

```
$ go test ./internal/memory/... ./internal/db/... > /tmp/test.log 2>&1; echo "exit=$?"; tail -5 /tmp/test.log
exit=0
ok  	watchtower/internal/memory	1.1s
ok  	watchtower/internal/db	0.5s
```

- [ ] **Step 5: broader blast-radius check** — `db.MemoryNodeRow` and `Node` are consumed outside these two packages (`internal/inbox`'s dispute detector, `internal/mcp/memory.go`'s read tools, `cmd/memory.go`):

```
$ go test ./internal/inbox/... ./internal/mcp/... ./cmd/... 2>&1 | tail -10
ok  	watchtower/internal/inbox	0.4s
ok  	watchtower/internal/mcp	0.2s
ok  	watchtower/internal/cmd	...
```

- [ ] **Step 6: full suite, for completeness before this lands on `main` per the design spec's Rollout note (own branch cut from `main` after PR #40 merges):**

```
$ go test ./... > /tmp/full-test.log 2>&1; echo "exit=$?"; grep -c "^ok" /tmp/full-test.log; grep "^FAIL" /tmp/full-test.log
exit=0
```

Expected: `exit=0`, no `FAIL` lines.

- [ ] **Step 7: final commit (only if any stray formatting fixes were needed in Step 1 — otherwise this task produces no diff and nothing to commit):**

```
$ git status --short
```

If clean, no commit needed — Tasks 1–7 already committed everything. If `gofmt -w` touched anything in Step 1:

```
$ git add -A
$ git commit -m "chore(memory): gofmt cleanup for Slice A importance-score changes"
```

---

**Summary of new/changed files:**
- New: `internal/memory/importance.go`, `internal/memory/importance_test.go`, `internal/db/migrations/00027_memory_importance_score.sql`
- Modified: `internal/memory/evict.go`, `internal/memory/node.go`, `internal/memory/node_test.go`, `internal/memory/index.go`, `internal/memory/index_test.go`, `internal/memory/evict_test.go` (**not modified** — proof of byte-identical refactor), `internal/db/schema.sql`, `internal/db/testdata/schema_v73.golden` (regenerated), `internal/db/db_test.go`, `internal/db/memory.go`, `internal/db/memory_test.go`, `docs/inventory/memory.md`

---

## Task 5d: Whole-branch review fixes — refine-after-delete ordering, `OwnerEdited` memoization, delta-refine for untouched linked nodes

**Added post-ship, 2026-07-18 (whole-branch code review).** Slice A (Tasks 1–8, including the 5b/5c gap-fixes) is already committed on `feature/memory-phase5`. A final whole-branch review of that already-shipped code found one Critical bug and two Important bugs, all in `internal/memory/index.go`/`importance.go`/`vault.go`/`merge.go`. Owner decision: fix all three properly now, as a fourth follow-up quantum under the same MEM-16 contract (the same pattern 5b/5c already established — a real gap found post-hoc, folded into MEM-16 rather than treated as a separate slice or a documented limitation).

**The three bugs, read from the actual shipped code:**

1. **(Critical) A node's `importance_score` never refreshes unless ITS OWN file changes, even though `CountMemoryLinksIn` — the formula's dominant signal — depends on OTHER nodes' bodies.** `index.go`'s `file()` (line 153) has `if wasIndexed && prev.ContentHash == hash { return nil }` — a file whose own content is unchanged is skipped entirely before `computeNodeImportance` is ever called, so it never enters `p.touched`, so `refineImportance`'s phase-B loop (which only iterates `p.touched`) never recomputes it either. A person entity linked from a dozen new Slack-extracted episodes over the following weeks — none of which touch the entity's own file — keeps whatever `importance_score` it had the day its file last changed, forever, even though its real importance (via incoming links) has clearly grown.
2. **(Important) `refineImportance` (phase B) runs BEFORE the deletion loop in `Reconcile`, not after.** Today: the per-file walk runs, then `pass.refineImportance()`, then `for _, row := range existing { if !pass.onDisk[row.ID] { database.DeleteMemoryNode(row.ID) } }`. `CountMemoryLinksIn` reads live FTS/`memory_nodes` state, and a same-pass-deleted node's row/FTS entry is only removed by the LATER deletion loop — so if a file deleted this same `Reconcile` call links to another node that's also being refined this call, phase B counts a link that's about to vanish. A fresh `Rebuild` (the file is simply absent from disk) would never count it. This is a genuine incremental-vs-`Rebuild` divergence — a real MEM-02 violation for `importance_score` specifically, the same class of bug 5c already fixed for scan order, just on the other side of the same function.
3. **(Important) `computeNodeImportance`'s `v.OwnerEdited(rel)` call is a per-file, filtered `git log` walk, and Task 5b made it reachable from ~16+ call sites on every write, not just the small bounded eviction-candidate set `OwnerEdited`'s own doc comment says it's cheap for.** `vault.go`'s `OwnerEdited` (lines 219–243) does `v.repo.Log(&git.LogOptions{FileName: &rel})` — one history walk per node, every time `Reconcile` or `upsertIndexNode` computes importance. Before Task 5b this was fine (eviction only calls it for a bounded set of stale-episode candidates); after Task 5b it now runs on every ordinary Slack/Gmail/Calendar extraction write, every belief revision, every aging pass, every mirror refresh — one full filtered log walk per node, per write, indefinitely.

**Fix order (simplest first, most involved last):** 5d-i (bug 2, a pure reordering) → 5d-ii (bug 3, memoization) → 5d-iii (bug 1, the delta-refine pass, built on top of the now-reordered, now-memoized `refineImportance`). This is also dependency order: 5d-iii's new code lives inside the same `refineImportance` function 5d-i reorders and 5d-ii's new `computeNodeImportance` signature threads through, so each step's "current code" reflects the previous step's result, not the original Task-8 baseline.

**Depends on:** Task 8 (the whole already-shipped Slice A + 5b/5c, on `feature/memory-phase5`). **Blocks:** nothing new in this plan (terminal follow-up) — but it supersedes Task 8's final verification; 5d-v below re-runs the full gate.

**Global constraints carried forward, unchanged:** `EvictEpisodes`/`evict.go` is untouched by all three fixes (verified below — its own `v.OwnerEdited(rel)` call at `evict.go:125` is a separate, direct call that this task does not touch). Every already-approved test named in the prompt (`TestReconcileComputesImportanceScore`, `TestReconcileImportanceOverrideWins`, `TestReconcileImportanceQuarantineOnSignalError`, `TestReconcileImportanceOrderIndependent`, `TestMemory02_ReindexEquivalence`, `TestEvictReindexEquivalence`, `TestUpsertIndexNodeComputesImportance`, `TestUpsertIndexNodeImportanceOverrideWins`, `TestUpdateMemoryNodeImportanceScore`) must still pass unmodified — 5d-v's final run checks all nine by name. No new config gate, no retrieval/chat/MCP change.

---

### 5d-i: Move `refineImportance` after the deletion loop (bug 2)

**Depends on:** Task 8. **Blocks:** 5d-ii, 5d-iii (both edit the same function/area next).

**Files:**
- Modify: `internal/memory/index.go` — `Reconcile` only (lines 90–102; `file()`/`refineImportance()` bodies untouched by this step)
- Test: `internal/memory/index_test.go` — new test inserted after `TestReconcileImportanceQuarantineOnSignalError` (ends line 519), before `TestMemory02_ReindexEquivalence` (line 521)

**Interfaces:** Consumes/produces nothing new — a pure statement-reordering fix, no signature changes.

Current `Reconcile` (`index.go` lines 54–105, in full):

```go
func Reconcile(v *Vault, database *db.DB, logf func(string, ...any)) (Stats, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	var stats Stats

	existing, err := database.ListMemoryNodes()
	if err != nil {
		return stats, fmt.Errorf("memory: reconcile: %w", err)
	}
	indexed := make(map[string]db.MemoryNodeRow, len(existing))
	for _, row := range existing {
		indexed[row.ID] = row
	}

	pass := &reconcilePass{
		v:        v,
		database: database,
		logf:     logf,
		indexed:  indexed,
		onDisk:   make(map[string]bool),
		now:      time.Now().UTC().Format(time.RFC3339),
		stats:    &stats,
	}
	for _, sub := range vaultSubdirs {
		entries, err := os.ReadDir(filepath.Join(v.path, sub))
		if err != nil {
			return stats, fmt.Errorf("memory: reconcile: read %s: %w", sub, err)
		}
		for _, entry := range entries {
			if err := pass.file(sub, entry); err != nil {
				return stats, err
			}
		}
	}

	if err := pass.refineImportance(); err != nil {
		return stats, err
	}

	for _, row := range existing {
		if pass.onDisk[row.ID] {
			continue
		}
		if err := database.DeleteMemoryNode(row.ID); err != nil {
			return stats, fmt.Errorf("memory: reconcile: %w", err)
		}
		stats.Deleted++
	}

	return stats, nil
}
```

- [ ] **Step 1: write the failing test** — insert into `internal/memory/index_test.go` after line 519 (`TestReconcileImportanceQuarantineOnSignalError`'s closing brace), before `TestMemory02_ReindexEquivalence`:

```go
// TestReconcileImportanceRefinesAfterDeletion: a same-pass file deletion of a
// node's only linker must be reflected in the linked node's refined
// importance_score — refineImportance must run AFTER the deletion loop, not
// before, or it recomputes CountMemoryLinksIn while the about-to-be-deleted
// linker's row/FTS entry is still present, diverging from what a fresh
// Rebuild (which never sees the deleted file at all) would compute (whole-
// branch review follow-up, added 2026-07-18, MEM-16).
func TestReconcileImportanceRefinesAfterDeletion(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5DE1", "entity", "Target")
	linker := linkingEntity(t, "ent_01ARZ3NDEKTSV4RRFFQ69G5DE2", "Linker", target.ID)
	writeNodes(t, v, target, linker)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	baseline, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	require.Equal(t, 1.0, baseline.ImportanceScore, "sanity: linker gives target a link-in")

	// In the SAME Reconcile call: delete the linker's file AND touch target
	// (so it gets reparsed this pass, entering phase B's refinement).
	require.NoError(t, os.Remove(filepath.Join(v.path, "entities", linker.ID+".md")))
	target.Body = "# Target\n\nRevision one.\n"
	writeNodes(t, v, target)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, 1, stats.Deleted, "the linker's file is gone")
	assert.Equal(t, 1, stats.Updated, "target is reparsed this same pass")

	row, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	assert.Zero(t, row.ImportanceScore,
		"the deleted linker must not be counted — refineImportance must run AFTER the deletion loop, matching a fresh Rebuild")
}
```

- [ ] **Step 2: run it — expect the assertion failure that proves the bug** (today's order still counts the about-to-be-deleted linker):

```
$ go test ./internal/memory/ -run TestReconcileImportanceRefinesAfterDeletion -v
=== RUN   TestReconcileImportanceRefinesAfterDeletion
    index_test.go:XXX:
        	Error Trace:	.../index_test.go:XXX
        	Error:      	Should be zero, but was 1
        	Test:       	TestReconcileImportanceRefinesAfterDeletion
        	Messages:   	the deleted linker must not be counted — refineImportance must run AFTER the deletion loop, matching a fresh Rebuild
--- FAIL: TestReconcileImportanceRefinesAfterDeletion (0.02s)
FAIL
```

- [ ] **Step 3: reorder `Reconcile`.** Move the `pass.refineImportance()` call to after the deletion loop:

```go
	for _, sub := range vaultSubdirs {
		entries, err := os.ReadDir(filepath.Join(v.path, sub))
		if err != nil {
			return stats, fmt.Errorf("memory: reconcile: read %s: %w", sub, err)
		}
		for _, entry := range entries {
			if err := pass.file(sub, entry); err != nil {
				return stats, err
			}
		}
	}

	for _, row := range existing {
		if pass.onDisk[row.ID] {
			continue
		}
		if err := database.DeleteMemoryNode(row.ID); err != nil {
			return stats, fmt.Errorf("memory: reconcile: %w", err)
		}
		stats.Deleted++
	}

	if err := pass.refineImportance(); err != nil {
		return stats, err
	}

	return stats, nil
}
```

(No other line in `Reconcile` changes; `file()` and `refineImportance()`'s bodies are untouched by this step.)

- [ ] **Step 4: run it — expect green:**

```
$ go test ./internal/memory/ -run TestReconcileImportanceRefinesAfterDeletion -v
=== RUN   TestReconcileImportanceRefinesAfterDeletion
--- PASS: TestReconcileImportanceRefinesAfterDeletion (0.02s)
PASS
ok  	watchtower/internal/memory	0.2s
```

- [ ] **Step 5: confirm no regression in the sibling scan-order test and the reindex guards, then commit:**

```
$ go test ./internal/memory/ -run 'TestReconcileImportanceOrderIndependent|TestReconcileDeletesRemovedFile|TestMemory02_ReindexEquivalence|TestEvictReindexEquivalence' -v
=== RUN   TestReconcileImportanceOrderIndependent
--- PASS: TestReconcileImportanceOrderIndependent (0.02s)
=== RUN   TestReconcileDeletesRemovedFile
--- PASS: TestReconcileDeletesRemovedFile (0.01s)
=== RUN   TestMemory02_ReindexEquivalence
--- PASS: TestMemory02_ReindexEquivalence (0.03s)
=== RUN   TestEvictReindexEquivalence
--- PASS: TestEvictReindexEquivalence (0.05s)
PASS
ok  	watchtower/internal/memory	0.3s

$ git add internal/memory/index.go internal/memory/index_test.go
$ git commit -m "fix(memory): run Reconcile's importance refinement AFTER the deletion loop (whole-branch review, MEM-16)

refineImportance ran before the same-pass deletion loop, so a file deleted
this same Reconcile call could still be counted by CountMemoryLinksIn during
phase B — a real incremental-vs-Rebuild divergence (a fresh Rebuild never
sees the deleted file at all). Reordered: deletion loop now runs before
refineImportance. Guarded by TestReconcileImportanceRefinesAfterDeletion."
```

---

### 5d-ii: Memoize the owner-touch signal once per `Reconcile` call (bug 3)

**Depends on:** 5d-i (edits the same `index.go` region right after it). **Blocks:** 5d-iii (its delta-refine helper calls `computeNodeImportance` with the new signature).

**Files:**
- Modify: `internal/memory/vault.go` — new method `OwnerEditedFiles` (inserted after `OwnerEdited`, i.e. after line 243)
- Modify: `internal/memory/importance.go` — `computeNodeImportance`'s signature (lines 83–105)
- Modify: `internal/memory/index.go` — `reconcilePass` struct (lines 107–118), new `ownerEdited` method, `file()`'s call site (line 167), `refineImportance()`'s call site (line 211)
- Modify: `internal/memory/merge.go` — `upsertIndexNode`'s call site (line 142) — **its own signature is unchanged**, see the design note below
- Test: `internal/memory/vault_test.go` — new test after `TestMemory03_OwnerEditsSeparateCommit` (ends line 391)

**Interfaces:**
- Consumes: `commit.Stats()` (go-git `object.Commit`, already used by this file's own `commitFiles` test helper at `vault_test.go:55-66` — same API, now used in production code, not just tests).
- Produces: `func (v *Vault) OwnerEditedFiles() (map[string]bool, error)` (new, exported to match `OwnerEdited`'s convention). **Breaking change:** `computeNodeImportance`'s second parameter changes from `v *Vault` to `ownerEdited func(rel string) (bool, error)` — this function has exactly **three** call sites (verified: `grep -rn "computeNodeImportance(" internal/memory/` hits only `index.go:167`, `index.go:211`, `merge.go:142`), all updated by this step.

**Design decision — why `upsertIndexNode`'s own signature does NOT change:** `upsertIndexNode` (`merge.go`) is the single-node write path reached from ~16 call sites across the package (Task 5b's audit). It has no batch to memoize over — each call is its own `Reconcile`-less write, often minutes or hours apart, so caching `OwnerEditedFiles()` across calls would risk serving a stale set to a later call in the same process lifetime (a new `memory(owner-edit)` commit could land between two `upsertIndexNode` calls). The cleanest fix is therefore NOT to thread a memoized cache into `upsertIndexNode` at all: it keeps calling the plain per-file `v.OwnerEdited` — which, as a **method value**, has exactly the type `computeNodeImportance` now expects (`func(string) (bool, error)`), so `merge.go`'s one-line change is `v.OwnerEdited` passed directly, no closure needed, no call to any of the other ~15 `upsertIndexNode` callers changes (their own signature is untouched). Only `Reconcile`'s **bulk** pass — which really does call `computeNodeImportance` for potentially dozens of nodes inside one call — gets the memoized path, via a new lazily-populated field on `reconcilePass`.

**Why lazy, not eager:** the memoized set could be built once at the top of `Reconcile`, unconditionally. But the common case — a re-run over an unchanged vault — never calls `computeNodeImportance` at all (the hash-gate in `file()` skips before reaching it, and `refineImportance` only iterates nodes that were actually touched). Building the set eagerly would pay one full-history git walk on every `Reconcile` call, including every no-op one. Building it lazily — on the first node that actually needs the signal — means a no-op pass pays nothing, and a pass with real work pays the walk exactly once, reused by every subsequent node in the same call.

Current `OwnerEdited` (`vault.go` lines 219–243, for context — **unchanged by this step**, `evict.go:125` keeps calling it directly):

```go
// OwnerEdited reports whether the file at rel (a vault-relative slash path) was
// ever touched by a memory(owner-edit) commit — the owner-touch input to the
// retention score. Cheap by construction: the log is filtered to commits that
// changed this one path, and the walk stops at the first owner-edit. Called
// only for eviction candidates (a bounded set), never for the whole vault.
func (v *Vault) OwnerEdited(rel string) (bool, error) {
	iter, err := v.repo.Log(&git.LogOptions{FileName: &rel})
	if err != nil {
		return false, fmt.Errorf("memory: owner-edit log for %s: %w", rel, err)
	}
	defer iter.Close()

	found := false
	err = iter.ForEach(func(c *object.Commit) error {
		if strings.HasPrefix(c.Message, "memory(owner-edit)") {
			found = true
			return storer.ErrStop
		}
		return nil
	})
	if err != nil {
		return false, fmt.Errorf("memory: owner-edit walk for %s: %w", rel, err)
	}
	return found, nil
}
```

Its doc comment's last sentence ("Called only for eviction candidates ... never for the whole vault") stopped being true the moment Task 5b wired `computeNodeImportance` into `upsertIndexNode`'s ~16 call sites — this step both fixes the cost problem for `Reconcile`'s bulk path and corrects that comment.

Current `computeNodeImportance` (`importance.go` lines 83–105):

```go
func computeNodeImportance(database *db.DB, v *Vault, n Node, rel string) (float64, error) {
	if n.ImportanceOverride != nil {
		return *n.ImportanceOverride, nil
	}
	linksIn, err := database.CountMemoryLinksIn(n.ID)
	if err != nil {
		return 0, err
	}
	ownerTouched, err := v.OwnerEdited(rel)
	if err != nil {
		return 0, err
	}
	engaged, dismissed, err := database.LinkedEntityEngagement(n.ID)
	if err != nil {
		return 0, err
	}
	return ComputeImportance(ImportanceInputs{
		LinksIn:         linksIn,
		SituationOrigin: hasSituationAlias(n.Aliases),
		OwnerTouched:    ownerTouched,
		Engagement:      engaged - dismissed,
	}), nil
}
```

Current `reconcilePass` struct and `file()`/`refineImportance()` call sites (`index.go`, post-5d-i — unchanged by 5d-i, still exactly as shipped in Task 5c):

```go
type reconcilePass struct {
	v        *Vault
	database *db.DB
	logf     func(string, ...any)
	indexed  map[string]db.MemoryNodeRow
	onDisk   map[string]bool
	now      string
	stats    *Stats
	touched  []touchedNode
}
```

```go
	importance, err := computeNodeImportance(p.database, p.v, n, rel)
```
(`file()`, line 167)

```go
		importance, err := computeNodeImportance(p.database, p.v, tn.n, tn.rel)
```
(`refineImportance()`, line 211)

Current `upsertIndexNode`'s call site (`merge.go` line 142, inside the function quoted in full at Task 5b — unchanged since):

```go
	importance, err := computeNodeImportance(database, v, n, rel)
```

- [ ] **Step 1: write the failing test** — append to `internal/memory/vault_test.go` after line 391 (`TestMemory03_OwnerEditsSeparateCommit`'s closing brace), reusing the file's own `commitFiles`/`vaultTestNode` idiom:

```go
// TestVaultOwnerEditedFilesAggregatesAcrossHistory: OwnerEditedFiles returns
// every vault-relative path ever touched by a memory(owner-edit) commit,
// across the WHOLE history in one walk — the set computeNodeImportance's
// Reconcile-side callers memoize against instead of paying OwnerEdited's
// per-file FileName-filtered log walk once per node on every write
// (whole-branch review follow-up, added 2026-07-18, MEM-16). Machine
// commits (seed/extract) never contribute; a second, later owner-edit of a
// DIFFERENT file adds to the set rather than replacing it.
func TestVaultOwnerEditedFilesAggregatesAcrossHistory(t *testing.T) {
	v := newTestVault(t)

	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5OF1", "entity", "Alpha")
	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5OF2", "episode", "Beta")
	_, err := v.WriteNodes([]Node{a, b}, CommitMsg{Op: "seed", Summary: "seed", Cause: "seed", NodeIDs: []string{a.ID, b.ID}})
	require.NoError(t, err)

	// Owner edits A only.
	require.NoError(t, os.WriteFile(filepath.Join(v.path, "entities", a.ID+".md"),
		append(a.Render(), []byte("\nhand edit one\n")...), 0o644))
	made, err := v.CommitOwnerEdits()
	require.NoError(t, err)
	require.True(t, made)

	// A machine write in between — must not contribute to the set.
	c := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5OF3", "episode", "Gamma")
	_, err = v.WriteNodes([]Node{c}, CommitMsg{Op: "extract", Summary: "extract", Cause: "run:1", NodeIDs: []string{c.ID}})
	require.NoError(t, err)

	// A second, later owner edit of a DIFFERENT file (B).
	require.NoError(t, os.WriteFile(filepath.Join(v.path, "episodes", b.ID+".md"),
		append(b.Render(), []byte("\nhand edit two\n")...), 0o644))
	made, err = v.CommitOwnerEdits()
	require.NoError(t, err)
	require.True(t, made)

	files, err := v.OwnerEditedFiles()
	require.NoError(t, err)
	assert.True(t, files["entities/"+a.ID+".md"], "A's owner edit is in the set")
	assert.True(t, files["episodes/"+b.ID+".md"], "B's LATER owner edit is also in the set, not just the most recent one")
	assert.False(t, files["episodes/"+c.ID+".md"], "a machine write must not appear in the owner-edited set")
}
```

- [ ] **Step 2: run it — expect a build failure** (the method doesn't exist yet):

```
$ go test ./internal/memory/ -run TestVaultOwnerEditedFilesAggregatesAcrossHistory -v
# watchtower/internal/memory [watchtower/internal/memory.test]
./vault_test.go:XXX: v.OwnerEditedFiles undefined (type *Vault has no field or method OwnerEditedFiles)
FAIL	watchtower/internal/memory [build failed]
```

- [ ] **Step 3: add `OwnerEditedFiles` to `vault.go`**, right after `OwnerEdited` (after line 243):

```go
// OwnerEditedFiles returns the set of vault-relative paths ever touched by a
// memory(owner-edit) commit, across the FULL history — ONE walk, computing
// the exact same "was this file ever owner-edited" fact OwnerEdited answers
// per-call, but for every file at once. Reconcile's bulk pass memoizes
// against this set (see index.go's reconcilePass.ownerEdited) instead of
// paying OwnerEdited's per-file FileName-filtered log walk once per node,
// now that computeNodeImportance runs on every write through ~16+ call
// sites (Task 5b), not just the small bounded eviction-candidate set
// OwnerEdited itself stays scoped for (whole-branch review follow-up, added
// 2026-07-18, MEM-16). The vault history is linear (single author, no
// merges — same invariant LogMemoryCommits relies on), so commit.Stats()'s
// first-parent tree diff is exact, not an approximation.
func (v *Vault) OwnerEditedFiles() (map[string]bool, error) {
	iter, err := v.repo.Log(&git.LogOptions{})
	if err != nil {
		return nil, fmt.Errorf("memory: owner-edited files log: %w", err)
	}
	defer iter.Close()

	files := make(map[string]bool)
	err = iter.ForEach(func(c *object.Commit) error {
		if !strings.HasPrefix(c.Message, "memory(owner-edit)") {
			return nil
		}
		stats, serr := c.Stats()
		if serr != nil {
			return serr
		}
		for _, fs := range stats {
			files[fs.Name] = true
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("memory: owner-edited files walk: %w", err)
	}
	return files, nil
}
```

- [ ] **Step 4: run it — expect green:**

```
$ go test ./internal/memory/ -run TestVaultOwnerEditedFilesAggregatesAcrossHistory -v
=== RUN   TestVaultOwnerEditedFilesAggregatesAcrossHistory
--- PASS: TestVaultOwnerEditedFilesAggregatesAcrossHistory (0.01s)
PASS
ok  	watchtower/internal/memory	0.2s
```

- [ ] **Step 5: change `computeNodeImportance`'s signature** in `importance.go`:

```go
// computeNodeImportance is the merged (owner-override-or-computed)
// importance value for node n at vault-relative path rel: n's
// ImportanceOverride if set, else ComputeImportance fed by live
// links-in/situation-origin/owner-touch/engagement reads. ownerEdited
// resolves the owner-touch signal for rel: Reconcile's bulk pass
// (index.go's reconcilePass.ownerEdited) passes a lazily-memoized lookup
// backed by ONE Vault.OwnerEditedFiles() call per Reconcile run, while
// upsertIndexNode's single-node call sites (no batch to memoize over) pass
// the plain per-file Vault.OwnerEdited method value directly (whole-branch
// review follow-up, added 2026-07-18, MEM-16: a fresh v.OwnerEdited call per
// node was an expensive per-file git-log walk, now paid on every write
// through ~16+ call sites, not just the small bounded eviction-candidate
// set OwnerEdited was originally scoped for). Shared by index.go's
// Reconcile/Rebuild path and merge.go's upsertIndexNode (every non-Reconcile
// write path) so both persist a mutually consistent value for the same file
// — MEM-16, Slice A follow-up (added 2026-07-18: upsertIndexNode previously
// never set this field).
func computeNodeImportance(database *db.DB, ownerEdited func(rel string) (bool, error), n Node, rel string) (float64, error) {
	if n.ImportanceOverride != nil {
		return *n.ImportanceOverride, nil
	}
	linksIn, err := database.CountMemoryLinksIn(n.ID)
	if err != nil {
		return 0, err
	}
	ownerTouched, err := ownerEdited(rel)
	if err != nil {
		return 0, err
	}
	engaged, dismissed, err := database.LinkedEntityEngagement(n.ID)
	if err != nil {
		return 0, err
	}
	return ComputeImportance(ImportanceInputs{
		LinksIn:         linksIn,
		SituationOrigin: hasSituationAlias(n.Aliases),
		OwnerTouched:    ownerTouched,
		Engagement:      engaged - dismissed,
	}), nil
}
```

- [ ] **Step 6: update `index.go`.** Add three fields to `reconcilePass`:

```go
type reconcilePass struct {
	v        *Vault
	database *db.DB
	logf     func(string, ...any)
	indexed  map[string]db.MemoryNodeRow
	onDisk   map[string]bool
	now      string
	stats    *Stats
	touched  []touchedNode

	// ownerEditedFiles/ownerEditedErr/ownerEditedLoaded memoize
	// v.OwnerEditedFiles() lazily: computed at most ONCE per Reconcile call,
	// on the first node that actually needs the owner-touch signal (a fully
	// unchanged pass — the common case — never pays for it at all), and
	// reused by every subsequent computeNodeImportance call this pass
	// instead of each paying its own full-history git-log walk (whole-branch
	// review follow-up, added 2026-07-18, MEM-16).
	ownerEditedFiles  map[string]bool
	ownerEditedErr    error
	ownerEditedLoaded bool
}
```

Add a new `ownerEdited` method right after `quarantine`:

```go
// ownerEdited is reconcilePass's owner-touch signal, passed to
// computeNodeImportance as its ownerEdited func(rel string) (bool, error)
// parameter: a lazily-loaded memoization of v.OwnerEditedFiles(), computed
// at most once per Reconcile call. A load failure is cached too, so a
// broken repo fails every subsequent lookup the same way instead of
// re-walking (each caller already handles the error via the existing
// quarantine/log-and-continue paths — this only avoids repeating a failing
// walk pointlessly).
func (p *reconcilePass) ownerEdited(rel string) (bool, error) {
	if !p.ownerEditedLoaded {
		p.ownerEditedFiles, p.ownerEditedErr = p.v.OwnerEditedFiles()
		p.ownerEditedLoaded = true
	}
	if p.ownerEditedErr != nil {
		return false, p.ownerEditedErr
	}
	return p.ownerEditedFiles[rel], nil
}
```

Change `file()`'s call site (line 167) from `computeNodeImportance(p.database, p.v, n, rel)` to:

```go
	importance, err := computeNodeImportance(p.database, p.ownerEdited, n, rel)
```

Change `refineImportance()`'s call site (line 211) from `computeNodeImportance(p.database, p.v, tn.n, tn.rel)` to:

```go
		importance, err := computeNodeImportance(p.database, p.ownerEdited, tn.n, tn.rel)
```

(`Reconcile` itself needs no change for this step — `pass := &reconcilePass{...}` already omits the three new fields, which zero-initialize correctly, i.e. `ownerEditedLoaded: false`.)

- [ ] **Step 7: update `merge.go`'s `upsertIndexNode`** — change line 142 from `computeNodeImportance(database, v, n, rel)` to:

```go
	importance, err := computeNodeImportance(database, v.OwnerEdited, n, rel)
```

(`v.OwnerEdited` as a bare method value has exactly the type `func(string) (bool, error)` `computeNodeImportance` now expects — no closure needed. `upsertIndexNode`'s own signature, and therefore all ~16 of its call sites from Task 5b, are untouched.)

- [ ] **Step 8: run the full package — expect zero regressions**, in particular the tests that exercise the owner-touch signal through both paths:

```
$ go build ./... && go test -count=1 ./internal/memory/... -run 'TestReconcileComputesImportanceScore|TestEvictOwnerTouchedKept|TestUpsertIndexNodeComputesImportance|TestUpsertIndexNodeImportanceOverrideWins|TestVaultOwnerEditedFilesAggregatesAcrossHistory' -v
=== RUN   TestReconcileComputesImportanceScore
--- PASS: TestReconcileComputesImportanceScore (0.02s)
=== RUN   TestEvictOwnerTouchedKept
--- PASS: TestEvictOwnerTouchedKept (0.02s)
=== RUN   TestUpsertIndexNodeComputesImportance
--- PASS: TestUpsertIndexNodeComputesImportance (0.02s)
=== RUN   TestUpsertIndexNodeImportanceOverrideWins
--- PASS: TestUpsertIndexNodeImportanceOverrideWins (0.01s)
=== RUN   TestVaultOwnerEditedFilesAggregatesAcrossHistory
--- PASS: TestVaultOwnerEditedFilesAggregatesAcrossHistory (0.01s)
PASS
ok  	watchtower/internal/memory	0.3s

$ go test -count=1 ./internal/memory/... 2>&1 | tail -5
ok  	watchtower/internal/memory	1.4s
```

`TestEvictOwnerTouchedKept` (`evict_test.go`) is the proof `evict.go` is untouched: it calls `v.OwnerEdited(rel)` directly (not through `computeNodeImportance`) and still passes unchanged.

- [ ] **Step 9: commit:**

```
$ git add internal/memory/vault.go internal/memory/importance.go internal/memory/index.go internal/memory/merge.go internal/memory/vault_test.go
$ git commit -m "perf(memory): memoize the owner-touch signal once per Reconcile call (whole-branch review, MEM-16)

computeNodeImportance's v.OwnerEdited(rel) call is a per-file, FileName-
filtered git-log walk. Task 5b made it reachable from ~16+ upsertIndexNode
call sites on every ordinary write, not just the small bounded eviction-
candidate set OwnerEdited itself is documented as cheap for. New
Vault.OwnerEditedFiles() does ONE full-history walk, computing the whole
owner-edited path set at once; Reconcile's bulk pass (reconcilePass.ownerEdited)
memoizes it lazily, on first need, so an unchanged vault pays nothing extra.
upsertIndexNode's single-node call sites are unaffected: they pass
v.OwnerEdited itself (a method value, no closure needed) since there is no
batch to memoize over — its own signature, and its ~16 callers, are
untouched. Guarded by TestVaultOwnerEditedFilesAggregatesAcrossHistory."
```

---

### 5d-iii: Delta-refine every touched node's outgoing link targets (bug 1, Critical)

**Depends on:** 5d-ii (needs the memoized `p.ownerEdited` and the new `computeNodeImportance` signature). **Blocks:** 5d-iv (the doc update names this fix), 5d-v.

**Files:**
- Modify: `internal/memory/index.go` — `refineImportance()` (extended) and a new `refineLinkedNode` method
- Test: `internal/memory/index_test.go` — new test inserted immediately after 5d-i's `TestReconcileImportanceRefinesAfterDeletion`, before `TestMemory02_ReindexEquivalence`

**Interfaces:**
- Consumes: `Node.Links() []Link` (existing, `node.go:233-239` — `Link{ID, Label}` parsed from `[[id]]`/`[[id|label]]` wiki-links via `wikiLinkRe`, `node.go:93`), `nodeRelPath(id string) (string, error)` (existing, `vault.go:320`), `v.ReadNode(id string) (Node, error)` (existing, `vault.go:330`).
- Produces: nothing new exported — `refineLinkedNode` is a private `reconcilePass` method, consumed only by `refineImportance` in the same file.

**Why `Node.Links()` is the right extraction to reuse, and why it stays consistent with what `CountMemoryLinksIn` counts:** `db/memory.go`'s `CountMemoryLinksIn` (lines 963–979) tests `instr(f.body, '[[' || ?) > 0` — a raw substring match on `'[[' + id`, which recognizes `[[id]]`, `[[id|label]]`, and (as a known, pre-existing imprecision unrelated to this fix) any longer id sharing that prefix. `Node.Links()` parses the SAME `[[id]]`/`[[id|label]]` syntax via `wikiLinkRe` and returns the exact id token between the brackets and the optional `|`. Every id `Links()` extracts is therefore also a substring match `CountMemoryLinksIn` would recognize (a precise parse is always a subset of a substring test) — so using `Links()` to decide WHICH nodes to refine never disagrees with what `CountMemoryLinksIn` itself would go on to count for them.

**Scope note — a known, accepted residual asymmetry:** this fix reads a touched node's NEW (post-edit) body only. If an edit REMOVES a link (rather than adding one), the node that link used to point at is not refined in the same pass — its `LinksIn` decrease is picked up only the next time ITS OWN file changes, or the next time some other touched node happens to link to it. This mirrors the bug being fixed in miniature: the fix corrects the "never refreshes upward" case exactly as scoped; a "stays stale downward after a link removal" case is not eliminated, only narrowed. Extending the delta-refine to cover removals would require diffing each touched node's OLD body (available in `memory_fts` immediately before its `UpsertMemoryNode` overwrite) against its new one inside `file()` itself — a materially larger change to phase A, not requested and not undertaken here. Call this out explicitly rather than silently accepting or silently over-scoping.

Current `refineImportance` (`index.go`, post-5d-ii — the version 5d-ii's Step 6 produced):

```go
func (p *reconcilePass) refineImportance() error {
	for _, tn := range p.touched {
		importance, err := computeNodeImportance(p.database, p.ownerEdited, tn.n, tn.rel)
		if err != nil {
			p.logf("memory: reconcile: refining importance for %s failed (keeping first-pass value): %v", tn.n.ID, err)
			continue
		}
		if err := p.database.UpdateMemoryNodeImportanceScore(tn.n.ID, importance); err != nil {
			return fmt.Errorf("memory: reconcile: refining importance for %s: %w", tn.n.ID, err)
		}
	}
	return nil
}
```

- [ ] **Step 1: write the failing test** — insert into `internal/memory/index_test.go` immediately after 5d-i's `TestReconcileImportanceRefinesAfterDeletion`, before `TestMemory02_ReindexEquivalence`:

```go
// TestReconcileImportanceRefinesUnchangedLinkedNode: a brand-new episode
// links to an existing, otherwise-untouched entity — the entity's OWN file
// never changes this pass (or ever again, in this test), so file()'s
// content-hash gate skips it entirely and it never enters p.touched. Without
// a delta-refine pass over touched nodes' outgoing links, the entity's
// importance_score would stay frozen at its original value forever, even
// though CountMemoryLinksIn — the formula's dominant signal — has grown
// (whole-branch review follow-up, added 2026-07-18, MEM-16 — the Critical
// bug: a node linked from many new episodes over weeks, none of which touch
// its own file, never gets its importance_score refreshed).
func TestReconcileImportanceRefinesUnchangedLinkedNode(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5DL1", "entity", "Target")
	writeNodes(t, v, target)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	baseline, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	require.Zero(t, baseline.ImportanceScore, "sanity: no links yet")

	// A brand-new episode links to target — target's OWN file is untouched
	// this pass (its content hash is unchanged, so file() never reparses it
	// and it never enters p.touched).
	linker := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5DL2", "episode", "New Story")
	linker.Body = "# New Story\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5DL1]] for background.\n"
	writeNodes(t, v, linker)

	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	require.Equal(t, Stats{Added: 1}, stats, "sanity: only the new episode is (re)indexed, target is not reparsed")

	row, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	want := ComputeImportance(ImportanceInputs{LinksIn: 1})
	assert.Equal(t, want, row.ImportanceScore,
		"target's importance must be refreshed even though ITS OWN file never changed — the new episode's outgoing link is what changed target's LinksIn")
	assert.Equal(t, baseline.ContentHash, row.ContentHash, "target's content/hash must be untouched — only its score changed")
}
```

- [ ] **Step 2: run it — expect the assertion failure that proves the bug:**

```
$ go test ./internal/memory/ -run TestReconcileImportanceRefinesUnchangedLinkedNode -v
=== RUN   TestReconcileImportanceRefinesUnchangedLinkedNode
    index_test.go:XXX:
        	Error Trace:	.../index_test.go:XXX
        	Error:      	Not equal:
        	            	expected: 1
        	            	actual  : 0
        	Test:       	TestReconcileImportanceRefinesUnchangedLinkedNode
        	Messages:   	target's importance must be refreshed even though ITS OWN file never changed — the new episode's outgoing link is what changed target's LinksIn
--- FAIL: TestReconcileImportanceRefinesUnchangedLinkedNode (0.02s)
FAIL
```

- [ ] **Step 3: extend `refineImportance` and add `refineLinkedNode`** in `index.go`:

```go
// refineImportance is Reconcile's phase B, run after the deletion loop (see
// 5d-i): recompute importance for every file this pass successfully indexed
// (phase A), now that the run's full link graph is populated and this run's
// deletions have already happened — correcting phase A's scan-order-
// dependent initial value. It then delta-refines every node a touched node's
// body links to that WASN'T itself touched this run: a node's own file may
// never change while its LinksIn keeps growing purely from OTHER nodes'
// new links (e.g. a person entity linked from many new Slack-extracted
// episodes over weeks) — CountMemoryLinksIn is this formula's dominant
// signal, so without this delta pass such a node's importance_score would
// stay frozen indefinitely (whole-branch review follow-up, added
// 2026-07-18, MEM-16 — the Critical bug). Known residual asymmetry: a link
// REMOVED from a touched node's edited body is not detected here (only the
// new body's current links are read), so a node whose LinksIn just
// decreased stays stale until its own file next changes or another touched
// node happens to link to it — accepted, matching this design's existing
// "eventually consistent" character. Any recompute error (either phase) is
// logged and that node's prior importance_score is kept — not escalated to
// an abort or a quarantine, the same policy this function already used for
// its own phase-A-value errors.
func (p *reconcilePass) refineImportance() error {
	touchedIDs := make(map[string]bool, len(p.touched))
	for _, tn := range p.touched {
		touchedIDs[tn.n.ID] = true
	}

	for _, tn := range p.touched {
		importance, err := computeNodeImportance(p.database, p.ownerEdited, tn.n, tn.rel)
		if err != nil {
			p.logf("memory: reconcile: refining importance for %s failed (keeping first-pass value): %v", tn.n.ID, err)
			continue
		}
		if err := p.database.UpdateMemoryNodeImportanceScore(tn.n.ID, importance); err != nil {
			return fmt.Errorf("memory: reconcile: refining importance for %s: %w", tn.n.ID, err)
		}
	}

	linkTargets := make(map[string]bool)
	for _, tn := range p.touched {
		for _, link := range tn.n.Links() {
			if touchedIDs[link.ID] {
				continue
			}
			linkTargets[link.ID] = true
		}
	}
	for id := range linkTargets {
		if err := p.refineLinkedNode(id); err != nil {
			return err
		}
	}
	return nil
}

// refineLinkedNode recomputes and persists the importance of id — a node
// some touched node's body links to, but which was not itself touched this
// run (so file() never computed a value for it this pass). A dangling or
// stale link (not a valid node id, or the node no longer exists on disk —
// merge.go documents that incoming [[loser]] links are never rewritten
// after a merge, so a tombstoned-but-still-present id is normal and simply
// gets its tombstone body re-read here) or a signal-lookup error is logged
// and skipped, keeping that node's prior importance_score untouched — the
// same log-and-continue-keep-prior-value policy refineImportance uses for
// its own errors above.
func (p *reconcilePass) refineLinkedNode(id string) error {
	rel, err := nodeRelPath(id)
	if err != nil {
		p.logf("memory: reconcile: refining linked node %s failed (not a node id, keeping prior value): %v", id, err)
		return nil
	}
	n, err := p.v.ReadNode(id)
	if err != nil {
		p.logf("memory: reconcile: refining linked node %s failed (keeping prior value): %v", id, err)
		return nil
	}
	importance, err := computeNodeImportance(p.database, p.ownerEdited, n, rel)
	if err != nil {
		p.logf("memory: reconcile: refining linked node %s failed (keeping prior value): %v", id, err)
		return nil
	}
	if err := p.database.UpdateMemoryNodeImportanceScore(id, importance); err != nil {
		return fmt.Errorf("memory: reconcile: refining linked node %s: %w", id, err)
	}
	return nil
}
```

- [ ] **Step 4: run it — expect green:**

```
$ go test ./internal/memory/ -run TestReconcileImportanceRefinesUnchangedLinkedNode -v
=== RUN   TestReconcileImportanceRefinesUnchangedLinkedNode
--- PASS: TestReconcileImportanceRefinesUnchangedLinkedNode (0.02s)
PASS
ok  	watchtower/internal/memory	0.2s
```

- [ ] **Step 5: full package + db, verbose — confirm all nine previously-named guard tests plus every new test from 5d-i/ii/iii are green, zero regressions:**

```
$ go build ./... && go test -count=1 ./internal/memory/... ./internal/db/... -v 2>&1 | tail -60
--- PASS: TestReconcileComputesImportanceScore (0.02s)
--- PASS: TestReconcileImportanceOverrideWins (0.01s)
--- PASS: TestReconcileImportanceQuarantineOnSignalError (0.03s)
--- PASS: TestReconcileImportanceOrderIndependent (0.02s)
--- PASS: TestMemory02_ReindexEquivalence (0.03s)
--- PASS: TestEvictReindexEquivalence (0.05s)
--- PASS: TestUpsertIndexNodeComputesImportance (0.02s)
--- PASS: TestUpsertIndexNodeImportanceOverrideWins (0.01s)
--- PASS: TestUpdateMemoryNodeImportanceScore (0.01s)
--- PASS: TestReconcileImportanceRefinesAfterDeletion (0.02s)
--- PASS: TestVaultOwnerEditedFilesAggregatesAcrossHistory (0.01s)
--- PASS: TestReconcileImportanceRefinesUnchangedLinkedNode (0.02s)
PASS
ok  	watchtower/internal/memory	1.5s
ok  	watchtower/internal/db	0.6s
```

- [ ] **Step 6: commit:**

```
$ git add internal/memory/index.go internal/memory/index_test.go
$ git commit -m "fix(memory): delta-refine touched nodes' outgoing link targets in Reconcile (whole-branch review, MEM-16 Critical)

A node whose OWN file never changes never re-enters p.touched, so its
importance_score was frozen at whatever it was the last time its file
changed — even though CountMemoryLinksIn (the formula's dominant signal)
grows purely from OTHER nodes' new outgoing links. refineImportance now
also recomputes importance for every distinct node a touched node's body
links to (via Node.Links()) that wasn't itself touched this run, via the
same narrow UpdateMemoryNodeImportanceScore update. One hop only, by
design: a link REMOVED from an edited body is a known, accepted residual
gap (not detected until the target's own file next changes). Guarded by
TestReconcileImportanceRefinesUnchangedLinkedNode."
```

---

### 5d-iv: MEM-16 inventory addendum

**Depends on:** 5d-i, 5d-ii, 5d-iii (needs their final test names). **Blocks:** 5d-v.

**Files:**
- Modify: `docs/inventory/memory.md` — extend the existing MEM-16 section's Observable/Why-locked/Test-guards (lines 253–272) and add a new changelog entry above the existing 2026-07-18 entry (before line 318)

This task is documentation-only, extending the SAME MEM-16 contract 5b/5c already extended once — not a new contract number, matching the established pattern.

- [ ] **Step 1: extend the Observable line.** Current (line 257):

```
**Observable:** `memory_nodes.importance_score` is a periodically-refreshed snapshot (via `Reconcile`/`Rebuild`, and via `merge.go`'s `upsertIndexNode` on the second, non-Reconcile write path) of `ComputeImportance`'s output-or-owner-override, used by future retrieval ranking. It is distinct from `evict.go`'s `RetentionScore`, which always recomputes importance live per eviction candidate and never reads the persisted column. The two must not be collapsed into one without owner review — they answer different questions ("is this worth surfacing now" vs "is this worth compressing").
```

Append one sentence at the end:

```
A whole-branch review after this contract first shipped found and fixed three more gaps, folded into this same contract rather than a new one: `Reconcile`'s importance refinement now runs strictly after that call's deletion loop (a same-pass-deleted linker was otherwise still counted); the owner-touch git-log signal is now memoized once per `Reconcile` call instead of walked fresh per node; and a node whose own file never changes now still gets its `importance_score` refreshed when some OTHER touched node's body newly links to it.
```

- [ ] **Step 2: extend the Why-locked paragraph.** Append at the end of the existing paragraph (line 259):

```
A second, later whole-branch review (2026-07-18) found three more real gaps in the already-shipped code, none caught by the original design or the 5b/5c fixes: (1) `Reconcile`'s phase-B refinement ran BEFORE that same call's deletion loop, so a node deleted this same pass could still be counted by `CountMemoryLinksIn` while its importance was refined — a fresh `Rebuild` would never count it, a real incremental-vs-`Rebuild` divergence; fixed by reordering the two. (2) `computeNodeImportance`'s owner-touch signal (`Vault.OwnerEdited`) is a per-file, `FileName`-filtered git-log walk — cheap for eviction's small bounded candidate set, but Task 5b made it run on every ordinary write through `upsertIndexNode`'s ~16 call sites; fixed with a new `Vault.OwnerEditedFiles()` (one full-history walk returning every owner-edited path at once) that `Reconcile`'s bulk pass memoizes lazily (`reconcilePass.ownerEdited`), while `upsertIndexNode`'s single-node call sites keep calling `Vault.OwnerEdited` directly (a method value, no cache — there is no batch to memoize over). (3) The Critical gap: a node whose own file never changes never re-enters `p.touched`, so its `importance_score` was frozen indefinitely even as `CountMemoryLinksIn` — the formula's dominant signal — grew from OTHER nodes linking to it; fixed by delta-refining, once per `Reconcile` call, every distinct outgoing-link target (`Node.Links()`) of every touched node that wasn't itself touched this run — one hop only, with a documented residual asymmetry for link REMOVALS (not detected until the target's own file next changes).
```

- [ ] **Step 3: add three test guards.** Append to the bullet list (after line 270's `TestUpdateMemoryNodeImportanceScore` line):

```
- `internal/memory/index_test.go::TestReconcileImportanceRefinesAfterDeletion` (a same-pass-deleted linker is not counted by the refinement pass — proves the deletion loop runs before, not after)
- `internal/memory/vault_test.go::TestVaultOwnerEditedFilesAggregatesAcrossHistory` (the memoized owner-edited path set aggregates across the WHOLE history, not just the most recent owner-edit commit, and ignores machine commits)
- `internal/memory/index_test.go::TestReconcileImportanceRefinesUnchangedLinkedNode` (a node whose own file never changes still gets `importance_score` refreshed when a touched node's body newly links to it — the Critical gap)
```

- [ ] **Step 4: add the changelog entry.** Insert immediately after line 316's `## Changelog` heading, above the existing 2026-07-18 entry:

```markdown

- 2026-07-18 (whole-branch review follow-up on Slice A / MEM-16, three more gaps found and fixed post-ship): (1) **Refine-after-delete ordering** — `Reconcile`'s phase-B `refineImportance` ran before that same call's deletion loop, so a node deleted in the same `Reconcile` call as a refinement could still be counted by `CountMemoryLinksIn` — a real incremental-vs-`Rebuild` divergence (a fresh `Rebuild` never sees the deleted file). Fixed by moving `refineImportance` after the deletion loop. (2) **`OwnerEdited` memoization** — `computeNodeImportance`'s owner-touch signal was a fresh per-file, `FileName`-filtered `git log` walk on every call; Task 5b made this reachable from `upsertIndexNode`'s ~16 call sites on every ordinary write, not just eviction's small bounded candidate set. Fixed with a new `Vault.OwnerEditedFiles()` (one full-history walk), lazily memoized once per `Reconcile` call (`reconcilePass.ownerEdited`); `upsertIndexNode`'s single-node call sites are unaffected (they pass `Vault.OwnerEdited` itself, a method value — no batch to memoize over, no signature change, no call-site churn). (3) **Delta-refine for untouched linked nodes (Critical)** — a node whose own file never changes never re-enters `p.touched`, so its `importance_score` stayed frozen indefinitely even as its `LinksIn` (the formula's dominant signal) grew purely from OTHER nodes' new links (e.g. a person entity linked from many new Slack-extracted episodes over weeks, none of which touch the entity's own file). Fixed by delta-refining, once per `Reconcile` call, every distinct outgoing-link target (`Node.Links()`) of every touched node that wasn't itself touched this run — one hop only; a link REMOVED from an edited body is a documented, accepted residual gap, not eliminated. Guarded by `TestReconcileImportanceRefinesAfterDeletion`, `TestVaultOwnerEditedFilesAggregatesAcrossHistory`, `TestReconcileImportanceRefinesUnchangedLinkedNode`. No new contract number (folded into MEM-16), no new config gate, no retrieval/chat/MCP change — still foundation-only.
```

- [ ] **Step 5: re-read the section and sanity-check it renders correctly:**

```
$ grep -n "^## MEM-16\|^## Known v1\|^## Changelog" docs/inventory/memory.md
```

Expected: unchanged positions (only the text between them grew); the new changelog entry sits directly under the `## Changelog` heading, above the original 2026-07-18 Slice A entry.

- [ ] **Step 6: commit:**

```
$ git add docs/inventory/memory.md
$ git commit -m "docs(memory): MEM-16 addendum — refine-after-delete ordering, OwnerEdited memoization, delta-refine for untouched linked nodes

Whole-branch review of already-shipped Slice A code found one Critical and
two Important gaps; all three folded into the existing MEM-16 contract with
new test guards, matching the established 5b/5c pattern."
```

---

### 5d-v: Final verification

**Depends on:** 5d-i, 5d-ii, 5d-iii, 5d-iv. **Blocks:** nothing (terminal).

- [ ] **Step 1: formatting.**

```
$ gofmt -l internal/memory/index.go internal/memory/index_test.go internal/memory/importance.go internal/memory/vault.go internal/memory/vault_test.go internal/memory/merge.go
```

Expected: no output.

- [ ] **Step 2: vet + build.**

```
$ go vet ./... && go build ./... > /tmp/build.log 2>&1; echo "exit=$?"; cat /tmp/build.log
exit=0
```

- [ ] **Step 3: the directly-touched packages, verbose, real exit code checked explicitly (never piped through `tail` alone):**

```
$ go test -count=1 ./internal/memory/... ./internal/db/... -v > /tmp/test.log 2>&1; echo "exit=$?"; grep -E "^--- (FAIL|PASS)" /tmp/test.log | grep -c PASS; grep "^--- FAIL" /tmp/test.log
exit=0
```

Expected: `exit=0`, zero `FAIL` lines, and (by name) `TestReconcileComputesImportanceScore`, `TestReconcileImportanceOverrideWins`, `TestReconcileImportanceQuarantineOnSignalError`, `TestReconcileImportanceOrderIndependent`, `TestMemory02_ReindexEquivalence`, `TestEvictReindexEquivalence`, `TestUpsertIndexNodeComputesImportance`, `TestUpsertIndexNodeImportanceOverrideWins`, `TestUpdateMemoryNodeImportanceScore`, `TestReconcileImportanceRefinesAfterDeletion`, `TestVaultOwnerEditedFilesAggregatesAcrossHistory`, `TestReconcileImportanceRefinesUnchangedLinkedNode` all present and passing.

- [ ] **Step 4: broader blast-radius check** (nothing outside `internal/memory` calls `computeNodeImportance`/`upsertIndexNode`/`reconcilePass` — both unexported — but `db.MemoryNodeRow`/`Node` are read elsewhere):

```
$ go test ./internal/inbox/... ./internal/mcp/... ./internal/daemon/... ./cmd/... > /tmp/blast.log 2>&1; echo "exit=$?"; tail -10 /tmp/blast.log
exit=0
```

- [ ] **Step 5: full suite.**

```
$ go test ./... > /tmp/full-test.log 2>&1; echo "exit=$?"; grep -c "^ok" /tmp/full-test.log; grep "^FAIL" /tmp/full-test.log
exit=0
```

Expected: `exit=0`, no `FAIL` lines.

- [ ] **Step 6: final status check — confirm nothing is left uncommitted:**

```
$ git status --short
```

Expected: clean (5d-i through 5d-iv already committed everything).

---

**Summary of 5d's new/changed files:**
- Modified: `internal/memory/index.go` (`Reconcile` reordered; `reconcilePass` gains `ownerEdited`/memoization fields and method; `refineImportance` extended; new `refineLinkedNode`), `internal/memory/importance.go` (`computeNodeImportance` signature), `internal/memory/vault.go` (new `OwnerEditedFiles`), `internal/memory/merge.go` (`upsertIndexNode`'s one-line call-site update — signature unchanged), `internal/memory/index_test.go` (three new tests), `internal/memory/vault_test.go` (one new test), `docs/inventory/memory.md` (MEM-16 addendum + changelog entry)
- Untouched (verified, not just assumed): `internal/memory/evict.go`, `internal/memory/evict_test.go`, all ~16 of `upsertIndexNode`'s Task-5b call sites (their own signature never changed)

---

## Task 5e: Second whole-branch review fixes — close the link-removal asymmetry, generalize `upsertIndexNode`'s owner-touch memoization to every batch call site

**Added post-ship, 2026-07-19 (second whole-branch code review).** Task 5d (5d-i through 5d-v) shipped and is committed on `feature/memory-phase5`. A SECOND whole-branch review, run specifically to confirm 5d's three fixes, found all three genuinely fixed — and surfaced two more real, non-blocking ("should fix") issues in the same `internal/memory/index.go`/`merge.go` machinery. Owner decision: fix both now, as a fifth follow-up quantum under the same MEM-16 contract (the 5b/5c/5d precedent: a real gap found post-hoc, folded into MEM-16 rather than spun into a new contract or a documented-only limitation).

**The two issues, read from the actual shipped (post-5d) code:**

1. **The link-removal asymmetry 5d-iii explicitly documented as a "known, accepted residual" is a real, closeable gap — and the guard test meant to catch a regression in it is currently blind to it.** `index.go`'s `refineImportance` (post-5d) only reads a touched node's NEW body's `Links()` to build its delta-refine candidate set; a link REMOVED from an edited body is invisible to it, so the old target keeps a stale, too-HIGH `importance_score` until its own file next changes or some other touched node happens to link to it. A second, worse vector: `Reconcile`'s deletion loop removes a node's file (and index row) entirely — that node's own outgoing links vanish with it, but nothing refines ITS former link targets either. Since a later slice will use this score for retrieval ranking, a stale-too-HIGH score is the harmful direction (over-surfacing something no longer well-connected). Compounding this: `TestMemory02_ReindexEquivalence`'s pass-3 "touch A once more" step is redundant (5d-iii's delta-refine already gets A to the right value in pass 2, when C's link first lands) and its redundancy means the guard has never actually exercised a link-removal scenario — a regression here would currently go undetected.
2. **`upsertIndexNode`'s owner-touch signal still pays a full per-node git walk inside batch loops.** 5d-ii's design assumed `upsertIndexNode`'s call sites were single-node writes with no batch to memoize over, so it left all ~16 of them calling the un-memoized `v.OwnerEdited` (a bare method value) directly. Reading every real call site (not just the reviewer's named seven) shows this assumption fails almost everywhere: `aging.go`'s `AgeEpisodes`, `action_ingest.go`'s `ingestInteractions`, `beliefs.go`'s `ReviseBeliefs`, `calendar_ingest.go`'s `commitCalendarNodes`, `concepts.go`'s `PromoteConcepts`, `dedupe.go`'s `DedupeEpisodes` (via repeated `unionProvenance` calls within one run), `evict.go`'s `EvictEpisodes` (both its tombstone and rollup loops), `gmail_extract.go`'s `extractGmailBatch`, `ingest.go`'s `IngestSituations`, `merge.go`'s own `Merge` (its `stub`/`winner` pair), `mirror_ingest.go`'s `commitMirrorNodes`, `pipeline.go`'s `extractBatch`, `reflect.go`'s `Reflect`, `rewrite.go`'s `RewriteEntityPages`, and `seed.go`'s `SeedEntities` ALL loop over more than one node calling `upsertIndexNode` (or, for `dedupe.go`, calling a helper that calls it) within a single invocation. In practice essentially every production call site qualifies — the "single-node call site with nothing to memoize" case 5d-ii's design note describes does not exist in today's code.

**Fix order:** 5e-i (issue 1, the code fix) → 5e-ii (strengthen the `TestMemory02_ReindexEquivalence` fixture that 5e-i's fix makes meaningfully testable) → 5e-iii (issue 2, batch memoization — independent of 5e-i/5e-ii, touches a different signal path, ordered last only because it is the larger diff) → 5e-iv (docs) → 5e-v (final verification).

**Depends on:** Task 5d (5d-i through 5d-v, already committed). **Blocks:** nothing new in this plan (terminal follow-up) — supersedes 5d-v's final verification; 5e-v below re-runs the full gate.

**Global constraints carried forward, unchanged:** `EvictEpisodes`'s own retention-SCORING logic (`RetentionScore`, the per-candidate loop computing `score := RetentionScore(...)`) is untouched by both fixes and never reads `memory_nodes.importance_score` — its two `upsertIndexNode` calls (writing the tombstone/rollup index mirrors, a DIFFERENT concern) DO get 5e-iii's batch-memoization fix, since those are ordinary `upsertIndexNode` call sites like any other. No new config gate, no retrieval/chat/MCP/prompt change — still foundation-only. A signal-lookup error anywhere in the new code follows the same log-and-continue-keep-prior-value policy already established everywhere in this contract. Every already-approved test named in 5d's prompt, plus 5d's own three new tests (`TestReconcileImportanceRefinesAfterDeletion`, `TestVaultOwnerEditedFilesAggregatesAcrossHistory`, `TestReconcileImportanceRefinesUnchangedLinkedNode`), must still pass unmodified — 5e-v's final run checks all twelve by name.

---

### 5e-i: Close the link-removal asymmetry — capture prior/doomed bodies' outgoing links before they vanish

**Depends on:** Task 5d (5d-iii's `refineImportance`/`refineLinkedNode`, already shipped). **Blocks:** 5e-ii (its fixture change proves this fix), 5e-iv.

**Files:**
- Modify: `internal/db/memory.go` — new `GetMemoryNodeBody` (inserted after `UpdateMemoryNodeImportanceScore`, before `SearchMemoryFTS`)
- Modify: `internal/memory/index.go` — `reconcilePass` struct (new `priorLinkTargets` field), `file()` (capture prior body before `UpsertMemoryNode`), `Reconcile`'s deletion loop (capture doomed body before `DeleteMemoryNode`), `refineImportance()` (union `priorLinkTargets` into the delta-refine candidate set)
- Test: `internal/db/memory_test.go` — new `TestGetMemoryNodeBody` (after `TestUpdateMemoryNodeImportanceScore`)
- Test: `internal/memory/index_test.go` — two new tests inserted after 5d-iii's `TestReconcileImportanceRefinesUnchangedLinkedNode`, before `TestMemory02_ReindexEquivalence`

**Interfaces:**
- Produces: `func (db *DB) GetMemoryNodeBody(id string) (string, error)` — reads `memory_fts.body` for id, `sql.ErrNoRows` when absent (the `LookupMemoryAlias` convention: bare `sql.ErrNoRows`, not wrapped, so callers can `errors.Is` it if they choose to — this task's own callers treat ANY error uniformly, see below).
- Consumes: `Node.Links() []Link` (existing, `node.go:233-239`) — called against a throwaway `Node{Body: oldBody}` for the OLD-body case, since `Links()` reads only `n.Body` and nothing else (confirmed by inspection: no other field is referenced). No new parsing helper needed — `Node{Body: s}.Links()` is the simplest correct extraction, exactly as the design note anticipated.

**Why a throwaway `Node{Body: oldBody}` rather than a new `parseLinkIDs(body string) []string` helper:** `Node.Links()`'s entire body is `for _, m := range wikiLinkRe.FindAllStringSubmatch(n.Body, -1) { ... }` — it reads `n.Body` and nothing else on `n`. Constructing `Node{Body: oldBody}` and calling `.Links()` on it is therefore exactly equivalent to a standalone function, with zero new exported surface and no duplicated regex logic.

Current `GetMemoryNodeBody`'s neighbors (`db/memory.go`, for placement context — `UpdateMemoryNodeImportanceScore` ends, then `SearchMemoryFTS` begins, unchanged):

```go
func (db *DB) UpdateMemoryNodeImportanceScore(id string, score float64) error {
	_, err := db.Exec(`UPDATE memory_nodes SET importance_score = ? WHERE id = ?`, score, id)
	if err != nil {
		return fmt.Errorf("updating importance_score for %s: %w", id, err)
	}
	return nil
}

// SearchMemoryFTS runs a full-text search over node titles and bodies, ...
```

- [ ] **Step 1: write the failing test** — append to `internal/db/memory_test.go` after `TestUpdateMemoryNodeImportanceScore` (ends line 332):

```go
// TestGetMemoryNodeBody: the new narrow FTS-body reader returns the exact
// body last upserted, and sql.ErrNoRows for an id with no FTS row — the
// contract memory's Reconcile (index.go) relies on to read a node's PRIOR
// body BEFORE UpsertMemoryNode overwrites it (whole-branch review follow-up,
// 2026-07-19, MEM-16 addendum — closing the link-removal asymmetry).
func TestGetMemoryNodeBody(t *testing.T) {
	db := openTestDB(t)

	row := memTestNode("ent_body_read", nil)
	if err := db.UpsertMemoryNode(row, "# Body\n\nSee [[ent_other]].\n", nil); err != nil {
		t.Fatalf("UpsertMemoryNode: %v", err)
	}

	body, err := db.GetMemoryNodeBody("ent_body_read")
	if err != nil {
		t.Fatalf("GetMemoryNodeBody: %v", err)
	}
	if body != "# Body\n\nSee [[ent_other]].\n" {
		t.Errorf("GetMemoryNodeBody = %q, want the exact body last upserted", body)
	}

	if _, err := db.GetMemoryNodeBody("ent_does_not_exist"); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("GetMemoryNodeBody for unknown id: err = %v, want sql.ErrNoRows", err)
	}
}
```

- [ ] **Step 2: run it — expect a build failure** (the method doesn't exist yet):

```
$ go test ./internal/db/ -run TestGetMemoryNodeBody -v
# watchtower/internal/db [watchtower/internal/db.test]
./memory_test.go:XXX: db.GetMemoryNodeBody undefined (type *DB has no field or method GetMemoryNodeBody)
FAIL	watchtower/internal/db [build failed]
```

- [ ] **Step 3: add `GetMemoryNodeBody`** to `internal/db/memory.go`, between `UpdateMemoryNodeImportanceScore` and `SearchMemoryFTS`:

```go
// GetMemoryNodeBody returns the raw body last indexed for id from
// memory_fts — the pre-edit body a caller must read BEFORE overwriting it via
// UpsertMemoryNode, e.g. to diff a node's OLD outgoing links against its NEW
// ones (internal/memory/index.go's Reconcile, MEM-16: closing the
// link-removal asymmetry). Returns sql.ErrNoRows when the node has no FTS row
// (never indexed, or already deleted) — the LookupMemoryAlias convention.
func (db *DB) GetMemoryNodeBody(id string) (string, error) {
	var body string
	err := db.QueryRow(`SELECT body FROM memory_fts WHERE id = ?`, id).Scan(&body)
	if errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if err != nil {
		return "", fmt.Errorf("getting memory fts body for %s: %w", id, err)
	}
	return body, nil
}
```

- [ ] **Step 4: run it — expect green:**

```
$ go test ./internal/db/ -run TestGetMemoryNodeBody -v
=== RUN   TestGetMemoryNodeBody
--- PASS: TestGetMemoryNodeBody (0.01s)
PASS
ok  	watchtower/internal/db	0.2s
```

- [ ] **Step 5: commit:**

```
$ git add internal/db/memory.go internal/db/memory_test.go
$ git commit -m "feat(memory): add GetMemoryNodeBody, the pre-overwrite FTS body reader (MEM-16 prep)

A caller diffing a node's OLD vs NEW outgoing links (closing the
link-removal importance asymmetry) needs the body memory_fts held BEFORE
UpsertMemoryNode replaces it. New narrow reader, LookupMemoryAlias's
sql.ErrNoRows convention. Guarded by TestGetMemoryNodeBody."
```

Now the core `index.go` fix.

Current `reconcilePass` struct (`index.go` lines 107-129, post-5d):

```go
type reconcilePass struct {
	v        *Vault
	database *db.DB
	logf     func(string, ...any)
	indexed  map[string]db.MemoryNodeRow
	onDisk   map[string]bool
	now      string
	stats    *Stats
	touched  []touchedNode

	// ownerEditedFiles/ownerEditedErr/ownerEditedLoaded memoize
	// v.OwnerEditedFiles() lazily: computed at most ONCE per Reconcile call,
	// on the first node that actually needs the owner-touch signal (a fully
	// unchanged pass — the common case — never pays for it at all), and
	// reused by every subsequent computeNodeImportance call this pass
	// instead of each paying its own full-history git-log walk (whole-branch
	// review follow-up, added 2026-07-18, MEM-16).
	ownerEditedFiles  map[string]bool
	ownerEditedErr    error
	ownerEditedLoaded bool
}
```

- [ ] **Step 6: write the two failing tests** — insert into `internal/memory/index_test.go` immediately after 5d-iii's `TestReconcileImportanceRefinesUnchangedLinkedNode`, before `TestMemory02_ReindexEquivalence`:

```go
// TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit: a touched node's body
// EDIT that REMOVES a link must still cause the old link target's
// importance_score to drop — closing the link-removal asymmetry 5d-iii's
// version of refineImportance left open (only the NEW body's current links
// were read there). Reconcile now also captures the PRIOR body's outgoing
// links (read from memory_fts, before UpsertMemoryNode overwrites it) and
// unions them into the same delta-refine candidate set — recomputation is
// idempotent, so unioning in a link that's still present costs nothing extra
// (second whole-branch review follow-up, 2026-07-19, MEM-16 addendum).
func TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RM1", "entity", "Target")
	linker := linkingEntity(t, "ent_01ARZ3NDEKTSV4RRFFQ69G5RM2", "Linker", target.ID)
	writeNodes(t, v, target, linker)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	baseline, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	require.Equal(t, 1.0, baseline.ImportanceScore, "sanity: linker gives target a link-in")

	// Edit the linker's body to REMOVE its link to target — target's OWN
	// file is untouched, so without reading the linker's PRIOR body this
	// pass would never know to re-refine target.
	linker.Body = "# Linker\n\nNo more link.\n"
	writeNodes(t, v, linker)
	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, Stats{Updated: 1}, stats, "sanity: only the linker is reparsed this pass")

	row, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	assert.Zero(t, row.ImportanceScore,
		"target's importance must drop once its only linker's body no longer links to it")
}

// TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion: deleting a node's
// FILE removes its outgoing links too — the SECOND vector of the same
// asymmetry (a node whose only linker's FILE disappeared entirely was also
// never re-refined). Reconcile now captures the doomed node's body (from
// memory_fts) BEFORE calling DeleteMemoryNode, unioning its outgoing links
// into the same delta-refine candidate set (second whole-branch review
// follow-up, 2026-07-19, MEM-16 addendum).
func TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion(t *testing.T) {
	v, d := newTestVault(t), newTestDB(t)

	target := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5RM3", "entity", "Target")
	linker := linkingEntity(t, "ent_01ARZ3NDEKTSV4RRFFQ69G5RM4", "Linker", target.ID)
	writeNodes(t, v, target, linker)
	_, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	baseline, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	require.Equal(t, 1.0, baseline.ImportanceScore, "sanity: linker gives target a link-in")

	// Delete the linker's FILE entirely — target's own file is untouched.
	require.NoError(t, os.Remove(filepath.Join(v.path, "entities", linker.ID+".md")))
	stats, err := Reconcile(v, d, t.Logf)
	require.NoError(t, err)
	assert.Equal(t, Stats{Deleted: 1}, stats, "sanity: only the linker's file is gone, target is not reparsed")

	row, err := d.GetMemoryNode(target.ID)
	require.NoError(t, err)
	assert.Zero(t, row.ImportanceScore,
		"target's importance must drop once its only linker's FILE — and its outgoing links — are gone")
}
```

- [ ] **Step 7: run them — expect both assertion failures that prove the gap:**

```
$ go test ./internal/memory/ -run 'TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit|TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion' -v
=== RUN   TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit
    index_test.go:XXX:
        	Error Trace:	.../index_test.go:XXX
        	Error:      	Should be zero, but was 1
        	Test:       	TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit
        	Messages:   	target's importance must drop once its only linker's body no longer links to it
--- FAIL: TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit (0.02s)
=== RUN   TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion
    index_test.go:XXX:
        	Error Trace:	.../index_test.go:XXX
        	Error:      	Should be zero, but was 1
        	Test:       	TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion
        	Messages:   	target's importance must drop once its only linker's FILE — and its outgoing links — are gone
--- FAIL: TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion (0.02s)
FAIL
```

- [ ] **Step 8: extend `reconcilePass`** with a new field, right after `touched`:

```go
type reconcilePass struct {
	v        *Vault
	database *db.DB
	logf     func(string, ...any)
	indexed  map[string]db.MemoryNodeRow
	onDisk   map[string]bool
	now      string
	stats    *Stats
	touched  []touchedNode

	// priorLinkTargets collects node ids a REMOVED link used to point at:
	// from an edited touched node's PRIOR body (captured in file(), read
	// from memory_fts before UpsertMemoryNode overwrites it) and from a
	// deleted node's body (captured in Reconcile's deletion loop, read
	// before DeleteMemoryNode drops it). Unioned into refineImportance's
	// delta-refine candidate set alongside the NEW-body link targets 5d-iii
	// already collects, so both a link ADDED and a link REMOVED cause the
	// affected target to be recomputed — closing the asymmetry 5d-iii left
	// open as a documented residual (second whole-branch review follow-up,
	// 2026-07-19, MEM-16 addendum).
	priorLinkTargets map[string]bool

	// ownerEditedFiles/ownerEditedErr/ownerEditedLoaded memoize
	// v.OwnerEditedFiles() lazily: computed at most ONCE per Reconcile call,
	// on the first node that actually needs the owner-touch signal (a fully
	// unchanged pass — the common case — never pays for it at all), and
	// reused by every subsequent computeNodeImportance call this pass
	// instead of each paying its own full-history git-log walk (whole-branch
	// review follow-up, added 2026-07-18, MEM-16).
	ownerEditedFiles  map[string]bool
	ownerEditedErr    error
	ownerEditedLoaded bool
}
```

(5e-iii below replaces the last three fields with a shared `*ownerEditedMemo` — left untouched here so this step's diff is purely additive and isolated to issue 1.)

Update `Reconcile`'s pass literal (unchanged fields omitted) to initialize the new map:

```go
	pass := &reconcilePass{
		v:                v,
		database:         database,
		logf:             logf,
		indexed:          indexed,
		onDisk:           make(map[string]bool),
		now:              time.Now().UTC().Format(time.RFC3339),
		stats:            &stats,
		priorLinkTargets: make(map[string]bool),
	}
```

- [ ] **Step 9: capture the prior body in `file()`**, right before the `UpsertMemoryNode` call (current code for context — `row := db.MemoryNodeRow{...}` through `p.touched = append(...)`, unchanged except for the new block inserted directly above `row := db.MemoryNodeRow{`):

```go
	importance, err := computeNodeImportance(p.database, p.ownerEdited, n, rel)
	if err != nil {
		p.quarantine(rel, fmt.Errorf("computing importance: %w", err))
		return nil
	}

	if wasIndexed {
		// Capture the PRIOR body's outgoing links before UpsertMemoryNode
		// (below) overwrites the FTS row — a link REMOVED by this edit must
		// still cause its old target to be delta-refined. A read failure
		// only narrows this pass's delta-refine candidate set for this one
		// file; it does not quarantine the file or abort Reconcile (the
		// file's own index write proceeds normally either way) — the same
		// log-and-continue-keep-prior-value policy this package already
		// applies to every other signal-lookup error.
		if oldBody, berr := p.database.GetMemoryNodeBody(id); berr != nil {
			p.logf("memory: reconcile: reading prior body for %s failed (link-removal delta-refine narrowed for this edit): %v", id, berr)
		} else {
			for _, link := range (Node{Body: oldBody}).Links() {
				p.priorLinkTargets[link.ID] = true
			}
		}
	}

	row := db.MemoryNodeRow{
		ID:              n.ID,
		Type:            n.Type,
		Tier:            n.Tier,
		Status:          n.Status,
		RedirectTo:      n.RedirectTo,
		Title:           n.Title,
		Path:            rel,
		ContentHash:     hash,
		IndexedAt:       p.now,
		Subject:         n.Subject,
		Confidence:      n.Confidence,
		ImportanceScore: importance,
	}
	if err := p.database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, p.logf)...); err != nil {
		p.quarantine(rel, err)
		return nil
	}
	p.touched = append(p.touched, touchedNode{n: n, rel: rel})
	if wasIndexed {
		p.stats.Updated++
	} else {
		p.stats.Added++
	}
	return nil
}
```

- [ ] **Step 10: capture doomed bodies in `Reconcile`'s deletion loop**, before `database.DeleteMemoryNode`:

Current (post-5d-i, `Reconcile` lines 90-98):

```go
	for _, row := range existing {
		if pass.onDisk[row.ID] {
			continue
		}
		if err := database.DeleteMemoryNode(row.ID); err != nil {
			return stats, fmt.Errorf("memory: reconcile: %w", err)
		}
		stats.Deleted++
	}
```

New:

```go
	for _, row := range existing {
		if pass.onDisk[row.ID] {
			continue
		}
		// Capture this doomed node's OWN outgoing links before its row and
		// FTS entry vanish below — its former link targets must still be
		// delta-refined (the second vector of the same link-removal
		// asymmetry file()'s edit case closes above). A read failure only
		// narrows this pass's delta-refine set for this one deletion; the
		// deletion itself is never blocked by it.
		if oldBody, berr := database.GetMemoryNodeBody(row.ID); berr != nil {
			logf("memory: reconcile: reading body for deleted node %s failed (link-removal delta-refine narrowed for this deletion): %v", row.ID, berr)
		} else {
			for _, link := range (Node{Body: oldBody}).Links() {
				pass.priorLinkTargets[link.ID] = true
			}
		}
		if err := database.DeleteMemoryNode(row.ID); err != nil {
			return stats, fmt.Errorf("memory: reconcile: %w", err)
		}
		stats.Deleted++
	}
```

- [ ] **Step 11: union `priorLinkTargets` into `refineImportance`'s delta-refine set.**

Current `refineImportance` (post-5d-iii, for the relevant tail — the per-touched recompute loop above is unchanged):

```go
	linkTargets := make(map[string]bool)
	for _, tn := range p.touched {
		for _, link := range tn.n.Links() {
			if touchedIDs[link.ID] {
				continue
			}
			linkTargets[link.ID] = true
		}
	}
	for id := range linkTargets {
		if err := p.refineLinkedNode(id); err != nil {
			return err
		}
	}
	return nil
}
```

New:

```go
	linkTargets := make(map[string]bool)
	for _, tn := range p.touched {
		for _, link := range tn.n.Links() {
			if touchedIDs[link.ID] {
				continue
			}
			linkTargets[link.ID] = true
		}
	}
	// Union in every id a REMOVED link (from an edit's prior body, or from a
	// deleted node's body) used to point at — recomputation is idempotent,
	// so a target already in linkTargets (a link that's still present) costs
	// nothing extra to add again. Closes the asymmetry a link ADDITION alone
	// left open (second whole-branch review follow-up, 2026-07-19, MEM-16
	// addendum).
	for id := range p.priorLinkTargets {
		if touchedIDs[id] {
			continue
		}
		linkTargets[id] = true
	}
	for id := range linkTargets {
		if err := p.refineLinkedNode(id); err != nil {
			return err
		}
	}
	return nil
}
```

Also update `refineImportance`'s doc comment: replace its "Known residual asymmetry: a link REMOVED..." sentence (the one 5d-iii wrote) with:

```go
// Also delta-refines every node a REMOVED link used to point at: file()
// captures an edited touched node's PRIOR body's outgoing links (read from
// memory_fts before UpsertMemoryNode overwrites it) and Reconcile's deletion
// loop captures a doomed node's own outgoing links (read before
// DeleteMemoryNode drops it) — both unioned into the same candidate set
// below, closing the asymmetry a prior version of this pass left as a
// documented residual (second whole-branch review follow-up, 2026-07-19,
// MEM-16 addendum). Still one hop only: a target's OWN further link
// neighbors are never chased.
```

- [ ] **Step 12: run the two new tests — expect green:**

```
$ go test ./internal/memory/ -run 'TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit|TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion' -v
=== RUN   TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit
--- PASS: TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit (0.02s)
=== RUN   TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion
--- PASS: TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion (0.02s)
PASS
ok  	watchtower/internal/memory	0.3s
```

- [ ] **Step 13: confirm no regression in every 5d guard, then commit:**

```
$ go test ./internal/memory/... ./internal/db/... -run 'TestReconcileComputesImportanceScore|TestReconcileImportanceOverrideWins|TestReconcileImportanceQuarantineOnSignalError|TestReconcileImportanceOrderIndependent|TestMemory02_ReindexEquivalence|TestEvictReindexEquivalence|TestUpsertIndexNodeComputesImportance|TestUpsertIndexNodeImportanceOverrideWins|TestUpdateMemoryNodeImportanceScore|TestReconcileImportanceRefinesAfterDeletion|TestVaultOwnerEditedFilesAggregatesAcrossHistory|TestReconcileImportanceRefinesUnchangedLinkedNode' -v 2>&1 | tail -30
--- PASS: TestReconcileComputesImportanceScore (0.02s)
--- PASS: TestReconcileImportanceOverrideWins (0.01s)
--- PASS: TestReconcileImportanceQuarantineOnSignalError (0.03s)
--- PASS: TestReconcileImportanceOrderIndependent (0.02s)
--- PASS: TestMemory02_ReindexEquivalence (0.03s)
--- PASS: TestEvictReindexEquivalence (0.05s)
--- PASS: TestUpsertIndexNodeComputesImportance (0.02s)
--- PASS: TestUpsertIndexNodeImportanceOverrideWins (0.01s)
--- PASS: TestUpdateMemoryNodeImportanceScore (0.01s)
--- PASS: TestReconcileImportanceRefinesAfterDeletion (0.02s)
--- PASS: TestVaultOwnerEditedFilesAggregatesAcrossHistory (0.01s)
--- PASS: TestReconcileImportanceRefinesUnchangedLinkedNode (0.02s)
PASS
ok  	watchtower/internal/memory	1.6s
ok  	watchtower/internal/db	0.6s

$ git add internal/memory/index.go internal/memory/index_test.go
$ git commit -m "fix(memory): close the link-removal importance asymmetry (second whole-branch review, MEM-16)

refineImportance's delta-refine only read a touched node's NEW body, so a
REMOVED link left its old target's importance_score stale-too-high — the
harmful direction for future retrieval ranking. Reconcile now also captures
an edited node's PRIOR body (file(), before UpsertMemoryNode overwrites the
FTS row) and a deleted node's own body (the deletion loop, before
DeleteMemoryNode) and unions their outgoing links into the same delta-refine
candidate set 5d-iii built — recomputation is idempotent so re-adding a
still-present link costs nothing. One hop only, still. Guarded by
TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit and
TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion."
```

---

### 5e-ii: Strengthen `TestMemory02_ReindexEquivalence`'s fixture to actually exercise a link removal

**Depends on:** 5e-i (the fixture change proves 5e-i's fix; it would fail against pre-5e-i code). **Blocks:** 5e-iv.

**Files:**
- Modify: `internal/memory/index_test.go` — `TestMemory02_ReindexEquivalence`'s pass 3 (lines 630-652, post-5d)

**Why this test's fixture, not a new standalone test:** `TestMemory02_ReindexEquivalence` is MEM-02's guard — its whole job is proving an incremental history and a fresh `Rebuild` converge on the SAME `memory_nodes` dump, including `importance_score`. The second review's specific finding was that THIS test's own pass-3 step ("touch A once more") is redundant given 5d-iii's delta-refine (A already reaches `LinksIn=1` in pass 2, the moment C's link to it first lands) — and that redundancy means the guard has never exercised a link REMOVAL, so a regression in 5e-i's fix would slip past MEM-02's own equivalence guard undetected. The fix is therefore to make THIS fixture actually cover a removal, not to add a parallel test that duplicates the guard's setup while leaving the original blind spot in place. (5e-i's two new dedicated tests already prove the mechanism in isolation; this step proves it specifically under MEM-02's incremental-vs-`Rebuild` lens — Task 6's precedent for "strengthen this SAME guard test's fixture" rather than adding a new one.)

Current pass 3 (`index_test.go` lines 630-652, post-5d — for context, passes 1-2 above and the final `Rebuild`/`assert.Equal` below are UNCHANGED by this step):

```go
	// Pass 3: delete B (its provenance rows must vanish with it), edit C —
	// keep its link to A alongside a surviving ## Provenance section — and
	// touch A once more (a trivial body edit) so A gets reparsed NOW THAT C's
	// link to it is already committed (pass 2): this is what makes A's
	// persisted importance_score reflect LinksIn=1 by the end of the
	// incremental history, matching what a fresh Rebuild computes from the
	// FINAL vault state.
	require.NoError(t, os.Remove(filepath.Join(v.path, "episodes", b.ID+".md")))
	c.Body = "# Q3 rollup\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5IXA]] for background.\n\n## Provenance\n" +
		"- C0AAAAAAA 1700100000.000200\n"
	a.Body = "# Alpha Prime\n\nRewritten body, revision two.\n"
	writeNodes(t, v, c, a)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	incremental := dumpIndex(t, d)
	require.Len(t, incremental.Nodes, 2, "sanity: A and C survive")
	for _, row := range incremental.Nodes {
		if row.ID == a.ID {
			require.Equal(t, 1.0, row.ImportanceScore,
				"sanity: A's persisted importance reflects C's link-in, not a trivial zero")
		}
	}

	_, err = Rebuild(v, d, t.Logf)
	require.NoError(t, err)
	rebuilt := dumpIndex(t, d)

	assert.Equal(t, incremental, rebuilt)
}
```

New pass 3 + a new pass 4 (replaces the block above through the end of the function):

```go
	// Pass 3: delete B (its provenance rows must vanish with it) and edit C —
	// keep its link to A alongside a surviving ## Provenance section. A is
	// deliberately NOT re-touched here: 5d-iii's delta-refine already brought
	// A to LinksIn=1 in pass 2, the moment C's link to A first landed —
	// re-touching A here would be redundant AND would mask whether pass 4's
	// removal below actually works (the second whole-branch review's exact
	// finding about this fixture, 2026-07-19).
	require.NoError(t, os.Remove(filepath.Join(v.path, "episodes", b.ID+".md")))
	c.Body = "# Q3 rollup\n\nSee [[ent_01ARZ3NDEKTSV4RRFFQ69G5IXA]] for background.\n\n## Provenance\n" +
		"- C0AAAAAAA 1700100000.000200\n"
	writeNodes(t, v, c)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	midpoint := dumpIndex(t, d)
	for _, row := range midpoint.Nodes {
		if row.ID == a.ID {
			require.Equal(t, 1.0, row.ImportanceScore,
				"sanity: A already reflects C's link-in without ever being re-touched itself")
		}
	}

	// Pass 4: edit C to REMOVE its link to A entirely — a link REMOVAL, not
	// just an addition. Without closing the link-removal asymmetry (5e-i),
	// A's importance_score would stay stuck at 1.0 here even though its only
	// linker no longer links to it at all — a stale-too-HIGH score, and one
	// that this guard's PRE-5e-ii fixture could never have caught (second
	// whole-branch review follow-up, MEM-16 addendum).
	c.Body = "# Q3 rollup\n\nNo more link to Alpha.\n\n## Provenance\n" +
		"- C0AAAAAAA 1700100000.000200\n"
	writeNodes(t, v, c)
	_, err = Reconcile(v, d, t.Logf)
	require.NoError(t, err)

	incremental := dumpIndex(t, d)
	require.Len(t, incremental.Nodes, 2, "sanity: A and C survive")
	for _, row := range incremental.Nodes {
		if row.ID == a.ID {
			require.Zero(t, row.ImportanceScore,
				"A's importance must drop back to 0 once C's link to it is removed — the closed link-removal asymmetry")
		}
	}

	_, err = Rebuild(v, d, t.Logf)
	require.NoError(t, err)
	rebuilt := dumpIndex(t, d)

	assert.Equal(t, incremental, rebuilt)
}
```

- [ ] **Step 1: apply the fixture change above, run it, then confirm it WOULD have failed before 5e-i by temporarily reverting 5e-i's `index.go` changes:**

```
$ go test ./internal/memory/ -run TestMemory02_ReindexEquivalence -v
=== RUN   TestMemory02_ReindexEquivalence
--- PASS: TestMemory02_ReindexEquivalence (0.03s)
PASS
ok  	watchtower/internal/memory	0.2s

$ git stash push internal/memory/index.go   # temporarily revert 5e-i's production fix only
$ go test ./internal/memory/ -run TestMemory02_ReindexEquivalence -v
=== RUN   TestMemory02_ReindexEquivalence
    index_test.go:XXX:
        	Error Trace:	.../index_test.go:XXX
        	Error:      	Should be zero, but was 1
        	Test:       	TestMemory02_ReindexEquivalence
--- FAIL: TestMemory02_ReindexEquivalence (0.02s)
FAIL
$ git stash pop   # restore 5e-i's fix
```

Expected: the second run FAILS without 5e-i's `index.go` fix (proving the strengthened fixture actually exercises the gap 5e-i closed), and the restored run is green again.

- [ ] **Step 2: full package regression check, then commit:**

```
$ go test -count=1 ./internal/memory/... ./internal/db/... -v 2>&1 | tail -20
ok  	watchtower/internal/memory	1.6s
ok  	watchtower/internal/db	0.6s

$ git add internal/memory/index_test.go
$ git commit -m "test(memory): strengthen TestMemory02_ReindexEquivalence to exercise a link removal (MEM-16 addendum)

The prior fixture's pass-3 'touch A once more' step was redundant (5d-iii's
delta-refine already reached the right value in pass 2) and its redundancy
meant this guard never exercised a link REMOVAL — a regression in the
link-removal asymmetry fix (5e-i) could have slipped past MEM-02's own
equivalence guard. Removed the redundant re-touch; added a pass 4 that
removes C's link to A and asserts A's importance_score drops to 0 in both
the incremental and rebuilt dumps."
```

---

### 5e-iii: Generalize `upsertIndexNode`'s owner-touch memoization to every genuine batch call site

**Depends on:** Task 5d (5d-ii's `computeNodeImportance(database, ownerEdited func(string)(bool,error), n, rel)` signature and `Vault.OwnerEditedFiles()`, already shipped) — independent of 5e-i/5e-ii (a different signal path: owner-touch, not links-in). **Blocks:** 5e-iv.

**Files:**
- Modify: `internal/memory/vault.go` — new `ownerEditedMemo` type + constructor (inserted after `OwnerEditedFiles`)
- Modify: `internal/memory/merge.go` — `upsertIndexNode`'s signature (`v *Vault` → `ownerEdited func(rel string) (bool, error)`); `Merge`'s call-site loop
- Modify: `internal/memory/index.go` — `reconcilePass` drops its own three `ownerEdited*` fields in favor of the shared `*ownerEditedMemo`; `ownerEdited` method becomes a one-line delegate
- Modify every genuine batch call site — `aging.go` (`AgeEpisodes`), `action_ingest.go` (`ingestInteractions`), `beliefs.go` (`ReviseBeliefs`), `calendar_ingest.go` (`commitCalendarNodes`), `concepts.go` (`PromoteConcepts`), `dedupe.go` (`DedupeEpisodes`/`unionProvenance` — signature threaded), `evict.go` (`EvictEpisodes`), `gmail_extract.go` (`extractGmailBatch`), `ingest.go` (`IngestSituations`), `mirror_ingest.go` (`commitMirrorNodes`), `pipeline.go` (`extractBatch`), `reflect.go` (`Reflect`), `rewrite.go` (`RewriteEntityPages`), `seed.go` (`SeedEntities`)
- Test: `internal/memory/vault_test.go` — new `TestOwnerEditedMemoCachesAcrossLookups` (after `TestVaultOwnerEditedFilesAggregatesAcrossHistory`)
- Test: `internal/memory/merge_test.go` — update `TestUpsertIndexNodeComputesImportance`/`TestUpsertIndexNodeImportanceOverrideWins`'s direct `upsertIndexNode` calls (lines 211, 227) to the new signature

**Interfaces:**
- Produces: `type ownerEditedMemo struct{...}`, `func newOwnerEditedMemo(v *Vault) *ownerEditedMemo`, `func (m *ownerEditedMemo) lookup(rel string) (bool, error)` — a single small, reusable "memoize one `v.OwnerEditedFiles()` call across one function invocation" helper, generalizing the pattern 5d-ii built ad hoc inside `reconcilePass`. `reconcilePass` itself is refactored to USE this shared type (not a second parallel implementation) so there is exactly one memoization implementation in the package.
- **Breaking change:** `upsertIndexNode`'s second parameter changes from `v *Vault` to `ownerEdited func(rel string) (bool, error)` — mirroring `computeNodeImportance`'s own shape (5d-ii). `unionProvenance` (`dedupe.go`) gains the same parameter, threaded from its one caller, `DedupeEpisodes`.

**Why every call site turns out to need the batch fix, not just the reviewer's named seven:** grepping `upsertIndexNode(` (`grep -rn "upsertIndexNode(" internal/memory/*.go`) surfaces 16 production call sites (plus 2 direct test calls in `merge_test.go`, unaffected by this design question). Reading each enclosing function in full:

| File / function | Loops over > 1 node calling `upsertIndexNode` in one invocation? |
|---|---|
| `aging.go` `AgeEpisodes` | Yes — `for _, n := range nodes` over every aged episode this run |
| `action_ingest.go` `ingestInteractions` | Yes — `for _, n := range nodes` over every annotated situation mirror |
| `beliefs.go` `ReviseBeliefs` | Yes — `for _, n := range nodes` over every applied belief op |
| `calendar_ingest.go` `commitCalendarNodes` | Yes — `for _, n := range nodes` over every dirty calendar/series entity |
| `concepts.go` `PromoteConcepts` | Yes — `for _, n := range nodes` over every newly-created concept entity |
| `dedupe.go` `DedupeEpisodes` (via `unionProvenance`) | Yes — indirectly: `unionProvenance` itself writes exactly one node per call, but `DedupeEpisodes`'s own nested merge loop can call it many times in one run |
| `evict.go` `EvictEpisodes` | Yes — TWO loops, over `tombstones` and over `order` (rollups) |
| `gmail_extract.go` `extractGmailBatch` | Yes — `for _, n := range nodes` over every built episode in the batch |
| `ingest.go` `IngestSituations` | Yes — `for _, n := range toWrite` over every situation episode + linked entity this run |
| `merge.go` `Merge` | Yes — `for _, n := range []Node{stub, winner}`, exactly 2 nodes every call — a genuine batch-of-2 the original 5d-ii design note did not call out |
| `mirror_ingest.go` `commitMirrorNodes` | Yes — `for _, n := range nodes` over every built/refreshed mirror |
| `pipeline.go` `extractBatch` | Yes — `for _, n := range nodes` over every built episode in the batch (the reviewer's named example) |
| `reflect.go` `Reflect` | Yes — `for _, nd := range noteNodes` over every entity that got a reflection note |
| `rewrite.go` `RewriteEntityPages` | Yes — `for _, n := range nodes` over every rewritten entity page |
| `seed.go` `SeedEntities` | Yes — `for _, n := range nodes` over every seeded entity |

Every production call site qualifies. The "isolated single-node write, no batch to memoize over" case 5d-ii's design note assumed for `upsertIndexNode`'s callers turns out not to exist anywhere in the package today — `Merge`'s own 2-node loop is the smallest instance, and even it pays one avoidable git walk per call. The fix therefore threads a memoized lookup through literally every production caller; there is no longer a caller left that passes `v.OwnerEdited` (the bare method value) directly.

**Design — one shared type, no over-engineering:** `ownerEditedMemo` is deliberately minimal: a struct holding the source `*Vault`, the loaded map, a cached error, and a loaded flag — exactly `reconcilePass`'s own three ad hoc fields, lifted out and given one constructor + one method so every batch function can allocate its own instance (`mem := newOwnerEditedMemo(v)`) at the top of its node-writing block and pass `mem.lookup` to every `upsertIndexNode` call inside it. This is per-function-call memoization, not a package- or run-wide cache: two separate calls to, say, `extractGmailBatch` within one Gmail-extraction run each pay their own walk — a smaller win than a whole-run cache would give, but consistent with "a small closure per function suffices" and with keeping this change's blast radius to the exact shape 5d-ii already established for `Reconcile`, not a new cross-cutting cache lifetime to reason about.

Current `OwnerEditedFiles` (`vault.go`, unchanged, for placement context — the new type is inserted directly after it):

```go
func (v *Vault) OwnerEditedFiles() (map[string]bool, error) {
	iter, err := v.repo.Log(&git.LogOptions{})
	if err != nil {
		return nil, fmt.Errorf("memory: owner-edited files log: %w", err)
	}
	defer iter.Close()

	files := make(map[string]bool)
	err = iter.ForEach(func(c *object.Commit) error {
		if !strings.HasPrefix(c.Message, "memory(owner-edit)") {
			return nil
		}
		stats, serr := c.Stats()
		if serr != nil {
			return serr
		}
		for _, fs := range stats {
			files[fs.Name] = true
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("memory: owner-edited files walk: %w", err)
	}
	return files, nil
}
```

- [ ] **Step 1: write the failing test** — append to `internal/memory/vault_test.go` after `TestVaultOwnerEditedFilesAggregatesAcrossHistory` (5d-ii's test):

```go
// TestOwnerEditedMemoCachesAcrossLookups: ownerEditedMemo loads
// OwnerEditedFiles() at most ONCE and reuses it for every subsequent lookup
// in the same instance — proven by committing a NEW owner-edit AFTER the
// memo's first lookup and showing a second lookup on the SAME memo instance
// still does not see it (a fresh, uncached lookup against the vault would).
// This is the shared helper every genuine batch upsertIndexNode caller uses
// instead of reconcilePass's own ad hoc fields (second whole-branch review
// follow-up, 2026-07-19, MEM-16 addendum).
func TestOwnerEditedMemoCachesAcrossLookups(t *testing.T) {
	v := newTestVault(t)

	a := vaultTestNode("ent_01ARZ3NDEKTSV4RRFFQ69G5MO1", "entity", "Alpha")
	b := vaultTestNode("ep_01ARZ3NDEKTSV4RRFFQ69G5MO2", "episode", "Beta")
	_, err := v.WriteNodes([]Node{a, b}, CommitMsg{Op: "seed", Summary: "seed", Cause: "seed", NodeIDs: []string{a.ID, b.ID}})
	require.NoError(t, err)

	// Owner edits A only, BEFORE the memo is created.
	require.NoError(t, os.WriteFile(filepath.Join(v.path, "entities", a.ID+".md"),
		append(a.Render(), []byte("\nhand edit\n")...), 0o644))
	made, err := v.CommitOwnerEdits()
	require.NoError(t, err)
	require.True(t, made)

	mem := newOwnerEditedMemo(v)
	gotA, err := mem.lookup("entities/" + a.ID + ".md")
	require.NoError(t, err)
	assert.True(t, gotA, "A's owner edit predates the memo — must be seen on first lookup")
	gotB, err := mem.lookup("episodes/" + b.ID + ".md")
	require.NoError(t, err)
	assert.False(t, gotB, "B has no owner edit yet")

	// A SECOND owner edit, of B, AFTER the memo already loaded.
	require.NoError(t, os.WriteFile(filepath.Join(v.path, "episodes", b.ID+".md"),
		append(b.Render(), []byte("\nhand edit two\n")...), 0o644))
	made, err = v.CommitOwnerEdits()
	require.NoError(t, err)
	require.True(t, made)

	gotB, err = mem.lookup("episodes/" + b.ID + ".md")
	require.NoError(t, err)
	assert.False(t, gotB, "the SAME memo instance must stay cached — a fresh lookup would see B's new owner edit, a memoized one must not")

	// A brand-new memo over the SAME vault DOES see it — proving the miss
	// above is memoization, not a bug in OwnerEditedFiles itself.
	fresh := newOwnerEditedMemo(v)
	gotB, err = fresh.lookup("episodes/" + b.ID + ".md")
	require.NoError(t, err)
	assert.True(t, gotB, "sanity: a FRESH memo over the same vault does see B's owner edit")
}
```

- [ ] **Step 2: run it — expect a build failure** (the type doesn't exist yet):

```
$ go test ./internal/memory/ -run TestOwnerEditedMemoCachesAcrossLookups -v
# watchtower/internal/memory [watchtower/internal/memory.test]
./vault_test.go:XXX: undefined: newOwnerEditedMemo
FAIL	watchtower/internal/memory [build failed]
```

- [ ] **Step 3: add `ownerEditedMemo` to `vault.go`**, right after `OwnerEditedFiles`:

```go
// ownerEditedMemo lazily memoizes ONE Vault.OwnerEditedFiles() call, reused
// by every upsertIndexNode call made within a single batch-writing function
// invocation — the reconcilePass.ownerEdited pattern (Task 5d-ii),
// generalized so every production caller that writes more than one node per
// call gets it, not just Reconcile's bulk pass (second whole-branch review
// follow-up, 2026-07-19, MEM-16 addendum: every real upsertIndexNode call
// site turns out to loop over more than one node). A load failure is cached
// too, so every subsequent lookup in the same batch fails the same way
// instead of repeating a failing walk — each caller already handles the
// error via its existing log-and-continue/quarantine path.
type ownerEditedMemo struct {
	v      *Vault
	files  map[string]bool
	err    error
	loaded bool
}

// newOwnerEditedMemo returns a fresh memo scoped to ONE batch-writing call.
// Constructing it does no I/O — the walk happens lazily, on the first
// lookup — so a batch that ends up writing zero nodes never pays for it.
func newOwnerEditedMemo(v *Vault) *ownerEditedMemo {
	return &ownerEditedMemo{v: v}
}

// lookup resolves the owner-touch signal for rel, loading
// v.OwnerEditedFiles() at most once per memo instance. Pass m.lookup wherever
// computeNodeImportance (via upsertIndexNode) needs its
// ownerEdited func(string) (bool, error) parameter.
func (m *ownerEditedMemo) lookup(rel string) (bool, error) {
	if !m.loaded {
		m.files, m.err = m.v.OwnerEditedFiles()
		m.loaded = true
	}
	if m.err != nil {
		return false, m.err
	}
	return m.files[rel], nil
}
```

- [ ] **Step 4: run it — expect green:**

```
$ go test ./internal/memory/ -run TestOwnerEditedMemoCachesAcrossLookups -v
=== RUN   TestOwnerEditedMemoCachesAcrossLookups
--- PASS: TestOwnerEditedMemoCachesAcrossLookups (0.02s)
PASS
ok  	watchtower/internal/memory	0.2s
```

- [ ] **Step 5: refactor `reconcilePass` to use the shared type instead of its own three fields.**

Current (post-5e-i's Step 8):

```go
	priorLinkTargets map[string]bool

	// ownerEditedFiles/ownerEditedErr/ownerEditedLoaded memoize
	// v.OwnerEditedFiles() lazily: computed at most ONCE per Reconcile call,
	// on the first node that actually needs the owner-touch signal (a fully
	// unchanged pass — the common case — never pays for it at all), and
	// reused by every subsequent computeNodeImportance call this pass
	// instead of each paying its own full-history git-log walk (whole-branch
	// review follow-up, added 2026-07-18, MEM-16).
	ownerEditedFiles  map[string]bool
	ownerEditedErr    error
	ownerEditedLoaded bool
}
```

New:

```go
	priorLinkTargets map[string]bool

	// ownerMemo lazily memoizes v.OwnerEditedFiles() (ownerEditedMemo,
	// vault.go) — Reconcile's own instance of the same shared per-call
	// memoization every genuine batch upsertIndexNode caller now uses
	// (second whole-branch review follow-up, 2026-07-19, MEM-16 addendum:
	// this used to be three ad hoc fields on reconcilePass alone).
	ownerMemo *ownerEditedMemo
}
```

Current `ownerEdited` method:

```go
func (p *reconcilePass) ownerEdited(rel string) (bool, error) {
	if !p.ownerEditedLoaded {
		p.ownerEditedFiles, p.ownerEditedErr = p.v.OwnerEditedFiles()
		p.ownerEditedLoaded = true
	}
	if p.ownerEditedErr != nil {
		return false, p.ownerEditedErr
	}
	return p.ownerEditedFiles[rel], nil
}
```

New:

```go
// ownerEdited is reconcilePass's owner-touch signal, passed to
// computeNodeImportance as its ownerEdited func(rel string) (bool, error)
// parameter — a thin delegate to the shared ownerEditedMemo (vault.go),
// scoped to this one Reconcile call exactly as before this refactor.
func (p *reconcilePass) ownerEdited(rel string) (bool, error) {
	return p.ownerMemo.lookup(rel)
}
```

Update `Reconcile`'s pass literal to construct the memo instead of leaving the removed fields to zero-initialize:

```go
	pass := &reconcilePass{
		v:                v,
		database:         database,
		logf:             logf,
		indexed:          indexed,
		onDisk:           make(map[string]bool),
		now:              time.Now().UTC().Format(time.RFC3339),
		stats:            &stats,
		priorLinkTargets: make(map[string]bool),
		ownerMemo:        newOwnerEditedMemo(v),
	}
```

- [ ] **Step 6: change `upsertIndexNode`'s signature** in `merge.go`:

Current (`merge.go` lines 134-165):

```go
// upsertIndexNode mirrors a just-written node into the SQLite index, hashing
// the same rendered bytes that WriteNodes put on disk (so a later Reconcile
// sees the file as unchanged).
func upsertIndexNode(database *db.DB, v *Vault, n Node, indexedAt string) error {
	rel, err := nodeRelPath(n.ID)
	if err != nil {
		return err
	}
	importance, err := computeNodeImportance(database, v.OwnerEdited, n, rel)
	if err != nil {
		return fmt.Errorf("memory: computing importance for %s: %w", n.ID, err)
	}
	sum := sha256.Sum256(n.Render())
	row := db.MemoryNodeRow{
		ID:              n.ID,
		Type:            n.Type,
		Tier:            n.Tier,
		Status:          n.Status,
		RedirectTo:      n.RedirectTo,
		Title:           n.Title,
		Path:            rel,
		ContentHash:     hex.EncodeToString(sum[:]),
		IndexedAt:       indexedAt,
		Subject:         n.Subject,
		Confidence:      n.Confidence,
		ImportanceScore: importance,
	}
	if err := database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, nil)...); err != nil {
		return fmt.Errorf("memory: index %s: %w", n.ID, err)
	}
	return nil
}
```

New:

```go
// upsertIndexNode mirrors a just-written node into the SQLite index, hashing
// the same rendered bytes that WriteNodes put on disk (so a later Reconcile
// sees the file as unchanged). ownerEdited resolves the owner-touch signal
// for computeNodeImportance: every real caller of this function loops over
// more than one node per invocation (second whole-branch review follow-up,
// 2026-07-19, MEM-16 addendum — the "single-node, nothing to memoize" case
// 5d-ii's design assumed does not exist in production code), so every caller
// passes a per-call ownerEditedMemo's lookup method, never v.OwnerEdited
// directly.
func upsertIndexNode(database *db.DB, ownerEdited func(rel string) (bool, error), n Node, indexedAt string) error {
	rel, err := nodeRelPath(n.ID)
	if err != nil {
		return err
	}
	importance, err := computeNodeImportance(database, ownerEdited, n, rel)
	if err != nil {
		return fmt.Errorf("memory: computing importance for %s: %w", n.ID, err)
	}
	sum := sha256.Sum256(n.Render())
	row := db.MemoryNodeRow{
		ID:              n.ID,
		Type:            n.Type,
		Tier:            n.Tier,
		Status:          n.Status,
		RedirectTo:      n.RedirectTo,
		Title:           n.Title,
		Path:            rel,
		ContentHash:     hex.EncodeToString(sum[:]),
		IndexedAt:       indexedAt,
		Subject:         n.Subject,
		Confidence:      n.Confidence,
		ImportanceScore: importance,
	}
	if err := database.UpsertMemoryNode(row, n.Body, n.Aliases, provenanceRows(n, nil)...); err != nil {
		return fmt.Errorf("memory: index %s: %w", n.ID, err)
	}
	return nil
}
```

- [ ] **Step 7: update every production call site.** Each gets a one-line `mem := newOwnerEditedMemo(v)` (or `p.vault`) inserted immediately before its node-writing loop, and its `upsertIndexNode(..., v, ...)` / `upsertIndexNode(..., p.vault, ...)` calls become `upsertIndexNode(..., mem.lookup, ...)`. Every quoted "current" block below is verbatim from the actual post-5d source (comments included).

`merge.go`'s `Merge` (current loop, lines 75-81):

```go
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range []Node{stub, winner} {
		if err := upsertIndexNode(database, v, n, now); err != nil {
			return err
		}
	}
	return nil
}
```

New:

```go
	now := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(v)
	for _, n := range []Node{stub, winner} {
		if err := upsertIndexNode(database, mem.lookup, n, now); err != nil {
			return err
		}
	}
	return nil
}
```

`aging.go`'s `AgeEpisodes` (current tail, lines 75-81):

```go
	nowStr := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(database, v, n, nowStr); err != nil {
			return aged, err
		}
	}
	return aged, nil
}
```

New:

```go
	nowStr := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(v)
	for _, n := range nodes {
		if err := upsertIndexNode(database, mem.lookup, n, nowStr); err != nil {
			return aged, err
		}
	}
	return aged, nil
}
```

`concepts.go`'s `PromoteConcepts` (current inner block, lines 89-94):

```go
		now := time.Now().UTC().Format(time.RFC3339)
		for _, n := range nodes {
			if err := upsertIndexNode(database, v, n, now); err != nil {
				return 0, err
			}
		}
	}
```

New:

```go
		now := time.Now().UTC().Format(time.RFC3339)
		mem := newOwnerEditedMemo(v)
		for _, n := range nodes {
			if err := upsertIndexNode(database, mem.lookup, n, now); err != nil {
				return 0, err
			}
		}
	}
```

`seed.go`'s `SeedEntities` (current tail, lines 133-138):

```go
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(database, v, n, now); err != nil {
			return 0, err
		}
	}
	return len(nodes), nil
}
```

New:

```go
	now := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(v)
	for _, n := range nodes {
		if err := upsertIndexNode(database, mem.lookup, n, now); err != nil {
			return 0, err
		}
	}
	return len(nodes), nil
}
```

`ingest.go`'s `IngestSituations` (current inner block, lines 164-169):

```go
		now := time.Now().UTC().Format(time.RFC3339)
		for _, n := range toWrite {
			if err := upsertIndexNode(database, v, n, now); err != nil {
				return stats, err
			}
		}
	}
```

New:

```go
		now := time.Now().UTC().Format(time.RFC3339)
		mem := newOwnerEditedMemo(v)
		for _, n := range toWrite {
			if err := upsertIndexNode(database, mem.lookup, n, now); err != nil {
				return stats, err
			}
		}
	}
```

`evict.go`'s `EvictEpisodes` (current tail, lines 199-210 — its own `RetentionScore` candidate loop above, including the DIRECT `v.OwnerEdited(rel)` call at line 125, is UNTOUCHED by this step: that is a different concern, `RetentionScore`'s own live per-candidate signal, not the persisted `importance_score` this task is about):

```go
	nowStr := time.Now().UTC().Format(time.RFC3339)
	for _, t := range tombstones {
		if err := upsertIndexNode(database, v, t, nowStr); err != nil {
			return evicted, err
		}
	}
	for _, key := range order {
		if err := upsertIndexNode(database, v, *rollups[key], nowStr); err != nil {
			return evicted, err
		}
	}
	return evicted, nil
}
```

New:

```go
	nowStr := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(v)
	for _, t := range tombstones {
		if err := upsertIndexNode(database, mem.lookup, t, nowStr); err != nil {
			return evicted, err
		}
	}
	for _, key := range order {
		if err := upsertIndexNode(database, mem.lookup, *rollups[key], nowStr); err != nil {
			return evicted, err
		}
	}
	return evicted, nil
}
```

`dedupe.go`: `unionProvenance` gains the parameter, and `DedupeEpisodes` allocates ONE memo for its whole run, passed to every merge's `unionProvenance` call.

Current `DedupeEpisodes`'s `sitMirrors` load (lines 51-54), its merge-loop call site (line 102), and `unionProvenance`'s signature/tail (lines 127, 163):

```go
	sitMirrors, err := database.SituationMirrorNodeIDs()
	if err != nil {
		return 0, err
	}
```

```go
				if err := unionProvenance(v, database, eps[i].id, eps[j].id); err != nil {
					return merged, err
				}
```

```go
func unionProvenance(v *Vault, database *db.DB, winnerID, loserID string) error {
```

```go
	return upsertIndexNode(database, v, winner, time.Now().UTC().Format(time.RFC3339))
}
```

New — one memo allocated right after `sitMirrors` is loaded, threaded through:

```go
	sitMirrors, err := database.SituationMirrorNodeIDs()
	if err != nil {
		return 0, err
	}
	mem := newOwnerEditedMemo(v)
```

```go
				if err := unionProvenance(v, database, mem.lookup, eps[i].id, eps[j].id); err != nil {
					return merged, err
				}
```

```go
func unionProvenance(v *Vault, database *db.DB, ownerEdited func(rel string) (bool, error), winnerID, loserID string) error {
```

```go
	return upsertIndexNode(database, ownerEdited, winner, time.Now().UTC().Format(time.RFC3339))
}
```

`mirror_ingest.go`'s `commitMirrorNodes` (current tail, lines 166-172):

```go
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, p.vault, n, now); err != nil {
			p.logf("memory: index %s after operational mirror: %v", n.ID, err)
		}
	}
	return nil
}
```

New:

```go
	now := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(p.vault)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, mem.lookup, n, now); err != nil {
			p.logf("memory: index %s after operational mirror: %v", n.ID, err)
		}
	}
	return nil
}
```

`calendar_ingest.go`'s `commitCalendarNodes` (current tail, lines 266-272):

```go
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, p.vault, n, now); err != nil {
			p.logf("memory: index %s after calendar ingest: %v", n.ID, err)
		}
	}
	return nil
}
```

New:

```go
	now := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(p.vault)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, mem.lookup, n, now); err != nil {
			p.logf("memory: index %s after calendar ingest: %v", n.ID, err)
		}
	}
	return nil
}
```

`gmail_extract.go`'s `extractGmailBatch` (current tail, lines 329-337):

```go
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, p.vault, n, now); err != nil {
			// The vault commit stands; the index is derived and the next Reconcile
			// repairs it, so this does not fail the batch (the Slack extractor's rule).
			p.logf("memory: index %s after gmail extract: %v", n.ID, err)
		}
	}
	return len(kept), usage, nil
}
```

New:

```go
	now := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(p.vault)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, mem.lookup, n, now); err != nil {
			// The vault commit stands; the index is derived and the next Reconcile
			// repairs it, so this does not fail the batch (the Slack extractor's rule).
			p.logf("memory: index %s after gmail extract: %v", n.ID, err)
		}
	}
	return len(kept), usage, nil
}
```

`pipeline.go`'s `extractBatch` (current tail, lines 1019-1027):

```go
	now := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, p.vault, n, now); err != nil {
			// The vault commit stands; the index is derived and the next
			// Reconcile repairs it, so this does not fail the batch.
			p.logf("memory: index %s after extract: %v", n.ID, err)
		}
	}
	return len(kept), rejected, malformed, usage, nil
}
```

New:

```go
	now := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(p.vault)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, mem.lookup, n, now); err != nil {
			// The vault commit stands; the index is derived and the next
			// Reconcile repairs it, so this does not fail the batch.
			p.logf("memory: index %s after extract: %v", n.ID, err)
		}
	}
	return len(kept), rejected, malformed, usage, nil
}
```

`beliefs.go`'s `ReviseBeliefs` (current tail, lines 208-216):

```go
	nowStr := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, p.vault, n, nowStr); err != nil {
			// Index-mirror consistency: return the error so the step is recorded
			// as error; reconcile self-heals the missed mirror next run.
			return touched, rejected, capHit, usage, err
		}
	}
	return touched, rejected, capHit, usage, nil
}
```

New:

```go
	nowStr := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(p.vault)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, mem.lookup, n, nowStr); err != nil {
			// Index-mirror consistency: return the error so the step is recorded
			// as error; reconcile self-heals the missed mirror next run.
			return touched, rejected, capHit, usage, err
		}
	}
	return touched, rejected, capHit, usage, nil
}
```

`action_ingest.go`'s `ingestInteractions` (current inner block, lines 301-306):

```go
		now := time.Now().UTC().Format(time.RFC3339)
		for _, n := range nodes {
			if ierr := upsertIndexNode(p.db, p.vault, n, now); ierr != nil {
				p.logf("memory: interactions: index %s: %v", n.ID, ierr)
			}
		}
	}
```

New:

```go
		now := time.Now().UTC().Format(time.RFC3339)
		mem := newOwnerEditedMemo(p.vault)
		for _, n := range nodes {
			if ierr := upsertIndexNode(p.db, mem.lookup, n, now); ierr != nil {
				p.logf("memory: interactions: index %s: %v", n.ID, ierr)
			}
		}
	}
```

`rewrite.go`'s `RewriteEntityPages` (current tail, lines 166-174):

```go
	nowStr := time.Now().UTC().Format(time.RFC3339)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, p.vault, n, nowStr); err != nil {
			// Index-mirror consistency: return the error so the step is recorded
			// as error; reconcile self-heals the missed mirror next run.
			return rewritten, failed, usage, err
		}
	}
	return rewritten, failed, usage, nil
}
```

New:

```go
	nowStr := time.Now().UTC().Format(time.RFC3339)
	mem := newOwnerEditedMemo(p.vault)
	for _, n := range nodes {
		if err := upsertIndexNode(p.db, mem.lookup, n, nowStr); err != nil {
			// Index-mirror consistency: return the error so the step is recorded
			// as error; reconcile self-heals the missed mirror next run.
			return rewritten, failed, usage, err
		}
	}
	return rewritten, failed, usage, nil
}
```

`reflect.go`'s `Reflect` (current inner block, lines 188-193):

```go
		nowStr := time.Now().UTC().Format(time.RFC3339)
		for _, nd := range noteNodes {
			if ierr := upsertIndexNode(p.db, p.vault, nd, nowStr); ierr != nil {
				return n, flagged, dropped, usage, ierr // reconcile self-heals next run
			}
		}
	}
```

New:

```go
		nowStr := time.Now().UTC().Format(time.RFC3339)
		mem := newOwnerEditedMemo(p.vault)
		for _, nd := range noteNodes {
			if ierr := upsertIndexNode(p.db, mem.lookup, nd, nowStr); ierr != nil {
				return n, flagged, dropped, usage, ierr // reconcile self-heals next run
			}
		}
	}
```

- [ ] **Step 8: update the two direct test call sites** in `merge_test.go` (lines 211, 227):

```go
	require.NoError(t, upsertIndexNode(d, v, target, "2026-07-18T00:00:00Z"))
```

and

```go
	require.NoError(t, upsertIndexNode(d, v, n, "2026-07-18T00:00:00Z"))
```

both become (each is a single-node test call with nothing to batch — `v.OwnerEdited` as a bare method value is exactly the shape the parameter now expects, no memo needed for a lone call):

```go
	require.NoError(t, upsertIndexNode(d, v.OwnerEdited, target, "2026-07-18T00:00:00Z"))
```

and

```go
	require.NoError(t, upsertIndexNode(d, v.OwnerEdited, n, "2026-07-18T00:00:00Z"))
```

- [ ] **Step 9: build + run the full memory/db packages — expect zero regressions:**

```
$ go build ./... && go test -count=1 ./internal/memory/... ./internal/db/... -v > /tmp/test.log 2>&1; echo "exit=$?"; grep -c "^--- PASS" /tmp/test.log; grep "^--- FAIL" /tmp/test.log
exit=0
187
```

(no `FAIL` lines printed by the second grep)

- [ ] **Step 10: targeted check of every test that exercises a batch write path, by name:**

```
$ go test ./internal/memory/... -run 'TestAgeEpisodes|TestPromoteConcepts|TestSeedEntities|TestIngestSituations|TestEvict|TestDedupeEpisodes|TestReviseBeliefs|TestCommitCalendarNodes|TestExtractGmailBatch|TestExtractBatch|TestIngestInteractions|TestRewriteEntityPages|TestReflect|TestMerge|TestUpsertIndexNode|TestOwnerEditedMemoCachesAcrossLookups' -v 2>&1 | tail -80
```

Expected: every existing test in each touched file still passes (each file's own `_test.go` suite already exercises its production function's success/failure paths; this step's diff never changes behavior, only how the owner-touch signal is threaded, so no existing assertion should need updating beyond the two `merge_test.go` call sites in Step 8).

- [ ] **Step 11: commit:**

```
$ git add internal/memory/vault.go internal/memory/vault_test.go internal/memory/merge.go internal/memory/merge_test.go internal/memory/index.go internal/memory/aging.go internal/memory/action_ingest.go internal/memory/beliefs.go internal/memory/calendar_ingest.go internal/memory/concepts.go internal/memory/dedupe.go internal/memory/evict.go internal/memory/gmail_extract.go internal/memory/ingest.go internal/memory/mirror_ingest.go internal/memory/pipeline.go internal/memory/reflect.go internal/memory/rewrite.go internal/memory/seed.go
$ git commit -m "perf(memory): memoize upsertIndexNode's owner-touch signal in every batch call site (second whole-branch review, MEM-16)

5d-ii assumed upsertIndexNode's ~16 call sites were isolated single-node
writes with nothing to memoize. Reading every one shows that assumption is
wrong almost everywhere: AgeEpisodes, ingestInteractions, ReviseBeliefs,
commitCalendarNodes, PromoteConcepts, DedupeEpisodes (via unionProvenance),
EvictEpisodes (both loops), extractGmailBatch, IngestSituations, Merge (its
own stub/winner pair), commitMirrorNodes, extractBatch, Reflect,
RewriteEntityPages, and SeedEntities all loop over more than one node per
invocation. upsertIndexNode's signature now takes an
ownerEdited func(string) (bool, error) directly (computeNodeImportance's own
shape); every batch function allocates one ownerEditedMemo (new shared type,
vault.go — the reconcilePass.ownerEdited pattern generalized) before its
node-writing loop and passes its lookup method to every call inside it.
reconcilePass itself now delegates to the same shared type instead of
duplicating the memoization logic. EvictEpisodes' own RetentionScore
candidate-scoring loop (a different concern, never touches importance_score)
is untouched. Guarded by TestOwnerEditedMemoCachesAcrossLookups."
```

---

### 5e-iv: MEM-16 inventory addendum

**Depends on:** 5e-i, 5e-ii, 5e-iii (needs their final test names). **Blocks:** 5e-v.

**Files:**
- Modify: `docs/inventory/memory.md` — extend MEM-16's Observable/Why-locked paragraphs and test-guard list, add a new changelog entry above the existing 2026-07-18 entries

This task is documentation-only, extending the SAME MEM-16 contract 5b/5c/5d already extended — not a new contract number, matching the established pattern. `MEM-02`'s own text needs NO edit: with the link-removal asymmetry closed (5e-i/5e-ii), there is no longer any known residual divergence between the incremental and `Rebuild` paths for `importance_score` — MEM-02's existing blanket dump-equality claim is true again, not merely re-scoped. (Verified: the fix is one hop, symmetric with the ADD-a-link case 5d-iii already covers correctly, and `TestMemory02_ReindexEquivalence`'s strengthened fixture now exercises the removal case directly and passes.)

- [ ] **Step 1: extend the Observable line.** Current (line 257, post-5d):

```
... A whole-branch review after this contract first shipped found and fixed three more gaps, folded into this same contract rather than a new one: `Reconcile`'s importance refinement now runs strictly after that call's deletion loop (a same-pass-deleted linker was otherwise still counted); the owner-touch git-log signal is now memoized once per `Reconcile` call instead of walked fresh per node; and a node whose own file never changes now still gets its `importance_score` refreshed when some OTHER touched node's body newly links to it.
```

Append one sentence at the end:

```
A second whole-branch review (2026-07-19), run to confirm those three fixes, found them genuinely fixed and surfaced two more real, non-blocking gaps, also folded in here: the link-removal asymmetry the first review's delta-refine fix left as a documented residual is now closed (a REMOVED link — whether from an edit or from a whole-file deletion — now delta-refines its old target too), and `upsertIndexNode`'s owner-touch memoization, which the first review scoped to `Reconcile`'s bulk pass only, now covers every one of its production call sites, since every one of them turns out to loop over more than one node per invocation.
```

- [ ] **Step 2: extend the Why-locked paragraph.** Append at the end of the existing paragraph (after the second whole-branch-review sentence 5d-iv added):

```
A THIRD whole-branch review (2026-07-19), run specifically to confirm the second review's three fixes, found them genuinely fixed and surfaced two more real, non-blocking gaps in the same code. (1) The link-removal asymmetry 5d-iii explicitly documented as an accepted residual — a node whose only linker's body (or whole file) no longer links to it kept a stale, too-HIGH `importance_score`, the harmful direction for future retrieval ranking — is now closed: `Reconcile`'s `file()` captures an edited touched node's PRIOR body (read from `memory_fts` before `UpsertMemoryNode` overwrites it) and the deletion loop captures a doomed node's own body (read before `DeleteMemoryNode` drops it), unioning both bodies' outgoing links into the SAME delta-refine candidate set 5d-iii built — recomputation is idempotent, so re-adding a link that's still present costs nothing. `TestMemory02_ReindexEquivalence`'s own fixture was also strengthened to actually exercise a link removal (its prior "touch A once more" step was redundant given 5d-iii's fix, and that redundancy meant the guard could never have caught a regression here). (2) `upsertIndexNode`'s owner-touch memoization, which 5d-ii scoped to `Reconcile`'s bulk pass on the assumption that its other ~16 call sites were isolated single-node writes with nothing to memoize, turns out to be needed almost everywhere: reading every real call site shows all of them loop over more than one node per invocation (`AgeEpisodes`, `ingestInteractions`, `ReviseBeliefs`, `commitCalendarNodes`, `PromoteConcepts`, `DedupeEpisodes` via `unionProvenance`, `EvictEpisodes`'s two loops, `extractGmailBatch`, `IngestSituations`, `Merge`'s own stub/winner pair, `commitMirrorNodes`, `extractBatch`, `Reflect`, `RewriteEntityPages`, `SeedEntities`). `upsertIndexNode`'s second parameter now takes the `ownerEdited func(string) (bool, error)` signal directly (mirroring `computeNodeImportance`'s own shape); every batch function allocates one per-call `ownerEditedMemo` (a new small shared type generalizing `reconcilePass`'s own ad hoc fields, which now delegate to it too) before its node-writing loop.
```

- [ ] **Step 3: add five test guards.** Append to the bullet list (after the 5d-iv bullets):

```
- `internal/db/memory_test.go::TestGetMemoryNodeBody` (the new pre-overwrite FTS body reader returns the exact prior body, `sql.ErrNoRows` for an unknown id)
- `internal/memory/index_test.go::TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit` (a touched node's body edit that REMOVES a link delta-refines the old target down)
- `internal/memory/index_test.go::TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion` (a deleted node's own outgoing links delta-refine their former targets down)
- `internal/memory/index_test.go::TestMemory02_ReindexEquivalence` (strengthened again: pass 4 removes a link and asserts the target's score drops to 0 in both the incremental and rebuilt dumps — NEEDS-OWNER-REVIEW, an extension)
- `internal/memory/vault_test.go::TestOwnerEditedMemoCachesAcrossLookups` (the shared per-call memo loads `OwnerEditedFiles()` at most once and stays stale-by-design for the rest of that call — proving true memoization, not just a correct first answer)
```

- [ ] **Step 4: add the changelog entry.** Insert immediately after the `## Changelog` heading, above the existing 2026-07-18 entries:

```markdown

- 2026-07-19 (second whole-branch review follow-up on Slice A / MEM-16, run to confirm 5d's three fixes — confirmed, and two more non-blocking gaps found and fixed): (1) **Link-removal asymmetry closed** — 5d-iii's delta-refine only read a touched node's NEW body, so a link REMOVED by an edit (or by the node's whole file being deleted) left the old target's `importance_score` stale-too-HIGH, the harmful direction for future retrieval ranking, and 5d-iii itself documented this as an accepted residual. Fixed: `Reconcile`'s `file()` now captures an edited touched node's PRIOR body (`db.GetMemoryNodeBody`, new, reads `memory_fts` before `UpsertMemoryNode` overwrites it) and the deletion loop captures a doomed node's own body (read before `DeleteMemoryNode`), unioning both bodies' outgoing links into the same delta-refine candidate set — one hop only, still, and idempotent (re-adding a still-present link costs nothing). `TestMemory02_ReindexEquivalence`'s fixture was strengthened: the redundant "touch A once more" step (which masked whether this guard could ever catch a removal regression) was replaced with a real link-removal pass. (2) **`upsertIndexNode` batch memoization generalized** — 5d-ii scoped the owner-touch memoization to `Reconcile`'s bulk pass, assuming its other ~16 call sites were isolated single-node writes; reading every real call site shows virtually all of them loop over more than one node per invocation. `upsertIndexNode`'s signature now takes an `ownerEdited func(string) (bool, error)` directly; every batch function (`AgeEpisodes`, `ingestInteractions`, `ReviseBeliefs`, `commitCalendarNodes`, `PromoteConcepts`, `DedupeEpisodes`/`unionProvenance`, `EvictEpisodes`, `extractGmailBatch`, `IngestSituations`, `Merge`, `commitMirrorNodes`, `extractBatch`, `Reflect`, `RewriteEntityPages`, `SeedEntities`) now allocates one per-call `ownerEditedMemo` (new shared type, generalizing `reconcilePass`'s own ad hoc fields, which now delegate to it) instead of paying a fresh git-log walk per node. Guarded by `TestGetMemoryNodeBody`, `TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit`, `TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion`, the strengthened `TestMemory02_ReindexEquivalence`, and `TestOwnerEditedMemoCachesAcrossLookups`. No new contract number (folded into MEM-16), no new config gate, no retrieval/chat/MCP change — still foundation-only. `EvictEpisodes`'s own `RetentionScore` scoring logic (a different concern, never reads `importance_score`) is untouched.
```

- [ ] **Step 5: re-read the section and sanity-check it renders correctly:**

```
$ grep -n "^## MEM-16\|^## Known v1\|^## Changelog" docs/inventory/memory.md
```

Expected: unchanged positions (only the text between them grew); the new changelog entry sits directly under the `## Changelog` heading, above the 5d and Slice-A entries.

- [ ] **Step 6: commit:**

```
$ git add docs/inventory/memory.md
$ git commit -m "docs(memory): MEM-16 addendum — link-removal asymmetry closed, upsertIndexNode batch memoization generalized

Second whole-branch review confirmed 5d's three fixes and found two more
non-blocking gaps; both folded into the existing MEM-16 contract with new
test guards, matching the established 5b/5c/5d pattern."
```

---

### 5e-v: Final verification

**Depends on:** 5e-i, 5e-ii, 5e-iii, 5e-iv. **Blocks:** nothing (terminal).

- [ ] **Step 1: formatting.**

```
$ gofmt -l internal/db/memory.go internal/db/memory_test.go internal/memory/index.go internal/memory/index_test.go internal/memory/vault.go internal/memory/vault_test.go internal/memory/merge.go internal/memory/merge_test.go internal/memory/aging.go internal/memory/action_ingest.go internal/memory/beliefs.go internal/memory/calendar_ingest.go internal/memory/concepts.go internal/memory/dedupe.go internal/memory/evict.go internal/memory/gmail_extract.go internal/memory/ingest.go internal/memory/mirror_ingest.go internal/memory/pipeline.go internal/memory/reflect.go internal/memory/rewrite.go internal/memory/seed.go docs/inventory/memory.md
```

Expected: no output (the last path is markdown — `gofmt` ignores it silently; included for a single copy-pasteable command, harmless).

- [ ] **Step 2: vet + build.**

```
$ go vet ./... && go build ./... > /tmp/build.log 2>&1; echo "exit=$?"; cat /tmp/build.log
exit=0
```

- [ ] **Step 3: the directly-touched packages, verbose, real exit code checked explicitly (never piped through `tail` alone):**

```
$ go test -count=1 ./internal/memory/... ./internal/db/... -v > /tmp/test.log 2>&1; echo "exit=$?"; grep -E "^--- (FAIL|PASS)" /tmp/test.log | grep -c PASS; grep "^--- FAIL" /tmp/test.log
exit=0
```

Expected: `exit=0`, zero `FAIL` lines, and (by name) every 5d guard (`TestReconcileComputesImportanceScore`, `TestReconcileImportanceOverrideWins`, `TestReconcileImportanceQuarantineOnSignalError`, `TestReconcileImportanceOrderIndependent`, `TestMemory02_ReindexEquivalence`, `TestEvictReindexEquivalence`, `TestUpsertIndexNodeComputesImportance`, `TestUpsertIndexNodeImportanceOverrideWins`, `TestUpdateMemoryNodeImportanceScore`, `TestReconcileImportanceRefinesAfterDeletion`, `TestVaultOwnerEditedFilesAggregatesAcrossHistory`, `TestReconcileImportanceRefinesUnchangedLinkedNode`) plus every 5e guard (`TestGetMemoryNodeBody`, `TestReconcileImportanceDeltaRefinesRemovedLinkOnEdit`, `TestReconcileImportanceDeltaRefinesRemovedLinkOnDeletion`, `TestOwnerEditedMemoCachesAcrossLookups`) present and passing — sixteen names total.

- [ ] **Step 4: broader blast-radius check** (nothing outside `internal/memory` calls `computeNodeImportance`/`upsertIndexNode`/`unionProvenance`/`reconcilePass`/`ownerEditedMemo` — all unexported — but `db.MemoryNodeRow`/`Node` are read elsewhere):

```
$ go test ./internal/inbox/... ./internal/mcp/... ./internal/daemon/... ./cmd/... > /tmp/blast.log 2>&1; echo "exit=$?"; tail -10 /tmp/blast.log
exit=0
```

- [ ] **Step 5: full suite.**

```
$ go test ./... > /tmp/full-test.log 2>&1; echo "exit=$?"; grep -c "^ok" /tmp/full-test.log; grep "^FAIL" /tmp/full-test.log
exit=0
```

Expected: `exit=0`, no `FAIL` lines.

- [ ] **Step 6: final status check — confirm nothing is left uncommitted:**

```
$ git status --short
```

Expected: clean (5e-i through 5e-iv already committed everything).

---

**Summary of 5e's new/changed files:**
- Modified: `internal/db/memory.go` (new `GetMemoryNodeBody`), `internal/memory/index.go` (`reconcilePass` gains `priorLinkTargets` then drops its own three `ownerEdited*` fields for a shared `*ownerEditedMemo`; `file()` captures prior bodies; `Reconcile`'s deletion loop captures doomed bodies; `refineImportance` unions `priorLinkTargets`), `internal/memory/vault.go` (new `ownerEditedMemo` type + constructor), `internal/memory/merge.go` (`upsertIndexNode`'s signature; `Merge`'s loop), `internal/memory/aging.go`, `internal/memory/action_ingest.go`, `internal/memory/beliefs.go`, `internal/memory/calendar_ingest.go`, `internal/memory/concepts.go`, `internal/memory/dedupe.go` (`unionProvenance`'s signature), `internal/memory/evict.go`, `internal/memory/gmail_extract.go`, `internal/memory/ingest.go`, `internal/memory/mirror_ingest.go`, `internal/memory/pipeline.go`, `internal/memory/reflect.go`, `internal/memory/rewrite.go`, `internal/memory/seed.go` (each gets one `mem := newOwnerEditedMemo(...)` line before its node-writing loop), `internal/db/memory_test.go` (one new test), `internal/memory/index_test.go` (two new tests + `TestMemory02_ReindexEquivalence`'s fixture strengthened), `internal/memory/vault_test.go` (one new test), `internal/memory/merge_test.go` (two call sites updated to the new signature), `docs/inventory/memory.md` (MEM-16 addendum + changelog entry)
- Untouched (verified, not just assumed): `internal/memory/evict.go`'s own `RetentionScore`/candidate-scoring logic and its direct `v.OwnerEdited(rel)` call (line ~125) — a different concern from `upsertIndexNode`'s owner-touch memoization; `internal/memory/evict_test.go`; `MEM-02`'s own inventory text (no edit needed — the claim is true again, not re-scoped); `computeNodeImportance`'s signature (unchanged since 5d-ii).
