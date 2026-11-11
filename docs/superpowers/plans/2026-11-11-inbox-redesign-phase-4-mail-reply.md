# Inbox redesign phase 4 — mail closes on reply (Gmail) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gmail sync also stores the owner's sent mail as ordinary mail, every reader of `gmail_messages` takes the side the spec's reader rule gives it, and an open `email_received` item closes itself when the owner replies in its Gmail thread.

**Architecture:** One Gmail listing scope (`{in:inbox in:sent}`) replaces `in:inbox` in the incremental sync and the history backfill fetch, so sent rows share the existing watermark, cap and backfill rules; a one-time per-account catch-up brings the last `gmail.initial_history_days` of sent mail to accounts connected before this release. One predicate, "the owner's own sent row" (Go function + SQL fragment, pinned to each other), is the only test any reader uses. `autoResolveByRules` gains a Gmail branch that resolves through the existing `ResolveInboxItem(id, "User replied")`.

**Tech Stack:** Go 1.26, SQLite (goose migration), Gmail REST API v1 search syntax.

**Spec:** `docs/superpowers/specs/2026-11-11-inbox-redesign-design.md` (section "Mail closes on reply (phase 4)", Decisions 8 and 10, Inventory → INBOX-02).

## Execution rules

- Each task runs in its own worktree/branch merged by the controller into the phase branch; never two implementers in one tree. Lanes: Task 1 first; then Tasks 2, 3, 4 and 5 in parallel (they touch disjoint files: 2 = `internal/gmail`, `internal/daemon`; 3 = `internal/inbox/gmail_detector.go`, `internal/db/automation_event_sources.go`, `internal/memory/seed.go`; 4 = `internal/db/emails_read.go`, `internal/tools/emails.go`, tests only elsewhere; 5 = `internal/db/gmail_sent.go`, `internal/inbox/pipeline.go`); Task 6 after 3, 4, 5; Task 7 after 2 and 5.
- Inner loop only: the `go test ./internal/<pkg> -run …` lines each task names, plus `make lint-diff`. The controller runs the full gate (`make test`, `make lint-all`) once after Task 7 and before the PR. No Swift is written; the generated `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` changes only through the Task 1 regeneration command.
- Each implementer self-reviews against `docs/review/review-rules.md` (Go sections) before hand-back; the reviewer uses the same file.
- Every brief carries these invariants verbatim: **"A reader that treats a row as something that happened to the owner skips the owner's own sent rows; a reader that treats a row as knowledge keeps them."** **"Sent mail is ordinary mail."** **"The Gmail sync watermark and the inbox watermark move exactly as before; sent rows never freeze or advance either one on their own."**
- Tests seed every time from `time.Now()` (no hard-coded dates). Sample data: `acme`, `owner@example.com`, `alias@example.com`, `colleague-a@example.com`. No live data, ids or paths.
- Migration number: the next free one at implementation time (`00188` as of this plan; renumber at merge if another phase took it), via the `add-migration` skill. No table rebuild.

## Global Constraints

- Phase 4 is Go only; no Swift, no AI call, no new prompt.
- Gmail only. IMAP mail does not close on reply (no Sent folder sync, no thread headers): a v1 limit, named in the guide, the feature note and the INBOX-02 amendment.
- The listing scope is `{in:inbox in:sent}` everywhere the sync lists mail by date (incremental and history backfill); the deletions listing keeps `after:<oldest−1d> -in:trash -in:spam` (already covers Sent).
- Owner's own sent row = its `labels_json` contains the label id `"SENT"`, **or** its `from_email` equals the account's `google_accounts.email` (case-insensitive, trimmed).
- Mail branch: item `trigger_type = 'email_received'`, `status = 'pending'`, resolved with `ResolveInboxItem(id, "User replied")`; `email_cc` items and `imap:` items are untouched.
- "Newer than the item" = the owner's sent row's `internal_date` is strictly later than the item's received message's `internal_date` (row `account_id`, `id = message_ts`); when that row is gone or undated, than the item's `created_at`.
- Sent catch-up: once per account, `in:sent` over the last `gmail.initial_history_days` days (default `7`), rows stamped with their own date as `synced_at`, no watermark or auth-state write; stamp column `google_accounts.gmail_sent_catchup_at` (RFC 3339 UTC, `''` = not yet); a 404 message is skipped, and the pass gives up (stamps) after 3 failed attempts per process.
- Inventory: INBOX-02 amendment as approved in ask #634; INBOX-09, SRCDEL-01..03, PURGE-02 unchanged and relied on.

