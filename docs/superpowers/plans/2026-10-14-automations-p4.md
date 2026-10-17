# Automations P4 (events) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fire `event` automations from the daemon's sync cycle: the source phases (Slack, Gmail, IMAP, Jira, Google Calendar, CalDAV, Confluence) publish typed, content-free events to an in-process bus; once per cycle the bus queues **at most one run per automation** through `db.EnqueueAutomationRun` with `Trigger: db.TriggerEvent`, and the script sees the matching events as `trigger.events`. Reaction commands are not migrated.

**Architecture:** `automations.Bus` (owned by the daemon) loads the runnable `event` subscriptions at the start of `runSync` (`Begin`), so a source is observed only when someone listens (`Wants`). Each observed phase is bracketed by a DB snapshot taken before it and a diff after it (`EventSource.Before` → phase → `EventDiff.After`); Gmail/IMAP publish from their syncers' own stored-message counts. `Publish` matches an event against every subscription's `type` + `where` at once and keeps at most 100 events per subscription. After the source phases `runSync` calls `Flush(cycleID)`: one `EnqueueAutomationRun` per subscription with at least one match (`EventCycle = cycleID`, `EventJSON` = the matches), then wakes the executor. Nothing executes inline (AUTO-09). The syncers themselves are not changed beyond two read-only `AccountID()` accessors.

**Tech Stack:** Go 1.26, SQLite (no migration in P4), the P1 `automations`/`db` seams.

**Spec:** `docs/superpowers/specs/2026-10-14-automations-design.md` — §2.3 (`trigger.event`), §7.1 (event trigger, coalescing), §8 (events), §9.2 (`event_cycle`, `event_json`, unique `(automation_id, event_cycle)`), §14.1 AUTO-09, §16 (reaction commands not on the bus), §17 (P4 depends on P1 only), §18 P4 tests. P1 plan and its **Seams for later phases**: `docs/superpowers/plans/2026-10-14-automations-p1.md`.

**Branch:** `feature/automations-p4` → PR into `feature/automations`. Never `main`. Depends on P1 merged into `feature/automations`. May run as a parallel lane with P2 (P4 touches `internal/daemon` sync phases and read-only DB helpers; P2 the registry).

**Header notes (seams):**
- Consumes P1's names exactly: `db.EnqueueAutomationRun(db.EnqueueRequest{AutomationID, Trigger, EventCycle, EventJSON, Now})`, `db.TriggerEvent`, `db.GetAutomationRun`, `db.ListAutomations(db.AutomationFilter{TriggerKind: "event", RunnableOnly: true})`, `db.AutomationEventPayload`, `automations.Trigger`/`EventTrigger{Type, Where}`/`EventTypes`, `automations.MaxEventsPerRun`, `automations.TriggerInfo{Events, Truncated}`, `(*Executor).Wake`, `daemon.AutomationRunner`/`(*Daemon).SetAutomations`, `cfg.Automations.Enabled`, `automationstest.*`.
- **Seams settled in P1** (P4 consumes them, adds no parallel name):
  - **S5** `TriggerInfo.Truncated`, and P1's executor decodes `event_json` into `trigger.events`/`trigger.truncated` for `trigger='event'` runs (P1 Task 10: `TestExecutor_EventRunExposesTriggerEvents`, `…_NonEventRunHasNoEvents`, `…_MalformedEventJSONFailsAsBackend`). P4 only produces the rows; Task 3 below is an integration check, not an implementation.
  - **S7** the `event_json` shape `{"cycles": ["<cycle id>", …], "events": [<event>, … ≤ 100], "count": <total matched>, "truncated": <bool>}` is P1's `db.AutomationEventPayload`, documented on the 00113 column; `MaxEventsPerRun = 100` is in P1's `limits.go`.
- **Owned by P4 (S6):** `db.MergeQueuedAutomationRunEvents` (Task 2). It fits P1's queue invariants: it never inserts a run (`EnqueueAutomationRun` stays the only way to create one), never writes `event_cycle` (the unique `(automation_id, event_cycle)` index keeps the first cycle), and only touches a row still `queued` with `trigger='event'` (the partial unique queued index is untouched). P1's enqueue already treats a cycle listed in any run's `event_json.cycles` as delivered (check 1 of its order), so a merged cycle is never enqueued again.

## Global Constraints

