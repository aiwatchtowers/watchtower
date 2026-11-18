# AI chat on the iPhone over the relay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner uses Watchtower's main AI chat from the iPhone over the hosted relay. The Go hub in the daemon runs the turns. The Mac and the phone share the same chats.

**Architecture:**
- A new `internal/chatstore` ports the Swift chat write path to Go.
- `internal/hub/chatrun` spawns the existing `watchtower ai session` per conversation and feeds its events into that store.
- A `chat_turn_leases` row gives one turn per conversation across the Swift and Go writers.
- New hub actions and slices carry chats to the phone.
- A new Chats tab on the phone renders them.

**Tech Stack:**
- Go 1.26: goose migrations, `internal/hub` actions, slices and `secure`.
- Swift: WatchtowerCore and Desktop on GRDB, WatchtowerKit, and the iPhone app in SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-15-iphone-chat-design.md` (approved ask #1345; contracts ask #1340). Mockups: `docs/design/mockups/iphone-chat/index.html`.

**Branching:** umbrella branch `feature/1791-iphone-chat`. Each task runs on `feature/1791-tN-<slug>` in its own worktree, with its own review and a PR into the umbrella. The umbrella PR into `main` stays a draft until T12 is done.

## Global Constraints

- **Relay only:**
  - `capabilities.chat` is `"on"` only while the hub's transport is the relay, `chatrun` started, and no running Desktop lacks the lease flag (spec §4.8, D18).
  - The phone requires an explicit `"on"`.
- **Lease times** are integer Unix epoch milliseconds (`*_at_ms`):
  - stale after `60000` ms without a heartbeat;
  - heartbeat every 15 s;
  - cancel poll every 1 s;
  - on cancel, finalise `partial` if no `turn_done` comes within 7 s, then SIGTERM, then SIGKILL.
- **Hub pool:** 2 live sessions, idle TTL 10 min on a 30 s check. A new turn evicts an idle session at once. A queue exists only while both are mid-turn.
- **Flush:** assistant text is written every 1 s.
- **Feed:**
  - last 60 active-branch messages;
  - 600 000 bytes cap;
  - 40 000 chars per message;
  - `chat_page` pages of 60;
  - `chat_search` up to 50 hits with snippets ≤ 200 chars;
  - `chat_list` up to 200 conversations with `last_line` ≤ 120 chars.
- **Watches and expiry:**
  - an `open` watch lasts 5 min and is repeated every 60 s;
  - a `prefetch` record is deleted after 2 min;
  - page and search records are deleted after 5 min;
  - the phone shows "The Mac did not answer" + Retry after 30 s with no record.
- **Text limits:**
  - `chat_turn.text` ≤ 32 000 chars;
  - search query ≤ 200 chars;
  - prefix title = first 80 chars.
- **Attachments:**
  - images png/jpeg/gif/webp ≤ 5 MB;
  - PDF ≤ 32 MB;
  - text ≤ 256 KB;
  - one message ≤ 30 MB encoded.
- **Push:**
  - `chat_answer` titles carry the conversation title; the body is fixed: "Answer ready" / "The answer stopped" / "Waiting for your approval";
  - a push is suppressed only by an `open` request in the last 90 s;
  - ledger key `chat:<turn_id>:<event>`.
- **Phone offline copy:**
  - 200 MB per hub;
  - prefetch the 20 most recent chats, at most once per chat per hour, foreground only;
  - file protection `completeUntilFirstUserAuthentication`.
- **Grant:**
  - `chat` is on by default for linked and new phones;
  - approvals also need `permissions`.
- **Copy, verbatim:**
  - "Answering from your iPhone — you can watch here"
  - "Your Mac is asleep. You can read chats; sending works when it wakes."
  - "Your Mac is asleep — sending works when it wakes."
  - "Answering on your Mac — you can watch here."
  - "Switch to Relay…"
  - "Chat works over Relay"
  - "Update Watchtower on your Mac"
  - "Chat is off for this phone"
  - "Couldn't load chats"
  - "Getting your chats from the Mac…"
  - "Opening the chat on your Mac…"
  - "The Mac did not answer"
  - "Waiting for a free slot"
  - "Load earlier messages"
  - "Searching on your Mac…"
  - "Searching messages needs your Mac"
  - "Open this chat once while your Mac is awake to read it here"
  - "Approve on the Mac"
  - "The action changed — look again"
  - "Chat on this iPhone: ask, approve with Permissions"
- **Logs:** ids and counts only (FILES-01). Tests never wait on wall-clock: use `testing/synctest`, a fake clock or fakes.
- **Repo rules:**
  - every new table goes into `internal/db/schema.sql` and `TestAllTablesExist`, with the goldens regenerated (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`);
  - every Desktop UI text lives in a model and is tested;
  - colours only through `Tone`;
  - a new Go reader of chat tables joins `liveCheckedReaders` or `displayOnlyReaders` (`internal/db/live01_test.go`).
- **Inner loop only per task** (CLAUDE.md "Agent-driven runs"). The full gate runs once per phase, by the controller.

## Review Focus

1. **A phone send while the Mac app is mid-turn on the same chat.** The phone must get `conversation_busy` and its text back. A half-written turn must never appear. Test `TestLease_ConcurrentClaimOneWins` (T1) and the `chat_turn` refusal test in T5.
2. **The daemon restarts mid-turn.** The Mac must show the partial text and be able to send at once, without waiting 60 s. Test `TestChatrun_StartupSweepMarksSessionLost` (T4).
3. **A chat with a very long history or huge artifacts opened on the phone.** It must not fail to publish (the oversized record is silently skipped by the publisher). Test `TestChatFeed_CapsDropOldestThenArtifacts` (T6) with a 2 MB conversation.
4. **An owner approves an action on the phone after it changed on the Mac.** It must refuse with "The action changed — look again", never apply. Test `TestChatActionAnswer_StaleHashRefused` (T5).
5. **The phone is killed mid-upload of a large PDF.** No `chat_attachments` row is written, and the next `chat_turn` naming it is refused with `attachment_missing`. Test `TestChatAttachment_PartialUploadWritesNothing` (T5).

---

### Task 1: `chat_turn_leases` migration and the Go lease API

**Files:**
- Create: `internal/db/migrations/00189_chat_turn_leases.sql` (take the next free number on the umbrella at implementation time)
- Create: `internal/db/chat_lease.go`, `internal/db/chat_lease_test.go`
- Create: `internal/db/testdata/chat_lease_cases.json` (shared with Swift in T8)
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), the schema goldens and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)

