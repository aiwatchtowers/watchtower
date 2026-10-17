# Source Deletions and Edits Implementation Plan (Phases 1–2, board #640)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A message, email or comment deleted at its source leaves Watchtower's raw tables, `messages_fts` and the KB index within about a day, and an edit replaces the old text everywhere, using the API budget we already spend.

**Architecture:** Each source diffs a listing it already trusts (Slack `search.messages`, Gmail `messages.list`, IMAP `UID SEARCH ALL`, Jira's full comment list) against what is stored, behind one shared false-deletion guard. Slack rows become tombstones (row kept, text blanked, self-healing); mail rows and Jira comments are deleted. A new `kb_dirty` table, filled by SQL triggers in the same write as the change, makes the KB indexer re-render exactly the documents a deletion or an old edit touched.

**Tech Stack:** Go 1.26, SQLite (`modernc.org/sqlite`, goose migrations, triggers), slack-go, go-imap v2 (`imapmemserver` in tests), Gmail REST via `httptest`; one SwiftUI/GRDB query.

**Spec:** `docs/superpowers/specs/2026-10-17-source-deletions-design.md` (approved 2026-10-17, ask #324: options 1a tombstone, 2a full-history sweep one day per cycle, 3a AI-derived text left as is, 4a losing access counts as deletion). Phase 3 (deleted Jira issues, retention purge) is out of scope.

## Global Constraints

- **Task-scope checks only** (CLAUDE.md "Agent-driven runs"): an implementer runs `go test ./internal/<pkg>` for each package it touched (plus the extra packages its task names), `make lint-diff`, and nothing broader. No `-count=1`. The full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) runs once per phase by the controller and once before the PR.
- **Lint version:** CI pins golangci-lint **v2.11.4**; `make lint-diff` runs `golangci-version-check` first — lint with 2.11.4, never an older local binary. `make lint-diff` is Go-only; a task that touches Swift also runs `make lint-swift`.
- **Swift only where a task says so** (Task 3 only): `make test-swift FILTER=MessageQueryTests`, never an unfiltered `swift test`. Never delete `WatchtowerDesktop/.build`.
- **Migrations:** follow `.claude/skills/add-migration/SKILL.md`. The new file is `internal/db/migrations/00135_source_deletions.sql` (00134 is the last on `origin/main` f854228e3; if another branch lands 00135 first, renumber at merge). Mirror into `internal/db/schema.sql`, add `kb_dirty` to `TestAllTablesExist`, regenerate with `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- **Write transactions stay short** (CLAUDE.md "Database & Migrations"): no network call, no listing, no render inside a write transaction. Every diff reads the stored set, then calls the API, then opens one short transaction for the deletes.
- **False-deletion guards are mandatory, never optional:** a diff runs only on a listing that is complete (no API error, every page fetched, Slack: matches received ≥ reported total). Then `sourcediff.Check` (Task 2) refuses an empty listing over stored rows and a removal of more than half. Every skip is logged with the source, account, range and reason.
- **Inventory guards are never weakened.** No `Test<Module>NN_` test is edited, renamed or split by any task. KB-01's wording and guard are touched only after the owner approves proposal P1 (see "Inventory proposals"); until then new tests live outside `contracts_test.go`.
- **Tests that spawn processes reap them** (none planned; if one appears, kill its process group in `t.Cleanup`). **No network in tests:** only `httptest` servers and `imapmemserver` on loopback.
- **Public repo hygiene:** test data uses `acme`/`example.com`, fake ids such as `C001`/`U001`/`PROJ-1`; no live-install ids, names, domains or paths in code, tests, docs or commit messages.
- **Commits:** one commit per task, conventional prefix, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Slack search silently truncated** (`search.messages` stops at 100 pages, so a window over 10 000 matches reports `pages` ≤ 100 and "completes"): no tombstone may come from it. Pinned in Task 7 (`TestLiveDiff_SkipsWhenTotalExceedsMatched`).
2. **A wrong tombstone heals**: the next search that returns the message restores text and `is_deleted = 0`, and the KB document gets the text back. Pinned in Task 7 (`TestSRCDEL02_ReturningMessageHeals`) and Task 4 (`TestDrainDirty_HealedMessageReturnsToIndex`).
3. **Rows the listing cannot see are never touched**: the last 2 h, rows with a subtype, rows of another Slack account, rows outside the swept day. Pinned in Task 7 (`TestLiveDiff_LeavesRowsOutsideItsScope`) and Task 8 (`TestSweep_DiffsOnlyTheSweptDay`).
4. **Jira returns an empty comment page while reporting `total > 0`**: today that is a silent "no comments", and with set-replace it would wipe the issue's comments. Pinned in Task 5 (`TestSyncComments_IncompleteListingDeletesNothing`).
5. **Mail that arrives between the stored-set read and the listing** must not be deleted, and **IMAP rows under the current UIDVALIDITY** must never be hit by the old-epoch cleanup. Pinned in Task 9 (`TestCheckDeletions_ReadsStoredSetBeforeListing`) and Task 6 (`TestSync_UIDValidityCleanupKeepsCurrentEpoch`).

## Design corrections found against the code

These change what the spec says; each task below already follows the corrected version.

- **`GetOldestMessagesByTimeRange` must NOT filter `is_deleted`.** The digest already treats tombstones as invisible (`internal/digest/pipeline.go:845,948,2181,2190,2203,2277,2499`). It needs them loaded: the channel's considered-mark is `newestTS(loaded)` (`pipeline.go:824`), and `stampConsidered` ignores 0 (`pipeline.go:605-608`). If the loader dropped a channel's trailing tombstones while `ChannelsWithUndigestedMessages` (`internal/db/digests.go:430-451`, which counts every row) still offers the channel, the load would come back empty and the mark would never move. The channel would then be offered again every cycle. That is the discovery/loader disagreement `internal/db/digests.go:423-429` warns about.
- **`GetMessagesByTS` (`internal/db/messages.go:353`) and the targets resolver (`internal/targets/resolver.go:187`) also lack the predicate.** `GetMessagesByTS` serves `tools/taskcontext.go:175`, `tools/experts.go:369`, `tracks/pipeline.go:1418` and `jira/blockers.go:330,364`. Both are added to Task 3.
- **Jira `GetIssueComments` is not proof of a complete set.** It returns success with a short list when a page comes back empty before `total` (`internal/jira/client.go:420-422`, pinned by `TestClient_GetIssueComments_StopsOnEmptyPage`, `client_test.go:69`). Task 5 makes it report completeness, and deletes only on a complete listing.
- **Slack `completed == true` is not proof of a complete listing either.** `searchAndSave` (`internal/sync/search_sync.go:381-384`) completes on `page >= result.Pages`, and Slack caps `pages` at 100. Task 7 adds the matched ≥ `Total` check.
- **IMAP needs no `kb_dirty`.** Its KB key is one message (`internal/kb/source_mail.go:200`), and every non-Slack source reconciles on every run (`internal/kb/indexer.go:356-366`), so a deleted row leaves the index within one cycle already. Gmail does need it, because its key is the thread (`source_mail.go:82`).
- **`kb_dirty` is filled by triggers, not by each writer.** A trigger is the same write by construction, and it also covers writers no task names, such as `message_sync.go` and thread sync edits. It follows the `messages_au` FTS precedent (`00001_init.sql:106-112`). This is the spec's "same transaction" requirement, met with less code.
- **Confluence needs nothing.** A deleted comment stamps its page's `children_changed_at` (`internal/extsync/reconcile.go:165-196`), and the KB's Confluence `Changed` reads that marker (`internal/kb/source_ext_changed.go:71-73`). The spec's Phase 1 check is answered; there is no task.
- **The Slack tombstone also deletes the message's `files` rows** (file names are content). The spec names only reactions.

## Lanes and dependencies

```
Task 1 (migration) ──┬─> Task 4 (KB drain)
                     ├─> Task 7 (Slack live diff) ──> Task 8 (Slack sweep)      [Phase 2]
Task 2 (guard) ──────┼─> Task 6 (IMAP)
                     └─> Task 9 (Gmail daily diff)                               [Phase 2]
Task 3 (readers + Swift)   Task 5 (Jira comments)    — independent from the start
Task 10 (docs) after all
```

- **Start in parallel lanes (own worktree each):** Task 1, Task 2, Task 3, Task 5.
- **After Tasks 1 and 2 merge into the branch:** Task 4, Task 6, Task 7 and Task 9 can run in parallel lanes. They touch disjoint files: `internal/kb/*`, `internal/imap/*` + `internal/db/email_accounts.go`, `internal/sync/*` + `internal/db/slack_deletions.go`, and `internal/gmail/*` + `internal/db/gmail.go` + `internal/daemon/daemon.go`.
- **Sequential:** Task 8 after Task 7 (same `search_sync.go`). Task 10 last.
- **Phase 1** = Tasks 1–7. **Phase 2** = Tasks 8–9. The controller runs the full gate after Task 7 and again after Task 10.
- Swift is only in Task 3, so there is never more than one ML-stack link.

---

### Task 1: Migration 00135 — `kb_dirty`, its triggers, and the two sweep stamps

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00135_source_deletions.sql`
- Modify: `internal/db/schema.sql` (after the `kb_*` block near line 2171; the new columns in `slack_accounts` at line 1534 and `google_accounts` at line 1514)
- Modify: `internal/db/db_test.go:166` (`TestAllTablesExist` gains `kb_dirty`)
- Regenerate: `internal/db/testdata/*.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Test: `internal/db/kb_dirty_test.go`

**Interfaces:**
- Produces: table `kb_dirty(source, key, gen)`, where `source` is a KB source name (`slack`/`gmail`/`jira`) and `key` is that source's document key. Triggers `messages_kb_dirty`, `gmail_messages_kb_dirty` and `jira_comments_kb_dirty`. Columns `slack_accounts.deletion_sweep_day TEXT NOT NULL DEFAULT ''` (the last UTC day the Slack sweep finished, `YYYY-MM-DD`) and `google_accounts.deletions_checked_at TEXT NOT NULL DEFAULT ''` (RFC 3339 UTC of the last Gmail ID diff).

The SQL is fixed copy: the key expressions must equal `slackKeyFor` (`internal/kb/source_slack.go:87`), `gmailKeyExpr` (`source_mail.go:82`) and the Jira key (`source_work.go:20`).

```sql
-- +goose Up
CREATE TABLE IF NOT EXISTS kb_dirty (
    source TEXT NOT NULL,              -- KB source name: slack | gmail | jira
    key    TEXT NOT NULL,              -- that source's document key (kb_documents.id)
    gen    INTEGER NOT NULL DEFAULT 0, -- bumped on every re-mark; the drain deletes only the gen it rendered
    PRIMARY KEY (source, key)
);
ALTER TABLE slack_accounts ADD COLUMN deletion_sweep_day TEXT NOT NULL DEFAULT '';
ALTER TABLE google_accounts ADD COLUMN deletions_checked_at TEXT NOT NULL DEFAULT '';

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS messages_kb_dirty AFTER UPDATE OF text, is_deleted ON messages
WHEN OLD.text != NEW.text OR OLD.is_deleted != NEW.is_deleted
BEGIN
    INSERT INTO kb_dirty (source, key) VALUES ('slack',
        CASE WHEN COALESCE(NEW.thread_ts, '') != '' THEN 'slack:thread:' || NEW.channel_id || ':' || NEW.thread_ts
             ELSE 'slack:day:' || NEW.channel_id || ':' || date(NEW.ts_unix, 'unixepoch') END)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
    INSERT INTO kb_dirty (source, key) VALUES ('slack',
        CASE WHEN COALESCE(OLD.thread_ts, '') != '' THEN 'slack:thread:' || OLD.channel_id || ':' || OLD.thread_ts
             ELSE 'slack:day:' || OLD.channel_id || ':' || date(OLD.ts_unix, 'unixepoch') END)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS gmail_messages_kb_dirty AFTER DELETE ON gmail_messages
BEGIN
    INSERT INTO kb_dirty (source, key) VALUES ('gmail',
        'gmail:' || OLD.account_id || ':' || CASE WHEN OLD.thread_id = '' THEN 'm:' || OLD.id ELSE OLD.thread_id END)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS jira_comments_kb_dirty AFTER DELETE ON jira_comments
BEGIN
    INSERT INTO kb_dirty (source, key) VALUES ('jira', 'jira:' || OLD.account_id || ':' || OLD.issue_key)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER IF EXISTS jira_comments_kb_dirty;
DROP TRIGGER IF EXISTS gmail_messages_kb_dirty;
DROP TRIGGER IF EXISTS messages_kb_dirty;
ALTER TABLE google_accounts DROP COLUMN deletions_checked_at;
ALTER TABLE slack_accounts DROP COLUMN deletion_sweep_day;
DROP TABLE IF EXISTS kb_dirty;
```

- [ ] **Step 1: Write the failing tests** in `internal/db/kb_dirty_test.go`:
  - `TestKBDirty_SlackTextChangeMarksThreadAndDay`: upsert a top-level message (ts `1700000000.000100`, channel `1:C001`) and a reply (thread_ts `1700000000.000100`). Re-upsert both with new text through `UpsertMessageBatch`. Rows `('slack','slack:day:1:C001:2023-11-14')` and `('slack','slack:thread:1:C001:1700000000.000100')` exist.
  - `TestKBDirty_UnchangedUpsertMarksNothing`: re-upserting identical text and `is_deleted` leaves `kb_dirty` empty.
  - `TestKBDirty_TombstoneMarks`: `UPDATE messages SET is_deleted = 1, text = ''` marks the key, and `messages_fts` no longer matches the old text (the existing `messages_au` trigger still runs alongside).
  - `TestKBDirty_ReMarkBumpsGen`: two changes to the same key leave one row with `gen >= 1`.
  - `TestKBDirty_GmailDeleteMarksThreadOrMessageKey`: deleting a threaded row marks `gmail:<acct>:<thread>`, and deleting a threadless one marks `gmail:<acct>:m:<id>`.
  - `TestKBDirty_JiraCommentDeleteMarksIssue`: marks `jira:<acct>:PROJ-1`.
  - `TestMigration00135_AddsSweepStampColumns`: both columns exist with default `''`.
- [ ] **Step 2:** `go test ./internal/db -run 'TestKBDirty|TestMigration00135'`. Expected FAIL: `no such table: kb_dirty`.
- [ ] **Step 3:** Write the migration above, mirror it into `schema.sql` (table, the two columns with a trailing comment each, the three triggers), and add `kb_dirty` to `TestAllTablesExist`.
- [ ] **Step 4:** `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then `go test ./internal/db`. Expected PASS, with `TestMigrationIdempotent` included.
- [ ] **Step 5:** `make lint-diff`. Commit the migration, `schema.sql`, the test, the goldens and `TestDatabase+Schema.swift`: `feat(db): kb_dirty table, its triggers and the deletion sweep stamps (#640)`.

---

### Task 2: `internal/sourcediff` — the shared false-deletion guard

**Depends on:** none

**Files:**
- Create: `internal/sourcediff/guard.go`, `internal/sourcediff/guard_test.go`

**Interfaces:**
- Produces:
  ```go
  // Floors are the minimum stored-row counts at which each refusal applies.
  type Floors struct{ EmptyMin, HalfMin int }
  var SlackFloors = Floors{EmptyMin: 5, HalfMin: 10} // spec: 0 hits over >=5 rows; > half of >=10 rows
  var MailFloors  = Floors{EmptyMin: 1, HalfMin: 1}  // spec: 0 IDs while any stored; > half
  // Check reports whether a diff may delete the missing rows. stored = local rows inside the
  // range the listing covers, listed = how many of that range the listing returned,
  // missing = stored rows absent from it. reason is non-empty exactly when a delete is refused.
  func Check(stored, listed, missing int, f Floors) (ok bool, reason string)
  ```
  Rules: `missing == 0` → `(false, "")` (nothing to do). `listed == 0 && stored >= f.EmptyMin` → refuse with `"listing returned 0 of N stored rows"`. `2*missing > stored && stored >= f.HalfMin` → refuse with `"would remove M of N stored rows"`. Otherwise `(true, "")`.

- [ ] **Step 1: Write the failing table test** `TestCheck` with these cases, asserting `ok` and whether `reason` is empty:
  `(0,0,0,Slack)→false,""`; `(5,0,5,Slack)→false,reason`; `(4,0,4,Slack)→true`; `(10,4,6,Slack)→false,reason`; `(9,3,6,Slack)→true`; `(10,5,5,Slack)→true`; `(1,0,1,Mail)→false,reason`; `(3,1,2,Mail)→false,reason`; `(4,2,2,Mail)→true`.
- [ ] **Step 2:** `go test ./internal/sourcediff`. Expected FAIL (package missing).
- [ ] **Step 3:** Implement `Check`. No logging and no I/O in this package.
- [ ] **Step 4:** `go test ./internal/sourcediff` passes. Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(sourcediff): shared guard against deleting from a bad listing (#640)`.

---

### Task 3: Readers skip tombstones (Go + one Desktop query)

**Depends on:** none

**Files:**
- Modify: `internal/db/messages.go`: `GetMessages` (line 98, add `is_deleted = 0` to `conditions`, with the `m.` prefix through `col`), `GetThreadReplies` (306), `GetMessageNear` (325), `GetMessagesByTS` (353). **Do not** change `GetOldestMessagesByTimeRange` (177). Extend its doc comment with one sentence: tombstones stay in the load because the digest's considered-mark is computed from it (see "Design corrections").
- Modify: `internal/targets/resolver.go:187`: add `AND is_deleted = 0`, so a tombstoned message resolves as "not in local DB".
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/MessageQueries.swift:4-9`: `fetchByTimeRange` adds `AND is_deleted = 0` (`DigestDetailView` would otherwise list blank rows).
- Test: `internal/db/messages_test.go` (or a new `messages_tombstone_test.go`), `internal/targets/resolver_test.go`, `WatchtowerDesktop/Tests/Core/QueryTests.swift` (`MessageQueryTests`).

**Interfaces:**
- Consumes: nothing new. A tombstone in tests is a row with `is_deleted = 1, text = ''`, written by `UpsertMessage` with `IsDeleted: true`.

- [ ] **Step 1: Write the failing tests:**
  - `TestMessageReaders_SkipTombstones`: seed one live row and one tombstone in `1:C001`, the tombstone as a thread reply and the nearest row to a probe ts. Assert:
    - `GetMessages{ChannelID}` returns only the live row, and so does `GetMessages{ExcludeDMs: true}` (seed the channel row as type `public`).
    - `GetThreadReplies` omits the tombstone.
    - `GetMessageNear` at the tombstone's ts returns the live row (when it lies within 60 s) or nil.
    - `GetMessagesByTS([tombstone ts])` is empty.
  - `TestGetOldestMessagesByTimeRange_KeepsTombstones`: the tombstone is returned, with `IsDeleted == true`.
  - `TestSlackResolver_TombstoneIsNotInLocalDB` (`internal/targets`): the body is `"[slack url not in local DB]"`.
  - Swift `MessageQueryTests.testFetchByTimeRangeSkipsDeleted`: one row inserted with `is_deleted = 1` is not returned.
- [ ] **Step 2:** `go test ./internal/db -run 'TestMessageReaders_SkipTombstones|TestGetOldestMessagesByTimeRange_KeepsTombstones'` and `go test ./internal/targets -run TestSlackResolver_Tombstone`. Expected FAIL. Then `make test-swift FILTER=MessageQueryTests`. Expected FAIL.
- [ ] **Step 3:** Add the predicates.
- [ ] **Step 4:** `go test ./internal/db ./internal/targets ./internal/tools ./internal/tracks ./internal/jira ./internal/ai ./internal/guide ./internal/reactioncmd ./internal/digest`. These are the consumers of the four readers. A non-inventory test that seeded a deleted row and expected it back is updated, and the commit message says so. A `Test<Module>NN_` failure is stop-and-ask. Then `make test-swift FILTER=MessageQueryTests`, `make lint-diff` and `make lint-swift`.
- [ ] **Step 5:** Commit: `fix(db): message readers skip tombstoned rows (#640)`.

---

### Task 4: KB indexer drains `kb_dirty`

**Depends on:** Task 1

**Files:**
- Create: `internal/kb/dirty.go`, `internal/kb/dirty_test.go`
- Modify: `internal/kb/indexer.go:76-88` (`runner.run`: call the drain for each source after `runSource` reports caught up, before `reconcileIfDue`. An error is appended to `errs` like a reconcile error. Over budget sets `st.Incomplete` and breaks, the same as `runSource`.)

**Interfaces:**
- Consumes: `kb_dirty` (Task 1); `buildBatch`, `prepareBatch`, `storeBatch`, `withTx` and `batchSize` (`indexer.go`).
- Produces: `func drainDirty(ctx context.Context, d *db.DB, src Source, overBudget func() bool, st *Stats) (caughtUp bool, err error)`. It loops: `SELECT key, gen FROM kb_dirty WHERE source = ? ORDER BY key LIMIT batchSize`, renders the keys outside any transaction (`buildBatch` + `prepareBatch`), then in one `withTx` calls `storeBatch` and, per key, `DELETE FROM kb_dirty WHERE source = ? AND key = ? AND gen = ?` with the gen it read. It stops when the select is empty (true) or `overBudget()` (false). A key re-marked during its render keeps its row, because its gen moved, and is drained on a later pass.

- [ ] **Step 1: Write the failing tests** in `dirty_test.go`. Use the package's existing test DB helper and fixed `Options.Now`; everything below is seeded through `db` writers.
  - `TestDrainDirty_OldSlackEditReachesIndex`: index a top-level message 10 days old with text `alpha`. Re-upsert it with `beta`. `Run`. The day document's chunks contain `beta` and not `alpha`, and `kb_dirty` is empty. (Before the drain it fails: the 48 h tail at `source_slack.go:121-125` misses the edit.)
  - `TestDrainDirty_TombstoneRemovesTextFromDayDoc`: two old top-level messages (`alpha`, `gamma`) on one day, both indexed. Tombstone `alpha` (`UPDATE messages SET is_deleted = 1, text = ''`). `Run`. The day document holds `gamma` and not `alpha`.
  - `TestDrainDirty_LastMessageGoneDeletesDoc`: tombstone the only reply of an old thread whose parent is also tombstoned. `Run`. The thread document is gone from `kb_documents` and `kb_chunks`.
  - `TestDrainDirty_GmailPartialThreadDelete`: index a two-message thread, delete one row, `Run`. The thread document lacks the deleted body.
  - `TestDrainDirty_HealedMessageReturnsToIndex`: tombstone, `Run`, re-upsert the original text with `IsDeleted: false`, `Run`. The text is searchable again through `kb.Search`.
  - `TestDrainDirty_ReMarkDuringRenderSurvives`: use a test `runner` with a stub `Source` named `slack` whose `Build` bumps its own key's `gen` once (`INSERT ... ON CONFLICT DO UPDATE SET gen = gen + 1`) and returns nil. After `run`, `kb_dirty` still holds the key.
  - `TestSRCDEL03_TriggerKeysMatchSourceKeys`: for a reply, a top-level message, a threaded and a threadless Gmail row, and a Jira comment, the key the trigger writes equals `SlackDocRef(...)`, a key in `gmailSource{}.Keys(...)`, and a key in `jiraSource{}.Keys(...)` respectively. This test pins the Go↔SQL dual path.
- [ ] **Step 2:** `go test ./internal/kb -run 'TestDrainDirty|TestKBDirtyTriggerKeys'`. Expected FAIL on the first five.
- [ ] **Step 3:** Implement `drainDirty` and wire it into `run`.
- [ ] **Step 4:** `go test ./internal/kb` passes, `TestKB01_IncrementalEqualsRebuild` / `TestKB03_*` unchanged and green. `TestRun_RendersOutsideTheWriteLock` stays green: the drain renders before its transaction. Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(kb): re-render documents marked dirty by deletions and edits (#640)`.

---

### Task 5: Jira comments — set-replace for refetched issues

**Depends on:** none (the KB follows through the issue's `synced_at` bump; Task 1's trigger adds a second path once merged)

**Files:**
- Modify: `internal/jira/client.go:399-425`: `GetIssueComments(ctx, key) (comments []IssueComment, complete bool, err error)`. `complete` is false only when the loop stopped on an empty page while `startAt < page.Total`.
- Modify: `internal/db/ideas.go:641-675`: keep `UpsertJiraComments` (used only for an incomplete listing) and add `ReplaceJiraIssueComments(accountID int64, issueKey string, comments []JiraComment) (removed int, err error)`. In one transaction it runs the same upsert per comment, then `DELETE FROM jira_comments WHERE account_id = ? AND issue_key = ? AND id NOT IN (<fetched ids>)`. With an empty list, it deletes every comment of the issue.
- Modify: `internal/jira/sync.go:597-650` (`syncComments`): drop the `len(comments) == 0 → continue` at line 624. On `complete == false`, log `comment sync: %s listing incomplete (%d of total), keeping stored comments`, upsert what was fetched with `UpsertJiraComments`, and delete nothing. A complete listing (including an empty one) goes through `ReplaceJiraIssueComments`.
- Test: `internal/jira/client_test.go`, `internal/jira/sync_comments_test.go`, `internal/db/ideas_test.go` (or `jira_comments_test.go`)

**Interfaces:**
- Produces: `GetIssueComments` with the three-value signature (only caller: `sync.go:621`), and `db.ReplaceJiraIssueComments` as above.

- [ ] **Step 1: Write the failing tests:**
  - `TestClient_GetIssueComments_StopsOnEmptyPage`: update its call site to the new signature, keep its assertions, and add `assert.False(t, complete)`. It is not an inventory guard. The single-page and paginated tests assert `complete == true`.
  - `TestReplaceJiraIssueComments_RemovesAbsentAndEmptyClears`: store c1, c2 on PROJ-1 and c3 on PROJ-2. Replace PROJ-1 with [c2 edited]: c1 gone, c2 has the new body, c3 untouched, `removed == 1`. Replace PROJ-1 with an empty list: PROJ-1 has no comments, c3 is untouched.
  - `TestSyncComments_DeletedCommentDisappears`: with the stub server, sync PROJ-1 with comments [c1, c2], then again with [c2]. Only c2 is stored.
  - `TestSyncComments_LastCommentDeleted`: the second sync returns `{"total":0,"comments":[]}`, and no comment is stored.
  - `TestSyncComments_IncompleteListingDeletesNothing`: the second sync returns `{"total":5,"comments":[]}`, and c1 and c2 are still stored.
  - `TestSyncComments_FetchErrorDeletesNothing`: a 500 on the second fetch leaves both stored.
- [ ] **Step 2:** `go test ./internal/jira ./internal/db -run 'GetIssueComments|ReplaceJiraIssueComments|TestSyncComments_'`. Expected FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `go test ./internal/jira ./internal/db ./internal/ideas` passes; `TestIdeas01_*` is unchanged (IDEA-01 covers the comment cap, which this task leaves alone). Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(jira): drop comments deleted at the source on refetch (#640)`.

---

### Task 6: IMAP — UID diff and the old-UIDVALIDITY cleanup

**Depends on:** Task 2

**Files:**
- Modify: `internal/imap/client.go`: add `func (cl *Client) SearchAll() ([]uint32, error)` (`UIDSearch(&imap.SearchCriteria{}, nil)`, error wrapped as `imap: search all: %w`).
- Modify: `internal/db/email_accounts.go`: add `ImapStoredUIDs(accountID, uidValidity int64) ([]int64, error)`, `DeleteImapMessages(accountID, uidValidity int64, uids []int64) (int, error)` (one transaction, chunked `IN` lists of 500), and `DeleteImapMessagesOutsideUIDValidity(accountID, uidValidity int64) (int, error)`.
- Modify: `internal/imap/sync.go:146-255`: after the watermark block, call `s.reconcileDeletions(client, int64(newUIDValidity))` (new unexported method, same file). It runs only when the account's persisted uidvalidity, read back with `GetImapWatermark`, equals `newUIDValidity`, so it never runs after a failed `SetImapWatermark`.
  1. `stored := ImapStoredUIDs(acct, v)`, read before the listing.
  2. `listed := client.SearchAll()`. On error, log and return; nothing is deleted.
  3. `missing := stored − listed`. Apply `sourcediff.Check(len(stored), len(stored ∩ listed), len(missing), sourcediff.MailFloors)`. Refusals are logged.
  4. `DeleteImapMessages(acct, v, missing)`.
  5. `DeleteImapMessagesOutsideUIDValidity(acct, v)`. The guard does not apply here: rows under a dead UIDVALIDITY name nothing on the server.

  Failures are logged with the account id and never change `Sync`'s return.
- Test: `internal/imap/sync_test.go`, `internal/db/email_accounts_test.go`

**Interfaces:**
- Consumes: `sourcediff.Check`, `sourcediff.MailFloors` (Task 2).

- [ ] **Step 1: Write the failing tests** (in-memory `imapmemserver` via `startTestServer`, loopback only):
  - `TestSearchAll_ReturnsEveryUID` (`client_test.go`).
  - `TestSync_ExpungedMessageIsDeleted`: sync 3 messages, expunge one on the server, sync again. 2 rows remain.
  - `TestSync_EmptyMailboxDeletesNothing`: sync 2, expunge both, sync. Both rows remain (guard), and the log holds the refusal.
  - `TestSync_OverHalfGoneDeletesNothing`: sync 4, expunge 3, sync. 4 rows remain.
  - `TestSync_UIDValidityCleanupKeepsCurrentEpoch`: seed rows under uidvalidity `old` and the watermark at `old`. The server's mailbox has a different UIDVALIDITY (recreate the mailbox, or seed `old` as a value the server never uses). After `Sync`, no row has `uidvalidity = old`, and the rows stored under the new value in this same `Sync` are all present.
  - `TestDeleteImapMessagesOutsideUIDValidity_ScopesToAccount` (`internal/db`): another account's rows are untouched.
- [ ] **Step 2:** `go test ./internal/imap ./internal/db -run 'SearchAll|TestSync_Expunged|TestSync_EmptyMailbox|TestSync_OverHalf|TestSync_UIDValidityCleanup|OutsideUIDValidity'`. Expected FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `go test ./internal/imap ./internal/db` passes. The existing watermark and cap tests are unchanged. Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(imap): delete expunged mail and rows of a dead UIDVALIDITY (#640)`.

---

### Task 7: Slack — tombstone writer and the live-window diff

**Depends on:** Task 1, Task 2

**Files:**
- Create: `internal/db/slack_deletions.go`, `internal/db/slack_deletions_test.go`
- Create: `internal/sync/deletions.go`, `internal/sync/deletions_test.go`
- Modify: `internal/sync/search_sync.go`:
  - `searchAndSave` (line 233) gains a last parameter `listing *searchListing` (nil for no collection). `BackfillSearch` (line 211) passes nil, so its behaviour and `ErrBackfillIncomplete` are unchanged.
  - `syncViaSearch` (line 147) passes a listing and, after the `if completed` block, calls `o.diffLiveWindow(listing)`.

**Interfaces:**
- Consumes: `sourcediff.Check`, `sourcediff.SlackFloors` (Task 2); the `messages_kb_dirty` trigger (Task 1).
- Produces (db):
  ```go
  type SlackMessageKey struct{ ChannelID, TS string } // namespaced channel id, Slack ts
  // LiveSlackMessageKeys lists the account's rows with subtype = '' AND is_deleted = 0 and
  // from <= ts_unix < to (channel_id in the account's "<id>:" prefix range, as SlackAccountHasMessages does).
  func (db *DB) LiveSlackMessageKeys(accountID int64, from, to float64) ([]SlackMessageKey, error)
  // TombstoneSlackMessages, in one transaction per call: UPDATE messages SET is_deleted = 1,
  // text = '', raw_json = '{}' WHERE channel_id = ? AND ts = ? AND is_deleted = 0; DELETE FROM
  // reactions WHERE channel_id = ? AND message_ts = ?; DELETE FROM files WHERE
  // message_channel_id = ? AND message_ts = ?. Returns rows tombstoned.
  func (db *DB) TombstoneSlackMessages(keys []SlackMessageKey) (int, error)
  ```
- Produces (sync):
  ```go
  type searchListing struct {
      seen     map[db.SlackMessageKey]struct{}
      matched  int  // matches received across pages
      total    int  // result.Total from page 1
      maxPages int  // 0 = no cap; used by Task 8
      tooLarge bool // page 1 reported more than maxPages pages
  }
  func newSearchListing(maxPages int) *searchListing
  func (l *searchListing) complete() bool { return l.matched >= l.total }
  // liveDiffWindow: [UTC midnight of now's UTC date, now − 2h); empty when to <= from.
  func liveDiffWindow(now time.Time) (from, to time.Time)
  // tombstoneMissing diffs [from, to) against l (guard with SlackFloors), tombstones, logs.
  func (o *Orchestrator) tombstoneMissing(l *searchListing, from, to time.Time) (int, error)
  func (o *Orchestrator) diffLiveWindow(l *searchListing)
  ```
  `diffLiveWindow` runs only when the search completed and `l.complete()` is true. It reads `now` from `o.clock()` (`orchestrator.go:489`) so tests can fix it. It logs and swallows a `tombstoneMissing` error (the deletion is best-effort and never fails the sync). The window is always inside what the query covered: `searchWindow` keeps `after:` at or before local today − 2, so local yesterday onward is fetched, which contains UTC today in every time zone. `listed` counts only `seen` keys whose ts (seconds via `parseSlackTS`) lies in `[from, to)`.

- [ ] **Step 1: Write the failing tests:**
  - db: `TestTombstoneSlackMessages_BlanksRowAndChildren`. Text is `''`, `is_deleted = 1`, `raw_json = '{}'`, and `user_id`/`thread_ts`/`ts` are kept. The message's reactions and files are gone, those of another message stay, and `SearchMessages` no longer finds the text.
  - db: `TestLiveSlackMessageKeys_Scope`. Rows with a subtype, tombstones, another account's rows and rows outside `[from, to)` are excluded.
  - sync: `TestLiveDiffWindow`. `now = 2026-09-22T15:00Z` gives `[2026-09-22T00:00Z, 13:00Z)`. `now = 2026-09-22T01:30Z` gives an empty window.
  - sync, using `newTestSetup` + `searchAuditMux` with a search handler serving fixed matches, `ts.orch.now` fixed at `2026-09-22T15:00Z`, and rows seeded at 08:00–12:00Z that day:
    - `TestLiveDiff_TombstonesMissingRow`: 10 stored, 9 returned. The missing row is a tombstone and `kb_dirty` holds its key.
    - `TestLiveDiff_SkipsWhenListingEmpty`: 6 stored, 0 matches. Nothing is tombstoned.
    - `TestLiveDiff_SkipsOverHalf`: 10 stored, 4 returned. Nothing is tombstoned.
    - `TestLiveDiff_SkipsWhenTotalExceedsMatched`: page 1 of 1 with `total: 500` and 9 matches. Nothing is tombstoned.
    - `TestLiveDiff_SkipsIncompletePages`: page 2 fails non-fatally. Nothing is tombstoned.
    - `TestLiveDiff_LeavesRowsOutsideItsScope`: a row at 14:00Z (last 2 h), a `channel_join` row, a row from yesterday, and a row of account 2. None returned by search, and all survive.
    - `TestSRCDEL02_ReturningMessageHeals`: tombstoned in run 1, returned by search in run 2. Text is back and `is_deleted = 0`.
    - `TestBackfillSearch_NeverTombstones`: `BackfillSearch` over a range whose stored rows search does not return leaves them live.
- [ ] **Step 2:** `go test ./internal/db -run 'TombstoneSlackMessages|LiveSlackMessageKeys'` and `go test ./internal/sync -run 'TestLiveDiff|TestBackfillSearch_NeverTombstones'`. Expected FAIL.
- [ ] **Step 3:** Implement. `searchAndSave` adds each converted message's `{namespacedChannelID, msg.Timestamp}` to `listing.seen`, adds `len(result.Messages)` to `matched`, and records `total` on page 1.
- [ ] **Step 4:** `go test ./internal/sync ./internal/db ./internal/historybackfill` pass. `search_backfill_test.go` and `search_sync_ratelimit_test.go` are unchanged. Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(sync): tombstone Slack messages deleted inside the live search window (#640)`.

---

### Task 8: Slack — rolling day sweep (Phase 2)

**Depends on:** Task 7 (same files), Task 1 (`deletion_sweep_day`)

**Files:**
- Modify: `internal/db/slack_deletions.go`: add
  ```go
  func (db *DB) SlackDeletionSweepDay(accountID int64) (string, error)      // '' = never swept
  func (db *DB) SetSlackDeletionSweepDay(accountID int64, day string) error // "YYYY-MM-DD" UTC
  // NextSlackSweepDay: newest UTC date (date(ts_unix,'unixepoch')) holding a row of the account
  // with subtype = '' AND is_deleted = 0 AND ts_unix < before; ok=false when none.
  func (db *DB) NextSlackSweepDay(accountID int64, before float64) (day string, ok bool, err error)
  ```
- Modify: `internal/sync/deletions.go`: add `const sweepMaxPages = 10` (about 30 s of the shared ~20 req/min Tier-2 budget per cycle, `internal/slack/ratelimit.go:23`) and `func (o *Orchestrator) sweepDeletionDay(ctx context.Context) error`.
- Modify: `internal/sync/orchestrator.go:407-410` (`runSearchSync`): right after the `searchRateLimited` early return, call `sweepDeletionDay` unless `o.searchIncomplete`. Log and swallow its error.
- Modify: `internal/sync/search_sync.go` (`searchAndSave`): when `listing.maxPages > 0 && result.Pages > listing.maxPages` on page 1, set `tooLarge`, upsert page 1, and return `completed = false`.

**Behaviour of `sweepDeletionDay`:**
1. `now := o.clock()`. `ceiling` = UTC midnight of `(now − 2h)`. `cursor` = `SlackDeletionSweepDay`. `before` = the cursor's UTC midnight when it is set and earlier than `ceiling`, else `ceiling`.
2. `day := NextSlackSweepDay(acct, before)`. If none and the cursor was set, wrap: `NextSlackSweepDay(acct, ceiling)`. If still none, return.
3. `after, beforeDate := slackSearchRange(day, day+24h)`, then query `after:<after> before:<beforeDate>` through `searchAndSave(ctx, q, false, newSearchListing(sweepMaxPages))`. The upsert refreshes edited text, and the trigger marks the KB.
4. If `listing.tooLarge`, log `slack deletion sweep: %s has more than %d pages, skipped`, advance the cursor to `day`, and return. Else if not completed or `!listing.complete()` (rate limit, partial pages), return without advancing the cursor, so the day is retried next cycle.
5. Call `tombstoneMissing(listing, day 00:00Z, day+1 00:00Z)`, then `SetSlackDeletionSweepDay(acct, day)`. The cursor also advances after a guard refusal, so one bad day cannot stall the sweep.

- [ ] **Step 1: Write the failing tests** (`ts.orch.now` fixed at `2026-09-22T15:00Z`; rows on 2026-09-10 and 2026-09-05; search handler keyed on the query):
  - `TestNextSlackSweepDay` (db): newest day first, strictly before `before`. Days holding only tombstones or subtyped rows are skipped, and other accounts are ignored.
  - `TestSweep_FirstRunTakesNewestDayAndAdvances`: cursor `''`. The query is `after:2026-09-09 before:2026-09-12`, a row missing from the results is tombstoned, and the cursor is `2026-09-10`.
  - `TestSweep_NextRunWalksBackThenWraps`: cursor `2026-09-10` sweeps 2026-09-05. Cursor `2026-09-05` wraps to 2026-09-10.
  - `TestSweep_DiffsOnlyTheSweptDay`: a 2026-09-11 row absent from the results survives, because it lies outside `[day, day+1)`.
  - `TestSweep_RefreshesEditedText`: search returns new text for a stored row. The row is updated and `kb_dirty` holds its key.
  - `TestSweep_TooManyPagesSkipsAndAdvances`: page 1 reports `pages: 11`. No tombstone, and the cursor advances.
  - `TestSweep_RateLimitedHoldsCursor`: page 1 returns 429. No tombstone, and the cursor is unchanged.
  - `TestSweep_GuardRefusalAdvances`: the day has 6 rows and search returns 0. No tombstone, and the cursor advances.
  - `TestRunSearchSync_SkipsSweepWhenRateLimited`: the live search is rate-limited, and no sweep query is sent.
- [ ] **Step 2:** `go test ./internal/db -run TestNextSlackSweepDay` and `go test ./internal/sync -run 'TestSweep_|TestRunSearchSync_SkipsSweep'`. Expected FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `go test ./internal/sync ./internal/db` pass. Check that existing `orchestrator_test.go` tests which count search queries still hold. Where one breaks because of the extra sweep query, update the expectation to the new behaviour and say so in the commit (none are inventory guards). Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(sync): sweep one stored Slack day per cycle for deletions and edits (#640)`.

---

### Task 9: Gmail — daily message ID diff (Phase 2)

**Depends on:** Task 1 (`deletions_checked_at`), Task 2

**Files:**
- Modify: `internal/db/gmail.go`: add `GmailStoredIDs(accountID int64) (ids []string, oldestUnix float64, err error)` (`oldestUnix` is `MIN(internal_date)` parsed, 0 when empty) and `DeleteGmailMessages(accountID int64, ids []string) (int, error)` (one transaction, `IN` chunks of 500; the trigger marks the thread keys).
- Modify: `internal/db/google_accounts.go`: add `GmailDeletionsCheckedAt(accountID int64) (time.Time, error)` (zero when `''` or unparseable) and `SetGmailDeletionsCheckedAt(accountID int64, t time.Time) error`.
- Create: `internal/gmail/deletions.go`, `internal/gmail/deletions_test.go`.
- Modify: `internal/daemon/daemon.go:842-856` (`phaseGmailSync`): after a `Sync` that returned no error, call `s.CheckDeletions(ctx, time.Now())`. Log `gmail: %d deleted messages removed` when the count is above 0, and log any error. This runs outside `observePhase`, because deletions publish no event.

**Interfaces:**
- Consumes: `ListInboxMessageIDs(ctx, query, 0)` (`internal/gmail/client.go:197`, which fails as a whole on any page error); `sourcediff.Check`, `sourcediff.MailFloors`.
- Produces: `func (s *Syncer) CheckDeletions(ctx context.Context, now time.Time) (removed int, err error)`:
  1. If `now − GmailDeletionsCheckedAt < 24h`, return 0.
  2. `stored, oldest := GmailStoredIDs`, read before the listing. When nothing is stored, stamp `now` and return.
  3. List with `fmt.Sprintf("after:%d -in:trash -in:spam", int64(oldest)-86400)`. All mail, so archived mail is not counted as deleted. On error, return it wrapped, without a stamp, so the next cycle retries. `ErrAuthRevoked` stays matchable.
  4. `missing := stored − listed`, then `sourcediff.Check(len(stored), len(stored ∩ listed), len(missing), MailFloors)`. On refusal, log, stamp and return 0.
  5. `DeleteGmailMessages`, then stamp `now`.

- [ ] **Step 1: Write the failing tests** (`newTestSyncerForMux` from `sync_test.go:779`; the list handler records each `q`):
  - `TestCheckDeletions_RemovesUnlistedMessage`: 4 stored, 3 listed. One row is deleted, and the query contains `-in:trash -in:spam` and no `in:inbox`.
  - `TestCheckDeletions_RunsOncePerDay`: a second call 1 h later sends no list request; a call 25 h later does.
  - `TestCheckDeletions_EmptyListingDeletesNothing`: 3 stored, 0 listed. Nothing is deleted, and the stamp is written.
  - `TestCheckDeletions_OverHalfDeletesNothing`: 4 stored, 1 listed.
  - `TestCheckDeletions_ListErrorKeepsRowsAndRetries`: a 500 from the list leaves no deletion and no stamp.
  - `TestCheckDeletions_ReadsStoredSetBeforeListing`: the list handler inserts a new row (via the test DB) before answering without it. That row survives.
  - `TestCheckDeletions_ScopedToAccount`: account 2's rows are untouched.
  - `TestGmailDeletionsCheckedAt_RoundTrip` (db).
- [ ] **Step 2:** `go test ./internal/gmail ./internal/db -run 'CheckDeletions|GmailDeletionsCheckedAt'`. Expected FAIL.
- [ ] **Step 3:** Implement, and wire the daemon call.
- [ ] **Step 4:** `go test ./internal/gmail ./internal/db ./internal/daemon` passes. Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(gmail): remove mail deleted at the source, checked once a day (#640)`.

---

### Task 10: Docs — feature note, cross-references and the user guide

**Depends on:** Tasks 1–9

**Files:**
- Create: `docs/features/source-deletions.md`. Cover what each source detects, and at what cadence: Slack live window per cycle plus one swept day per cycle; Gmail daily; IMAP per cycle; Jira on refetch. Cover the tombstone shape and self-heal, the shared guard and its floors, the matched ≥ total rule, `kb_dirty` and its triggers (the key expressions are a Go↔SQL dual path, pinned by `TestSRCDEL03_TriggerKeysMatchSourceKeys`), and the corrections listed above. v1 limits:
  - A Slack day with more than 1000 searchable messages is skipped by the sweep.
  - A message moved out of the synced IMAP folder, or out of a Slack channel the token can no longer search, counts as deleted (4a).
  - AI-derived text and `inbox_items` snippets are not touched (3a, see Open questions).
  - A Slack message search never indexes stays until a full sync heals it.
- Modify: `CLAUDE.md`: one Feature Notes line for the new note.
- Modify: `docs/features/knowledge-search.md`: one paragraph. Old Slack edits and deletes now reach the index through `kb_dirty`. A deleted Slack message leaves search within one cycle; a hard-deleted Slack document still waits for the daily reconcile.
- Modify: `docs/features/slack-multi-account.md`, `google-multi-account.md`, `jira-multi-account.md`: one line each pointing at the note (the per-account sweep cursor, the daily stamp, comment set-replace).
- Modify: `docs/guide/concepts/privacy.md`: a new `## When something is deleted at the source` section, following `docs/guide/WRITING.md`. Say what disappears and when: a deleted Slack message within about a day, older ones as the sweep reaches them; deleted or trashed Gmail within a day; IMAP mail on the next sync; a deleted Jira comment on the issue's next sync. Say that summaries already written are kept.
- Modify: `docs/guide/features/search-and-knowledge.md:20`: update "a deleted Slack message within a day" to the new timing.
- Modify: `docs/guide/features/mail.md` and `docs/guide/features/jira-and-linear.md`: one sentence each in "When it's empty or wrong" (a deleted mail or comment disappears here too).

- [ ] **Step 1:** Write the docs. Check every timing and query against the merged code (WRITING.md rule 6). Keep each guide page under about 8 KB (`wc -c`).
- [ ] **Step 2:** `go test ./internal/userguide ./docs/guide` (the embedded guide index), and `bash scripts/leak-check.sh` over the branch if the hook is not installed.
- [ ] **Step 3:** Commit: `docs: source deletions and edits (#640)`.

---

## Inventory proposals (for the owner — not written into `docs/inventory/`)

- **P1 — amend KB-01** (`docs/inventory/knowledge-search.md`):
  - Delete the accepted v1 limit "a Slack in-place edit/delete older than the 48h tail … is caught only by `kb reindex`".
  - Replace "Deletions leave search within one daemon cycle for every source but Slack" with: an edit or tombstone of any Slack message, and a deleted Gmail message or Jira comment, re-renders its document within one cycle through `kb_dirty`. A hard-deleted Slack document still waits for the daily reconcile.
  - Extend `TestKB01_IncrementalEqualsRebuild`'s incremental pass with an old (> 48 h) Slack edit, a tombstone and a Gmail partial-thread delete. Assertions only grow.
  - Note that `kb_dirty` is index-side (written by source-table triggers, drained by the indexer), so "the indexer never writes a source table" still holds.
  - This edits a guard test, so it waits for approval.
- **P2 — new `docs/inventory/source-deletions.md`:**
  - **SRCDEL-01 — no deletion from a bad listing.** A diff deletes only after a complete listing (no error, every page, Slack matched ≥ total, Jira `complete`) that passes `sourcediff.Check`. Guards: `TestSourceDel01_` renames of Task 2's `TestCheck` and of the skip tests in Tasks 5–9.
  - **SRCDEL-02 — a Slack deletion is a self-healing tombstone.** The row, ts, user and thread_ts are kept. Text and raw_json are blanked, and reactions and files are dropped. A later fetch restores the message. Guards: Task 7's tombstone and heal tests.
  - **SRCDEL-03 — every deletion and edit reaches the KB in the same write.** Triggers write `kb_dirty`, and the indexer drains it with gen compare-and-delete. Guards: Task 1's trigger tests, `TestSRCDEL03_TriggerKeysMatchSourceKeys`, `TestDrainDirty_ReMarkDuringRenderSurvives`.

  If approved, the tests are renamed into the `TestSourceDel0N_` convention in the same commit as the inventory file.
- **Awareness, no contract change:**
  - IDEA-01 lists `internal/jira/sync.go` (bounded comment sync). The cap is untouched, and deleted comments only drop out of `ListJiraCommentsSince` input.
  - BACKFILL-01..03 list `search_sync.go` (`BackfillSearch`) and the Gmail/IMAP syncers. `BackfillSearch` passes a nil listing and never deletes (`TestBackfillSearch_NeverTombstones`).
  - MEM-01 already treats a tombstone as absent.

## Open questions for the owner (outside the approved design)

- `inbox_items.snippet` / `raw_text` / `context` (`internal/db/schema.sql:538-540`) hold mechanical copies of message text. The spec scopes only raw rows, FTS and the KB. Should a deleted source message also blank its inbox item's copied text? This plan leaves them as they are.
- `sweepMaxPages = 10`: a large workspace's busy days (> 1000 searchable messages across the account) are skipped by the sweep and logged. Raising it costs about 3 s of Tier-2 budget per page per cycle.
