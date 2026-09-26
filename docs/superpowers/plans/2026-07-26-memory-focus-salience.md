# Memory Focus Salience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Owner-steerable salience: a vault `focus.md` (`## Now`/`## Cooled` free-text bullets) mechanically matched to nodes, multiplying computed importance ×2.0/×0.5, with a fingerprint-triggered score sweep and a Desktop editor (spec: `docs/superpowers/specs/2026-07-26-memory-focus-salience-design.md`).

**Architecture:** Focus matches persist in a memory-owned `memory_focus_matches` table written once per fingerprint change — so `computeNodeImportance` (17 call sites) reads a node's focus state with one extra SELECT (next to `LinkedEntityEngagement`) and NO signature changes anywhere. `ImportanceInputs.Focus` carries the tri-state into the pure `ComputeImportance`; `importance_override` bypasses the multiplier. A fingerprint mismatch triggers a whole-vault importance sweep (list + recompute + `UpdateMemoryNodeImportanceScore`), then stores the fingerprint.

**Tech Stack:** Go 1.25, SQLite via `modernc.org/sqlite`, goose migration 00031, SwiftUI/GRDB Desktop.

## Global Constraints

- Branch: `feature/memory-phase5` (verify before committing). A CONCURRENT session lands Slice-D commits on this branch — before each task, `git pull --rebase=false` is FORBIDDEN (no network ops); just note foreign commits and base review packages on your own commit's parent.
- Migration number **00031** (verify `ls internal/db/migrations/ | tail -1` first — if a concurrent commit took 00031, use the next free number everywhere it appears).
- Gate `memory.focus.enabled` default false; gate off → no parse, no fingerprint read/write, no matches write; outputs byte-identical.
- The multiplier applies to the COMPUTED arm only; `ImportanceOverride` returns early and NEVER sees the multiplier.
- Both-sections match → `now` wins (logged).
- Guard tests: only additive extensions; if any `TestMemory*`/`TestComputeImportance*`/`TestRetentionScore*` existing assertion fails, STOP → BLOCKED (the multiplier must default to ×1.0 for Focus=none so every existing fixture is unchanged).
- Never pipe verification output through tail — `> /tmp/x.log 2>&1; echo exit=$?`.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Xo7jXEcJB3kQjpqR7Q4PvH
  ```

---

### Task 1: DB substrate — migration 00031, fingerprint, matches table, title match

**Files:**
- Create: `internal/db/migrations/00031_memory_focus.sql`
- Modify: `internal/db/schema.sql` (workspace column + new table), `internal/db/memory.go`
- Test: `internal/db/memory_test.go`

**Interfaces:**
- Produces (Tasks 2-4 rely on):
  - `func (db *DB) FocusFingerprint() (string, error)` / `func (db *DB) SetFocusFingerprint(fp string) error` (workspace column `memory_focus_fingerprint TEXT NOT NULL DEFAULT ''`; missing singleton row reads "").
  - `func (db *DB) ReplaceFocusMatches(now, cooled []string) error` — one transaction: `DELETE FROM memory_focus_matches` then insert every id with its state (`'now'`/`'cooled'`).
  - `func (db *DB) FocusState(nodeID string) (string, error)` — `''` when unmatched (sql.ErrNoRows → clean `''`), else `'now'`/`'cooled'`; other errors propagate.
  - `func (db *DB) ListMemoryNodeIDsByTitleMatch(phrase string) ([]string, error)` — non-tombstone nodes whose title contains phrase case-insensitively (`WHERE instr(lower(title), lower(?)) > 0 AND status != 'tombstone'`), sorted by id.

- [ ] **Step 1: Migration**

`internal/db/migrations/00031_memory_focus.sql`:

```sql
-- +goose Up
-- Memory focus salience (docs/superpowers/specs/2026-07-26-memory-focus-salience-design.md):
-- memory_focus_fingerprint is the hash of the last APPLIED parsed focus.md
-- directive set — runtime state like the extraction watermarks, MEM-02-exempt.
-- memory_focus_matches is the mechanically-matched node set (state 'now' or
-- 'cooled'), rewritten wholesale on every fingerprint change so
-- computeNodeImportance reads a node's focus with one SELECT instead of
-- threading sets through its ~17 call sites. Runtime state: rebuilt from
-- focus.md + the index, cleared and rewritten by the pipeline, no FK (a match
-- may outlive its node briefly between runs; reads join against live nodes).
ALTER TABLE workspace ADD COLUMN memory_focus_fingerprint TEXT NOT NULL DEFAULT '';
CREATE TABLE IF NOT EXISTS memory_focus_matches (
    node_id TEXT PRIMARY KEY,
    state   TEXT NOT NULL CHECK (state IN ('now','cooled'))
);