- All repo text English; repo is public — fixtures use `acme`, `example.com`, labels `work`/`home`, channel `releases`, Jira project `PAY`, space `ENG`; no real ids, no local absolute paths (`t.TempDir()`).
- Inner loop only: `go test ./internal/<pkg>`, `go test ./cmd -run '<Name>'`, `make lint-diff`. The full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) runs once at the end of the phase, by the controller.
- Tests that start a subprocess kill its process group and wait for it in `t.Cleanup` (P4 starts none).
- Transactions `BEGIN IMMEDIATE`; snapshots and diffs are read-only (`BeginTx(ctx, &sql.TxOptions{ReadOnly: true})` where a tx is needed); no write tx spans a sync phase.
- Pinned values (spec, do not change without the spec):
  - Event types and fields — ids, labels and counts only, **never content** (no message text, subject, summary, title, body):
    - `slack.new_messages{account, channel, channel_id, count}` (`phaseSlackSync`)
    - `gmail.new_messages{account, provider, count}` — `provider` ∈ `gmail`, `imap` (`phaseGmailSync`, `phaseImapSync`)
    - `jira.issue_changed{account, key, project, field}` — `field` ∈ `status`, `assignee`, `priority`, `comment`, `other` (`phaseJiraSync`)
    - `calendar.event_changed{account, event_id, change}` — `change` ∈ `created`, `updated`, `cancelled` (`phaseCalendarSync`/`phaseCalDAVSync`)
    - `confluence.page_changed{space, page_id}` (`phaseExternalSync`)
  - `cycleID` = `syncStart` of `runSync` in RFC 3339 UTC; `Flush` is called **once**, after `phaseExternalSync` and before the pipelines.
  - At most **100** events stored per run (`event_json.events`), `truncated: true` beyond; `count` = total matched.
  - At most one event run per automation per cycle — the unique index `(automation_id, event_cycle)` plus the bus.
  - `where`: every key must match (AND); a value matches case-insensitively by equality or as a `path.Match` glob (`*`); matching is not a permission (the script still needs the manifest to read the subject).
  - Reaction commands are untouched: `phaseReactionCommands` keeps its place and inputs; no `reaction.*` event type exists.
- No guard of REACT/STRIP/AGENT is touched. `docs/inventory/reaction-commands.md` is not edited.

## Review Focus

1. **Backfill is not news** — the first sync of a Slack channel, of a Jira project, of a Confluence space (before `backfill_done`) and the Gmail/IMAP initial window must not fire event runs with hundreds of "new" items. Pinned in Task 4 (`TestSlackEvents_FirstSyncOfChannelPublishesNothing`), Task 5 (`TestJiraEvents_FirstSeenProjectPublishesNothing`), Task 6 (`TestConfluenceEvents_BackfillPublishesNothing`) and Task 4 (`TestMailEvents_InitialBackfillPublishesNothing`).
2. **An automation that posts to the channel it listens to** (`output.slack` into `#releases`, `event: slack.new_messages where channel: releases`) must not trigger itself every cycle — the owner's own messages are not counted. Pinned in Task 4 (`TestSlackEvents_OwnerMessagesNotCounted`).
3. **A second cycle while the first cycle's event run is still queued** — its events are merged into the queued run (never lost, never duplicated if `Flush` runs twice), and a claim racing the merge makes the bus enqueue a fresh run. Pinned in Task 2 (`TestBus_SecondCycleMergesIntoQueuedRun`, `TestBus_MergeRaceWithClaimEnqueuesAgain`, `TestBus_OneRunPerAutomationPerCycle`).
4. **Calendar rows deleted because they left the sync window** are not "cancelled" — only events whose end is still in the future. Pinned in Task 5 (`TestCalendarEvents_PastEventLeavingWindowIsNotCancelled`).
5. **Feature off or no event subscription** — no snapshot queries run at all (no cost on every cycle). Pinned in Task 7 (`TestDaemon_NoSubscribersTakesNoSnapshots`, `TestDaemon_AutomationsDisabledNoBus`).
6. **Events carry no content** — every field of every type is an id, a label, an enum or a count. Pinned in Task 1 (`TestBus_EventsCarryNoContent`, reflecting over each source's emitted events with content-laden fixtures).

---

## File structure

| Path | Responsibility |
|---|---|
| `internal/automations/events.go` | `Event`, `EventFields`, `where` matching, `where` key validation |
| `internal/automations/bus.go` | `Bus` (`Begin`/`Wants`/`Publish`/`Flush`) |
| `internal/automations/eventsrc.go`, `eventsrc_slack.go`, `eventsrc_mail.go`, `eventsrc_jira.go`, `eventsrc_calendar.go`, `eventsrc_confluence.go` | `EventSource`/`EventDiff` per source |
| `internal/db/automation_event_sources.go` | read-only snapshot/diff queries |
| `internal/db/automation_runs.go` | `MergeQueuedAutomationRunEvents` |
| `internal/automations/bus_executor_test.go` | integration check: a flushed run decodes in P1's executor (S5 is P1's) |
| `internal/gmail/sync.go`, `internal/imap/sync.go` | `AccountID()` accessors |
| `internal/daemon/automation_events.go`, `internal/daemon/daemon.go` | bus wiring, observed phases, `Flush` |
| `cmd/sync.go` | build the bus when the daemon starts |
| `docs/inventory/automations.md`, `docs/features/automations.md` | docs |