## Agent's calls (not in the spec; the owner can overturn any)

1. **One-time sent catch-up, 7 days** (`gmail.initial_history_days`). Accounts connected before this release get their last week of sent mail once, so open items they already answered close. Older sent mail of those accounts is never fetched (their history backfill already ran); knowledge loses only that. Alternative the owner may prefer: a month (the backfill depth), at more Gmail API calls once.
2. **`seedGmailSenders` is a skip reader.** It seeds correspondents ("who wrote to you"); without the skip the owner's own address would become a person node. Memory extraction stays a keep reader.
3. **A sent-only message links to `#sent/<id>`** instead of `#inbox/<id>`, so **Open in Gmail** lands in the folder that holds it. Received mail's links are unchanged.
4. **Sent and received mail share the per-cycle cap** (`gmail.max_messages_per_sync`, default 100, oldest first) because they are one listing. A cycle with more than 100 new messages in total delivers the rest next cycle, as today; an owner who sends a lot can see received mail arrive one cycle later. One listing keeps one watermark and no new loss path; a separate sent cursor would need its own watermark rules.
5. **"Newer than the item" is measured against the received message's date**, so a reply sent before the cycle that creates the item still closes it.

## Review Focus

- **The owner replies from a "Send mail as" alias** (From ≠ the account address): the `SENT` label still makes the row the owner's own, so the item resolves and the detector mints nothing — tests in Task 1 (predicate) and Task 5 (`TestGmailItemsAnsweredByOwner_AliasSentLabel`).
- **The owner replies before the cycle that creates the item** (received 10:00, reply 10:05, detector runs 10:10): the comparison is against the received message's date, not the item's `created_at`, so the item still resolves — Task 5 `TestGmailItemsAnsweredByOwner_ReplyBeforeItemCreated`.
- **The owner's older message in the same thread** (they wrote first, someone answered): the received answer stays pending — Task 5 `TestGmailItemsAnsweredByOwner_OlderOwnMessageKeepsItem`.
- **The same Gmail thread id under two connected accounts:** a reply in account B never closes account A's item — Task 5 `TestGmailItemsAnsweredByOwner_OtherAccountKeepsItem`.
- **An account connected before this release:** its last week of sent mail arrives once, a failed catch-up retries next cycle without moving the Gmail watermark, and a message that keeps failing (or was deleted mid-pass) never makes it re-download the week forever — Task 2 `TestCatchUpSent_ErrorLeavesStampAndWatermark`, `TestCatchUpSent_GoneMessageSkipped`, `TestCatchUpSent_GivesUpAfterThreeFailures`.

---

### Task 1: Sent-row predicate, Gmail channel parser, catch-up column

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00188_gmail_sent_catchup.sql`
- Create: `internal/db/gmail_sent.go`, `internal/db/gmail_sent_test.go`
- Modify: `internal/db/gmail.go` (channel id parser), `internal/db/gmail_test.go` (or the file holding `GmailAccountIDFromChannelID`'s tests)
- Modify: `internal/db/schema.sql` (google_accounts column), regenerated `internal/db/testdata` schema golden and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`

**Interfaces:**
- Produces:
  - `const GmailSentLabel = "SENT"`
  - `func GmailOwnSent(labelsJSON, fromEmail, accountEmail string) bool` — true when `labelsJSON` contains `"SENT"` (quoted, substring test on the stored JSON) or `strings.EqualFold(strings.TrimSpace(fromEmail), strings.TrimSpace(accountEmail))` with a non-empty account email.
  - `func GmailOwnSentSQL(msg, acct string) string` — the SQL twin over table aliases `msg` (a `gmail_messages` row) and `acct` (its `google_accounts` row): `(msg.labels_json LIKE '%"SENT"%' OR (acct.email <> '' AND lower(trim(msg.from_email)) = lower(trim(acct.email))))`. Callers concatenate fixed aliases only (no user input).
  - `func ParseGmailChannelID(channelID string) (accountID int64, threadID string, ok bool)` — the one parser of `gmail:<account-id>:<thread-id>`; `ok` false for anything else, an empty thread included. `GmailAccountIDFromChannelID` becomes a thin call to it (its tests unchanged).
  - `func (db *DB) GmailSentCatchUpAt(accountID int64) (string, error)` — `''` for a missing account.
  - `func (db *DB) SetGmailSentCatchUpAt(accountID int64, at time.Time) error` — writes `at.UTC()` RFC 3339.
  - Migration: `ALTER TABLE google_accounts ADD COLUMN gmail_sent_catchup_at TEXT NOT NULL DEFAULT ''`; Down drops the column. Mirror in `schema.sql` with the comment `-- RFC 3339 UTC when the one-time Gmail sent catch-up finished; '' = not yet (see 00188)`.

