# Thread-Follow + Suggested Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thread replies re-feed their situation (summary/chronology stay live), and the composer can mark an open situation "looks resolved" for one-click user confirmation — never auto-closing it (DASH-07).

**Architecture:** The detector's thread-fold clears `composed_at` so the existing DASH-01 merge path re-reads updated signals. A new `suggest_resolve` compose op writes `situations.suggested_resolution` (migration 00015); a merge without a same-pass re-suggest clears a stale suggestion. Desktop shows a row badge + review-pane banner with Done / Keep open.

**Tech Stack:** Go 1.25 (goose, modernc sqlite, DB-backed prompt store), SwiftUI macOS 14+ / GRDB.

**Spec:** `docs/superpowers/specs/2026-07-09-resolution-suggestion-design.md`

## Global Constraints

- DASH-07 (new): the AI may only SET `suggested_resolution`; every transition to done/dismissed stays a user action (or the pre-existing user-reply auto-close). A merge without a fresh `suggest_resolve` in the same pass clears a stale suggestion.
- DASH-01/02 untouched: apply stays all-or-nothing in one transaction; hallucinated situation ids are skipped silently; failed compose leaves everything (incl. suggestions) untouched.
- Timestamps: SQL `strftime('%Y-%m-%dT%H:%M:%SZ','now')`.
- Behavior-inventory rule: never weaken existing guard tests (`docs/inventory/*`). Prompt changes follow `.claude/skills/add-ai-prompt/SKILL.md` (default text + version bump).
- Swift verification: redirect output to a log file and check `$?` — never pipe through tail/head.
- Commits in English, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- The working tree may contain unrelated uncommitted user changes — `git add` only the files each task lists.

---

### Task 1: Thread-follow — fold clears `composed_at`

**Files:**
- Modify: `internal/db/inbox.go:99-105` (`UpdateInboxItemSnippet`)
- Test: `internal/db/inbox_test.go` (or the file holding existing UpdateInboxItemSnippet coverage — match its location)
- Test: `internal/inbox/compose_test.go` (DASH-01 family extension)

**Interfaces:**
- Consumes: existing `FindPendingInboxByThread` fold path (`internal/inbox/pipeline.go:607-615`, sole caller).
- Produces: folded items reappear in `ListUncomposedSignals` (its `composed_at IS NULL` filter, `internal/db/situations.go:177`).

- [ ] **Step 1: Write the failing db-level test**