-- +goose Down
DROP TABLE IF EXISTS memory_focus_matches;
ALTER TABLE workspace DROP COLUMN memory_focus_fingerprint;
```

Mirror both into `internal/db/schema.sql` (column beside `memory_jira_last_extracted_ts`; table after `memory_digest_shadow`'s block). Add `memory_focus_matches` to `TestAllTablesExist`'s table list (`internal/db/` — grep for the test; additive).

- [ ] **Step 2: Failing tests**

Append to `internal/db/memory_test.go` (reuse `openTestDB`/`seedWorkspace` — the actual fixture names used by `TestMemoryJiraWatermark`):

```go
// TestFocusFingerprintRoundTrip: the applied-focus fingerprint round-trips on
// the workspace singleton; a fresh workspace reads "".
func TestFocusFingerprintRoundTrip(t *testing.T) {
	db := openTestDB(t)
	seedWorkspace(t, db)
	fp, err := db.FocusFingerprint()
	if err != nil || fp != "" {
		t.Fatalf("fresh = %q, %v; want \"\", nil", fp, err)
	}
	if err := db.SetFocusFingerprint("abc123"); err != nil {
		t.Fatal(err)
	}
	fp, err = db.FocusFingerprint()
	if err != nil || fp != "abc123" {
		t.Fatalf("got %q, %v; want abc123", fp, err)
	}
}

// TestFocusMatches: ReplaceFocusMatches rewrites wholesale; FocusState reads
// '' for unmatched, 'now'/'cooled' for matched.
func TestFocusMatches(t *testing.T) {
	db := openTestDB(t)
	if err := db.ReplaceFocusMatches([]string{"ent_a", "ent_b"}, []string{"ent_c"}); err != nil {
		t.Fatal(err)
	}
	for id, want := range map[string]string{"ent_a": "now", "ent_b": "now", "ent_c": "cooled", "ent_zzz": ""} {
		got, err := db.FocusState(id)
		if err != nil || got != want {
			t.Errorf("FocusState(%s) = %q, %v; want %q", id, got, err, want)
		}
	}
	// Wholesale replace: previous matches vanish.
	if err := db.ReplaceFocusMatches(nil, []string{"ent_a"}); err != nil {
		t.Fatal(err)
	}
	if got, _ := db.FocusState("ent_b"); got != "" {
		t.Errorf("ent_b survived replace: %q", got)
	}
	if got, _ := db.FocusState("ent_a"); got != "cooled" {
		t.Errorf("ent_a = %q, want cooled", got)
	}
}