- [ ] **Step 1: Write the failing tests** in `internal/db/gmail_sent_test.go`:
  - `TestGmailOwnSent_Cases` — table: `["SENT"]` + any from → true; `["INBOX","SENT"]` + other from → true; `["INBOX"]` + from `Owner@Example.com ` vs account `owner@example.com` → true; `["INBOX"]` + `colleague-a@example.com` → false; labels `not json` + other from → false; `["INBOX"]` + empty from + empty account → false; `["Label_SENT_1"]` (user label id containing SENT unquoted) → false.
  - `TestGmailOwnSentSQL_MatchesGo` — inserts each case of the table above as a `gmail_messages` row under a `google_accounts` row with that account email, evaluates `SELECT `+GmailOwnSentSQL("m","a")+` FROM gmail_messages m JOIN google_accounts a ON a.id = m.account_id WHERE m.id = ?` and asserts it equals `GmailOwnSent` for every case.
  - `TestParseGmailChannelID` — `gmail:3:thr-a` → (3, `thr-a`, true); `gmail:3:` → false; `gmail:x:thr` → false; `imap:1:2-3` → false; `C123` → false.
  - `TestGmailSentCatchUpAt_RoundTrip` — new account reads `''`; after `SetGmailSentCatchUpAt(id, now)` reads `now.UTC().Format(time.RFC3339)`; missing account reads `''` with nil error.
- [ ] **Step 2: Run** `cd <repo> && go test ./internal/db -run 'TestGmailOwnSent|TestParseGmailChannelID|TestGmailSentCatchUpAt'` — Expected: FAIL (undefined).
- [ ] **Step 3: Implement** the migration, `schema.sql` line and the functions above. Regenerate: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- [ ] **Step 4: Run** `go test ./internal/db -run 'TestGmailOwnSent|TestParseGmailChannelID|TestGmailSentCatchUpAt|TestGmailAccountIDFromChannelID|TestSchemaGolden|TestDesktopTestSchema|TestMigrat'` and `make lint-diff` — Expected: PASS, no new lint.
- [ ] **Step 5: Commit** — `feat(gmail): owner sent-row predicate and sent catch-up column (#1076)`.

---

### Task 2: Gmail sync lists sent mail; one-time sent catch-up

**Depends on:** Task 1

**Files:**
- Modify: `internal/gmail/sync.go`, `internal/gmail/client.go` (permalink)
- Modify: `internal/daemon/daemon.go` (`phaseGmailSync`)
- Test: `internal/gmail/sync_test.go`, `internal/gmail/fetch_range_test.go`, `internal/gmail/client_test.go`, new `internal/gmail/sent_catchup_test.go`, `internal/daemon/` test file holding the `phaseGmailSync` tests

**Interfaces:**
- Consumes: `db.SetGmailSentCatchUpAt`, `db.GmailSentCatchUpAt` (Task 1).
- Produces:
  - `const listScope = "{in:inbox in:sent}"` in `internal/gmail/sync.go`; `Sync` lists `listScope + " after:<watermark>"` / `listScope + " newer_than:<days>d"`, `FetchRange` lists `listScope + " after:<from> before:<to>"`. Nothing else in `Sync` changes (cap, oldest-first, watermark rules, noise skip).
  - `Sync` on an account's first sync (watermark 0, listing succeeded) also calls `SetGmailSentCatchUpAt(accountID, listedAt)` (that window already held the sent mail); a failed stamp is logged, never returned.
  - `func (s *Syncer) CatchUpSent(ctx context.Context, now time.Time) (int, error)` — no-op `(0, nil)` when the stamp is set or the watermark is 0; else lists `in:sent after:<now − initial_history_days·24h>` (all pages), stores each through `storeMessage` with `backfillSyncedAt` (own date) and `skipAtOrBelow = 0`. A message whose `GetMessage` answers 404 (deleted between the listing and the fetch) is skipped, not an error. Any other error stops the pass, returns wrapped and stamps nothing, so the next cycle retries — at most `sentCatchUpMaxAttempts = 3` passes per account per process that fail on a message fetch or store (a failed listing — offline, revoked — never counts and never stamps) (`Syncer.catchUpFailures`, in memory); the third failure stamps `now` anyway and logs `gmail: sent catch-up for account <id> gave up after 3 attempts: <err>`, so one bad message can never re-download the week every cycle. Stamps `now` after a pass where every listed message was stored or skipped. Writes no watermark, no auth state.
  - `GetMessage` permalink: `#sent/<id>` when the labels contain `SENT` and not `INBOX`, else `#inbox/<id>` as today.
  - In `internal/daemon/daemon.go`: `type sentCatchUpper interface { CatchUpSent(ctx context.Context, now time.Time) (int, error) }`, `var _ sentCatchUpper = (*gmail.Syncer)(nil)`; `phaseGmailSync` calls it after a successful `Sync`, outside `observePhase` (catch-up rows are never news), before `CheckDeletions`; errors logged as `gmail sent catch-up error: …`.