In the file with existing `UpdateInboxItemSnippet`/inbox item db tests (find via `grep -rn "UpdateInboxItemSnippet" internal/db/*_test.go internal/inbox/*_test.go`; if none, add to `internal/db/inbox_test.go` following that package's test style with `openTestDB(t)`):

```go
func TestUpdateInboxItemSnippetClearsComposedAt(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`INSERT INTO inbox_items (id, channel_id, message_ts, thread_ts, sender_user_id, trigger_type, snippet, status, composed_at)
		VALUES (1, 'C1', '100.1', '100.1', 'U2', 'mention', 'original', 'pending', '2026-07-09T07:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateInboxItemSnippet(1, "100.2", "U3", "thread reply", "", "raw", ""); err != nil {
		t.Fatal(err)
	}
	var composedAt sql.NullString
	if err := d.QueryRow(`SELECT composed_at FROM inbox_items WHERE id = 1`).Scan(&composedAt); err != nil {
		t.Fatal(err)
	}
	if composedAt.Valid {
		t.Fatalf("fold must clear composed_at so the composer re-reads the thread, got %q", composedAt.String)
	}
}
```

(Adjust the INSERT's column list to the real `inbox_items` NOT NULL columns if it fails to execute — the intent is: pending item with `composed_at` set.)

- [ ] **Step 2: Run it to verify it fails**

Run: `go test ./internal/db/ -run TestUpdateInboxItemSnippetClearsComposedAt -v`
Expected: FAIL — `composed_at` still set.

- [ ] **Step 3: Implement**

In `internal/db/inbox.go`, `UpdateInboxItemSnippet`'s UPDATE adds one line and a doc-comment note:

```go
// UpdateInboxItemSnippet updates the snippet, context, raw_text, sender,
// message_ts and permalink of an existing inbox item (the detector's
// thread-fold path). It also clears composed_at: a folded thread update must
// re-enter the composer so the owning situation's story stays live (DASH-01
// re-merge; see the 2026-07-09 resolution-suggestion spec).
func (db *DB) UpdateInboxItemSnippet(id int, messageTS, senderUserID, snippet, context, rawText, permalink string) error {
	_, err := db.Exec(`UPDATE inbox_items SET
		message_ts = ?, sender_user_id = ?, snippet = ?, context = ?, raw_text = ?, permalink = ?,
		ai_reason = '', read_at = NULL,
		composed_at = NULL,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?`,
		messageTS, senderUserID, snippet, context, rawText, permalink, id)
	...
```

(Keep the rest of the function exactly as-is; only the `composed_at = NULL` line and the comment change.)

- [ ] **Step 4: Add the compose-level re-merge test (DASH-01 family)**

In `internal/inbox/compose_test.go`, next to `TestDash01_MergeIntoOpenSituation` (reuse its fake-generator setup style — read that test first and mirror its helpers exactly):

```go
// Thread-follow: a signal already composed into a situation gets a thread
// update (fold clears composed_at) → the next compose cycle re-feeds it and
// the AI's merge back into the SAME situation is idempotent: no duplicate
// situation_signals row, card invalidated, updated_at bumped.
func TestDash01_ThreadFollowRefeedMergesIdempotently(t *testing.T)
```

Body: seed one open situation with one linked, composed signal (as `TestDash01_MergeIntoOpenSituation` does); call `d.UpdateInboxItemSnippet(...)` on that signal; run compose with a fake generator returning `{"ops":[{"op":"merge","situation_id":<id>,"signals":["sig:<sigID>"],"reason":"thread update"}]}`; assert: still exactly one situation; `SELECT COUNT(*) FROM situation_signals WHERE situation_id=? AND inbox_item_id=?` == 1 (the `INSERT OR IGNORE` no-op); `card_status='none'`; the signal's `composed_at` is set again.

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/db/ -run TestUpdateInboxItemSnippet -v && go test ./internal/inbox/ -run 'TestDash01' -v`
Expected: all PASS (including the pre-existing DASH-01 guards, untouched).

- [ ] **Step 6: Commit**

```bash
git add internal/db/inbox.go internal/db/inbox_test.go internal/inbox/compose_test.go
git commit -m "fix(inbox): thread-fold re-feeds the composer so situations stay live

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Adjust the test-file path in `git add` if Step 1 landed elsewhere.)

---

### Task 2: Migration 00015 + `suggested_resolution` db layer

**Files:**
- Create: `internal/db/migrations/00015_suggested_resolution.sql`
- Modify: `internal/db/schema.sql` (situations block, after `resolved_reason`)
- Modify: `internal/db/situations.go` (`situationSelectCols`, `scanSituation`, new helpers)
- Modify: `internal/db/models.go` (`DashboardSituation` struct — add field next to `ResolvedReason`)
- Regenerate: `internal/db/testdata/schema_v73.golden`
- Test: `internal/db/situations_test.go`

**Interfaces:**
- Produces (used by Task 3):
  - `DashboardSituation.SuggestedResolution string`
  - `func (db *DB) SetSuggestedResolutionTx(tx *sql.Tx, id int, reason string) error` (also bumps `updated_at` so the feed resurfaces the item)
  - `func (db *DB) ClearSuggestedResolutionTx(tx *sql.Tx, id int) error`
  - `func (db *DB) ClearSuggestedResolution(id int) error` (non-Tx, for the Desktop-mirroring CLI path if ever needed and for tests; thin wrapper)

- [ ] **Step 1: Migration**

`internal/db/migrations/00015_suggested_resolution.sql`:

```sql
-- +goose Up
-- The secretary's "looks resolved" mark (DASH-07): set by the composer's
-- suggest_resolve op when new material shows the story concluded without the
-- owner acting; cleared by a later merge without a re-suggest, or by the
-- user's "Keep open". Never closes the situation — status stays 'open'.
ALTER TABLE situations ADD COLUMN suggested_resolution TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE situations DROP COLUMN suggested_resolution;
```

Mirror the column into `internal/db/schema.sql`'s situations block (same comment style), then regenerate: `go test ./internal/db/ -run TestSchemaGolden -update`. Verify: `go test ./internal/db/ -run 'TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden'` — PASS (no new table, so `TestAllTablesExist` needs no edit).

- [ ] **Step 2: Write failing helper tests**

In `internal/db/situations_test.go` (match its existing style — it has `TestMarkSituationConverted`):

```go
func TestSuggestedResolutionSetAndClear(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSituation(DashboardSituation{Title: "story", Kind: "external", Priority: "medium"})
	if err != nil {
		t.Fatal(err)
	}
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if err := d.SetSuggestedResolutionTx(tx, int(id), "answered in thread"); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	got, err := d.GetSituation(int(id))
	if err != nil {
		t.Fatal(err)
	}
	if got.SuggestedResolution != "answered in thread" {
		t.Fatalf("suggested_resolution not set: %+v", got)
	}
	if got.Status != "open" {
		t.Fatalf("DASH-07: suggestion must never change status, got %q", got.Status)
	}
	if err := d.ClearSuggestedResolution(int(id)); err != nil {
		t.Fatal(err)
	}
	got, _ = d.GetSituation(int(id))
	if got.SuggestedResolution != "" {
		t.Fatalf("clear failed: %+v", got)
	}
}
```

Run: `go test ./internal/db/ -run TestSuggestedResolution -v` — expected FAIL (undefined methods/field).

- [ ] **Step 3: Implement**

In `internal/db/models.go`, add to `DashboardSituation` next to `ResolvedReason`: `SuggestedResolution string`.

In `internal/db/situations.go`:
- add `suggested_resolution` to `situationSelectCols` (and the matching `&s.SuggestedResolution` to `scanSituation`, keeping column/scan order aligned);
- if `createSituationOn`'s INSERT enumerates columns, leave it — the column defaults to `''`;
- add, following the file's `...Tx` + shared-`On` convention:

```go
// SetSuggestedResolutionTx records the secretary's "looks resolved" mark
// (DASH-07). It never touches status; updated_at bumps so the feed
// resurfaces the situation with its new badge.
func (db *DB) SetSuggestedResolutionTx(tx *sql.Tx, id int, reason string) error {
	return setSuggestedResolutionOn(tx, id, reason)
}

func (db *DB) ClearSuggestedResolution(id int) error {
	return setSuggestedResolutionOn(db, id, "")
}

func (db *DB) ClearSuggestedResolutionTx(tx *sql.Tx, id int) error {
	return setSuggestedResolutionOn(tx, id, "")
}

func setSuggestedResolutionOn(q situationsExecer, id int, reason string) error {
	if _, err := q.Exec(`UPDATE situations SET suggested_resolution = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?`, reason, id); err != nil {
		return fmt.Errorf("setting suggested resolution on situation %d: %w", id, err)
	}
	return nil
}
```

- [ ] **Step 4: Run tests**

Run: `go test ./internal/db/ -v -run 'TestSuggestedResolution|TestSchemaGolden|TestMigrationIdempotent'` then the whole package `go test ./internal/db/` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/migrations/00015_suggested_resolution.sql internal/db/schema.sql internal/db/situations.go internal/db/models.go internal/db/situations_test.go internal/db/testdata/schema_v73.golden
git commit -m "feat(db): suggested_resolution column and helpers (DASH-07)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Compose op `suggest_resolve` + prompt v2 + DASH-07 inventory

**Files:**
- Modify: `internal/prompts/defaults.go` (`defaultInboxCompose` text ~line 1225; `InboxCompose: 1` version map entry ~line 101 → `2`)
- Modify: `internal/inbox/compose.go` (`applyComposeOps`, merge case, new case)
- Test: `internal/inbox/compose_test.go`
- Modify: `docs/inventory/dashboard.md` (DASH-07 + changelog)

**Interfaces:**
- Consumes: Task 2 helpers (`SetSuggestedResolutionTx`, `ClearSuggestedResolutionTx`, `DashboardSituation.SuggestedResolution`).
- Produces: op contract `{"op":"suggest_resolve","situation_id":N,"reason":"..."}` (reuses existing `composeOp.SituationID`/`.Reason` fields — no struct change).

- [ ] **Step 1: Read `.claude/skills/add-ai-prompt/SKILL.md`** and confirm the version-bump mechanics (default text change + version map bump → store refreshes the DB row). Follow anything it adds beyond this plan.

- [ ] **Step 2: Write failing tests**

In `internal/inbox/compose_test.go`, mirroring the existing fake-generator setup (same helpers as `TestDash01_MergeIntoOpenSituation` / `TestDash02_AIFailureTouchesNothing`):

```go
// DASH-07: suggest_resolve sets the mark and reason but NEVER changes status.
func TestDash07_SuggestResolveSetsMarkNeverStatus(t *testing.T)
// Body: open situation + one uncomposed signal; fake AI returns
// {"ops":[{"op":"merge","situation_id":ID,"signals":["sig:N"]},
//         {"op":"suggest_resolve","situation_id":ID,"reason":"answered in thread"}]}
// Assert: SuggestedResolution=="answered in thread", Status=="open".

// DASH-07 freshness: a later merge WITHOUT a re-suggest clears a stale mark.
func TestDash07_MergeWithoutResuggestClearsStaleMark(t *testing.T)
// Body: open situation with suggested_resolution pre-set (via
// SetSuggestedResolutionTx in a committed tx) + one new uncomposed signal;
// fake AI returns only a merge op for it. Assert SuggestedResolution=="".

// A rerank alone does NOT clear the mark (only merges represent new material).
func TestDash07_RerankAloneKeepsMark(t *testing.T)
// Same pre-set mark; fake AI returns only {"op":"rerank",...}. Assert mark intact.

// Hallucinated/malformed suggest ops are skipped like other bad ops.
func TestDash07_SuggestResolveSkipsHallucinatedAndEmptyReason(t *testing.T)
// Fake AI returns suggest_resolve for a non-open id and one with reason:"".
// Assert: no error, no situation gains a mark.
```

Write full bodies following the neighbouring tests' helper conventions (seeding via the same functions they use). Run: `go test ./internal/inbox/ -run TestDash07 -v` — expected FAIL (op unknown → mark never set).

- [ ] **Step 3: Implement apply logic**

In `applyComposeOps` (`internal/inbox/compose.go:203`):

1. Pre-pass before the loop:

```go
	// DASH-07 freshness: which situations get a fresh suggestion this pass —
	// a merge without one clears any stale mark below.
	suggested := make(map[int]bool)
	for _, op := range ops {
		if op.Op == "suggest_resolve" {
			suggested[op.SituationID] = true
		}
	}
```

2. In the `case "merge"` branch, after the rerank block, before `merged++`:

```go
			if sit.SuggestedResolution != "" && !suggested[sit.ID] {
				if cerr := database.ClearSuggestedResolutionTx(tx, sit.ID); cerr != nil {
					return created, merged, fmt.Errorf("clearing stale suggestion on situation %d: %w", sit.ID, cerr)
				}
			}
```

3. New case after `case "rerank"`:

```go
		case "suggest_resolve":
			sit, ok := openByID[op.SituationID]
			if !ok || op.Reason == "" {
				continue // hallucinated id or empty reason — skip like other bad ops
			}
			if serr := database.SetSuggestedResolutionTx(tx, sit.ID, op.Reason); serr != nil {
				return created, merged, fmt.Errorf("suggesting resolution on situation %d: %w", sit.ID, serr)
			}
```

4. Update `composeOp`'s doc comment (`// create|merge|rerank|suggest_resolve`).

- [ ] **Step 4: Prompt v2**

In `internal/prompts/defaults.go`:
- Version map: `InboxCompose: 1` → `InboxCompose: 2, // v2: suggest_resolve op (DASH-07)`.
- In `defaultInboxCompose`, extend the op list (after the `"rerank"` bullet):

```
- "suggest_resolve": the new material shows an open situation concluded
  WITHOUT the user needing to act — the question was answered and accepted,
  the blocker lifted, the decision made elsewhere. Propose closing it;
  reason: one sentence, what resolved it, in the user's language. The user
  confirms — never suggest on weak or partial evidence, and never instead
  of a needed merge (emit both).
```

- And extend the JSON example with one line:

```
 {"op":"suggest_resolve","situation_id":9,"reason":"..."},
```

- [ ] **Step 5: Run tests**

Run: `go test ./internal/inbox/ -run 'TestDash07|TestDash01|TestDash02' -v` then `go test ./internal/inbox/ ./internal/prompts/` — all PASS (existing DASH-01/02 guards untouched). `go vet ./...` clean.

- [ ] **Step 6: Inventory**

Append to `docs/inventory/dashboard.md` before the Changelog:

```markdown
## DASH-07 — Resolution is suggested, never automatic

**Status:** Enforced

**Observable:** The composer's `suggest_resolve` op may only set `situations.suggested_resolution` (a reason string shown in the UI); it never changes `status`. Every transition to done/dismissed remains a user action (or the pre-existing signals-resolved auto-close driven by the user's own replies). A merge folding new material into a situation clears a stale suggestion unless the same pass re-suggests; a bare rerank leaves it intact. Hallucinated ids and empty reasons are skipped like any malformed op, and the whole apply stays inside the DASH-02 transaction.

**Why locked:** "The secretary marks, the user closes" is the trust boundary for third-party closures: a false auto-close would silently bury a live issue, while a stale suggestion surviving fresh activity would misrepresent the secretary's current judgment.

**Test guards:**
- `internal/inbox/compose_test.go::TestDash07_SuggestResolveSetsMarkNeverStatus`
- `internal/inbox/compose_test.go::TestDash07_MergeWithoutResuggestClearsStaleMark`
- `internal/inbox/compose_test.go::TestDash07_RerankAloneKeepsMark`
- `internal/inbox/compose_test.go::TestDash07_SuggestResolveSkipsHallucinatedAndEmptyReason`

**Locked since:** 2026-07-09
```

Changelog line: `- 2026-07-09: added DASH-07 (suggested resolution). Introduced by the thread-follow + suggested-resolution feature (spec docs/superpowers/specs/2026-07-09-resolution-suggestion-design.md), together with the thread-fold composed_at reset that keeps situations live.`

- [ ] **Step 7: Commit**

```bash
git add internal/prompts/defaults.go internal/inbox/compose.go internal/inbox/compose_test.go docs/inventory/dashboard.md
git commit -m "feat(inbox): suggest_resolve compose op — secretary marks, user closes (DASH-07)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Swift — model, queries, test schema

**Files:**
- Modify: `WatchtowerDesktop/Sources/Models/Situation.swift`
- Modify: `WatchtowerDesktop/Sources/Database/Queries/SituationQueries.swift`
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (situations DDL block ~line 942 + `insertSituation` helper)
- Test: `WatchtowerDesktop/Tests/SituationQueriesTests.swift` (or the file holding existing SituationQueries tests — match its location; `DashboardViewModelTests.swift` hosts related coverage if no dedicated file exists)

**Interfaces:**
- Consumes: Task 2 column `suggested_resolution` (TEXT NOT NULL DEFAULT '').
- Produces (used by Task 5): `Situation.suggestedResolution: String`; `SituationQueries.clearSuggestedResolution(_ db: Database, id: Int) throws`.

- [ ] **Step 1: Test schema mirror**

In `TestDatabase.swift`'s situations `CREATE TABLE` block add, after `resolved_reason`:

```sql
    suggested_resolution TEXT NOT NULL DEFAULT '',
```

(Known drift trap — the column must match production exactly.)

- [ ] **Step 2: Write failing tests**

In the SituationQueries/Dashboard test file:

```swift
func test_situation_readsSuggestedResolution() throws {
    // insert a situation row with suggested_resolution set (raw SQL or the
    // insertSituation helper extended with a suggestedResolution: String = ""
    // parameter), fetch via SituationQueries.fetchByID, assert
    // situation.suggestedResolution == "answered in thread".
}

func test_clearSuggestedResolution_clearsField() throws {
    // insert with mark set; SituationQueries.clearSuggestedResolution(db, id:);
    // re-fetch; assert suggestedResolution == "".
}
```

Write real bodies following the file's fixture conventions. Run (log-file discipline): `cd WatchtowerDesktop && swift test --filter SituationQueries > /tmp/swift-sq.log 2>&1; echo "exit=$?"` — expected `exit=1` (missing member).

- [ ] **Step 3: Implement**

`Situation.swift`: add `let suggestedResolution: String   // column: suggested_resolution` next to `resolvedReason`-adjacent fields, and in `init(row:)`: `suggestedResolution = row["suggested_resolution"] ?? ""`. Add computed `var hasSuggestedResolution: Bool { !suggestedResolution.isEmpty }`.

`SituationQueries.swift`, next to the other mutation helpers:

```swift
/// User's "Keep open" on a suggested resolution (DASH-07): clears the
/// secretary's mark, nothing else — status untouched, no feedback call.
static func clearSuggestedResolution(_ db: Database, id: Int) throws {
    try db.execute(
        sql: "UPDATE situations SET suggested_resolution = '', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
        arguments: [id])
}
```

- [ ] **Step 4: Run tests, then the full Swift suite**

`cd WatchtowerDesktop && swift test > /tmp/swift-t4.log 2>&1; echo "exit=$?"` — expected `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Models/Situation.swift WatchtowerDesktop/Sources/Database/Queries/SituationQueries.swift WatchtowerDesktop/Tests/Helpers/TestDatabase.swift WatchtowerDesktop/Tests/<test-file>.swift
git commit -m "feat(desktop): read and clear the suggested-resolution mark

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Swift — badge, banner, VM action, docs, verification

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/DashboardViewModel.swift` (new `keepOpen` action)
- Modify: `WatchtowerDesktop/Sources/Views/Dashboard/SituationRow.swift` (badge)
- Modify: `WatchtowerDesktop/Sources/Views/Dashboard/SituationReviewPane.swift` (banner)
- Modify: `WatchtowerDesktop/Sources/Views/Dashboard/DashboardView.swift` (wire `onKeepOpen`, feed reload)
- Modify: `docs/app-guide.md`
- Test: `WatchtowerDesktop/Tests/DashboardViewModelTests.swift`

**Interfaces:**
- Consumes: Task 4 `Situation.suggestedResolution`/`hasSuggestedResolution`, `SituationQueries.clearSuggestedResolution`; existing `FeedViewModel.load()` reload pattern from the feed-dashboard feature.

- [ ] **Step 1: Failing VM test**

In `DashboardViewModelTests.swift` (its fixtures: `TestDatabase.createDatabaseManager()`, `insertSituation`, `vm.load()`):

```swift
func test_keepOpen_clearsSuggestionAndReloads() throws {
    // insert open situation with suggested_resolution='answered in thread'
    // (extend insertSituation or raw SQL UPDATE after insert);
    // vm.load(); let situation = vm.situations[0];
    // XCTAssertTrue(situation.hasSuggestedResolution)
    // vm.keepOpen(situation)
    // XCTAssertFalse(vm.situations[0].hasSuggestedResolution)  // reloaded
    // DB-level: suggested_resolution == '' via raw SELECT.
}
```

Write the real body per the file's conventions. Run: `cd WatchtowerDesktop && swift test --filter DashboardViewModelTests > /tmp/swift-t5.log 2>&1; echo "exit=$?"` — `exit=1` (no `keepOpen`).

- [ ] **Step 2: Implement `keepOpen`**

`DashboardViewModel.swift`, next to `done`/`dismiss` (mirror their write-then-reload shape exactly):

```swift
/// "Keep open" on a suggested resolution (DASH-07): clears the secretary's
/// mark and nothing else.
func keepOpen(_ situation: Situation) {
    do {
        try dbManager.dbPool.write { db in
            try SituationQueries.clearSuggestedResolution(db, id: situation.id)
        }
        load()
    } catch {
        errorMessage = "Failed to keep open: \(error.localizedDescription)"
    }
}
```

- [ ] **Step 3: Badge in `SituationRow`**

In the title `VStack`, next to `kindBadge`, render when `situation.hasSuggestedResolution`:

```swift
if situation.hasSuggestedResolution {
    Label("Resolved?", systemImage: "checkmark.circle")
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.green.opacity(0.15), in: Capsule())
        .foregroundStyle(.green)
        .labelStyle(.titleAndIcon)
}
```

(Place it beside `kindBadge` in an `HStack(spacing: 4)` if they'd otherwise stack awkwardly — match the row's existing layout rhythm.)

- [ ] **Step 4: Banner in `SituationReviewPane`**

Add an `onKeepOpen: () -> Void` closure parameter (alongside `onDone` etc.). At the TOP of the pane's scrollable content, above the secretary-card section, render when `situation.hasSuggestedResolution`:

```swift
VStack(alignment: .leading, spacing: 8) {
    Label("The secretary believes this is resolved", systemImage: "checkmark.circle")
        .font(.headline)
        .foregroundStyle(.green)
    Text(situation.suggestedResolution)
        .font(.callout)
    HStack(spacing: 8) {
        Button("Done") { onDone() }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        Button("Keep open") { onKeepOpen() }
    }
}
.padding(12)
.frame(maxWidth: .infinity, alignment: .leading)
.background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
```

- [ ] **Step 5: Wire in `DashboardView`**

In the `SituationReviewPane` call (its verbatim block — add ONLY the new closure, do not disturb the `.id(situation.id)` call-site comment):

```swift
onKeepOpen: { vm.keepOpen(situation); feedVM.load() },
```

(`feedVM.load()` mirrors the other situation mutations — the feed re-joins live content so the badge disappears immediately.)

- [ ] **Step 6: Docs**

`docs/app-guide.md`, Inbox section: after the action-bar paragraph, add — "When a discussion resolves itself (someone else answered and the question was accepted), the secretary marks the situation with a green 'Resolved?' badge and shows its reasoning in a banner with **Done** (confirm and close) and **Keep open** (clear the mark) — it never closes a situation on its own." Follow the stash-dance procedure if `docs/app-guide.md` carries uncommitted user edits at execution time (`git stash push -- docs/app-guide.md` → edit → commit → `git stash pop`, verify `git diff` shows only the user's edits after).

- [ ] **Step 7: Full verification**

```bash
cd /Users/user/PhpstormProjects/watchtower && go build ./... && go vet ./... && go test ./... > /tmp/go-final-rs.log 2>&1; echo "exit=$?"
cd /Users/user/PhpstormProjects/watchtower/WatchtowerDesktop && swift test > /tmp/swift-final-rs.log 2>&1; echo "exit=$?"
```
Both `exit=0`; existing guard tests untouched.

- [ ] **Step 8: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/DashboardViewModel.swift WatchtowerDesktop/Sources/Views/Dashboard/ WatchtowerDesktop/Tests/DashboardViewModelTests.swift
git commit -m "feat(desktop): suggested-resolution badge and banner with Done / Keep open

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git add docs/app-guide.md
git commit -m "docs: describe the suggested-resolution flow in the app guide

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