// TestListMemoryNodeIDsByTitleMatch: case-insensitive substring on title,
// tombstones excluded, sorted by id.
func TestListMemoryNodeIDsByTitleMatch(t *testing.T) {
	db := openTestDB(t)
	upsertNamedNode(t, db, "ent_hash", "Hashbank Integration", "active")
	upsertNamedNode(t, db, "ent_other", "Preview Environments", "active")
	upsertNamedNode(t, db, "ent_tomb", "hashbank legacy", "tombstone")
	ids, err := db.ListMemoryNodeIDsByTitleMatch("HASHBANK")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(ids, ",") != "ent_hash" {
		t.Errorf("ids = %v, want [ent_hash] (case-insensitive, tombstone excluded)", ids)
	}
}
```

`upsertNamedNode` stands for a tiny local helper inserting a `memory_nodes` row with the given id/title/status via `UpsertMemoryNode` (mirror how other tests in this file build `MemoryNodeRow` — e.g. the `epNode` fixture in `TestListEpisodesForChannelWindow`; adapt the helper, keep the assertions).

- [ ] **Step 3: Run red** — `go test ./internal/db/ -run 'TestFocus|TestListMemoryNodeIDsByTitleMatch' -v` → compile FAIL (undefined helpers).

- [ ] **Step 4: Implement** the four helpers + `ReplaceFocusMatches` in `internal/db/memory.go` (after the jira block):

```go
// FocusFingerprint reads the hash of the last APPLIED focus.md directive set
// (memory focus salience; runtime state like the extraction watermarks).
func (db *DB) FocusFingerprint() (string, error) {
	var fp string
	err := db.QueryRow(`SELECT COALESCE(memory_focus_fingerprint, '') FROM workspace LIMIT 1`).Scan(&fp)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("getting focus fingerprint: %w", err)
	}
	return fp, nil
}

// SetFocusFingerprint stores the applied-focus hash. Callers set it only AFTER
// the matches rewrite and the importance sweep succeeded (freeze-on-error).
func (db *DB) SetFocusFingerprint(fp string) error {
	if _, err := db.Exec(`UPDATE workspace SET memory_focus_fingerprint = ?`, fp); err != nil {
		return fmt.Errorf("setting focus fingerprint: %w", err)
	}
	return nil
}