---

### Task 1: Event model and `where` matching

**Files:**
- Create: `internal/automations/events.go`, `internal/automations/events_test.go`
- Modify: `internal/automations/recipe.go` (validate `where` keys at parse time), `internal/automations/recipe_test.go`

**Interfaces:**
- Consumes: P1 `EventTypes`, `EventTrigger{Type, Where map[string]string}`, `ParseRecipe`.
- Produces:
  - `type Event struct { Type string; Fields map[string]any }`; `func (e Event) MarshalJSON() ([]byte, error)` → flat `{"type": …, <fields>}` (the shape of one `trigger.events` element).
  - `var EventFields = map[string][]string{"slack.new_messages": {"account","channel","channel_id"}, "gmail.new_messages": {"account","provider"}, "jira.issue_changed": {"account","key","project","field"}, "calendar.event_changed": {"account","event_id","change"}, "confluence.page_changed": {"space","page_id"}}` — the matchable (string) fields; `count` is not matchable.
  - `func MatchWhere(where map[string]string, e Event) bool` — every key present and matching (case-insensitive equality, or `path.Match` on lower-cased pattern and value); empty `where` matches all events of the type.
  - `ParseRecipe` refuses a `where` key not in `EventFields[type]` and a malformed glob (`path.ErrBadPattern`) — parse error naming the key. (`trigger` is outside `approval_hash`, D5: no hash impact.)
- Depends on: none.