**Interfaces:**
- Produces, in package `db`:
  - `type ChatLeaseOwner string` with constants `ChatLeaseDesktop = "desktop"` and `ChatLeaseHub = "hub"`;
  - `type ChatLease struct { ConversationID int64; Owner ChatLeaseOwner; OwnerID, TurnID string; StartedAtMS, HeartbeatAtMS int64; CancelRequestedAtMS *int64 }`;
  - `ClaimChatLeaseTx(tx *sql.Tx, l ChatLease, nowMS int64) (bool, error)`, which upserts the row only when it is absent or `heartbeat_at_ms < nowMS-60000`;
  - `HeartbeatChatLease(conv int64, turnID string, nowMS int64) (bool, error)`, which returns false when the row is gone;
  - `RequestChatCancel(conv int64, turnID string, nowMS int64) (bool, error)`;
  - `ReleaseChatLeaseTx(tx *sql.Tx, conv int64, turnID string) error`;
  - `GetChatLease(conv int64) (*ChatLease, error)`;
  - `ReleaseOwnedChatLeases(owner ChatLeaseOwner, ownerID string) (int64, error)`.
  - `const ChatLeaseStaleMS = 60000`.
- The fixture is a JSON array of `{name, steps:[{op: claim|heartbeat|cancel|release, owner, owner_id, turn_id, now_ms}], expect:[{ok, lease:{…}|null}]}`.

- [ ] **Step 1: Write the failing tests.**
  - `TestChatLeaseCases` runs every case in `chat_lease_cases.json`. Include these cases:
    - claim on an empty row → ok;
    - a second claim by another owner at +59 999 ms → refused;
    - the same at +60 001 → ok;
    - heartbeat on a released row → false;
    - cancel with a wrong `turn_id` → false;
    - release by a wrong `turn_id` → no-op.
  - `TestLease_ConcurrentClaimOneWins`: two `*DB` handles on one file, both `BEGIN IMMEDIATE` and claim the same conversation from two goroutines; exactly one commits a lease.
  - `TestLease_CascadeOnConversationDelete`: deleting the conversation removes the lease.
  - `TestAllTablesExist` lists `chat_turn_leases`.
