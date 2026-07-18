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

## Task 6: Strengthen the MEM-02 guard + add override/quarantine regression tests

**Depends on:** Task 5b (needs `TestEvictReindexEquivalence` passing again before this task's own "full package, expect green" step; also needs Task 5's behavior under test to already exist). **Blocks:** Task 7.

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