// ReplaceFocusMatches rewrites the matched-node set wholesale in one
// transaction — the focus counterpart of the alias/FTS replace discipline.
func (db *DB) ReplaceFocusMatches(now, cooled []string) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("focus matches tx: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM memory_focus_matches`); err != nil {
		return fmt.Errorf("clearing focus matches: %w", err)
	}
	for _, id := range now {
		if _, err := tx.Exec(`INSERT OR REPLACE INTO memory_focus_matches (node_id, state) VALUES (?, 'now')`, id); err != nil {
			return fmt.Errorf("inserting focus match %s: %w", id, err)
		}
	}
	for _, id := range cooled {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO memory_focus_matches (node_id, state) VALUES (?, 'cooled')`, id); err != nil {
			return fmt.Errorf("inserting cooled match %s: %w", id, err)
		}
	}
	return tx.Commit()
}

// FocusState reads one node's focus membership: '' (unmatched), 'now', or
// 'cooled'. The empty answer is the overwhelmingly common case and must stay
// cheap — a primary-key point read.
func (db *DB) FocusState(nodeID string) (string, error) {
	var state string
	err := db.QueryRow(`SELECT state FROM memory_focus_matches WHERE node_id = ?`, nodeID).Scan(&state)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("reading focus state for %s: %w", nodeID, err)
	}
	return state, nil
}

// ListMemoryNodeIDsByTitleMatch returns non-tombstone node ids whose title
// contains phrase case-insensitively — the focus matcher's title arm.
func (db *DB) ListMemoryNodeIDsByTitleMatch(phrase string) ([]string, error) {
	rows, err := db.Query(`SELECT id FROM memory_nodes
		WHERE status != 'tombstone' AND instr(lower(title), lower(?)) > 0
		ORDER BY id`, phrase)
	if err != nil {
		return nil, fmt.Errorf("title-matching focus phrase: %w", err)
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning title match: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
```

Note the now/cooled insert pair: `INSERT OR REPLACE` for now, `INSERT OR IGNORE` for cooled — a node listed in both sections lands 'now' regardless of insertion order (the both→now rule enforced at the storage layer too).

- [ ] **Step 5: Green + golden + package** — targeted run PASS; `go test ./internal/db/ -run TestSchemaGolden -update`; full `go test ./internal/db/` exit=0.

- [ ] **Step 6: Commit** — `feat(db): focus salience substrate — 00031 fingerprint + matches table + title match` (+ footer).

---

### Task 2: Parser + matcher + fingerprint (`internal/memory/focus.go`)

**Files:**
- Create: `internal/memory/focus.go`, `internal/memory/focus_test.go`

**Interfaces:**
- Consumes: Task 1 helpers; `LookupMemoryAlias`; the vault root path (grep how `worldmap.go` writes `map.md` — reuse the same path mechanics to READ `focus.md`).
- Produces (Task 4 relies on):
  - `type focusDirectives struct { Now, Cooled []string }` (trimmed bullet texts, document order)
  - `func parseFocus(raw string) focusDirectives` — pure; fixed `## Now`/`## Cooled` headings (case-insensitive match on the heading line), `- ` bullets trimmed; unknown headings/prose ignored; empty/missing → zero value.
  - `func (fd focusDirectives) fingerprint() string` — sha256 hex over the sorted, normalized (lowercased, trimmed) bullets with section tags (`now:<bullet>`, `cooled:<bullet>`), so reordering bullets does not change it but moving a bullet between sections does.
  - `func (p *Pipeline) matchFocus(fd focusDirectives) (now, cooled []string, err error)` — per bullet: (1) `LookupMemoryAlias(bullet)` on the whole trimmed bullet AND on each comma-separated fragment; (2) `ListMemoryNodeIDsByTitleMatch` on the whole bullet and each fragment. Union, dedupe; a node in both sections → now (log one line). A bullet matching nothing logs `memory: focus: bullet %q matched nothing` and contributes nothing. A DB error propagates (the caller freezes the focus step).
  - `func (p *Pipeline) readFocusFile() (string, bool, error)` — reads `<vaultRoot>/focus.md`; (raw, true, nil) when present, ("", false, nil) when absent (os.IsNotExist → clean miss), error otherwise.

- [ ] **Step 1: Failing tests** — write `focus_test.go` covering: parser (both sections; missing file section; bullets trimmed; `## NOW` case-insensitive; prose between sections ignored; empty raw → zero); fingerprint (bullet reorder → same; section move → different; case/space normalization); matcher (alias hit via a seeded aliased node; title hit case-insensitive; comma-fragment hit; both-sections → now; nothing-matched bullet → empty + no error). Use the package's existing `newTestVault`/`newTestDB` fixtures and `UpsertMemoryNode`-based node seeding (mirror `digest_compare_test.go`'s style). Write out every test function in full — parser and fingerprint tests are pure-function table tests; the matcher test seeds two nodes (one aliased `CEX`, one titled "Hashbank Integration") and asserts id sets.

- [ ] **Step 2: red** → compile FAIL. **Step 3:** implement `focus.go` per the interfaces above (pure functions + the two Pipeline methods; `crypto/sha256` + `encoding/hex` for the fingerprint; heading detection: a line equal to `## Now`/`## Cooled` after TrimSpace, case-insensitive; bullets: lines starting `- ` inside the current section). **Step 4:** green + full package exit=0. **Step 5:** commit `feat(memory): focus.md parser, matcher, fingerprint` (+ footer).

---

### Task 3: The multiplier — `ImportanceInputs.Focus` through both consumers

**Files:**
- Modify: `internal/memory/importance.go` (`ImportanceInputs`, constants, `ComputeImportance`, `computeNodeImportance`), `internal/memory/evict.go` (`RetentionScore` input gathering — read it first; it feeds `ComputeImportance` via its own inputs struct)
- Test: `internal/memory/importance_test.go`, `internal/memory/evict_test.go`

**Interfaces:**
- Consumes: Task 1's `FocusState(nodeID)`.
- Produces: `ImportanceInputs.Focus string` (`""`/`"now"`/`"cooled"`); constants `focusBoostFactor = 2.0`, `focusCooledFactor = 0.5`; `computeNodeImportance` reads `database.FocusState(n.ID)` alongside `LinkedEntityEngagement` (signature UNCHANGED — this is the whole point of the matches table).