- [ ] **Step 2: Run** `go test ./internal/db -run 'TestChatLease|TestLease_|TestAllTablesExist'`. Expected: FAIL (no table).
- [ ] **Step 3: Write the migration** with the spec §4.4 columns (`started_at_ms`, `heartbeat_at_ms`, `cancel_requested_at_ms` as INTEGER), the `ON DELETE CASCADE` FK and the CHECK on `owner`. Mirror it in `schema.sql` and regenerate the goldens.
- [ ] **Step 4: Implement the functions in `chat_lease.go`.** The claim is one `INSERT … ON CONFLICT(conversation_id) DO UPDATE SET … WHERE chat_turn_leases.heartbeat_at_ms < excluded.heartbeat_at_ms - 60000`, with `RowsAffected()==1` meaning won. Add the new readers to `displayOnlyReaders` if `TestLIVE01_ReaderList` asks.
- [ ] **Step 5: Run** `go test ./internal/db`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(db): chat turn leases (#1791 T1)`.

---

### Task 2: Shared chat text code in the Kit, and the Go artifact parser twin

**Files:**
- Move: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactParser.swift`, `MarkdownRunBuilder.swift` and `ChatQuoteReply.swift` → `WatchtowerKit/Sources/WatchtowerKit/Chat/`. Keep them `public`; WatchtowerCore re-exports them via `@_exported import WatchtowerKit` or plain imports at the call sites. Their tests move to `WatchtowerKit/Tests/WatchtowerKitTests/Chat/`.
- Create: `internal/chat/testdata/artifact_parse_cases.json`
- Create: `internal/chatstore/artifacts.go`, `internal/chatstore/artifacts_test.go`
- Create: `WatchtowerKit/Tests/WatchtowerKitTests/Chat/ArtifactParseFixtureTests.swift`

**Interfaces:**
- Produces (Go):
  - `chatstore.ParsedArtifact{Key, Kind, Title, Content string; Meta map[string]string}`;
  - `chatstore.ParseArtifacts(text string, final bool) []ParsedArtifact`, where the last block of a key wins and kinds are restricted to `document|table|email|slack|event|code|html`.
- Produces (Kit): the same public Swift types as today: `ArtifactParser`, `MarkdownRunBuilder` and `ChatQuoteReply.compose`.
- The fixture is an array of `{name, text, final, expect:[{key, kind, title, content, meta}]}`.

- [ ] **Step 1: Write the fixture.** Build it from at least 12 cases mirroring the existing `ArtifactParserTests`, including: unknown kind ignored, unterminated fence while `final=false` → none, the same while `final=true` → per the Swift rule, two blocks with one key → last wins, `html` kind.
- [ ] **Step 2: Write `TestParseArtifacts_SharedCases` (Go) and `testSharedArtifactParseCases` (Kit), both over the fixture.** Run them; expected: Go FAIL (no package), Kit FAIL (file missing).
- [ ] **Step 3: Move the three Swift files and their tests into the Kit.** Fix the imports. Run `make kit-test FILTER='ArtifactParse|MarkdownRun|ChatQuoteReply'` and `make test-swift FILTER='Artifact|MarkdownRun|ChatQuote'`. Expected: PASS.
- [ ] **Step 4: Implement `ParseArtifacts` in Go**, following `ArtifactParser.swift` line by line.
- [ ] **Step 5: Run** `go test ./internal/chatstore` and `make kit-test FILTER=ArtifactParseFixture`. Expected: PASS. Run `make lint-swift` and `make lint-diff`.
- [ ] **Step 6: Commit** `refactor(kit): share chat parsers with the phone; Go artifact parser twin (#1791 T2)`.

---

### Task 3: Go turn store `internal/chatstore`

**Depends on:** T1, T2.

**Files:**
- Create: `internal/chatstore/store.go` (start, edit and regenerate, branch select, read), `turn.go` (`Turn` event application), `outcomes.go` (actions-outcome block), `prefix.go` (remember and knowledge prefixes), `title.go` (title hook seam)
- Create: `internal/chatstore/testdata/chat_turn_cases.json` (shared with a new Swift `ChatTurnStoreFixtureTests`)
- Create: `internal/db/chat_idea.go` (`CreateIdeaFromChat`) + `internal/db/testdata/chat_idea_rows.json` (shared with a Swift test of `IdeaQueries.createFromChat`)
- Move: the title generation out of `cmd/chat.go` (`chatTitlePrompt`, `cleanChatTitle`, `titleLine`, the generate step of `runChatTitle`) into `internal/chat/title.go` as `GenerateTitle(ctx, d *db.DB, cfg *config.Config, conv int64) (written bool, err error)`. `runChatTitle` calls it.
- Tests: `internal/chatstore/*_test.go`, `WatchtowerDesktop/Tests/Core/ChatTurnStoreFixtureTests.swift`

**Interfaces:**
- Consumes: the T1 lease functions and `chatstore.ParseArtifacts` (T2).
- Produces:

```go
type Store struct{ /* db, clock, owner, ownerID, title func(conv int64), now func() time.Time */ }
func New(d *db.DB, owner db.ChatLeaseOwner, ownerID string, opts ...Option) *Store
type StartRequest struct {
    ConversationID int64; Mode string /* send|regenerate|edit */; MessageID int64
    Text string; AttachmentIDs []int64; TurnID string
    Routing *Routing // nil = keep
}
type Started struct{ UserMessageID, AssistantMessageID int64; TurnID string; Replay bool; SendText string; Attachments []chat.TurnAttachment }
var ErrBusy, ErrConversationGone, ErrNotFound, ErrInvalid error
func (s *Store) Start(ctx context.Context, r StartRequest) (Started, error)   // one BEGIN IMMEDIATE tx: claim lease → rows (spec §4.1)
type Turn struct{ /* per running turn */ }
func (s *Store) Turn(st Started) *Turn
func (t *Turn) Apply(ev chat.Event) error  // session_ready/text_delta/tool_start/tool_end/tool_wait/usage; returns ErrConversationGone on 0-row update or FK failure
func (t *Turn) Flush() error                // 1 s cadence, driven by the caller's clock
func (t *Turn) Finalize(status string, failure *chat.Failure) error // one tx incl. artifacts + lease release
func (t *Turn) Text() string; func (t *Turn) Steps() []Step          // live view for the feed
func (s *Store) SelectBranch(ctx context.Context, messageID int64) error
func (s *Store) MarkRead(ctx context.Context, conv, messageID int64) error // MAX semantics
```

- `Start` sets `Replay` from `ChatContinuity` semantics. The caller passes `continuousLeafID` through `Option`. `SendText` = the outcomes block + the owner's text.
- After the commit (not on regenerate), `Start` runs the prefix commands: `instructions.ParseRemember` → `db.RememberChatLine`, and `ideas.ParseKnowledgePrefix` → `db.CreateIdeaFromChat`.
- `Finalize` calls the title hook when the conversation now has exactly one `complete` answer and `title_source='prefix'`.

- [ ] **Step 1: Write `chat_turn_cases.json`.** Each case is a starting tree, a `StartRequest`, an event list and an expected end state for the rows: `chat_messages` (role, status, text, parent, tokens, error), `chat_turn_steps`, `chat_artifacts` (version), `active_leaf_message_id`, `live_slack_since` and the lease. Cover at least:
  - a plain complete turn;
  - a tool step then text;
  - a turn error;
  - quota with text → `partial`;
  - interrupted;
  - regenerate (reuses the owner row);
  - edit (sibling);
  - an artifact re-persisted from the same message (overwrite) vs a new message (version +1);
  - a Slack step marking `live_slack_since`;
  - a `tool_wait` with no prior start.
- [ ] **Step 2: Write the Go tests.**
  - `TestChatstore_MatchesSwiftFixture` runs the cases.
  - `TestChat01Go_OwnerRowBeforeTurn`: after `Start` returns, the owner row exists and the assistant row is `partial` with `text=''`.
  - `TestChat02Go_StepPersistedOnStart`: after `Apply(tool_start)` the step is in the DB with no flush.
  - `TestChatstore_StopKeepsPartial`.
  - `TestChatstore_ProcessDeathFinalizesPartial`: `Finalize("partial", &Failure{Code:"session_lost"})` keeps the flushed text.
  - `TestChatstore_ConversationDeletedMidTurnStopsCleanly`: delete the conversation between `tool_start` and `Finalize`; `Apply` and `Finalize` return `ErrConversationGone`; zero rows remain for that id.
  - `TestChatstore_ArchiveMidTurnFinishes`.
  - `TestChatstore_BranchSelectMidTurn`: `SelectBranch` during a turn; `Finalize` updates by id, the leaf stays where it was put.
  - `TestStart_BusyWritesNothing`: another owner's live lease → `ErrBusy` and no new rows.
  - `TestMarkRead_NeverBackwards`.
  - `TestPrefix_RememberAndIdeaRun` and `TestPrefix_NotOnRegenerate`.
  - `TestCreateIdeaFromChat_SharedRows` over `chat_idea_rows.json`.
  - `TestGenerateTitle_NeverOverUser`.
  - Run them; expected: FAIL.
- [ ] **Step 3: Write the Swift twin.** `ChatTurnStoreFixtureTests` drives `ChatTreeQueries` + `ChatTurnDriver` over the same `chat_turn_cases.json` (copy it to `WatchtowerDesktop/Tests/Core/Fixtures/` via the existing fixture-sync pattern, or read it by relative path as other Go↔Swift fixtures do), and `IdeaQueries.createFromChat` over `chat_idea_rows.json`. Run `make test-swift FILTER='ChatTurnStoreFixture|ChatIdeaRows'`. Expected: PASS against the current Swift code; this pins the fixture to today's behaviour. Where the fixture and today's Swift differ, the Swift is the reference (the Mac's behaviour is what the phone must match) and the fixture is fixed. A difference that looks like a Swift bug is reported to the controller, which files it as its own target; it is not fixed inside this plan.
- [ ] **Step 4: Implement `chatstore`** until the Go tests pass. Port `AgentActionFeed.outcomesBlock(after:)` exactly; add a shared fixture `outcomes_block_cases.json` read by a Swift test too. Add the new chat readers to `liveCheckedReaders`/`displayOnlyReaders`.
- [ ] **Step 5: Run** `go test ./internal/chatstore ./internal/db ./internal/chat ./cmd -run 'Chat|Title|LIVE01'`, `make test-swift FILTER='ChatTurnStoreFixture|ChatIdea|Outcomes'` and `make lint-diff`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(chatstore): Go chat turn store, the Swift write path's twin (#1791 T3)`.

---

### Task 4: Hub chat runner `internal/hub/chatrun`

**Depends on:** T3.

**Files:**
- Create: `internal/hub/chatrun/runner.go` (pool, queue, spawn), `session.go` (one `ai session` child: stdin commands and stdout events via `chat.Event` decode), `cancel.go` (lease poll and heartbeat), `sweep.go`
- Modify: `internal/hub/runtime.go` / `wiring.go` to start the runner with the hub and close it on stop. Add a `Deps` seam on the handlers in T5.
- Test: `internal/hub/chatrun/*_test.go`, with a fake `ai session` behind a `start` seam (the in-process twin pattern of `internal/chat/fake_claude_test.go`) under `testing/synctest`

**Interfaces:**
- Consumes: `chatstore.Store`, `chatstore.Turn`, `db.ReleaseOwnedChatLeases`.
- Produces:

```go
type Config struct{ Exe, DBPath string; HubID string; Store *chatstore.Store; Start StartFunc; Clock func() time.Time; OnChange func(conv int64); OnTurnEnd func(conv int64, turnID, status string) }
func New(c Config) *Runner
func (r *Runner) Run(ctx context.Context, req chatstore.StartRequest) (chatstore.Started, error) // Start + enqueue; returns after the start tx
func (r *Runner) Cancel(conv int64, turnID string) (bool, error)                               // via db.RequestChatCancel
func (r *Runner) Live(conv int64) (text string, steps []chatstore.Step, waitingSlot bool, ok bool)
func (r *Runner) Close(ctx context.Context) error                                              // close→2 s→SIGTERM→3 s→SIGKILL, waits for last write
const MaxLive = 2; const IdleTTL = 10 * time.Minute
```

- Spawn argv: `<Exe> ai session --conversation N --surface main [--provider P --model M] [--project-id K] --db-path <DBPath>`. Its own process group is killed and waited for on close (CHAT-03).
- The startup sweep calls `ReleaseOwnedChatLeases(hub, HubID)` and marks those turns' `partial` assistant rows `error_code='session_lost'` before the first claim.
- Orphans after a `kill -9` of the daemon: each child's process-group id is written at spawn to `<hub dir>/chatrun/<conversation>.pgid` (0600) and removed after the child is reaped. The startup sweep reads every file left, checks that the group still runs `watchtower ai session` (the process command line, so a reused pgid is never killed), kills that group with SIGKILL, waits, and removes the file.

- [ ] **Step 1: Write the failing tests.**
  - `TestChat03Go_PoolBound`: 3 conversations with turns that block mid-answer → 2 children alive, the third waits with `waitingSlot=true` and starts when one ends.
  - `TestChatrun_IdleEvictedForNewTurn`.
  - `TestChatrun_RemoteCancelStopsTurn`: `RequestChatCancel` → `cancel` is written to the fake's stdin within 1 s of virtual time; with no `turn_done`, `partial` comes at 7 s, then the group is killed.
  - `TestChatrun_DaemonStopLeavesPartialAndSweepReleases`.
  - `TestChatrun_StartupSweepMarksSessionLost`.
  - `TestChatrun_SweepKillsOrphanGroup`: a real stub child whose parent runner is dropped without `Close` (simulated `kill -9`); a new runner's sweep kills its group and removes the pgid file; a pgid file naming a process that is not `ai session` is removed without a kill.
  - `TestChatrun_HeartbeatEvery15s`.
  - `TestChatrun_RoutingChangeRecycles`.
  - `TestChatrun_ConversationGoneClosesSession`.
  - `TestFILES01_Chatrun`: a canary text in the turn never appears in the logs.
  - Run `go test ./internal/hub/chatrun`. Expected: FAIL.
- [ ] **Step 2: Implement** `runner.go`, `session.go`, `cancel.go` and `sweep.go`, modelled on `ChatSessionPool`/`ChatSessionPolicy` and the group handling in `sessionhost/ensure.go`.
- [ ] **Step 3: Wire it into the hub runtime:**
  - start the runner after the database opens;
  - run the sweep before the handlers register;
  - call `Close` in the hub's stop path before the DB closes.
- [ ] **Step 4: Run** `go test ./internal/hub/chatrun ./internal/hub -run 'Chatrun|Runtime'` and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(hub): chat runner spawning ai session per conversation (#1791 T4)`.

---

### Task 5: Hub actions, the `chat` grant, the attachment upload, and the capability

**Depends on:** T4, T6 (`ChatWatches`).

**Files:**
- Create in `internal/hub/actions/handlers/`:
  - `chat_turn.go`: `chat_new`, `chat_turn`, `chat_cancel`;
  - `chat_feed_request.go`: `chat_feed_request`, `chat_page`, `chat_search`, with watch registries like `chat_request.go`;
  - `chat_manage.go`: `chat_read`, `chat_branch_select`, `chat_manage`;
  - `chat_action_answer.go`;
  - `chat_attachment.go`: the upload intake, modelled on `recording.go` `IntakeRecording`;
  - a test file for each.
- Create: `internal/chatstore/attachments.go`:
  - limits and validation, ported from `ChatAttachmentStore`, with `testdata/attachment_limit_cases.json` shared with Swift;
  - the owner `directoryName`;
  - `RemoveConversationFiles`.
- The `chat_allowed` column and `state.Device.ChatAllowed` come from T6. This task adds the rest of the grant: `link.Grant` and its column map (`internal/hub/link/center.go`), every grant read and copy in `internal/hub/link/grants.go`, `device_record.go` and `keybox.go`, the `device_grant` record (`internal/hub/wire/grant.go`: a `chat` key) and its Kit twin (`WatchtowerKit/Sources/WatchtowerSync/Link/DeviceGrant.swift`), `cmd/hub_link.go` (`hub allow|deny <device> chat`) and `internal/hub/control.go`.
- Modify:
  - `actions/dispatcher.go`: put `chat_new`, `chat_turn`, `chat_action_answer` and `chat_manage` in `NonIdempotentKinds`, and `chat_turn` in `ReceivedEchoKinds`;
  - `handlers/deps.go` `Register` and `nudge.go`;
  - `wire/payloads.go` `HeartbeatCapabilities`: add `Chat string \`json:"chat,omitempty"\``;
  - `slices/heartbeat.go`;
  - `cmd/hub*.go` `desktop heartbeat`: add the `--chat-lease` flag, stored with its time in `hub_meta`;
  - `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` (the heartbeat section).

**Interfaces:**
- Consumes: `chatrun.Runner` (T4), `chatstore.Store` (T3), `tools.Registry.ApproveSeen` and `Reject`.
- Produces:
  - wire params (JSON keys exactly as spec §4.5):
    - `chat_new{client_key, project_id?, routing?}` → `{conversation_id}`;
    - `chat_turn{conversation_id, mode, message_id?, text, attachment_ids, routing?}` → `{user_message_id, assistant_message_id, turn_id}`;
    - `chat_cancel{conversation_id, turn_id}`;
    - `chat_feed_request{conversation_id, purpose}`; `conversation_id = 0` means "republish `chat_list` now" (the Retry on mockup 1h): the handler clears the list source's last error and calls `PublishNow(chat_list)`;
    - `chat_page{conversation_id, before_message_id}`;
    - `chat_search{query}`;
    - `chat_read{conversation_id, message_id}`;
    - `chat_branch_select{message_id}`;
    - `chat_manage{conversation_id, op, title?}`;
    - `chat_action_answer{action_id, decision, args_sha256}`;
    - the upload descriptor `{upload_id, conversation_id, name, mime, size}` → `{attachment_id}`.
  - new refusal reasons in `deps.go`: `conversation_busy`, `attachment_missing`, `changed`.
  - uses `ChatWatches` from T6 (`Watch(conv int64, purpose string, until time.Time)`, `Open(conv int64, since time.Time) bool`, `Pages`, `Searches`), also consumed by T7.
  - `Deps.ChatAvailable() (on bool, reason string)`. The reasons are `not_relay`, `runner_down` and `desktop_too_old`. Desktop freshness ≤ 2 min.

- [ ] **Step 1: Write the failing tests.**
  - One test per handler for its success and each refusal:
    - `TestChatHandlers_RefuseWithoutChatGrant`;
    - `TestChatHandlers_RefuseWhenNotOnRelay`;
    - `TestChatTurn_BusyReturnsConversationBusy`;
    - `TestChatTurn_RepeatReplaysEcho`;
    - `TestChatTurn_CrashMidApplyIsOutcomeUnknown`;
    - `TestChatActionAnswer_NeedsPermissions`;
    - `TestChatActionAnswer_StaleHashRefused`;
    - `TestChatActionAnswer_DeadSessionRowIsFinal`;
    - `TestChatManage_DeleteRemovesAttachmentFolder`;
    - `TestChatManage_RenameSetsUserTitle`;
    - `TestChatAttachment_PartialUploadWritesNothing`;
    - `TestChatAttachment_LimitsSharedCases` over `attachment_limit_cases.json`;
    - `TestChatCapability_OffWhileOldDesktopRuns`;
    - `TestChatCapability_OnWithoutDesktop`;
    - `TestChatGrant_SurvivesRelink`: the owner turns Chat off, the phone links again → still off (every path that rewrites a device row carries `chat_allowed`).
    - `TestChatGrant_InDeviceGrantRecord`: the `device_grant` payload carries `chat`; the Kit `DeviceGrantTests` decode it from the same fixture.
    - `TestChatFeedRequest_ZeroRepublishesList`.
  - The heartbeat contract case `chat: "on"` and the Kit `HubContractFixtureTests`; the `device_grant` fixture case with `chat`.
  - Run `go test ./internal/hub/... ./internal/db ./internal/chatstore ./cmd -run 'Chat|HubContract'`. Expected: FAIL.
- [ ] **Step 2: Write the Swift twin tests.** `ChatAttachmentLimitFixtureTests` runs over the shared fixtures against today's Swift. Run `make test-swift FILTER='ChatAttachmentLimitFixture'`. Expected: PASS.
- [ ] **Step 3: Implement the handlers, the grant, the intake, the search port and the capability.** Heavy work goes in a goroutine after the fast ack (the `session_input` pattern). The `chat_turn` ack waits only for `Runner.Run` (the start tx).
- [ ] **Step 4: Run** the same commands and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(hub): chat actions, chat grant, attachment upload, relay-only capability (#1791 T5)`.

---

### Task 6: Slices `chat_list`, `chat_feed`, `chat_page`, `chat_search`, and the Kit mirrors

**Depends on:** T3. `ChatWatches` is defined in this task (`internal/hub/slices/sources/chat_watch.go`) and consumed by T5's handlers, so T6 runs beside T4 right after T3, as the spec's lanes say.

**Files:**
- Create in `internal/hub/slices/sources/`: `chat_list.go`, `chat_feed.go` (feed, page and search sources sharing one payload builder) and their tests.
- Modify:
  - `slices/kinds.go`: add the four kinds to `AllKinds`, put `chat_feed` in `UrgentKinds`, and set the publish order (after the ask kinds);
  - `secure/` `dataKinds`;
  - `sources/registry.go` `All`.
- Create: `WatchtowerKit/Tests/Fixtures/workbench/chat_list.json`, `chat_feed.json`, `chat_page.json`, `chat_search.json`.
- Create: `WatchtowerKit/Sources/WatchtowerKit/Models/ChatList.swift`, `ChatFeed.swift`, `ChatPage.swift`, `ChatSearch.swift` (`SliceMirror`). Modify `WatchtowerSync/Sync/SliceRecord.swift` `SliceKind`.

**Interfaces:**
- Consumes: `chatrun.Runner.Live` through a `LiveText` seam (T4 merges its implementation; until then a fake), and `chatstore` readers.
- Also creates the grant's storage, so the sources can gate on it: `internal/hub/state/migrations/00017_chat_grant.sql` (`chat_allowed INTEGER NOT NULL DEFAULT 1`, on by default, ask #1340), `state.Device.ChatAllowed bool` read in `state/devices.go`, and `Store.AnyChatPhone() (bool, error)` (a linked device with `chat_allowed = 1`). T5 adds the CLI, link, wire and relink paths on top. Test `TestChatGrant_DefaultOnForLinkedPhones` moves here.
- Also creates: `internal/db/chat_search.go`, `db.SearchChats(q string, limit int) ([]ChatSearchHit, error)`, a Go port of `ChatSearchQueries` (FTS `MATCH`, snippet, `bm25`, context-type and archived filters), with `internal/db/testdata/chat_search_cases.json` run by Go `TestChatSearch_SharedCases` and the Swift `ChatSearchQueriesFixtureTests` (which must pass against today's Swift first).
- Produces: the payload keys exactly as spec §4.6, pinned by the four fixtures:
  - `chat_list{conversations:[{id,title,pinned,updated_at,project?,state,last_line,lease_owner?}], projects:[{id,name}], models:[{provider,model,display_name,images,pdf}], error?}`;
  - `chat_feed{conversation:{id,title,project?,routing,actual_provider,actual_model,live_slack_since?,lease?:{owner,turn_id,waiting_slot}}, messages:[{id,role,text,text_cut,status,error_code?,error_message?,created_at,siblings:{index,count},attachments:[{id,name,mime,size}],steps:[{name,ok?,summary,sources:[…]}]}], has_more, artifacts:[{key,kind,title,version,content?,content_cut}], actions:[{id,tool,title,args_display,args_sha256,status,reason?}]}`;
  - `chat_page` = the `messages` and `has_more` shape;
  - `chat_search{query, hits:[{conversation_id,title,snippet,message_id,date}]}`.

- [ ] **Step 1: Write the fixtures and the failing tests.**
  - `TestChatList_PayloadMatchesKitFixture`.
  - `TestChatList_StatePrecedence` (waiting > answering > unread > read).
  - `TestChatFeed_PayloadMatchesKitFixture`.
  - `TestChatFeed_CapsDropOldestThenArtifacts`: a 2 MB conversation → ≤ 600 000 bytes, the oldest messages dropped and `has_more=true`, then the artifact `content_cut`.
  - `TestChatFeed_MessageTextCut40000`.
  - `TestChatFeed_HubTurnUsesLiveText`.
  - `TestChatFeed_DesktopTurnReadsDB`.
  - `TestChatFeed_UnlinkDropsWatches`.
  - `TestChatFeed_PrefetchRecordGoneAfter2Min`.
  - `TestChatPage_SixtyBeforeID`.
  - `TestChatSearch_RecordShape`.
  - `TestChatSources_OnlyWithChatGrant` (over `Store.AnyChatPhone`).
  - `TestChatGrant_DefaultOnForLinkedPhones`: the migration on a sidecar with an existing device → `chat_allowed=1`.
  - `TestChatSearch_SharedCases` (Go) and the Swift `ChatSearchQueriesFixtureTests`.
  - `TestLIVE01_ReaderList` stays green with the new readers listed.
  - Kit: `ChatSliceMirrorTests` decode all four fixtures.
  - Run `go test ./internal/hub/slices/... ./internal/hub/state ./internal/db -run 'Chat|LIVE01'`, `make kit-test FILTER=ChatSliceMirror` and `make test-swift FILTER=ChatSearchQueriesFixture` (this one must PASS against today's Swift before the Go port exists). Expected: the Go and Kit tests FAIL.
- [ ] **Step 2: Implement the sources and the Kit mirrors.** `chat_list` and every chat source publish only while at least one linked phone holds the `chat` grant (else `Items` returns none and the publisher deletes the records). The feed, page and search builders are display paths: add them to LIVE-01's `displayOnlyReaders` in `internal/db/live01_test.go`.
- [ ] **Step 3: Run** the same commands (including `make test-swift FILTER=ChatSearchQueriesFixture`), `make lint-diff` and `make lint-swift`. Expected: PASS.
- [ ] **Step 4: Commit** `feat(hub): chat slices, chat grant storage, Kit mirrors (#1791 T6)`.

---

### Task 7: `chat_answer` push for hub- and Mac-run turns

**Depends on:** T5, T6.

**Files:**
- Modify: `internal/hub/slices/sources/work_alert.go` (event `chat_answer` and candidates), `internal/hub/secure/record.go` (`WorkAlertFields.ConversationID int64 \`json:"conversation_id,omitempty"\``), `internal/hub/alerts_wiring.go`, `internal/hub/secure/testdata/go-sealed.json` (a new case), and `docs/features/go-hub.md`.
- Create: `internal/hub/chat_turn_watch.go`. It watches for Mac-run turn ends on `data_version`: a lease with `owner='desktop'` disappears and the row status is final. It also watches for new pending `agent_actions` of chat turns.

**Interfaces:**
- Consumes: `chatrun.Config.OnTurnEnd` (T4) and `ChatWatches.Open` (T5).
- Produces: alert key `chat:<turn_id>:<event>`, events `answer|stopped|approval`, the fixed bodies from Global Constraints, and the title clipped like the other alerts.

- [ ] **Step 1: Write the failing tests.**
  - `TestChatPush_HubTurnEndPushes`.
  - `TestChatPush_DesktopTurnEndPushesOnce`.
  - `TestChatPush_OpenWatchSuppresses`.
  - `TestChatPush_PrefetchDoesNotCountAsLooking`.
  - `TestChatPush_ApprovalWaitPushes`.
  - `TestChatPush_OwnerBackSkips`.
  - `TestAlertPushPayloadKeysMatchTheKit` (updated).
  - Run `go test ./internal/hub/...`. Expected: FAIL.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** `go test ./internal/hub/...` and `make lint-diff`. Expected: PASS.
- [ ] **Step 4: Commit** `feat(hub): chat_answer push (#1791 T7)`.

---

### Task 8: Desktop — the lease, a turn run elsewhere, Stop, the heartbeat flag, and the Chat toggle

**Depends on:** T1.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatLeaseQueries.swift`, with the same operations as the Go API and `chat_lease_cases.json` (T1) run by `ChatLeaseQueriesTests`.
- Modify:
  - `ChatViewModel.swift` `persistTurnStart`: claim inside the transaction; refused → `ChatBusyError` → the composer line;
  - `ChatTurnDriver.swift`: heartbeat 15 s; cancel poll 1 s through the existing Stop path; stop on a 0-row update or an FK failure, then `cancel`;
  - `ChatTurnStore.finalizeTurn`: release inside the transaction;
  - `ChatHistoryQueries.panelRows`: hub leases read as "answering";
  - the app launch: `ReleaseOwnedChatLeases(desktop, notThisLaunch)`.
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatForeignTurnModel.swift`. It is the pure model for the busy/foreign line and the reload cadence (1 s while a hub lease holds the open chat, once at release).
- Modify: the view that hosts the composer (show the line and Stop, Send off, draft kept).
- Modify: `MobileSettingsView.swift` (+ its model): the Chat toggle with the caption "Chat on this iPhone: ask, approve with Permissions", calling `hub allow|deny <device> chat --json`.
- Modify: the Desktop's `hub desktop heartbeat` caller: add `--chat-lease 1`.
- Create: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+IPhoneChat.swift`, with entries `chat-phone-turn` and `settings-mobile-phone-chat`.

**Interfaces:**
- Consumes: the T1 table and fixture.
- Produces: no new interfaces for other tasks.

- [ ] **Step 1: Write the failing tests.**
  - `ChatLeaseQueriesTests` over `chat_lease_cases.json`.
  - `ChatTurnLeaseTests.testConcurrentClaimOneWins`: two `DatabasePool`s on one file claim the same conversation from two tasks; exactly one owner row and one lease exist.
  - `testSendRefusedWhileHubHoldsLeaseKeepsDraft`.
  - `testDriverHonoursRemoteCancel`.
  - `testDriverStopsWhenConversationDeleted`.
  - `testFinalizeReleasesLease`.
  - `testLaunchReleasesOwnStaleLeases`.
  - `ChatForeignTurnModelTests` checks the exact copy "Answering from your iPhone — you can watch here" and the reload cadence.
  - `testPanelRowAnsweringForHubLease`.
  - `MobileSettingsChatToggleTests`.
  - `testHeartbeatCarriesChatLeaseFlag`.
  - Run `make test-swift FILTER='ChatLease|ChatForeignTurn|ChatViewModel|ChatTurnDriver|MobileSettingsChat'`. Expected: FAIL.
- [ ] **Step 2: Implement.** Keep the CHAT-01 order: the claim happens in the same write as the owner row.
- [ ] **Step 3: Run** the filtered tests, plus `testChat01*` and `testChat02*`, which must stay green, then `make lint-swift`. Run `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and compare 4a/4b with the mockups.
- [ ] **Step 4: Commit** `feat(desktop): chat turn lease, phone-run turns on the Mac, Chat toggle (#1791 T8)`.

---

### Task 9: Kit action params, the frozen kind lists, and the push event

**Depends on:** T5 (wire keys).

**Files:**
- Modify:
  - `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionRequestPayload.swift`: add the `ActionKind` cases `chat_new`, `chat_turn`, `chat_cancel`, `chat_feed_request`, `chat_page`, `chat_search`, `chat_read`, `chat_branch_select`, `chat_manage`, `chat_action_answer`;
  - `WatchtowerKit/Sources/WatchtowerKit/Models/WorkbenchActionParams.swift`: add the `Chat*Params`, or put them in a new `ChatActionParams.swift`;
  - `ActionReason.swift`: add `conversation_busy`, `attachment_missing` and `changed`;
  - `HeartbeatPayload.swift`: add `chat`;
  - the Kit `WorkAlertContent`/`AlertOpener`: add the `chat_answer` event and `conversation_id`;
  - the chat attachment upload frame, modelled on the recording upload in the Kit.
- Tests:
  - `RelayPayloadTests.testActionRequestWireFormatIsFrozen` (updated);
  - `WorkbenchMirrorFixtureTests` (the kind list);
  - a new `ChatActionParamsTests`, pinned against Go-written JSON fixtures `WatchtowerKit/Tests/Fixtures/chat/actions.json` that T5's Go tests also read.

**Interfaces:**
- Produces, for T10/T11:
  - `ChatTurnParams(conversationID:mode:messageID:text:attachmentIDs:routing:)` and the other params;
  - `ChatActionReason`;
  - `HeartbeatCapabilities.chat: String?`;
  - `WorkAlertContent.Event.chatAnswer` with `conversationID`.

- [ ] **Step 1: Write the fixture and the failing Kit tests.** Run `make kit-test FILTER='ChatActionParams|RelayPayload|WorkbenchMirrorFixture|HubContractFixture|WorkAlert'`. Expected: FAIL.
- [ ] **Step 2: Implement.** In T5, add a Go test `TestChatActionsFixture` that reads the same `chat/actions.json`. If T5 has already merged, add that test here.
- [ ] **Step 3: Run** the Kit tests, `go test ./internal/hub/actions/handlers -run ChatActionsFixture` and `make lint-swift`. Expected: PASS.
- [ ] **Step 4: Commit** `feat(kit): chat action params, push event, frozen lists (#1791 T9)`.

---

### Task 10: Phone — the Chats tab, gate, list, search and row actions

**Depends on:** T6, T9.

**Files:**
- Modify:
  - `WatchtowerMobile/Sources/App/RootTabView.swift`: a new `.chats` tab between Workbench and Calendar;
  - `AppNavigation.swift`: add `chatsPath` and `show(conversation:)`;
  - `AppEnvironment.swift` / `HubSession.swift`: expose a per-hub `ChatsCenter`.
- Create in `WatchtowerMobile/Sources/Features/Chats/`:
  - `ChatsGateModel.swift`: the states in spec §6.1 order with their exact copy;
  - `ChatListModel.swift`: sections, dot precedence, "▸ N older" and title filtering;
  - `ChatSearchModel.swift`: 300 ms debounce, `chat_search` and the 30 s timeout;
  - `ChatRowActions.swift`: Pin/Unpin, Rename, and Delete with a 5 s Undo that sends `chat_manage delete` at the end;
  - `ChatListView.swift`, `ChatsGateView.swift`.
- Create: `WatchtowerMobile/Sources/App/DemoSeed+Chat.swift`, and `ScreenshotTourTests` shots for 1a–1j (`SHOTS_ONLY=chat`).
- Modify: `WatchtowerMobile/Tests/OrangeToneTests.swift`: orange appears only for `waiting`.

**Interfaces:**
- Consumes: the T6 mirrors and the T9 params.
- Produces, for T11: `ChatsCenter` (outbox sender, list snapshot, gate) and `ChatRoute(id:)`.

- [ ] **Step 1: Write the failing tests:**
  - `ChatsGateModelTests` covers every state and its exact copy, including `desktop_too_old` → "Update Watchtower on your Mac", route iCloud → "Chat works over Relay" with the **Switch to Relay…** action (opens Settings → Macs → this Mac through `AppNavigation`), and the not-allowed state on a server hub carrying the refusal's `watchtower hub allow <phone> chat` line instead of the Settings line;
  - `ChatListRetryTests`: Retry on 1h sends `chat_feed_request` with `conversation_id 0`;
  - `ChatListModelTests`;
  - `ChatSearchModelTests` covers debounce, offline → "Searching messages needs your Mac", and timeout → "The Mac did not answer";
  - `ChatRowActionsTests` covers that Undo sends nothing;
  - `OrangeToneTests`.

  Run `make mobile-test MOBILE_FILTER='ChatsGate|ChatList|ChatSearch|ChatRowActions|OrangeTone'`. Expected: FAIL.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** the tests, `make lint-all` (the phone tree) and `SHOTS_ONLY=chat make mobile-shots`. Compare 1a–1j with the mockups and fix any difference.
- [ ] **Step 4: Commit** `feat(mobile): Chats tab, gate, list, search, row actions (#1791 T10)`.

---

### Task 11: Phone — conversation, composer, attachments, approvals, artifacts, and the offline copy

**Depends on:** T10. T7 is needed for the push router step.

**Files:**
- Create in `WatchtowerMobile/Sources/Features/Chats/`:
  - `ChatConversationModel.swift`: diffing the feed by id, siblings, steps, sources, the 30 s open timeout, paging with "Load earlier messages", and hiding partial artifact fences through the Kit `ArtifactParser`;
  - `ChatConversationView.swift`, `ChatMarkdownView.swift` (renders the Kit `MarkdownRunBuilder` runs in SwiftUI, with sideways-scrolling tables);
  - `ChatComposerModel.swift`: draft per conversation, model and project chips locked after the first message, quote batch via the Kit `ChatQuoteReply.compose`, Send/Stop, and offline off;
  - `ChatSendCoordinator.swift`: `chat_new` → uploads → `chat_turn`; a refused echo puts the text back;
  - `ChatAttachmentPicker.swift`: `PhotosPicker`, camera, `fileImporter`, HEIC → JPEG, downsizing over 5 MB, and the shared limits;
  - `ChatApprovalCard.swift`: Approve/Reject with `args_sha256`, "Approve on the Mac" without `permissions`, and "The action changed — look again";
  - `ChatArtifactSheet.swift` and `SandboxedArtifactWebView.swift` (non-persistent store, content rule blocking every non-local load, no message handlers, navigation pinned);
  - `ChatSourcesSheet.swift`;
  - `ChatOfflineCopy.swift`: its own GRDB file per hub, a 200 MB budget, eviction by last opened, deletion with the link, and the prefetch of the 20 most recent chats (foreground, once per chat per hour, `purpose: prefetch`).
- Modify: `WatchtowerMobile/Sources/App/NotificationRouter.swift`: `chat_answer` opens `ChatRoute`.
- Modify: `WatchtowerMobile/Info.plist`: add `NSPhotoLibraryUsageDescription` and reword `NSCameraUsageDescription` to cover the QR code and chat photos.
- Create: `DemoSeed+Chat` feeds and screenshot shots 2a–2i and 3a–3c.

**Interfaces:**
- Consumes: T10's `ChatsCenter`, `ChatRoute` and the T9 params; T2's Kit parsers.
- Produces: none.

- [ ] **Step 1: Write the failing tests:**
  - `ChatConversationModelTests`, including: the 2f line "Answering on your Mac — you can watch here." while `lease.owner == desktop`, with Stop sending `chat_cancel`; `chat_read` sent with the newest complete answer's id when the screen shows it (open, or a turn finishing while it is on screen), never for an older id;
  - `ChatFeedReconnectTests`: a feed record replaced after a relay reconnect (gap in versions, text shorter or longer) renders the latest record whole, with no duplicated or lost messages;
  - `ChatTurnActionsTests`: Retry on a retryable error card sends `chat_turn mode regenerate`; Regenerate on the last answer the same; Edit from the owner bubble's long-press sends `mode edit` with that message id; ‹ i/n › sends `chat_branch_select`; a non-retryable error shows no Retry;
  - `ChatArtifactActionsTests`: email → a `mailto:` URL with to/subject/body encoded; event → the Google Calendar template URL (the Mac's builder moved to the Kit, or a twin with a shared fixture); slack → copies the body and opens the Slack app's URL; Copy and Share for every kind;
  - `ChatSendTests`, the phone half of CHAT-01: the text comes back on `conversation_busy`, and the owner bubble stays pending until `applied`;
  - `ChatApprovalWiringTests`;
  - `ChatPagingModelTests`;
  - `ChatComposerModelTests`;
  - `ChatAttachmentPickerTests` (limits, HEIC conversion);
  - `ChatOfflineCopyTests` (budget eviction, link deletion, prefetch cadence, the list surviving a relaunch);
  - `NotificationRouterChatTests`;
  - `PhoneArtifactChat05ScanTests`, a source scan of `ChatArtifactSheet.swift` and `SandboxedArtifactWebView.swift`: no `URLSession`, no outbox enqueue, no `send(`.

  Run `make mobile-test MOBILE_FILTER='ChatConversation|ChatSend|ChatApproval|ChatPaging|ChatComposer|ChatAttachmentPicker|ChatOfflineCopy|NotificationRouterChat|PhoneArtifactChat05'`. Expected: FAIL.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** the tests, `make lint-all` and `SHOTS_ONLY=chat make mobile-shots`. Compare 2a–2i and 3a–3c with the mockups and fix any difference.
- [ ] **Step 4: Commit** `feat(mobile): chat conversation, composer, approvals, artifacts, offline copy (#1791 T11)`.

---

### Task 12: Docs, contracts, and the guide

**Depends on:** T1–T11.

**Files:**
- Create: `docs/features/iphone-chat.md`, with a line in `CLAUDE.md`'s feature list and a summary in `docs/features/README.md`.
- Modify:
  - `docs/inventory/chat.md`, following ask #1340:
    - CHAT-01/02/03/05 and the LIVE-01 Mechanism are amended;
    - a changelog line is added;
    - every new guard is named and verified by `grep`;
  - the hub grants and protocol in `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md`: §7.2 gets the kind rows, §9 the explicit-`on` rule;
  - `docs/features/go-hub.md`, `mobile-companion.md`, `relay-client.md` and `chat-redesign.md`, whose writers line becomes "the lease holder's store, Swift or Go";
  - the guide under `docs/guide/` (iPhone → Chat; Settings → Mobile → Chat), following `docs/guide/WRITING.md`, plus a Learn card if the section is new.

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Run** `go test ./docs/guide ./internal/learn` (the 8 KB cap and the cards) and `go test ./internal/db -run LIVE01`. Expected: PASS.
- [ ] **Step 3: Commit** `docs: iPhone chat feature note, contracts, guide (#1791 T12)`.

---

## Lanes

- **Lane A:** T1 → T3 → T4 → T5 → T7 (T5 also waits for T6).
- **Lane B:** T2, which joins A at T3.
- **Lane C:** T8, after T1.
- **Lane D:** T6, after T3, beside T4; T5 starts once T4 and T6 are merged.
- **Lane E:** T9, after T5, then T10 → T11.
- **Last:** T12.

T1 and T2 start in parallel; T8 starts as soon as T1 merges. The controller runs the full gate (`make test`, `make test-swift`, `make lint-all`, and `make mobile-test` from T9 on) at each phase end: after the hub phase (T5, T6, T7 merged), after T8, after the phone phase (T9, T10, T11 merged), and before the umbrella PR. Every task still runs its own inner loop; no task merges with a red inner loop.