- [ ] **Step 1: Write the failing tests:**
  - `TestSyncListsInboxAndSent` (sync_test.go) — fake server records `q`; first sync's query is `{in:inbox in:sent} newer_than:7d`; with a watermark set it is `{in:inbox in:sent} after:<wm>`; a listed message with labels `["SENT"]` is stored with `labels_json` containing `"SENT"` and its `thread_id`.
  - `TestSyncFirstSyncStampsSentCatchUp` — after a first sync with ≥ 1 message, `GmailSentCatchUpAt` is non-empty; after a sync of an account with watermark > 0 it stays `''`.
  - Update `fetch_range_test.go`'s expected query to `{in:inbox in:sent} after:%d before:%d`.
  - `TestGetMessagePermalinkSentOnly` (client_test.go) — labels `["SENT"]` → `…#sent/<id>`; `["SENT","INBOX"]` → `…#inbox/<id>`.
  - `sent_catchup_test.go`: `TestCatchUpSent_StoresOwnDateAndStamps` (watermark set, stamp `''`: query is `in:sent after:<now−7d>`, rows stored with `synced_at` = their own date, stamp = now, watermark unchanged, returns the stored count); `TestCatchUpSent_NoopWhenStampedOrFresh` (stamp set → no HTTP call; watermark 0 → no HTTP call); `TestCatchUpSent_ErrorLeavesStampAndWatermark` (second `GetMessage` fails → error returned, stamp `''`, watermark unchanged; next call with a healthy server stamps); `TestCatchUpSent_SkipsNoiseLabels` (a `CATEGORY_PROMOTIONS` message is not stored); `TestCatchUpSent_GoneMessageSkipped` (one listed id's `GetMessage` answers 404: the others are stored, the pass stamps, nil error); `TestCatchUpSent_GivesUpAfterThreeFailures` (one id answers 500 every time: calls 1 and 2 return the error with no stamp, call 3 returns the error and stamps, call 4 makes no HTTP call; watermark unchanged throughout).
  - Daemon: `TestPhaseGmailSync_RunsSentCatchUpAfterSync` — a fake syncer implementing `sentCatchUpper` records calls: called once after a successful `Sync`, not called when `Sync` returns an error.
- [ ] **Step 2: Run** `go test ./internal/gmail ./internal/daemon -run 'TestSync|TestFetchRange|TestGetMessagePermalink|TestCatchUpSent|TestPhaseGmailSync'` — Expected: FAIL.
- [ ] **Step 3: Implement** per Interfaces. Existing `TestSync*` tests stay green unchanged except where they assert the literal query.
- [ ] **Step 4: Run** `go test ./internal/gmail` and `go test ./internal/daemon -run 'Gmail|HistoryBackfill'`, `make lint-diff` — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(gmail): sync the owner's sent mail with a one-time catch-up (#1076)`.

---

### Task 3: Skip readers — detector, mail event, people seeding

**Depends on:** Task 1

**Files:**
- Modify: `internal/inbox/gmail_detector.go`, `internal/db/automation_event_sources.go`, `internal/memory/seed.go`
- Test: `internal/inbox/gmail_detector_test.go`, `internal/db/automation_event_sources_test.go`, `internal/automations/eventsrc_mail_test.go` (create if absent), `internal/memory/seed_test.go`

**Interfaces:**
- Consumes: `db.GmailOwnSent`, `db.GmailOwnSentSQL` (Task 1).
- Produces (behaviour only, no new exported names):
  - `detectGmailAccount` skips a row when `db.GmailOwnSent(m.LabelsJSON, m.FromEmail, acct.Email)` (replacing the from-only check).
  - `mailNewsFloorQueries["gmail"]` and `mailCountQueries["gmail"]` count and date only rows that are not the owner's own sent (join `google_accounts` on `account_id`, `AND NOT ` + `GmailOwnSentSQL`); the IMAP queries are unchanged.
  - `seedGmailSenders` excludes the owner's own sent rows (join `google_accounts`, `AND NOT ` + `GmailOwnSentSQL`). *Agent's call: seeding finds correspondents — "who wrote to you" — so it is a skip reader; memory extraction stays a keep reader.*

- [ ] **Step 1: Write the failing tests** (one per skip reader):
  - `TestDetectGmailAccounts_SkipsOwnSentFromAlias` — a row with labels `["SENT"]`, from `alias@example.com`, To containing the account address, synced now → 0 items; a received row in the same pass still mints its `email_received` item.
  - `TestAutomationEventSources_MailCountSkipsOwnSent` — floor read, then one received row and one `SENT` row dated after it: `CountMailAfter("gmail", …)` returns 1; an IMAP account's count is unchanged by the change.
  - `TestAutomationEventSources_MailNewsFloorIgnoresOwnSent` — the newest stored row is the owner's sent one: the floor equals the newest received row's date (or `created_at` when later).
  - `TestMailSource_OwnSentIsNotNews` — through `MailSource(d, "gmail", id)`: `Before`, then insert only an owner `SENT` row dated after the floor, `After` returns no event.
  - `TestSeedGmailSenderSkipsOwnSent` — owner address with ≥ `gmailSenderMinMessages` `SENT` rows in the window yields no candidate; a colleague over the threshold still does.
- [ ] **Step 2: Run** `go test ./internal/inbox -run TestDetectGmailAccounts`, `go test ./internal/db -run TestAutomationEventSources_Mail`, `go test ./internal/automations -run TestMailSource`, `go test ./internal/memory -run TestSeedGmailSender` — Expected: the new tests FAIL.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** the same four commands plus `make lint-diff` — Expected: PASS (existing tests in those files unchanged).
- [ ] **Step 5: Commit** — `feat(inbox): readers of what happened to the owner skip the owner's sent mail (#1076)`.

---

### Task 4: Keep readers — `sent` on the email tools; knowledge, deletions and purge take sent rows

**Depends on:** Task 1

**Files:**
- Modify: `internal/db/emails_read.go` (`LocalEmail.Sent`), `internal/tools/emails.go` (`emailSummary.Sent`, descriptions)
- Test: `internal/db/emails_read_test.go`, `internal/tools/emails_test.go`, `internal/kb/source_mail_test.go`, `internal/gmail/deletions_test.go`, `internal/db/account_purge_steps_test.go`

**Interfaces:**
- Consumes: `db.GmailOwnSentSQL` (Task 1).
- Produces:
  - `LocalEmail.Sent bool` — Gmail: `GmailOwnSentSQL` over the row and its `google_accounts` row; IMAP: `lower(trim(from_email)) = lower(trim(email_accounts.email_address))` (no Sent folder is synced, so only a self-addressed message can be true).
  - `emailSummary.Sent bool` with JSON key `sent` (additive; every existing key unchanged), filled in `summarizeEmail`, so `list_emails` and `get_email` both carry it.
  - Descriptions: `list_emails` says the list includes the owner's sent mail marked `sent: true`; the `since`/`before` jsonschema texts say "sent or received" instead of "received". Regenerate any tool-schema golden the tools package keeps.

- [ ] **Step 1: Write the failing tests:**
  - `TestListLocalEmails_MarksOwnSent` (db) — Gmail account with one received and one `SENT` row: `Sent` false/true; an IMAP self-addressed row is `Sent` true, another false.
  - `TestListEmails_SentKey` (tools) — the tool result's messages carry `"sent": true` for the owner's row and `false` for the received one; `get_email` on the sent row carries `"sent": true`.
  - `TestGmail_ThreadDocIncludesOwnerReply` (kb) — a thread with a received row and the owner's `SENT` row in the same `thread_id` builds one document whose text holds both bodies (keep side pinned).
  - `TestCheckDeletions_SentRowsLikeReceived` (gmail) — stored: a received row, a listed `SENT` row and an unlisted `SENT` row (plus enough listed rows to pass `sourcediff.MailFloors`): the unlisted sent row is removed, the listed one kept, the listing query still has no `in:inbox`.
  - `TestPurge02_GmailStepTakesSentRows` (db) — a purge of the account deletes its `SENT` rows with the received ones; another account's `SENT` row stays. (Supporting test under PURGE-02; the entry's text is unchanged.)