- [ ] **Step 1: Failing tests**

```go
// TestComputeImportanceFocus pins the 2026-07-26 salience multiplier (owner
// verdict A): focus multiplies the COMPUTED importance — now ×2, cooled ×0.5,
// unmatched ×1 — proportional to organic importance, so a barely-linked node
// never outranks an org-central one just by being mentioned in focus.
func TestComputeImportanceFocus(t *testing.T) {
	base := ImportanceInputs{LinksIn: 3, SituationOrigin: true} // computed 4.0
	assert.InDelta(t, 4.0, ComputeImportance(base), 1e-9)
	now := base
	now.Focus = "now"
	assert.InDelta(t, 8.0, ComputeImportance(now), 1e-9)
	cooled := base
	cooled.Focus = "cooled"
	assert.InDelta(t, 2.0, ComputeImportance(cooled), 1e-9)
}
```

Plus in `importance_test.go` a `computeNodeImportance`-level test: a node with `ImportanceOverride` set AND a 'now' match keeps the override exactly (the multiplier never touches the override path); a node with a 'now' match and organic signals gets the doubled value persisted. Model the fixture on `TestReconcileComputesImportanceScore`'s setup (read it first; it already seeds links/engagement — add a `ReplaceFocusMatches` call). In `evict_test.go`, extend the retention side minimally: a 'now'-matched episode's `RetentionScore` doubles its importance arm versus the identical unmatched fixture (adapt an existing `TestRetentionScore*` fixture pair — additive test, never modify existing assertions).

- [ ] **Step 2: red.** **Step 3: implement** — `Focus string` field + constants + at the END of `ComputeImportance` (after the engagement arm):

```go
	switch in.Focus {
	case "now":
		importance *= focusBoostFactor
	case "cooled":
		importance *= focusCooledFactor
	}
	return importance
```

In `computeNodeImportance`, after `LinkedEntityEngagement`, add `focus, err := database.FocusState(n.ID)` (propagate error) and set `Focus: focus` in the inputs — the override early-return above it stays FIRST, so an override never sees the multiplier. In `evict.go`, find where `RetentionScore`'s inputs are gathered per candidate (read the candidate loop) and add the same `FocusState` read into its importance inputs. **Step 4:** targeted + full package green (existing `TestComputeImportance*`/`TestRetentionScore*` fixtures pass unchanged — Focus zero value is `""` → ×1). **Step 5:** commit `feat(memory): focus multiplier in ComputeImportance — both consumers via FocusState` (+ footer).

---

### Task 4: Run wiring — the focus step + fingerprint sweep + gate

**Files:**
- Modify: `internal/config/config.go` (new `MemoryFocusConfig`/field — mirror how `memory.semantic.enabled` nests: add `Focus struct { Enabled bool }` with mapstructure `focus`/`enabled`), `internal/memory/pipeline.go` (Run step + RunStats)
- Test: `internal/memory/focus_test.go`

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: `runFocus(runID int64, stepOffset int, stats *RunStats) (int, error)` — Run step right AFTER the owner-edit commit + `Reconcile` (so a focus.md edit is committed and the index is fresh) and BEFORE situation ingest; gate `p.cfg.Focus.Enabled`.