- [ ] **Step 1: Failing tests:**
  - `TestBus_WhereFilterAndGlob` — `{channel:"releases"}` matches `Releases`, not `release`; `{channel:"rel*"}` matches `releases`; `{account:"work", channel:"*"}` requires both; `{}` matches all of the type.
  - `TestRecipe_EventWhereUnknownKeyRefused` — `where: {count: "3"}` and `where: {subject: "x"}` on `gmail.new_messages` → parse error naming the key; `where: {channel: "[bad"}` → parse error.
  - `TestEvent_MarshalsFlat`.
  - `TestBus_EventsCarryNoContent` — scaffold here (asserts every `EventFields` key plus `count`/`channel_id` belongs to an allowlist of id/label/enum/count names); extended in Tasks 4–6 with each source's emitted events from fixtures whose text/subject/summary/title contain the marker `CONTENT-MARKER-acme` — no serialised event contains it.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestBus_WhereFilterAndGlob|TestRecipe_EventWhere|TestEvent_|TestBus_EventsCarryNoContent'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): event model and where matching`.

### Task 2: The bus — subscriptions, publish, flush, merge

**Files:**
- Create: `internal/automations/bus.go`, `internal/automations/bus_test.go`
- Modify: `internal/db/automation_runs.go`, `internal/db/automation_runs_test.go`

**Interfaces:**
- Consumes: `db.ListAutomations(db.AutomationFilter{TriggerKind: "event", RunnableOnly: true})`, `db.EnqueueAutomationRun`, `db.GetAutomationRun`, `db.AutomationEventPayload`, `automations.MaxEventsPerRun`, `automations.Trigger` (decoding `trigger_spec` with the same type P1 marshals), Task 1.
- Produces:
  - `db`: `func (d *DB) MergeQueuedAutomationRunEvents(runID int64, cycleID string, events []json.RawMessage, total int, maxEvents int) (merged bool, err error)` — one `BEGIN IMMEDIATE` tx over the run's `AutomationEventPayload`: only while `status='queued'` and `trigger='event'`; never writes `event_cycle`; a `cycleID` already in `event_json.cycles` → `(true, nil)` with nothing written (idempotent); else appends the cycle, appends events up to `maxEvents` (older kept, newer beyond the cap dropped), adds `total` to `count`, sets `truncated` when anything was dropped. Not queued any more → `(false, nil)`.
  - `type Bus struct{…}`; `func NewBus(d *db.DB, clock Clock, wake func(), logger *log.Logger) *Bus`.
  - `func (b *Bus) Begin() error` — loads the subscriptions (automation id + `EventTrigger`) and clears the previous cycle's matches.
  - `func (b *Bus) Wants(eventType string) bool` — any subscription of that type.
  - `func (b *Bus) Publish(events ...Event)` — for each subscription of the event's type whose `where` matches: keep the first `MaxEventsPerRun`, count all; safe for concurrent callers (mutex).
  - `type FlushReport struct { Queued, Merged, Coalesced int }`; `func (b *Bus) Flush(cycleID string) (FlushReport, error)` — per subscription with ≥ 1 match: `EnqueueAutomationRun{AutomationID, Trigger: db.TriggerEvent, EventCycle: cycleID, EventJSON: <db.AutomationEventPayload{Cycles: [cycleID], Events, Count, Truncated}>, Now: clock.Now()}`; on `coalesced`: if the returned run already lists `cycleID` (its `event_cycle` or its `event_json.cycles` — P1's check 1) → nothing (already delivered); else (P1's check 2, a queued run of another cycle) `MergeQueuedAutomationRunEvents`; a merge returning `false` (the run was claimed meanwhile) → `EnqueueAutomationRun` once more; one subscription's error is logged and does not stop the others; `wake()` once when anything was queued or merged; matches are cleared after `Flush`.
- Depends on: Task 1.

- [ ] **Step 1: Failing tests** (file DB, `automationstest.SeedAutomation` with `trigger: {event: …}`):
  - `TestAuto09_FlushOnlyQueues` — matching events + `Flush` → one `queued` row `trigger='event'`, `event_cycle` = cycleID; `FakeGenerator` and `FakeRegistry` record zero calls; no row ever leaves `queued` within the test.
  - `TestBus_OneRunPerAutomationPerCycle` — three matching events, `Flush(c)` twice → one run with three events; a second automation subscribed to the same type → its own single run.
  - `TestBus_TruncatesAt100` — 150 matching events → `events` length 100 (the first 100 published), `count` 150, `truncated` true.
  - `TestBus_SecondCycleMergesIntoQueuedRun` — cycle A queues; cycle B (run still queued) → no new row, the run's `event_json.cycles` = [A, B], events appended, `count` summed; `Flush(B)` again → unchanged.
  - `TestBus_MergeRaceWithClaimEnqueuesAgain` — the run is claimed between enqueue and merge (a test hook) → a new `queued` row for cycle B.
  - `TestBus_NonMatchingAndNotRunnableQueueNothing` — `where` mismatch; unconfirmed recipe; disabled; parse error → zero rows.
  - `TestBus_WantsOnlySubscribedTypes`; `TestBus_BeginClearsPreviousCycle`.
  - `TestBus_WakeCalledOnceWhenQueued` / not called when nothing queued.
  - `TestMergeQueuedEvents_RefusesNonQueuedAndNonEvent` (db).
  - `TestMergeQueuedEvents_KeepsQueueInvariants` (db) — after a merge of cycle B into the queued run of cycle A: `event_cycle` still A, exactly one queued row of the automation, `EnqueueAutomationRun{EventCycle: B}` → coalesced onto that run (P1's check 1), also after the run finished.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestAuto09_Flush|TestBus_'` and `go test ./internal/db -run 'TestMergeQueuedEvents|TestEnqueue_EventCycle'` → FAIL (new ones; P1's `TestEnqueue_EventCycle*` stay green).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS; `go test -race ./internal/automations -run TestBus_` once.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): event bus with one run per automation per cycle`.

### Task 3: The bus's rows reach `trigger.events` (S5 integration check)

**Files:**
- Create: `internal/automations/bus_executor_test.go`

**Interfaces:**
- Consumes: P1's executor, which already decodes `event_json` into `trigger.events`/`trigger.truncated` (S5, P1 Task 10); Task 2's `Flush` and merge.
- Produces: nothing new — pins that what the bus writes is what P1's executor decodes (one shape, one owner).
- Depends on: Task 2.

- [ ] **Step 1: Failing tests:**
  - `TestBus_FlushedRunDecodesInExecutor` — `Publish` two `slack.new_messages` events, `Flush`, `Executor.Step` → the script returns `trigger.events.length + ":" + trigger.events[0].channel + ":" + trigger.truncated` = `"2:releases:false"`.
  - `TestBus_MergedAndTruncatedRunDecodesInExecutor` — 150 events over two cycles merged into one queued run → `trigger.events.length === 100`, `trigger.truncated === true`.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestBus_FlushedRunDecodes|TestBus_MergedAndTruncated'` → FAIL.
- [ ] **Step 3:** Fix only the bus side if they fail (the decoder is P1's).
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `test(automations): bus rows decode as trigger.events`.

### Task 4: Sources — Slack and mail

**Files:**
- Create: `internal/automations/eventsrc.go`, `eventsrc_slack.go`, `eventsrc_mail.go`, `eventsrc_slack_test.go`, `eventsrc_mail_test.go`; `internal/db/automation_event_sources.go`, `internal/db/automation_event_sources_test.go`
- Modify: `internal/gmail/sync.go`, `internal/imap/sync.go` (`func (s *Syncer) AccountID() int64`, read-only accessors)

**Interfaces:**
- Consumes: `sync_state(channel_id, last_synced_ts, is_initial_sync_complete)`, `messages(channel_id, ts, user_id, is_deleted)`, `channels(id, name)`, `slack_accounts(id, label, team_domain, current_user_id)`, `google_accounts(id, label, email)`, `email_accounts(id, label, email_address)`.
- Produces:
  - `type EventSource interface { Type() string; Before(ctx context.Context) (EventDiff, error) }`; `type EventDiff interface { After(ctx context.Context) ([]Event, error) }`.
  - `func SlackSource(d *db.DB) EventSource` — Before: per channel `(last_synced_ts, is_initial_sync_complete)`; After: for each channel whose `last_synced_ts` advanced **and** whose initial sync was complete before the phase → one `slack.new_messages` with `count` = non-deleted messages with `ts` > the old `last_synced_ts` whose `user_id` is not the account's `current_user_id`; a count of 0 → no event; `account` = the Slack account label (fallback `team_domain`), `channel` = `channels.name`, `channel_id` = the namespaced id.
  - `func MailEvent(d *db.DB, provider string, accountID int64, count int) (Event, bool, error)` — `gmail.new_messages{account, provider, count}`; `account` = label (fallback the address); `count == 0` → `(…, false, nil)`.
  - `db` read helpers: `SlackChannelSyncMarks() (map[string]SlackSyncMark, error)`, `CountSlackMessagesAfter(channelID, afterTS, excludeUserID string) (int, error)`, `SlackEventLabels(accountID int64) (account string, ownerUserID string, err error)`, `ChannelName(channelID string) (string, error)`, `MailAccountLabel(provider string, accountID int64) (string, error)`; each read-only.
  - Mail backfill rule: the daemon publishes only when the account had a non-zero watermark before the phase (`google_accounts.gmail_last_internal_date > 0`; `email_accounts.last_uid > 0`) — read by `db.MailWatermarkSet(provider, accountID) (bool, error)` before the syncer runs.
- Depends on: Task 1.

- [ ] **Step 1: Failing tests** (seeded file DB; the "phase" is simulated by inserting rows and advancing `sync_state` between `Before` and `After`):
  - `TestSlackEvents_NewMessagesPerChannel` — two channels advanced (3 and 1 new) → two events with the right counts, labels and names.
  - `TestSlackEvents_FirstSyncOfChannelPublishesNothing` — channel with `is_initial_sync_complete=0` before → no event.
  - `TestSlackEvents_OwnerMessagesNotCounted` — 2 messages by `current_user_id`, 1 by colleague A → count 1; only owner messages → no event.
  - `TestSlackEvents_DeletedMessagesNotCounted`.
  - `TestSlackEvents_UnchangedWatermarkNoEvent`.
  - `TestMailEvents_LabelFallbackAndProvider` — Gmail account with label `work` → `account:"work", provider:"gmail"`; IMAP account without label → its address, `provider:"imap"`.
  - `TestMailEvents_InitialBackfillPublishesNothing` — watermark 0 before the phase → none.
  - `TestBus_EventsCarryNoContent` extended with Slack and mail events over `CONTENT-MARKER-acme` fixtures.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestSlackEvents|TestMailEvents|TestBus_EventsCarryNoContent'` and `go test ./internal/db -run TestAutomationEventSources` → FAIL.
- [ ] **Step 3:** Implement (accessors are one-liners; no change to the syncers' behaviour).
- [ ] **Step 4:** Step 2 commands → PASS; `go test ./internal/gmail ./internal/imap` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): Slack and mail event sources`.

### Task 5: Sources — Jira and calendars

**Files:**
- Create: `internal/automations/eventsrc_jira.go`, `eventsrc_calendar.go`, `eventsrc_jira_test.go`, `eventsrc_calendar_test.go`
- Modify: `internal/db/automation_event_sources.go` (+ tests)

**Interfaces:**
- Consumes: `jira_issues(account_id, key, project_key, status, assignee_account_id, priority, updated_at, is_deleted)`, `jira_comments(account_id, issue_key)`, `jira_accounts(id, label, site_name)`; `calendar_events(id, calendar_id, event_status, updated_at, start_time, end_time)`, `calendar_calendars(id, account_id)`, `google_accounts`, `calendar_accounts(id, label)` with `db.CalendarAccountCalendarID(provider, id)` = `"<provider>:<id>"`.
- Produces:
  - `func JiraSource(d *db.DB) EventSource` — Before: per `(account, key)` `{project, status, assignee_account_id, priority, updated_at, comment_count}` plus the set of `(account, project)` with ≥ 1 issue; After: for each issue now present: unchanged tuple → nothing; else one event **per changed field** in the order `status`, `assignee`, `priority`, `comment` (comment count grew); `other` only when none of those changed but `updated_at` moved; an issue absent before in a project that had issues → one `field:"other"` event; an issue in a project with no issues before (first sync) → nothing; `account` = label (fallback `site_name`), `project` = `project_key`.
  - `func CalendarSource(d *db.DB) EventSource` — spans `phaseCalendarSync` **and** `phaseCalDAVSync` (Before ahead of the first, After behind the second). Before: per event `{calendar_id, event_status, updated_at, start_time, end_time}`; After: new id → `created`; `event_status` became `cancelled` → `cancelled`; a row gone whose `end_time` is still after now → `cancelled`; a row gone whose end has passed → nothing (left the window); `updated_at`, start or end changed → `updated`; `account` = the Google account label (fallback email) via `calendar_calendars.account_id`, or the `calendar_accounts.label` for a `caldav:<id>`/`ics:<id>` calendar.
  - A calendar or Jira account with no rows before the phase (just connected) → nothing (backfill rule).
- Depends on: Task 4 (`EventSource` types).

- [ ] **Step 1: Failing tests:**
  - `TestJiraEvents_FieldPerChange` — status + assignee changed → two events in that order; priority only → one; comment added → `comment`; only `updated_at` → `other`.
  - `TestJiraEvents_FirstSeenProjectPublishesNothing`; `TestJiraEvents_NewIssueInKnownProjectIsOther`.
  - `TestJiraEvents_AccountLabelFallback`.
  - `TestCalendarEvents_CreatedUpdatedCancelled` — new, moved, `event_status` cancelled → `created`, `updated`, `cancelled`.
  - `TestCalendarEvents_DeletedFutureEventIsCancelled`; `TestCalendarEvents_PastEventLeavingWindowIsNotCancelled`.
  - `TestCalendarEvents_CalDAVAccountLabel` — `caldav:2` calendar → `calendar_accounts.label`.
  - `TestCalendarEvents_NewAccountBackfillPublishesNothing`.
  - `TestBus_EventsCarryNoContent` extended (titles/summaries/descriptions carry the marker).
- [ ] **Step 2:** `go test ./internal/automations -run 'TestJiraEvents|TestCalendarEvents|TestBus_EventsCarryNoContent'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): Jira and calendar event sources`.

### Task 6: Source — Confluence

**Files:**
- Create: `internal/automations/eventsrc_confluence.go`, `eventsrc_confluence_test.go`
- Modify: `internal/db/automation_event_sources.go` (+ tests)

**Interfaces:**
- Consumes: `ext_documents(source_id, ext_id, kind, version)`, `ext_sources(id, container_key, backfill_done)`.
- Produces: `func ConfluenceSource(d *db.DB) EventSource` — Before: per `(source_id, ext_id)` of `kind='page'` the `version`, plus each source's `backfill_done`; After: for a source whose `backfill_done` was 1 before the phase, a page that is new or whose `version` increased → `confluence.page_changed{space: container_key, page_id: ext_id}`; comment-only changes (`children_changed_at`), attachments and blog posts → nothing in v1.
- Depends on: Task 4.

- [ ] **Step 1: Failing tests:** `TestConfluenceEvents_NewAndBumpedPages`, `TestConfluenceEvents_BackfillPublishesNothing`, `TestConfluenceEvents_CommentOnlyChangeIsNotAnEvent`, `TestConfluenceEvents_BlogpostAndAttachmentIgnored`; `TestBus_EventsCarryNoContent` extended (page titles/sections carry the marker).
- [ ] **Step 2:** `go test ./internal/automations -run 'TestConfluenceEvents|TestBus_EventsCarryNoContent'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): Confluence event source`.

### Task 7: Daemon — observed phases and the per-cycle flush

**Files:**
- Create: `internal/daemon/automation_events.go`, `internal/daemon/automation_events_test.go`
- Modify: `internal/daemon/daemon.go` (field, setter, `runSync`, mail syncer interfaces), `cmd/automations_daemon.go` (build `automations.NewBus` next to P1's scheduler/executor in `newDaemonAutomations`/`wireAutomations`, `wake` = the executor's `Wake`; P1's wiring moved out of `cmd/sync.go`, which only calls `wireAutomations`)

**Interfaces:**
- Consumes: Tasks 2, 4–6; P1 `(*Daemon).SetAutomations`, `cfg.Automations.Enabled`.
- Produces:
  - `type AutomationEvents interface { Begin() error; Wants(eventType string) bool; Publish(events ...automations.Event); Flush(cycleID string) (automations.FlushReport, error) }`; `func (d *Daemon) SetAutomationEvents(ev AutomationEvents)` (nil = off).
  - `func (d *Daemon) observePhase(src automations.EventSource, phase func())` — when `ev != nil && ev.Wants(src.Type())`: `Before` → `phase()` → `After` → `Publish`; a snapshot/diff error is logged (never fails or skips the phase); otherwise just `phase()`.
  - `runSync`: `ev.Begin()` first (error logged, events off for this cycle); `phaseSlackSync` through `observePhase(SlackSource)`; `phaseCalendarSync`+`phaseCalDAVSync` through one `observePhase(CalendarSource)`; `phaseJiraSync` through `observePhase(JiraSource)`; `phaseExternalSync` through `observePhase(ConfluenceSource)`; `phaseGmailSync`/`phaseImapSync` publish `MailEvent` per syncer with its returned `n` (also when the syncer returned an error with `n > 0`), gated by `Wants("gmail.new_messages")` and the pre-phase watermark check; then `ev.Flush(syncStart.UTC().Format(time.RFC3339Nano))` once (amended 2026-10-17 from `time.RFC3339`: the startup calendar pass is its own event cycle, and two cycles in one second must not share an id; still RFC 3339) — also on a cancelled ctx (it only inserts rows, no network), before the "context cancelled, skipping pipelines" return. `phaseReactionCommands` keeps its position and arguments.
  - `gmailSyncers`/`imapSyncers` fields become narrow interfaces `mailAccountSyncer interface { Sync(ctx context.Context) (int, error); AccountID() int64 }` (the `jiraAccountSyncer` precedent); `SetGmailSyncers`/`SetImapSyncers` keep their concrete parameter types.
  - `cmd/sync.go`: the bus exists only when `cfg.Automations.Enabled`; otherwise `SetAutomationEvents(nil)`.
- Depends on: Tasks 2–6.

- [ ] **Step 1: Failing tests** (`automation_events_test.go`; a fake `AutomationEvents` recording calls, plus a real `Bus` over a file DB for the end-to-end ones):
  - `TestPhaseSlackSync_PublishesNewMessages` — `observePhase(SlackSource, fakePhase)` where `fakePhase` writes messages + advances `sync_state` → one published event.
  - `TestPhaseGmailSync_PublishesNewMessages` / `TestPhaseImapSync_PublishesNewMessages` — fake mail syncers returning `(3, nil)` and `(2, errPartial)` → events with counts 3 and 2; `(0, nil)` → none.
  - `TestPhaseJiraSync_PublishesIssueChanged` — fake `jiraAccountSyncer` whose `Sync` updates a seeded issue's status → one `field:"status"` event; the Jira interval gate returning early → none.
  - `TestPhaseCalendarSync_PublishesEventChanged` — one snapshot around both calendar phases (Google + CalDAV fixtures).
  - `TestPhaseExternalSync_PublishesPageChanged` — fake `ExternalSyncRunner` bumping a page version.
  - `TestRunSync_FlushOncePerCycleAfterSources` — call order recorded: `Begin`, sources…, `Flush` exactly once with `syncStart` in RFC 3339 UTC, before `phaseChannelDigests`.
  - `TestRunSync_FlushRunsOnCancelledContext`.
  - `TestDaemon_NoSubscribersTakesNoSnapshots` — `Wants` false everywhere → the snapshot queries never run (a counting `EventSource` fake).
  - `TestDaemon_AutomationsDisabledNoBus` — `cfg.Automations.Enabled=false` through the `cmd/sync.go` builder → `SetAutomationEvents(nil)`; `runSync` unchanged.
  - `TestDaemon_ReactionCommandsUnchangedByBus` — with a bus subscribed to `slack.new_messages`, `phaseReactionCommands` still runs right after `phaseSlackSync` with the same inputs, and the bus sees no event type outside `EventTypes`.
  - `TestDaemon_SnapshotErrorDoesNotSkipPhase`.
- [ ] **Step 2:** `go test ./internal/daemon -run 'TestPhase.*Publishes|TestRunSync_Flush|TestDaemon_NoSubscribers|TestDaemon_AutomationsDisabledNoBus|TestDaemon_ReactionCommandsUnchangedByBus|TestDaemon_SnapshotError'` and `go test ./cmd -run TestDaemon_AutomationsDisabledNoBus` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS; `go test ./internal/daemon` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): publish sync events and flush once per cycle`.