- [ ] **Step 2: Run** `go test ./internal/db -run 'TestListLocalEmails|TestPurge02_GmailStepTakesSentRows'`, `go test ./internal/tools -run TestListEmails`, `go test ./internal/kb -run TestGmail_`, `go test ./internal/gmail -run TestCheckDeletions` — Expected: `Sent`/`sent` tests FAIL; the kb, deletions and purge tests may already pass (they pin existing behaviour; keep them).
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** the same commands plus `go test ./internal/tools` and `make lint-diff` — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(tools): mark the owner's sent mail in list_emails and get_email (#1076)`.

---

### Task 5: Mail branch of `autoResolveByRules`

**Depends on:** Task 1

**Files:**
- Modify: `internal/db/gmail_sent.go` (query), `internal/inbox/pipeline.go`
- Test: `internal/db/gmail_sent_test.go`, `internal/inbox/pipeline_test.go`

**Interfaces:**
- Consumes: `db.ParseGmailChannelID`, `db.GmailOwnSentSQL` (Task 1); `db.ResolveInboxItem(id int, reason string) error` (existing).
- Produces:
  - `func (db *DB) GmailItemsAnsweredByOwner() ([]int, error)` — reads every `inbox_items` row with `trigger_type = 'email_received' AND status = 'pending'` (drained before any further query), parses its `channel_id` with `ParseGmailChannelID` (unparseable → skipped), reads the received row's `internal_date` (`account_id`, `id = message_ts`; missing or unparseable → the item's `created_at`), and the newest owner sent row of the thread: `SELECT MAX(m.internal_date) FROM gmail_messages m JOIN google_accounts a ON a.id = m.account_id WHERE m.thread_id = ? AND m.account_id = ? AND ` + `GmailOwnSentSQL("m","a")` (uses `idx_gmail_messages_thread`). Both dates are parsed in Go (RFC 3339); the item's id is returned when the sent date is strictly later. Any read error returns the error (no partial list).
  - `func (p *Pipeline) autoResolveGmail() int` — calls it; a returned error is logged as `inbox: autoResolveGmail: …` and resolves nothing; each id goes through `ResolveInboxItem(id, "User replied")` (an error on one is logged, the rest continue). Added to `autoResolveByRules` after `autoResolveCalendar`; its doc comment names Gmail. It never reads or writes `inbox_last_processed_ts` and its errors are not detector errors (INBOX-09 unchanged: auto-resolve is not detection).

