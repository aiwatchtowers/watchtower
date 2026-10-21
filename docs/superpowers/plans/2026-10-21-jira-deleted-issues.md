# Jira Deleted Issues Implementation Plan (Source deletions Phase 3, board #674)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Jira issue deleted, moved to another project, or no longer visible to the signed-in user leaves Watchtower's raw tables and the KB within about a day, at a cost of a few key-only API calls per synced project per day.

**Architecture:** Once a day per synced project, the daemon lists the project's issue keys with the enhanced search (`/rest/api/3/search/jql`, `fields=key`). It diffs that listing against the stored keys, behind the shared `sourcediff.Check` guard. Each missing key is then confirmed one by one with `GET /rest/api/3/issue/{key}`. A 404 means deleted or not visible. A 200 with a different key means moved. Only confirmed keys are hard-deleted, with their child rows, in one short transaction. The KB follows through the existing per-run Jira reconcile and the existing `jira_comments_kb_dirty` trigger.

**Tech Stack:** Go 1.26, SQLite (`modernc.org/sqlite`), Jira REST v3 via `httptest` in tests. No migration, no Swift.

**Spec:** `docs/superpowers/specs/2026-10-17-source-deletions-design.md`, "Jira comments (and issues)" and Phase 3. Phases 1–2 are merged (PR #400). The Phase 3 retention mirror (purge Slack rows older than N days) is NOT in this plan. The spec calls it optional, and the board target names only deleted Jira issues.

## Decisions taken in this plan (the owner may overturn them, see the end)

- **Hard delete, not a tombstone.** `jira_issues.is_deleted` exists but production code never sets it. About 77 reader queries read `jira_issues`/`tracker_issues` (65 Go, 34+ Swift), and a large share of them have no `is_deleted = 0` predicate. A tombstone would mean auditing all of them, as Phase 1 had to for Slack. A Jira tombstone also brings nothing that Slack's does: no thread structure hangs off an issue row, and a deleted issue has no self-heal path either way. The incremental JQL never returns an issue that is not updated again. Mail is hard-deleted for the same reasons.
- **Every missing key is confirmed before deletion.** The enhanced search is eventually consistent (Atlassian documents `reconcileIssues` for read-after-write), and a hard delete cannot be undone. One `GET /issue/{key}?fields=key` per missing key turns "absent from a listing" into "Jira says 404" or "Jira says it is now `NEW-5`". Deletions are rare, so the cost is small. It is capped at `maxIssueConfirms = 100` per project per check, and the rest wait for the next day.
- **The daily stamp lives in memory** (`Syncer.deletionsCheckedAt`, per project), not in a new column. Syncers live for the daemon's lifetime (`wireJiraSyncers`, `cmd/sync.go:1071`). A daemon restart only re-runs one check of `ceil(issues / 5000)` calls per project, so there is no migration, no schema mirror and no golden or Swift schema regeneration.
- **Moved issue = the old key is deleted.** If the target project is synced, the move bumps `updated` and the regular incremental pass brings the new key in. If it is not synced, the issue has left what Watchtower syncs, the same rule as an IMAP mail moved out of the synced folder.
- **Lost permission = deleted, guarded.** Jira answers 404 for an issue the user cannot see, so a per-issue security change removes that issue. A project the user lost entirely makes the listing fail (Jira returns 400 for `project = X` it cannot see) or come back empty. Either way nothing is deleted (`sourcediff.Check`'s empty rule), which matches the Slack channel rule (owner ruling F7, ask #363).
- **AI-derived and owner-made data stays** (spec decision 3a): targets with `source_id = <key>`, memory notes (their `jira:` refs already fail closed through `JiraIssueExists`, `internal/memory/provenance.go:257-274`), digests, briefings, ideas. `jira_slack_links` and `issue_slack_links` stay too, because they are derived from Slack text that still exists.

## What follows the delete

| Data | Action | Where |
|---|---|---|
| `jira_issues` row `(account_id, key)` | deleted | `db.DeleteJiraIssues` |
| `jira_comments` of the issue | deleted; the existing `jira_comments_kb_dirty` trigger marks `jira:<acct>:<key>` | same tx |
| `jira_issue_changelog`, `jira_changelog_sync` of the issue | deleted | same tx |
| `jira_issue_links` with the key as `source_key` or `target_key` (same account) | deleted | same tx |
| `inbox_items` with a `jira_*` trigger and `channel_id = <key>` | `snippet`, `context`, `raw_text` blanked, the mail precedent; skipped when another account still holds a live row with that key (`channel_id` is a bare key) | same tx |
| KB document `jira:<acct>:<key>` | removed by the per-run Jira reconcile (`jiraSource` is not a `dailyReconciler`, `internal/kb/indexer.go:364-415`; `Keys` lists live rows only), or earlier by the drain when the issue had comments | next `phaseKnowledgeIndex`, same daemon cycle |
| `tracker_issues` view (Jira + Linear) | follows the base row | no code |
| Automation events | none: `jiraDiff.After` iterates only the post-phase rows (`internal/automations/eventsrc_jira.go:50-60`), so a removed issue publishes nothing | no code (asserted in Task 4) |
| `jira_boards.issue_count` | recounted with `UpdateJiraBoardIssueCount` for the project's boards | Task 3 |
| `jira_linked_issues` (other-board cache), targets, memory, `jira_slack_links`, `issue_slack_links`, AI text | kept | none |
| FTS | Jira has no FTS table; search goes through the KB | none |

## Global Constraints

- **Task-scope checks only** (CLAUDE.md "Agent-driven runs"): `go test ./internal/<pkg>` for each touched package plus the packages a task names, and `make lint-diff`. No `-count=1`. The controller runs the full gate (`make test`, `make lint-all`, `go test ./cmd/...`) once, before the PR. There is no Swift in this plan, so `make test-swift` runs only as part of the gate.
- **Lint version:** golangci-lint **v2.11.4** (CI pin). `make lint-diff` checks it.
- **Inventory:** read `docs/inventory/source-deletions.md` and `docs/inventory/knowledge-search.md` before touching `internal/jira/sync.go`, `internal/sourcediff/` or `internal/kb/`. No `TestSRCDEL0N_`/`TestKB0N_` test is edited, renamed or split. `internal/sourcediff/guard_test.go` is not edited, and the new floors get their tests in `internal/jira`. The inventory text changes only in Task 6, after the owner approves P1.
- **Write transactions stay short:** read the stored keys, then list, then confirm, then open one transaction for the deletes. No network call inside a transaction.
- **False-deletion guards are mandatory:** a diff runs only on a complete listing (every page fetched, `isLast` reached, every issue carrying a key), then `sourcediff.Check`, then the per-key confirm. Every skip is logged with account, project and reason.
- **No network in tests:** `httptest` only. **Public repo hygiene:** `acme`/`example.com`, keys `PROJ-1`/`OTHER-9`, no live ids or names.
- **Commits:** one per task, conventional prefix, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A short listing reported as complete** (a page with `isLast: false` and no `nextPageToken`, an issue object without `key`, a looping token) deletes nothing. Pinned in Task 1 (`TestSearchIssueKeys_*`) and Task 3 (`TestCheckDeletedIssues_IncompleteListingDeletesNothing`).
2. **The listing is wrong but Jira still has the issue** (index lag, an archived issue): the confirm GET returns 200 with the same key, so the issue is kept. Pinned in Task 3 (`TestCheckDeletedIssues_StillPresentIsKept`).
3. **An issue synced between the stored-set read and the listing** is never judged. Pinned in Task 3 (`TestCheckDeletedIssues_ReadsStoredSetBeforeListing`).
4. **Bare keys across accounts:** account 2's `PROJ-1` and its inbox items survive account 1's delete of `PROJ-1`. Pinned in Task 2.
5. **API cost:** one key-only listing per project per day (`maxResults=5000`), confirms only for missing keys, capped. An empty or over-half listing sends no confirm at all.

## Lanes and dependencies

```
Task 1 (client) ──┐
                  ├─> Task 3 (CheckDeletedIssues) ──> Task 4 (daemon) ──> Task 5 (docs)
Task 2 (db) ──────┘                                └─> Task 6 (inventory, owner-gated)
```

Tasks 1 and 2 can run in parallel lanes, since they touch disjoint files (`internal/jira/client.go` and `internal/db/`). Everything after them is sequential.

---

### Task 1: Jira client — key-only listing and the confirm lookup

**Depends on:** none

**Files:**
- Modify: `internal/jira/client.go` (next to `searchIssues`, line ~374)
- Test: `internal/jira/client_test.go`

**Interfaces (produces):**

```go
// searchIssueKeys lists every issue key jql matches, through the enhanced
// search with fields=key and maxResults=5000 (Jira's page maximum for key-only
// requests; a smaller page from the server is fine). complete is true only when
// a page reported isLast; a page with isLast=false and no nextPageToken, an issue
// without a key, a repeated token or more than maxKeyPages pages returns
// complete=false with the keys read so far. err wraps the client error, so
// ErrAuthRevoked stays matchable.
func (c *Client) searchIssueKeys(ctx context.Context, jql string) (keys []string, complete bool, err error)

// issueCurrentKey returns the issue's current key: "" when Jira answers 404
// (deleted, or not visible to this user), the same key when it still exists,
// another key when the issue was moved. Any other status is an error.
func (c *Client) issueCurrentKey(ctx context.Context, key string) (string, error)

const maxKeyPages = 200 // 1M issues per project; beyond that the listing is incomplete
```

`searchIssueKeys` calls `getWithQuery` with `jql`, `fields=key`, `maxResults=5000` and `nextPageToken`, decoding into `SearchResult` (`Issue.Key` is already mapped). `issueCurrentKey` uses `c.do(ctx, http.MethodGet, "/rest/api/3/issue/"+url.PathEscape(key)+"?fields=key", nil)` directly, because `get` folds the status into a string error. It checks `resp.StatusCode == http.StatusNotFound` and otherwise decodes `{"key": ...}` on 200.

- [ ] **Step 1: Write the failing tests** (`httptest` mux, the `newTestClient` helper used in `confluence_download_timeout_test.go:34`):
  - `TestSearchIssueKeys_PagesToLast`: two pages joined by a token. All keys come back, `complete`, and each request carries `fields=key` and `maxResults=5000`.
  - `TestSearchIssueKeys_IncompleteWithoutToken`: `isLast:false`, no token. `complete == false`.
  - `TestSearchIssueKeys_IncompleteOnMissingKey`: an issue `{"id":"1"}` makes `complete == false`.
  - `TestSearchIssueKeys_IncompleteOnRepeatedToken`: the same token twice makes `complete == false` and no endless loop.
  - `TestSearchIssueKeys_ErrorIsReturned`: a 500 returns an error with no keys.
  - `TestIssueCurrentKey`: 404 gives `""` and nil, 200 `{"key":"PROJ-1"}` gives `PROJ-1`, 200 `{"key":"OTHER-9"}` gives `OTHER-9`, and 500 gives an error.
- [ ] **Step 2:** `go test ./internal/jira -run 'TestSearchIssueKeys|TestIssueCurrentKey'`. Expected FAIL (undefined).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `go test ./internal/jira` passes. Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(jira): key-only issue listing and current-key lookup (#674)`.

---

### Task 2: DB — stored keys and the issue delete

**Depends on:** none

**Files:**
- Create: `internal/db/jira_deletions.go`, `internal/db/jira_deletions_test.go`
- Test (extra package): `internal/kb` (one end-to-end test, below)

**Interfaces (produces):**

```go
// JiraProjectIssueKeys returns every stored issue key of one account's project.
func (db *DB) JiraProjectIssueKeys(accountID int64, projectKey string) ([]string, error)

// DeleteJiraIssues removes the given issues of one account with their comments,
// changelog, changelog cursor and links, and blanks the text copies of the
// inbox items made from them, in one transaction (IN chunks of 500).
// It returns the number of jira_issues rows deleted.
func (db *DB) DeleteJiraIssues(accountID int64, keys []string) (int, error)
```

Statement order inside the one transaction, per chunk (the `DeleteGmailMessages` shape, `internal/db/gmail.go:268`, including its `//nolint:gosec // G202` note on placeholder-only concatenation):

1. `UPDATE inbox_items SET snippet = '', context = '', raw_text = '' WHERE substr(trigger_type, 1, 5) = 'jira_' AND channel_id IN (…) AND (snippet != '' OR context != '' OR raw_text != '') AND NOT EXISTS (SELECT 1 FROM jira_issues o WHERE o.key = inbox_items.channel_id AND o.account_id != ?)`. The Jira detector writes the bare issue key as `channel_id` (`internal/inbox/jira_detector.go:144,180`).
2. `DELETE FROM jira_comments WHERE account_id = ? AND issue_key IN (…)`. The existing trigger marks the KB key.
3. `DELETE FROM jira_issue_changelog …` and `DELETE FROM jira_changelog_sync …`, both by `(account_id, issue_key)`.
4. `DELETE FROM jira_issue_links WHERE account_id = ? AND (source_key IN (…) OR target_key IN (…))`.
5. `DELETE FROM jira_issues WHERE account_id = ? AND key IN (…)`, counting `RowsAffected`.

- [ ] **Step 1: Write the failing tests:**
  - `TestJiraProjectIssueKeys_Scope`: only the account's rows of that project come back. Another project and another account's same project are excluded.
  - `TestDeleteJiraIssues_RemovesIssueAndChildren`: `PROJ-1` with two comments, a changelog row, a cursor row, a link out (`PROJ-1 → PROJ-2`) and a link in (`PROJ-3 → PROJ-1`). Everything of `PROJ-1` is gone. `PROJ-2`/`PROJ-3` rows and their own links stay, the count is 1, and `kb_dirty` holds `jira:<acct>:PROJ-1`.
  - `TestDeleteJiraIssues_BlanksInboxCopies`: a `jira_assigned` and a `jira_comment_mention` item for `PROJ-1` are blanked. A Slack `mention` item whose `channel_id` happens to equal `PROJ-1` is untouched.
  - `TestDeleteJiraIssues_OtherAccountKeepsKey`: account 2 also stores `PROJ-1`. Its issue row, comments and inbox items survive account 1's delete.
  - `TestDeleteJiraIssues_Empty`: nil keys gives 0 with no transaction.
  - kb: `TestRun_DeletedJiraIssueLeavesIndex` (in `internal/kb`): index a seeded issue with no comments, `DeleteJiraIssues`, run the indexer again. The document `jira:<acct>:PROJ-1` is gone from `kb_documents` and search. This pins the reconcile path the plan relies on.
- [ ] **Step 2:** `go test ./internal/db -run 'JiraProjectIssueKeys|DeleteJiraIssues'` and `go test ./internal/kb -run TestRun_DeletedJiraIssueLeavesIndex`. Expected FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `go test ./internal/db ./internal/kb` passes. Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(db): delete Jira issues with their child rows (#674)`.

---

### Task 3: `Syncer.CheckDeletedIssues` — the daily per-project diff

**Depends on:** Task 1, Task 2

**Files:**
- Create: `internal/jira/deletions.go`, `internal/jira/deletions_test.go`
- Modify: `internal/jira/sync.go` (add `deletionsCheckedAt map[string]time.Time` to `Syncer`, initialised in `NewSyncer`)
- Modify: `internal/sourcediff/guard.go`: add `var IssueFloors = Floors{EmptyMin: 5, HalfMin: 10}` with a comment (the Slack numbers: small projects stay judgeable, and every deletion is confirmed per key anyway). `guard_test.go` is not edited.

**Interfaces (produces):**

```go
const (
	deletionCheckEvery = 24 * time.Hour
	maxIssueConfirms   = 100 // per project per check; the rest wait for the next day
)

// CheckDeletedIssues removes the issues Jira no longer has, at most once per
// deletionCheckEvery per project. It returns how many rows were removed.
// ErrAuthRevoked is returned as is; any other per-project failure is logged
// and leaves that project unstamped, so the next cycle retries it.
func (s *Syncer) CheckDeletedIssues(ctx context.Context, now time.Time) (removed int, err error)
```

Per selected board's project (`GetJiraSelectedBoards(s.accountID)`, project keys deduplicated, skipped when empty or failing `validProjectKeyRe`, or when the project's `jira_sync_state.last_synced_at` is empty, meaning no completed pass yet):

1. Skip when `now − deletionsCheckedAt[project] < deletionCheckEvery`.
2. `stored := JiraProjectIssueKeys`, read **before** the listing. When it is empty, stamp and continue.
3. `keys, complete, err := searchIssueKeys(ctx, "project = "+project+" ORDER BY key ASC")`. An `ErrAuthRevoked` error returns. Any other error, or `!complete`, is logged (`jira deletions: account %d project %s: listing incomplete, skipped`) and leaves the project unstamped.
4. `missing := stored − keys` (sorted). Call `sourcediff.Check(len(stored), len(stored ∩ keys), len(missing), sourcediff.IssueFloors)`. A refusal is logged with its reason and the project is stamped. No confirm calls are sent.
5. For the first `maxIssueConfirms` missing keys, call `issueCurrentKey`. `""` or a different key means confirmed (log a moved key as `PROJ-1 → OTHER-9`). The same key means kept and counted in one log line. `ErrAuthRevoked` returns. Any other error stops the confirms for this project and leaves it unstamped; the keys confirmed so far are still deleted.
6. `DeleteJiraIssues(s.accountID, confirmed)`, then `UpdateJiraBoardIssueCount` for each of the project's boards, log `jira deletions: account %d project %s: removed %d issues`, and stamp `now` (unless step 5 hit an error).

- [ ] **Step 1: Write the failing tests** (an `httptest` mux serving `/rest/api/3/search/jql` with a recorded `jql`/`fields` and `/rest/api/3/issue/{key}` per key; the store seeded through `UpsertJiraIssueBatch` plus a `jira_sync_state` watermark; account 1, project `PROJ`, one selected board):
  - `TestCheckDeletedIssues_RemovesConfirmedGone`: 6 stored, 5 listed, the GET of the missing key returns 404. One row is removed, the JQL is `project = PROJ …`, and `fields=key`.
  - `TestCheckDeletedIssues_MovedIssueRemovesOldKey`: the GET returns `{"key":"OTHER-9"}`. `PROJ-6` is removed.
  - `TestCheckDeletedIssues_StillPresentIsKept`: the GET returns the same key. Nothing is removed.
  - `TestCheckDeletedIssues_EmptyListingDeletesNothing`: 6 stored, 0 listed. Nothing is removed, no confirm GET is sent, and the project is stamped.
  - `TestCheckDeletedIssues_OverHalfDeletesNothing`: 10 stored, 4 listed. No GET is sent.
  - `TestCheckDeletedIssues_IncompleteListingDeletesNothing`: `isLast:false` with no token. Nothing is removed, and the next call lists again.
  - `TestCheckDeletedIssues_ListErrorRetriesNextCycle`: a 500 from the listing. Nothing is removed and nothing is stamped.
  - `TestCheckDeletedIssues_ConfirmErrorKeepsRest`: the second of two confirms returns 500. The first key is removed, the second is kept, and the project is not stamped.
  - `TestCheckDeletedIssues_ConfirmCap`: 400 stored, 150 missing. Exactly 100 GETs are sent and 100 rows removed.
  - `TestCheckDeletedIssues_RunsOncePerDay`: a second call 1 h later sends no request; a call 25 h later does.
  - `TestCheckDeletedIssues_ReadsStoredSetBeforeListing`: the search handler inserts `PROJ-99` into the test DB, then answers without it. `PROJ-99` survives and no GET is sent for it.
  - `TestCheckDeletedIssues_ScopedToAccountAndProject`: account 2's `PROJ-6` is untouched, and a selected project with no watermark is not listed.
  - `TestCheckDeletedIssues_AuthRevokedAborts`: a revoked token on the listing gives `errors.Is(err, ErrAuthRevoked)`.
- [ ] **Step 2:** `go test ./internal/jira -run TestCheckDeletedIssues`. Expected FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `go test ./internal/jira ./internal/sourcediff` passes. Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(jira): remove issues deleted or moved at the source, checked once a day (#674)`.

---

### Task 4: Daemon — run the check after a clean Jira pass

**Depends on:** Task 3

**Files:**
- Modify: `internal/daemon/daemon.go` (`phaseJiraSync`, line ~994, right after `anyClean = true` and `d.resolveJiraUsers`)
- Test: the existing Jira phase tests in `internal/daemon` (the `newEventsTestDaemon` harness in `automation_events_test.go:293`)

Call `removed, err := s.CheckDeletedIssues(ctx, time.Now())` only for an account whose `Sync` returned nil. Log `jira: account %d: %d deleted issues removed` when `removed > 0`. Log any error as `jira: account %d: deletion check: %v`. It is log-only: the next `Sync` records a revoked grant through the existing path, so no new auth-state writer is added (the three-writer rule in `jira-multi-account.md`). The call stays inside `phaseJiraSync`, which runs inside `observePhase(JiraSource)`. That is safe because a removed row produces no event.

- [ ] **Step 1: Write the failing tests:**
  - `TestPhaseJiraSync_ChecksDeletionsAfterCleanSync`: a clean pass sends one key-only listing, and an issue the listing lacks (confirm 404) is gone after the phase.
  - `TestPhaseJiraSync_NoDeletionCheckAfterFailedSync`: a failing `Sync` sends no key-only listing.
  - `TestPhaseJiraSync_DeletedIssuePublishesNoEvent`: inside `observePhase(automations.JiraSource(db), …)`, the removed issue publishes no `jira.issue_changed`.
- [ ] **Step 2:** `go test ./internal/daemon -run 'TestPhaseJiraSync_'`. Expected FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `go test ./internal/daemon ./internal/jira` passes. Run `make lint-diff`.
- [ ] **Step 5:** Commit: `feat(daemon): daily Jira deleted-issue check (#674)`.

---

### Task 5: Docs — feature note, cross-references, user guide

**Depends on:** Task 4

**Files:**
- Modify: `docs/features/source-deletions.md`:
  - Add a table row: "Jira issues | key-only `project = X` listing diffed against stored keys, each missing key confirmed with `GET /issue/{key}` (404 or a new key = gone), hard delete with comments, changelog, links and inbox text copies (`internal/jira/deletions.go`, `db.DeleteJiraIssues`) | once a day per project, in memory per daemon run (a restart checks again); an incomplete listing or a failed confirm retries next cycle".
  - Add a guard paragraph on `IssueFloors` {5, 10} and the confirm cap of 100.
  - Add a "What follows the delete" sentence: the KB through the per-run Jira reconcile; targets, memory, Slack links and AI text kept.
  - Add v1 limits:
    - An issue whose permission is restored, or that moved back, returns only when it is updated again.
    - A project the user can no longer see keeps its issues.
    - Deleting every issue of a project (or more than half of ten or more) is not detected.
    - Issues of a board that is no longer selected stay.
    - `jira_linked_issues` rows (other-board cache) are not diffed.
    - Linear permanent deletions are not diffed (archived and trashed issues are already flagged by the Linear sync).
    - The retention mirror from spec Phase 3 is not built.
  - Add the new tests to "Tests".
- Modify: `docs/features/jira-multi-account.md`: extend the last line (source deletions) with "and an issue deleted or moved in Jira is removed per account by a daily key diff".
- Modify: `CLAUDE.md`: in the "Source deletions" Feature Notes line, add "2026-10-21 phase 3: daily Jira issue key diff with per-key confirm (#674)".
- Modify: `docs/inventory/README.md`: add `internal/jira/deletions.go` to the Source deletions module list. Do this only together with Task 6. If P1 is declined, skip it.
- Modify: `docs/guide/concepts/privacy.md` (the "When something is deleted at the source" section, line 59). Change the Jira line to: a deleted comment disappears the next time the issue is synced, and a deleted issue, or one moved to a project you do not sync, disappears within about a day. If you lose access to a single issue, it disappears too; if you lose access to a whole project, its issues stay.
- Modify: `docs/guide/features/jira-and-linear.md:44`. Change it to "**A comment or issue deleted in Jira is still shown.** A comment disappears the next time that issue is synced; an issue within about a day."

- [ ] **Step 1:** Write the docs, following `docs/guide/WRITING.md`. Check every timing against the merged code. Keep each guide page under 8 KB (`wc -c`; both are about 6.5 KB now).
- [ ] **Step 2:** `go test ./docs/guide ./internal/kb` (the embedded guide and its index), plus `bash scripts/leak-check.sh` over the branch if the hook is not installed.
- [ ] **Step 3:** Commit: `docs: Jira deleted and moved issues (#674)`.

---

### Task 6: Inventory — amend SRCDEL-01 (only after the owner approves P1)

**Depends on:** Task 3, and the owner's approval of P1 below

**Files:** `docs/inventory/source-deletions.md`, `docs/inventory/README.md`

Apply P1 word for word as approved. Add a Changelog line naming the board target and the ask that approved it. No test is renamed or edited. `TestSRCDEL01_GuardRefusesBadListings` stays the guard.

- [ ] **Step 1:** Edit both files.
- [ ] **Step 2:** Commit: `docs(inventory): SRCDEL-01 covers deleted Jira issues (#674)`.

---

## Inventory proposal (for the owner — not written into `docs/inventory/` until approved)

- **P1 — amend SRCDEL-01** (`docs/inventory/source-deletions.md`). No new contract and no new guard test. The new behaviour sits under the existing guard `TestSRCDEL01_GuardRefusesBadListings`, which is unchanged.
  - **Module line:** add `internal/jira/deletions.go` and `internal/db/jira_deletions.go`.
  - **Observable:** after "Jira comment listing complete", add "; Jira issue key listing complete: every page read up to `isLast`, every issue carrying a key". Then add the sentence: "A Jira issue is deleted only after `GET /issue/{key}` answers 404 or returns another key; an issue Jira still returns under the same key is kept."
  - **Supporting tests** (add a "Jira issues" line): `internal/jira/deletions_test.go::TestCheckDeletedIssues_EmptyListingDeletesNothing`, `TestCheckDeletedIssues_OverHalfDeletesNothing`, `TestCheckDeletedIssues_IncompleteListingDeletesNothing`, `TestCheckDeletedIssues_StillPresentIsKept`.
  - **SRCDEL-02 and SRCDEL-03 are unchanged.** SRCDEL-02 is Slack only. SRCDEL-03 holds as is: no new trigger is added, the existing `jira_comments_kb_dirty` still fires on the comment deletes, and an issue's KB document leaves through the per-run reconcile. The KB-01 wording already covers that (`docs/inventory/knowledge-search.md`).

## Owner decisions

1. **Hard delete vs tombstone** for a gone Jira issue. (a) Hard delete the row and its child rows. Recommended: no reader audit, and the same as mail. (b) Set the existing `is_deleted = 1` and blank the text. This needs a predicate in every reader that lacks one (dozens of Go and Swift queries) and gains no self-heal.
2. **Per-key confirm before deletion.** (a) Confirm each missing key with `GET /issue/{key}` (≤ 100 per project per day). Recommended: it protects a hard delete from the search's eventual consistency and tells a move from a deletion. (b) Trust the listing plus `sourcediff.Check`, with no extra calls.
3. **P1, the SRCDEL-01 amendment** above: approve, edit or decline. If it is declined, Task 6 and the inventory README line in Task 5 are dropped. The code still ships with the same tests, but outside the inventory.
4. (Low stakes, taken unless you object.) **The daily stamp in memory**, so a daemon restart re-checks once, instead of a persisted `jira_sync_state` column that needs a migration.