### Task 8: End-to-end and docs

**Files:**
- Create: `internal/daemon/automation_events_e2e_test.go`
- Modify: `docs/inventory/automations.md`, `docs/features/automations.md`, `docs/inventory/README.md` (module row gains `internal/automations/bus.go`, `internal/automations/eventsrc*.go`, `internal/daemon/automation_events.go`, `internal/db/automation_event_sources.go`)

**Interfaces:**
- Consumes: everything above; P1 executor (incl. its S5 `trigger.events` decoding) with `automationstest` fakes.
- Produces:
  - `TestEventAutomation_EndToEnd` — a confirmed, enabled recipe `trigger: {event: {type: slack.new_messages, where: {channel: releases}}}`, `permissions: [llm:light]`, `outputs: [inbox]`, script `output.inbox({title: "New in #" + trigger.events[0].channel, body: String(trigger.events[0].count)})`; one simulated cycle through `runSync`'s observed Slack phase + `Flush`; `Executor.Step` → run `succeeded`, one inbox output `"New in #releases"` / `"2"`; a second cycle with no new messages → no run.
  - Inventory: **AUTO-09** event half Planned → **Enforced** — Observable gains "the event bus's `Flush` only inserts `queued` rows (one per automation per cycle) and merges into a still-queued event run; event runs carry ids, labels, enums and counts only"; guards `TestAuto09_FlushOnlyQueues`, `TestBus_OneRunPerAutomationPerCycle`, `TestBus_EventsCarryNoContent` (`internal/automations/bus_test.go`, `events_test.go`). No new AUTO number. AGENT/STRIP/REACT entries untouched.
  - Feature note: P4 section — event types and fields, backfill rule, owner-message rule, `where` semantics, merge into a queued run, cost (snapshots only for subscribed types), v1 limits (comment-only Confluence changes and blog posts are not events; a cycle's events are diffed against the previous DB state, so changes made and reverted within one sync interval are invisible).
- Depends on: Task 7.

- [ ] **Step 1:** Write the e2e test → FAIL; make it pass (fix only wiring, never weaken a Task 1–7 test).
- [ ] **Step 2:** `go test ./internal/daemon -run TestEventAutomation_EndToEnd` → PASS.
- [ ] **Step 3:** Docs; verify each guard name: `grep -rn '<name>' internal cmd` → found.
- [ ] **Step 4:** `git add`, `bash scripts/leak-check.sh --staged` → clean.
- [ ] **Step 5:** Commit `docs(automations): AUTO-09 event half enforced, P4 feature note`.

### Phase gate (controller, once)

- [ ] `bash scripts/dev-health.sh` → not overloaded.
- [ ] `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` (logs to files, explicit exit codes).
- [ ] local-review, then one PR `feature/automations-p4 → feature/automations`.

---

## Self-review against the spec

- §8 bus owned by the daemon → Tasks 2, 7; the five event families and their phases → Tasks 4–7; `Flush(cycleID)` once after the source syncs, `cycleID = syncStart` RFC 3339 UTC → Task 7; one run per automation per cycle with `event_cycle`/`event_json`, at most 100 + `truncated` → Task 2; unique index already in P1's 00113; `where` equality/glob, case-insensitive, not a permission → Task 1; "reaction commands are not migrated" → Task 7 (`TestDaemon_ReactionCommandsUnchangedByBus`); AUTO-09 event half → Tasks 2, 8.
- §18 P4 tests: `TestBus_OneRunPerAutomationPerCycle`, `TestBus_WhereFilterAndGlob`, `TestBus_EventsCarryNoContent`, `TestBus_TruncatesAt100`, one publisher test per sync phase (`TestPhaseSlackSync_…`, `TestPhaseGmailSync_PublishesNewMessages`, `TestPhaseImapSync_…`, `TestPhaseJiraSync_…`, `TestPhaseCalendarSync_…`, `TestPhaseExternalSync_…`), `TestAuto09_FlushOnlyQueues` — all present.
- No migration (P1's 00113 already has `event_cycle`, `event_json`, the unique index); no Swift (the trigger text "On new Gmail (work)" is P3's list rendering).