- [ ] **Step 1: Write the failing tests:**
  - db (`gmail_sent_test.go`), each seeding a Google account `owner@example.com`, a received row R from `colleague-a@example.com` in thread `thr-a` and a pending `email_received` item for R:
    - `TestGmailItemsAnsweredByOwner_ReplyAfterReceived` — owner `SENT` row in `thr-a` dated R+5 min → item id returned.
    - `TestGmailItemsAnsweredByOwner_ReplyBeforeItemCreated` — item `created_at` = R+10 min, reply R+5 min → returned.
    - `TestGmailItemsAnsweredByOwner_OlderOwnMessageKeepsItem` — owner row dated R−1 h only → not returned.
    - `TestGmailItemsAnsweredByOwner_AliasSentLabel` — reply from `alias@example.com` with labels `["SENT"]` → returned; a reply from `colleague-b@example.com` without `SENT` → not returned.
    - `TestGmailItemsAnsweredByOwner_OtherAccountKeepsItem` — the reply is stored under a second account with the same `thr-a` → not returned.
    - `TestGmailItemsAnsweredByOwner_ReceivedRowGoneUsesCreatedAt` — R deleted, reply after the item's `created_at` → returned; reply before it → not returned.
    - `TestGmailItemsAnsweredByOwner_OnlyPendingEmailReceived` — an `email_cc` item, a resolved `email_received` item and an `imap:` item in the same situation → none returned.
  - inbox: `TestInbox02_AutoResolveGmailOnOwnerReply` (guard) — run the pipeline (`Run`) with R and the owner's reply synced: the `email_received` item ends `status = 'resolved'`, `resolved_reason = 'User replied'`, and an IMAP `email_received` item in the same run stays `pending`.