- [ ] **Step 1: Failing tests** (in `focus_test.go`):
  - `TestRunFocusSweepOnFingerprintChange`: seed a vault with `focus.md` (one `## Now` bullet matching a seeded entity by title) + one UNRELATED indexed node with a stale persisted `importance_score`; run `runFocus`; assert (a) `memory_focus_matches` has the entity as 'now', (b) the matched entity's persisted `importance_score` doubled, (c) the unrelated node's score was recomputed too (the sweep is whole-vault), (d) the fingerprint column now holds `fd.fingerprint()`.
  - `TestRunFocusUnchangedFingerprintNoSweep`: second `runFocus` with the same file → no matches rewrite (assert via a probe: hand-tweak one node's `importance_score` to a sentinel; unchanged fingerprint run must NOT overwrite the sentinel), returns 0 steps.
  - `TestRunFocusSweepErrorFreezesFingerprint`: force a sweep failure (drop `memory_focus_matches`? no — force via the package's house error-injection pattern: DROP TABLE memory_nodes copy trick used by the jira freeze test — read `TestRunJiraIngestWatermarkFreezeOnError` and mirror its mechanism against the sweep's read path); assert the fingerprint column did NOT advance.
  - `TestRunFocusGateOffByteIdentical`: gate off + focus.md present → no parse (fingerprint stays ''), no matches, full `Run` output tables byte-identical to a run without the file (dump-compare `memory_nodes` like the MEM-14 guard does; mirror its dump helper).

- [ ] **Step 2: red.** **Step 3: implement** `runFocus`:

```go
// runFocus is the focus-salience step (behind memory.focus.enabled): parse
// focus.md, and when the parsed directive set's fingerprint differs from the
// last APPLIED one, rewrite memory_focus_matches wholesale, sweep EVERY
// indexed node's persisted importance_score (a focus edit touches no node
// file, so the MEM-16 touched-node refresh would never see it), and only
// after both succeeded store the new fingerprint (freeze-on-error: a failed
// sweep leaves the old fingerprint so the next run retries). Runs after the
// owner-edit commit + Reconcile (the focus edit is committed, the index is
// fresh) and before every consumer of importance.
func (p *Pipeline) runFocus(runID int64, stepOffset int, stats *RunStats) (int, error) { ... }
```

Body: `readFocusFile` (absent → parse of "" → empty directives — an owner DELETING focus.md must sweep back to neutral, so the fingerprint of the empty set still participates); `parseFocus`; `fingerprint()`; compare `FocusFingerprint()`; equal → return 0, nil. Different → `matchFocus` → `ReplaceFocusMatches` → sweep: `ListMemoryNodes()` + one `ownerEditedMemo` + per node `computeNodeImportance` + `db.UpdateMemoryNodeImportanceScore` (this IS the sweep — simple loop, no reconcilePass entanglement; quarantine philosophy: a per-node signal error logs + skips the node + counts, only IO/DB-wide errors fail the step) → `SetFocusFingerprint`. Step row `"focus"` via `recordSemanticStep` (1 step) on any work or error; errors logged, never fatal to the run (source-isolation precedent). RunStats gains `FocusMatched int` / `FocusSwept int` / `FocusFailed int` + run-done log clause. Wire into `Run` after the Reconcile block with `focusSteps` offset propagation (find the first step-consuming call after Reconcile — read the code — and shift offsets like jira's 3d wiring did).

**Step 4:** green; full `./internal/memory/ ./internal/config/` exit=0. **Step 5:** commit `feat(memory): focus salience Run step — fingerprint-gated match rewrite + whole-vault importance sweep` (+ footer).

---

### Task 5: Desktop Focus editor

**Files:**
- Modify: `WatchtowerDesktop/Sources/...(Memory tab files — locate via grep for `MemoryViewModel`/`saveEdit`)`
- Test: the Desktop test target file that covers the Memory raw editor (grep `saveEdit` in `WatchtowerDesktop/Tests`)

**Interfaces:**
- Consumes: the existing raw-editor write path (`saveEdit`-style: non-blocking flock on `memory.lock`, atomic write, refresh) and however the Memory tab resolves the vault root path.
- Produces: a "Focus" affordance in the Memory tab (toolbar button opening a sheet, or a pinned section — match the tab's existing idiom, read the view first): `TextEditor` bound to focus.md's raw content, Save/Cancel; VM methods `loadFocusRaw()` and `saveFocusRaw(_:)`.

- [ ] **Step 1:** Read the Memory tab implementation first (`MemoryView`, `MemoryViewModel`, `MemoryQueries`, `MemoryMarkdown` if present — names per the Slice D spec background; the raw whole-file editor from `feature/memory-desktop-browser` is merged). Identify: vault-root resolution, the flock+atomic write helper `saveEdit` uses, and the existing error-inline pattern.
- [ ] **Step 2:** Failing Swift test: `saveFocusRaw` writes focus.md atomically under the lock; lock-busy surfaces the same inline error `saveEdit` uses; `loadFocusRaw` on a missing file returns "" (template seeding "# Focus\n\n## Now\n\n## Cooled\n" is done by the VIEW when opening an empty editor, not written to disk until Save). Mirror the existing saveEdit test's fixture (temp vault dir + lock file).
- [ ] **Step 3:** Implement: VM methods (mirror `saveEdit`'s flock/atomic mechanics verbatim, path = `<vaultRoot>/focus.md`); a toolbar "Focus" button on the Memory master panel opening a sheet with the editor + Save/Cancel; Save disabled while a save is in flight. No new persistence, no per-bullet UI.
- [ ] **Step 4:** `cd WatchtowerDesktop && swift build > /tmp/swb.log 2>&1; echo exit=$?` and `swift test > /tmp/swt.log 2>&1; echo exit=$?` — real exit codes (house rule; Swift builds are slow, run once each).
- [ ] **Step 5:** Commit `feat(desktop): Focus editor in the Memory tab (edits vault focus.md via the raw-editor write path)` (+ footer).

---

### Task 6: Inventory + spec amendment + full sweep

**Files:**
- Modify: `docs/inventory/memory.md`, `docs/superpowers/specs/2026-07-26-memory-focus-salience-design.md`

- [ ] **Step 1:** MEM-16 section: append to the Observable a sentence: `Since 2026-07-26 (focus salience, owner-approved extension) ComputeImportance also consumes an owner-steerable Focus input (vault focus.md → mechanical match set in memory_focus_matches → ×2.0 now / ×0.5 cooled on the COMPUTED arm only; importance_override bypasses it), and a focus-fingerprint change triggers a whole-vault importance sweep — both consumers (snapshot and live retention) see focus through the same primitive.`
- [ ] **Step 2:** Known-limitations bullet:

```markdown
- **Focus salience is mechanical, direct-match-only, and never expires on its own.** `memory.focus.enabled` (default false) parses vault `focus.md` (`## Now`/`## Cooled`, free-text bullets) into `memory_focus_matches` (runtime state, MEM-02-exempt like the watermarks, fingerprint in `workspace.memory_focus_fingerprint`); matching is alias + case-insensitive title only (no AI, no one-hop propagation to a focused entity's episodes — future); a bullet matching nothing logs and does nothing; a node in both sections counts as `now`. Directives persist until the owner edits the file (no auto-expiry; a staleness reminder is future). The Desktop Focus editor stays visible with the gate off (editing a file the pipeline ignores is harmless).
```

- [ ] **Step 3:** Changelog entry (top of `## Changelog`, blank-line separated) summarizing: owner verdicts A/A/A, the matches-table threading decision (no signature churn at computeNodeImportance's ~17 call sites), the sweep discipline, gate, migration 00031, Desktop editor, MEM-16 extension with owner ask = design session.
- [ ] **Step 4:** Spec amendment: in the spec's §2, after the matched-sets sentence, add: `(Implementation note, plan-stage decision: the sets persist in a memory-owned memory_focus_matches table rewritten on fingerprint change, and computeNodeImportance reads FocusState(nodeID) with one point SELECT — threading sets through the ~17 call sites would have churned every signature for no gain.)`
- [ ] **Step 5:** Full sweep: gofmt/vet/build + `go test ./internal/db/ ./internal/memory/ ./internal/config/ ./internal/inbox/ ./internal/briefing/` (+ Swift build/test already done in Task 5) — real exit codes.
- [ ] **Step 6:** Commit `docs(memory): inventory + spec — focus salience (MEM-16 extension, 00031)` (+ footer).