- [ ] **Step 2: Run** `go test ./internal/db -run TestGmailItemsAnsweredByOwner` and `go test ./internal/inbox -run 'TestInbox02_|TestInbox09_'` — Expected: the new tests FAIL, every existing `TestInbox02_*`/`TestInbox09_*` passes.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** `go test ./internal/db -run TestGmailItemsAnsweredByOwner`, `go test ./internal/inbox`, `make lint-diff` — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(inbox): Gmail items close when the owner replies (#1076)`.

---

### Task 6: Reader registry guard and the INBOX-02 amendment

**Depends on:** Tasks 1, 3, 4, 5

**Files:**
- Create: `internal/inbox/gmail_readers_test.go`
- Modify: `docs/inventory/inbox-pulse.md` (INBOX-02 Observable, Test guards, Changelog)

**Interfaces:**
- Consumes: the files of Tasks 1, 3, 4, 5.
- Produces: `TestInbox02_EveryGmailReaderHasASide` — walks `../../internal` and `../../cmd` for non-test `.go` files containing `gmail_messages`, and asserts the set equals the keys of a pinned map `file → side`. A new file mentioning the table fails the test with "classify <file>: skip, keep or lifecycle (docs/inventory/inbox-pulse.md INBOX-02)". The map (side per file, the reader functions in the comment beside each):

| File | Side | Readers |
|---|---|---|
| `internal/inbox/gmail_detector.go` | skip | `detectGmailAccount` (via `GmailMessagesSyncedAfter`) |
| `internal/db/automation_event_sources.go` | skip | `MailNewsFloor`, `CountMailAfter` (`gmail.new_messages`) |
| `internal/memory/seed.go` | skip | `seedGmailSenders` (correspondents) |
| `internal/db/gmail_sent.go` | answer | `GmailItemsAnsweredByOwner` (reads only the owner's sent rows) |
| `internal/kb/source_mail.go` | keep | `gmailSource.Changed/Keys/Build` |
| `internal/kb/media.go` | keep | media parent key lookup |
| `internal/doclinks/linkscan/scan.go` | keep | `gmailScanQuery` |
| `internal/db/memory.go` | keep | `GmailMessageSender`, `GmailMessageExists`, `ListGmailThreadsForExtract` (memory extraction and ideas email digests) |
| `internal/memory/gmail_extract.go`, `internal/memory/provenance.go` | keep | comments over the `internal/db/memory.go` readers |
| `internal/db/emails_read.go` | keep | `ListLocalEmails`, `GetLocalEmail` (`list_emails`/`get_email`, `sent` key) |
| `internal/tools/emails.go` | keep | `list_emails`/`get_email` tool texts naming the table (reads through `internal/db/emails_read.go`) |
| `internal/db/gmail.go` | lifecycle | `upsertGmailMessage` (writer), `GmailMessagesSyncedAfter` (detector feed), `GmailStoredIDs` + `DeleteGmailMessages` (SRCDEL), `ClearGmailData` |
| `internal/db/account_purge_steps.go` | lifecycle | PURGE-02 gmail step (`account_id = ?`) |
| `internal/db/google_accounts.go` | lifecycle | `DeleteGoogleAccount` cascade (comment) |
| `cmd/gmail.go` | lifecycle | clear confirmation row count |
| `cmd/google_legacy.go` | lifecycle | comment only |

  The implementer re-runs `grep -rln gmail_messages --include='*.go' internal cmd | grep -v _test.go` and adds any file this table missed with its side (stop and ask the controller if a file is a reader of "what happened to the owner" that no task changed). Not readers of `gmail_messages` (verified for this plan, so no test): track updates (`has_updates` comes from `internal/tracks`, which reads no mail), people cards, unread/new counts on the Desktop, Kit and phone (no Swift reads the table), the briefing, day plan and Catch-Up (they read `inbox_items` and `stream_digests`).

- [ ] **Step 1: Write the test** with the map above.
- [ ] **Step 2: Run** `go test ./internal/inbox -run TestInbox02_EveryGmailReaderHasASide` — Expected: PASS once every file is classified (FAIL first if a file was missed; classify it).
- [ ] **Step 3: Amend INBOX-02** in `docs/inventory/inbox-pulse.md`:
  - Observable, after the existing first sentence, add: "**Mail (Gmail, amended 2026-11-11, approved by the owner in ask #634):** I reply to a Gmail message — from the account's address or a "Send mail as" alias — and its `email_received` item disappears without my click. The Gmail sync stores my sent mail (`{in:inbox in:sent}`) as ordinary mail; an item resolves (`User replied`) once its Gmail thread holds a message of mine (label `SENT`, or From = the account address) dated after the message the item came from (after the item's creation when that message is gone). A message of mine never mints an item, is never `gmail.new_messages` news and never seeds a correspondent; knowledge, memory, media, ideas and `list_emails`/`get_email` (marked `sent`) keep it. `email_cc` items still archive on their own. **Not covered:** IMAP and Outlook mail (no Sent folder sync, no thread headers) — those items archive on their own as before."
  - Test guards: add `internal/inbox/pipeline_test.go::TestInbox02_AutoResolveGmailOnOwnerReply` and `internal/inbox/gmail_readers_test.go::TestInbox02_EveryGmailReaderHasASide` — "every file that names `gmail_messages` has a side (skip / keep / answer / lifecycle)".
  - Changelog: one line dated 2026-11-11 — "INBOX-02 extended to Gmail mail (inbox redesign phase 4, board #1076, ask #634); IMAP named as not covered."
- [ ] **Step 4: Run** `go test ./internal/inbox` — Expected: PASS.
- [ ] **Step 5: Commit** — `docs(inventory): INBOX-02 covers Gmail replies, reader registry guard (#1076)`.

---

### Task 7: Guide, feature notes

**Depends on:** Tasks 2, 5

**Files:**
- Modify: `docs/guide/features/mail.md`, `docs/guide/features/inbox.md`
- Modify: `docs/features/inbox-redesign.md` (add a `## Phase 4 — mail closes on reply (Gmail)` section; if phase 1 has not merged into the branch yet, create the file with its title line `# Inbox redesign` and this section only, and phase 1 merges around it)
- Modify: `docs/features/history-backfill.md` ("Fetch per source" Gmail line), `docs/features/attention-detection.md` (auto-resolve list)

**Interfaces:** none (documentation; every statement checked against Tasks 2 and 5's code, `docs/guide/WRITING.md` rule 6).

- [ ] **Step 1: Guide `mail.md`:**
  - "What gets synced": **Gmail:** "the Inbox and the mail you sent"; add one sentence: "An account connected before this version also gets your last 7 days of sent mail once (`gmail.initial_history_days`)."
  - Replace the paragraph "Your reply does not close a mail item…" with: Gmail items close when you reply in the thread (from your address or a "Send mail as" alias), at the next sync; Cc items still archive on their own after 7 days, and Outlook/IMAP items after 14 days (To) or 7 days (Cc), as today. Under that `###` heading add a learn card: `id: mail-closes-on-reply`, `title: Mail closes when you reply`, `text: Reply to a Gmail message and its Waiting for me item closes on the next sync.`, `area: communication`, `level: basics`, `kind: feature`, `since: next`, `requires: source:google` (the `internal/learn` source name for a Google account).
  - "When it's empty or wrong": one symptom line — "A Gmail item stays after you replied" → the reply must be in the same Gmail thread; it closes at the next sync; Outlook/IMAP items never close on reply.
- [ ] **Step 2: Guide `inbox.md`:** in "Waiting for me" the sentence "An item leaves when you answer in the source…" gains "(Gmail mail too; Outlook and IMAP mail archives on its own)". Keep the page under ~8 KB (`wc -c`).
- [ ] **Step 3: Feature notes:** `inbox-redesign.md` phase 4 section — listing scope, sent catch-up and its column, the owner-sent predicate and its SQL twin (`TestGmailOwnSentSQL_MatchesGo`), the reader table from Task 6 (by side), the mail branch and its date rule, INBOX-02 amendment, v1 limits: IMAP/Outlook not covered; sent mail older than the catch-up window is not fetched for accounts connected before this release (the history backfill already done does not re-run); ideas and memory floors do not re-mine the catch-up rows. `history-backfill.md`: Gmail `FetchRange` lists `{in:inbox in:sent}`. `attention-detection.md`: auto-resolve list adds Gmail `email_received`.
- [ ] **Step 4: Run** `go test ./docs/guide/ ./internal/learn/ ./internal/kb/ ./internal/chat/` — Expected: PASS (if a guide golden changes, regenerate per `docs/guide/WRITING.md`).
- [ ] **Step 5: Commit** — `docs(inbox): Gmail mail closes on reply (#1076)`.

---

## Self-review notes

- The calls the spec left open are listed under **Agent's calls**.
- Spec coverage: `in:sent` + incremental/backfill rules + `SENT` label → Task 2; reader rule over every reader with one test per skip reader → Tasks 3, 6 (registry) and 4 (keep side); mail branch → Task 5; INBOX-02 amendment + guard → Task 6; INBOX-09 relied on unchanged → Task 5 (no watermark touch, `TestInbox09_*` stay green); SRCDEL/PURGE scopes → Task 4; IMAP v1 limit → Tasks 6, 7; guide + feature note → Task 7.
