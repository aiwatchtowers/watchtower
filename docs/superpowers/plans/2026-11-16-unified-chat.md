# Unified chat — one Go engine, one protocol, one chat UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac and the iPhone run the main AI chat on one Go engine inside the daemon, talk to it over one protocol (`chat.sock` on the Mac, the relay on the phone) and draw it with one SwiftUI package.

**Architecture:**
- `internal/chatengine` absorbs `internal/hub/chatrun` and the hub's feed/list/search builders and wraps `internal/chatstore`. It is the only writer of the main chat's rows. It has one pool of 3 sessions, an in-memory turn lock per conversation, the live state of every turn, and subscriptions coalesced to 150 ms (feed) and 500 ms (list).
- The daemon starts the engine before the hub and serves `<workspace>/chat.sock`, which accepts only the signed app. The hub's chat handlers and sources become adapters over the same in-process engine.
- `ai session --listen` moves a turn's process off the daemon's pipes, so a daemon restart detaches from the turn and reattaches to it.
- The new local package `WatchtowerChat/` has two targets: `ChatWire` (Foundation: models, operations, `ChatClient`, stores) and `ChatUI` (SwiftUI: one view per part kind, fallbacks, models, `Platform/macOS` + `Platform/iOS`). The Mac (`SocketChatClient`) and the phone (`RelayChatClient`) keep only their shells.

**Tech Stack:**
- Go 1.26: `testing/synctest`, goose (one migration, 00194 `chat_client_key`, in T1), the `internal/sqlcipher` driver.
- SwiftUI on macOS 14 / iOS 17 in the Swift 5.10 language mode, SwiftPM local packages, xcodegen for the phone.

**Spec:** `docs/superpowers/specs/2026-11-16-unified-chat-design.md` (approved, ask #1378; decisions in asks #1363 and #1371). Builds on `docs/features/iphone-chat.md` and `docs/inventory/chat.md`.

**Branching and execution:**
- The umbrella branch is `feature/unified-chat`. Each task is one implementer agent working in its own worktree on `feature/unified-chat-tN-<slug>`, branched from the umbrella. Its PR goes **into `feature/unified-chat`**, never into `main`. The umbrella PR into `main` stays a draft until T11 is merged.
- `Depends on` lists the task PRs that must be merged into the umbrella before a lane is branched. Tasks with no dependency between them run in parallel lanes.
- Lane setup for Swift work: copy the main worktree's `WatchtowerDesktop/.build`, then delete its path-bound `ModuleCache`. Phone lanes use their own `-derivedDataPath` per worktree.

**Verification model:**
- **Per task (inner loop only):**
  - `go test ./internal/<pkg>` (`-run` to narrow);
  - `make test-swift FILTER=…`, `make kit-test FILTER=…`, `make chattext-test` and the new `make chat-test FILTER=…`;
  - `make mobile-test MOBILE_FILTER=…`;
  - `make lint-diff` for Go;
  - `make lint-swift` for every task that touches Swift (lint-diff checks only Go).
  - Every task names the guard suites it can break and runs them.
- **Per phase (controller only):** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, and `make mobile-test` when the phone changed. These run once per phase and once before the umbrella PR, never per task.
- **Phases:**
  - A (Go): T1, T2, T3, T4, T5, T10a.
  - B (packages): T6, T7.
  - C (apps): T8, T9, T10b, T12.
  - D (docs): T11.
  - T0 runs first, beside T1.
- **Controller step after T0:** run `make desktop-shots DESKTOP_SHOTS=build/unified-chat-before` and `make mobile-shots SHOTS_ONLY=chat SHOTS_DIR=build/unified-chat-before-phone`. Keep both sets locally as the comparison baseline; they are gitignored. File the owner a **review** ask with the new-state PNGs (§10). **T7 is not dispatched until the owner answers.**
- Every brief carries the review checklist: `docs/review/review-rules.md`, §§ 7–9 and "Swift / Desktop conventions". The implementer self-reviews against it before hand-back.

## Global Constraints

- **The engine is the only writer** of the main chat's `chat_*` rows. No Swift writer is kept as a fallback, and there is no second feed builder (anti-goal).
- **Coalescing:** a feed `message_upsert` comes at most every **150 ms** while a turn runs; a `list_update` at most every **500 ms**.
- **Pool:** at most **3** live `ai session` processes for the Mac and the phone together, **10-minute** idle TTL, and a running turn is never cut.
- **`chat.sock`:**
  - path `<workspace>/chat.sock`, mode 0600, folder 0700;
  - one listener under `chat.sock.lock`;
  - newline-delimited JSON with request lines **≤ 2 MiB**;
  - a bounded queue of **256** events per connection; past it, one `resync` and a fresh snapshot.
- **Session listen sockets:**
  - `<workspace>/chatengine/sessions/<conversation>.sock`, 0600 in a 0700 folder;
  - the turn buffer caps text at **600 KB**; past the cap it keeps the latest text snapshot plus every step event;
  - a session with no attached engine exits **10 min** after its turn ends.
- **Shutdown:** `cancel` each running turn, finalise `partial`, `close` each session, then **2 s** grace, then SIGTERM, then SIGKILL after **3 s**.
- **Client reconnect:** backoff of **100 ms** doubling to **2 s**. "Unavailable" shows after **10 s** without a connection.
- **Paging:** `chat_page` returns **60** messages.
- **Marker:** `<workspace>/daemon.stopped`, 0600, one JSON line `{"at": <RFC 3339>, "by": "cli"}`.
  - `watchtower sync stop` writes it after the daemon has stopped; `--internal` writes none.
  - Every daemon start removes it first.
- **UI copy** (set in models or the Go part builder, and tested):
  - "Chat is starting…";
  - "Chat is unavailable — Watchtower's background service is not running" + **Retry**;
  - "Chat needs Watchtower's background service, which is stopped" + **Start**;
  - fallback example "Send a Slack message to #general — waiting for your approval" + **Open on the Mac**.
- **Part kinds (v1, exactly):** `text`, `steps`, `sources`, `artifact`, `approval`, `question`, `error`, `remember_mark`, `knowledge_mark`, `published_link`, `attachment`, `routing_note`.
  - `artifact` and `question` are derived on the client by `WatchtowerChatText` only (D14).
- **Fallbacks:** a fallback's actions are only `chat_turn` (a fixed text), `open_url` (CHAT-05 open/copy rules) or `none`.
- **One release of compatibility:**
  - the engine keeps claiming and releasing `chat_turn_leases`;
  - the feed keeps its flat fields beside `parts`;
  - `ChatWire` builds parts from flat fields when `parts` is absent (D22).
- **Platforms:** macOS 14 / iOS 17 and the Swift 5.10 language mode. `ChatUI` imports only SwiftUI/AppKit/UIKit/WebKit, `ChatWire`, `WatchtowerChatText` and `WatchtowerDesign` (D18).
- **Tests never wait on wall-clock time:** Go uses `synctest` or an injected clock; Swift uses injected clocks or fakes; no sleeps and no raised timeouts. A test that spawns a process (a fake `ai session` via re-exec of the test binary) kills and waits for its whole process group in `t.Cleanup`.
- **Public repo hygiene:** fixtures use `acme`, `example.com` and `<owner-slack-id>`; no real ids, emails or local paths.
- **Language:** all repo text is in English.

## Review Focus

1. **Long workspace paths.** `<workspace>/chatengine/sessions/<conv>.sock` or `<workspace>/chat.sock` can exceed darwin's 103-byte `sun_path`. Expected: the engine and every client (Go CLI, Swift app) compute the same shorter path, and chat still works. Owned by T4 (`TestSocketPath_TooLongFallsBackToTempDir` + the Swift twin over `socket_paths.json`).
2. **An echo lost to a dropped socket.** A send whose echo is lost when the socket drops must come back neither as a lost text nor as a duplicate turn. Expected: the client resends with the same `client_key`, and the engine answers the first result again, also across a daemon restart (the key is stored on the owner row). Owned by T1 (`TestChatengine_RepeatedClientKeyAppliesOnce`, `TestChatengine_ClientKeySurvivesRestart`) and T7 (`testDroppedEchoResendsWithSameKeyNoDuplicate`).
3. **A conversation deleted on the other device** while it is open here, with a typed draft. Expected: a "gone" state, the draft kept, Send off, and no crash on a late `message_upsert`. Owned by T7 (`testConversationDeletedElsewhereShowsGoneAndKeepsDraft`).
4. **Replay past the 600 KB buffer cap** after a daemon restart. Expected: the final stored text equals the whole answer and every step is present once. Owned by T10a (`TestTurnBuffer_PastCapReplaysLatestTextAndEveryStep`, `TestChatengine_ReplayPastCapStoresWholeText`).
5. **A half-open socket after Mac sleep/wake.** Expected: the next send or subscription write fails fast, and the client reconnects and resubscribes; no conversation stays "answering". Owned by T8 (`testWriteFailureTriggersReconnectAndResubscribe`).

## Spec gaps and code facts decided here

- **The package cycle.** `ChatUI` needs the Kit's `WatchtowerDesign`, so the `WatchtowerChat` package depends on the `WatchtowerKit` package. If the Kit also depended on `ChatWire` (§6.1), the two packages would form a cycle, which tools-version 5.10 rejects. **Decision (owner sign-off requested in the plan review ask):** the Kit does **not** depend on `ChatWire`.
  - The chat models move out of the Kit; no Kit source uses them.
  - The Kit-only conformances (`SliceMirror.sliceKind`, `ActionParams.actionKind`) move to the phone app as `@retroactive` extensions.
  - `WatchtowerCore` may import `ChatWire`.
- **The design kit.** `DesignKit` lives in the Desktop package, which `ChatUI` cannot import. **Decision:** `ChatUI` draws controls through an injected `ChatUIStyle` (environment, §13 "protocol witnesses"). The Mac app supplies `DesignKitChatStyle`; the phone supplies its DesignSystem style. Tokens still come from `WatchtowerDesign`.
- **The question parser.** D14 needs it in `WatchtowerChatText` before `ChatUI` (T7) can render question parts, but §11 placed it in T12. **Decision:** it moves in **T3**. T12 only repoints the remaining callers. Go has no question parser today (`internal/chat/questions_contract.go` is prompt text); T3 adds the Go twin (fallback text only).
- **Wire time.** `wire.Time` lives in `internal/hub/wire`, and `chatengine` must not import the hub. **Decision:** it moves to a neutral `internal/wiretime`; `wire.Time` becomes an alias.
- **Routing written by `ai session`.** `ai session` writes the routing columns of `chat_conversations` itself (`SetChatRouting`/`SetChatActual`, `cmd/ai_session_routing.go`); they stay its columns (writers list in `unified-chat.md` and the inventory). Since T5 drops the hub's `chat_*` table watch, the engine publishes routing from the session's own events (`session_ready`, the actual-model event), not from the database (T1, `routing_note` in T3).
- **The steps table** is named `chat_turn_steps` (the spec says `chat_steps`). The engine also writes `chat_knowledge_artifacts` and `chat_project_sources` (Add to Knowledge, project sources). `chat_queued_drafts` is embedded-only and stays a Desktop writer.
- **The CLI on `chat.sock`.** `watchtower sync stop` must end chat (§7), but D17 refuses CLI peers. **Decision (owner sign-off requested in the plan review ask):** a peer verified as the same-team watchtower CLI may send exactly `hello` and `chat_shutdown`; every other op is `forbidden`. This lets nothing write rows. When the socket is unreachable, the CLI falls back to the session sockets directly.
- **There is no `ChatSender`** on the phone; the send path is `ChatSendCoordinator`. `RelayChatClient` wraps it.
- **The phone's `@` and `/` pickers (§6.4)** need relay support. **Decision:** two idempotent hub action kinds, `chat_entity_search` and `chat_skills_list`, return their hits in the `applied` echo result (T5).
- **Hub-to-engine ownership.** The hub needs the daemon's engine (`hub.Options.ChatEngine`, added in T4), so T5 depends on T4 as well as T1 and T3. T10 is split:
  - **T10a (Go)** depends on T1 and T4.
  - **T10b (Swift)** depends on T8 and T10a.
- **Shots that do not exist yet.** There are no `owner-ask-*` shots, and no embedded-surface shots for the target, meeting or setup chats. T0 adds "before" shots of the current real views so T12 has a baseline.
- **The legacy lease (one release).** The engine claims as `db.ChatLeaseHub` with the fixed owner id `chatengine`. It keeps the 15 s heartbeat and the cancel poll, so an older app's lease check holds.

## File map

| Area | Create | Modify / delete |
|---|---|---|
| Engine | `internal/chatengine/{engine.go,pool.go,session.go,lease.go,sweep.go,live.go,subscribe.go,feed.go,list.go,search.go,ops.go,compose.go,entities.go,projects.go,artifacts.go,attach.go,parts.go,server.go,conn.go,handles.go,paths.go,reattach.go,shutdown.go}` + `testdata/{parts.json,compose_cases.json,entity_search_cases.json,socket_paths.json}` | `git mv internal/hub/chatrun/* → internal/chatengine/` (T1); `internal/hub/slices/sources/chat_feed.go`, `chat_list.go` builders move (T1) |
| Neutral | `internal/wiretime/time.go`, `internal/platform/{peer_*.go,listen.go}` | `internal/hub/wire/wire.go` (alias), `internal/hub/platform/peer_*.go` (moved), `internal/ownerconfirm/{peer_*.go,signature.go}` |
| chat | `internal/chat/{questions.go,listen.go,turnbuffer.go}`, `internal/chat/testdata/question_parse_cases.json` | `internal/chat/session.go` (`attach`), `cmd/ai_session.go` (`--listen`) |
| Daemon / CLI | `internal/daemon/stopped.go` | `cmd/sync.go` (`startChatEngine`, `--internal`, marker), `cmd/chat.go` (`chat shutdown`) |
| Hub | — | `internal/hub/{wiring.go,chat_wiring.go,chat_turn_watch.go,control.go,hub.go,state/recordings.go}`, `actions/handlers/chat*.go`, `slices/sources/{chat_*.go,registry.go}`, `WatchtowerKit/Tests/Fixtures/{chat/actions.json,link/hub_contract_cases.json}` |
| Swift packages | `WatchtowerChat/{Package.swift,.swiftlint.yml,Sources/ChatWire/**,Sources/ChatUI/**,Tests/**}`, `WatchtowerChatText/Sources/WatchtowerChatText/ChatQuestionParser.swift` | `WatchtowerKit/Sources/WatchtowerKit/Models/Chat{ActionParams,Feed,List,Page,Search}.swift` (moved out), `Makefile`, `scripts/kit-lint-guard.sh`, `scripts/tests/test-kit-lint-guard.sh`, `.github/workflows/ci.yml` |
| Mac | `WatchtowerCore/Services/Chat/{SocketChatClient.swift,ChatSocketPaths.swift,EmbeddedChatFeedAdapter.swift,WorkchatFeedAdapter.swift}`, `Sources/Views/Chat/DesignKitChatStyle.swift` | `ChatViewModel.swift` (split), `Views/Chat/**` (most deleted in T8/T12), `App/{QuitCoordinator,AppState,AppState+DaemonStart,AppState+Chat,TrayAppDelegate}.swift`, `WatchtowerCore/Services/{DaemonManager,DatabaseCompactionStep,HubControlClient}.swift`, `Package.swift` |
| Phone | `Features/Chats/{RelayChatClient.swift,ChatWireKitConformances.swift,PhoneChatStyle.swift}` | `Features/Chats/*` (views and models deleted), `project.yml` + regenerated `.xcodeproj` |
| Shots | `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+UnifiedChat.swift` | `DesignShotCatalog.swift`, `DesignShotFixtures+IPhoneChat.swift`, `WatchtowerMobile/Tests/ScreenshotTourTests.swift` |
| Docs | `docs/features/unified-chat.md` | `docs/inventory/chat.md`, `docs/features/{README.md,chat-redesign.md,iphone-chat.md}`, `CLAUDE.md`, `docs/guide/features/{ai-chat.md,iphone-chat.md}` |

## Guard map (what each task must run besides its own tests)

- **CHAT-01..05, LIVE-01** (`docs/inventory/chat.md`):
  - `go test ./internal/chatstore ./internal/chatengine ./internal/db -run 'Chat|LIVE01|Lease'`;
  - Swift `make test-swift FILTER='Chat0|ChatTurn|ChatLease|ArtifactChat05|LIVE01'` while the Swift twins exist.
- **FILES-01:** `go test ./internal/chatengine -run TestFILES01` and `go test ./internal/logcanary`.
- **Hub contracts:**
  - `go test ./internal/hub/... -run 'Chat|Contract|Fixture'`;
  - `make kit-test FILTER='HubContract|ChatSliceMirror|ChatActionParams'` (after T6: `make chat-test FILTER='ChatSliceMirror|ChatActionParams'`).
- **cmd:** `go test ./cmd/... -run 'Sync|AISession|Chat'` (CI runs `-race` on cmd only with `-run`).
- **Golden prompts:** `go test ./internal/chat -run 'Golden|Prompt'` for any change in `internal/chat`.
- **Kit / Core surfaces:** `make test-swift FILTER=PublicAPISurfaceTests` and `make kit-test FILTER=SeamBoundaryTests` for any package-graph change.
- **Schema:** one migration, `00194_chat_client_key.sql` (T1). T1 runs `go test ./internal/db -run 'TestSchemaGolden|TestDesktopTestSchema'` (regenerated with `-update`) and `go test ./internal/db`; any later task touching `internal/db` runs them too.

---

### Task T0: Design shots for the new states (§10)

**Depends on:** none

**Files:**
- Create: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+UnifiedChat.swift`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`, `WatchtowerMobile/Tests/ScreenshotTourTests.swift`

**Interfaces:**
- Produces: the shot names below. T8, T9 and T12 switch each one from its mock to the real view under the **same name**.
  - Mac mocks: `chat-daemon-starting`, `chat-daemon-unavailable`, `chat-daemon-stopped`, `chat-part-fallback`, `chat-remote-turn-live`.
  - Mac baselines from today's views: `embedded-chat-target`, `embedded-chat-meeting`, `embedded-chat-setup`, `owner-ask-question-card`; the existing `chat-phone-turn` entry is kept unchanged as the "before" of `chat-remote-turn-live`.
  - Phone frames in `testTheChatShots`: `iphone-chat-question-card`, `iphone-chat-approval-slack`, `chat-part-fallback`.

- [ ] **Step 1: Mac mock shots.** `UnifiedChatShotFixtures.shots: [DesignShot]` renders static mock views built from DesignKit and today's chat views. Each one uses the §10 sketch and the exact Global Constraints copy:
  - a feed with a kept draft and Send off, one state line each for starting / unavailable+Retry / stopped+Start;
  - a fallback card with the exact example text and **Open on the Mac**;
  - a phone-started answer streaming, with **Stop**.
- [ ] **Step 2: Baseline shots** of the current real views: a target chat, a meeting Discuss chat, a setup assistant (`EmbeddedChatView` with fixture rows), and `OwnerAskDrawer` showing a question card.
- [ ] **Step 3: Phone mock frames** in `ScreenshotTourTests.testTheChatShots`: a question card, a Slack approval card, and a fallback card (static SwiftUI in the test file).
- [ ] **Step 4: Render and look.**
  - Run `make desktop-shots DESKTOP_SHOTS=build/t0` and `make mobile-shots SHOTS_ONLY=chat`. Expected: every new name exists in light and dark.
  - Run `make lint-swift`.
- [ ] **Step 5: Commit.** `test(shots): unified chat states and baselines (#1822 T0)`

---

### Task T1: `internal/chatengine` core

**Depends on:** none

**Files:**
- Move: `internal/hub/chatrun/{runner.go,session.go,cancel.go,sweep.go}` → `internal/chatengine/{pool.go,session.go,lease.go,sweep.go}`, together with their tests (`runner_test.go`, `sweep_test.go`, `fake_test.go`, `files01_test.go`, `testmain_test.go`).
- Move: the builders in `internal/hub/slices/sources/chat_feed.go` (`chatFeedConversationTx`, `chatBranchTx`, `chatFeedMessagesTx`, `chatFeedMessageRowsTx`, `chatFeedAttachmentsTx`, `chatFeedStepsTx`, `applyLiveText`, `chatFeedArtifactsTx`, `chatFeedActionsTx`, `buildChatPage`, `search`) and `chat_list.go` (`chatListRows`, `chatListProjects`, `chatRowState`, `chatPreview`) → `internal/chatengine/{feed.go,list.go,search.go}`. The hub keeps only record fitting (`fitFeed`, `encodeChatFeed`, `encodeChatPage`, `shrinkLargestText`, `clearSteps`) and its caches.
- Create: `internal/chatengine/{engine.go,live.go,subscribe.go,ops.go}`, `internal/wiretime/time.go`
- Modify:
  - `internal/hub/wire/wire.go` (`type Time = wiretime.Time`);
  - `internal/hub/wiring.go` (`newChatRunner` builds a `*chatengine.Engine` until T4);
  - `internal/hub/actions/handlers/chat.go` (`ChatRunner` → `Turn`);
  - `internal/hub/slices/sources/chat_{feed,list}.go` (call the engine builders);
  - the LIVE-01 keys in `internal/db/live01_test.go` (`displayOnlyReadersAt`) to the new `chatengine/...:<func>` names;
  - `docs/inventory/chat.md` (CHAT-01 and CHAT-03 amendments).
- Create: `internal/db/migrations/00194_chat_client_key.sql`: `ALTER TABLE chat_messages ADD COLUMN client_key TEXT` (nullable) + `CREATE UNIQUE INDEX idx_chat_messages_client_key ON chat_messages(conversation_id, client_key) WHERE client_key IS NOT NULL`; Down drops the index and the column. Mirror it into `internal/db/schema.sql` and regenerate `internal/db/testdata` goldens and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db -run 'TestSchemaGolden|TestDesktopTestSchema' -update`). Modify `internal/chatstore/store.go` (`StartRequest.ClientKey`, written on the owner row inside the start transaction; `newMessage.ClientKey`).

**Interfaces:**
- Consumes: `chatstore.Store`/`StartRequest`/`Started`/`Routing`/`Step`, `chat.Event`, `db.ChatLeaseHub`.
- Produces (package `chatengine`):
  ```go
  const MaxLive = 3
  const IdleTTL = 10 * time.Minute
  const FeedCoalesce = 150 * time.Millisecond
  const ListCoalesce = 500 * time.Millisecond
  const PageSize = 60
  const LeaseOwnerID = "chatengine"

  type Config struct {
      Exe, DBPath, Dir string // Dir = <workspace>/chatengine
      DB, Read *db.DB         // Read nil = DB (T4 passes its own handles)
      Clock func() time.Time
      Start StartFunc         // test seam; nil = exec in its own process group
      Title func(ctx context.Context, conv int64) error
      PreferredProvider string
  }
  func New(c Config) *Engine
  func (e *Engine) Start(ctx context.Context) error // sweep, then serve
  func (e *Engine) Close(ctx context.Context) error // T1: terminate sessions; T10a splits Detach/Shutdown

  type TurnRequest struct {
      chatstore.StartRequest
      ClientKey string // stored in chat_messages.client_key; T2 adds Compose, ScreenContext, ArtifactCommentIDs
  }
  func (e *Engine) Turn(ctx context.Context, r TurnRequest) (chatstore.Started, error)
  func (e *Engine) Cancel(conv int64, turnID string) (bool, error)
  func (e *Engine) NewConversation(ctx context.Context, projectID *int64, r *chatstore.Routing) (int64, error)

  type ManageRequest struct {
      Conversation int64
      Op           string // pin|unpin|rename|delete|move
      Title        string
      ProjectID    *int64
  }
  func (e *Engine) Manage(ctx context.Context, r ManageRequest) error
  func (e *Engine) SelectBranch(ctx context.Context, messageID int64) error
  func (e *Engine) MarkRead(ctx context.Context, conv, messageID int64) error
  func (e *Engine) Feed(ctx context.Context, conv, beforeMessageID int64) (Feed, error)
  func (e *Engine) List(ctx context.Context) (List, error)
  func (e *Engine) Search(ctx context.Context, q string) (SearchResult, error)
  func (e *Engine) Live(conv int64) (text string, steps []chatstore.Step, waitingSlot, ok bool)

  type Target struct {
      List            bool
      Conversation    int64
      BeforeMessageID int64
  }
  type Subscription struct{ Events <-chan Event }
  func (s *Subscription) Close()
  func (e *Engine) Subscribe(t Target, c Client) *Subscription

  type Event struct {
      Type               string            `json:"event"` // snapshot|message_upsert|conversation_update|list_update|resync
      Conversation       int64             `json:"conversation_id,omitempty"`
      Snapshot           *Feed             `json:"snapshot,omitempty"`
      Message            *FeedMessage      `json:"message,omitempty"`
      ConversationUpdate *FeedConversation `json:"conversation,omitempty"`
      List               *List             `json:"list,omitempty"`
  }

  type Client struct {
      Kind      string          // mac|phone
      PartKinds map[string]bool // nil = all (relay, D21)
  }
  type OpHandler func(ctx context.Context, params json.RawMessage, c Client) (any, error)
  func (e *Engine) Register(op string, h OpHandler)
  func (e *Engine) Do(ctx context.Context, op string, params json.RawMessage, c Client) (json.RawMessage, error)
  func ErrorCode(err error) string // busy|not_found|invalid|forbidden|closed|internal

  func (e *Engine) OnChange(fn func(conv int64))
  func (e *Engine) OnTurnEnd(fn func(conv int64, turnID, status string))
  ```
  - `Feed`, `FeedConversation`, `FeedMessage`, `FeedStep`, `FeedArtifact`, `FeedAction`, `List`, `ListConversation`, `ListProject` and `SearchResult` are the moved hub types, exported with **unchanged JSON tags**.
  - T1 registers the ops `chat_new`, `chat_turn`, `chat_cancel`, `chat_page`, `chat_search`, `chat_read`, `chat_branch_select` and `chat_manage`.

- [ ] **Step 1: Move code with history.** `git mv` the runner and the builders. Rename the pool bound to `MaxLive = 3`. Keep `TestChat03Go_PoolBound` (now asserting 3) and `TestFILES01_Chatengine` (renamed in its `TestFILES01_` form). Run `go test ./internal/chatengine ./internal/hub/... ./internal/db -run 'LIVE01|Chat'`. Expected: PASS except the new tests.
- [ ] **Step 2: Failing tests** in `internal/chatengine/engine_test.go`. Each runs inside `synctest.Test` over a fake `StartFunc`.
  - `TestChatengine_SecondTurnBusy`: two `Turn`s on one conversation → the second returns `chatstore.ErrBusy`; `ErrorCode(err) == "busy"`; only one owner row exists.
  - `TestChat01_RefusedTurnWritesNothing`: a refused `Turn` (busy, invalid, conversation gone) leaves `chat_messages` unchanged.
  - `TestChatengine_RepeatedClientKeyAppliesOnce`: two `Turn`s with the same `ClientKey` → the same `Started` (owner, assistant and turn ids), one owner row (Review Focus 2).
  - `TestChatengine_ClientKeySurvivesRestart`: engine A applies a key and is closed; engine B over the same database gets the same key → the existing turn's echo (ids read back by `(conversation_id, client_key)`), and no new row; a concurrent duplicate insert hits the unique index and is answered the same way.
  - `TestMigration00194_ClientKeyUniquePerConversation` (`internal/db`): two NULL keys pass; the same key twice in one conversation fails; the same key in two conversations passes.
  - `TestChatengine_SubscriberSeesForeignTurnLive`: a subscriber with `Client{Kind:"mac"}` receives `message_upsert` for a turn started by a `Client{Kind:"phone"}` `Do("chat_turn")`, carrying the live text (G6).
  - `TestChatengine_FeedCoalescedAt150ms`: 20 text deltas in 100 ms → at most one `message_upsert` per 150 ms window, and the last event carries the full text.
  - `TestChatengine_ListCoalescedAt500ms`: the same check for `list_update` at 500 ms.
  - `TestChatengine_SlowSubscriberResyncsAndSeesTurnEnd`: a subscriber that never reads past 256 events gets one `resync` then a `snapshot`, and that snapshot holds the final `status` of the turn.
  - `TestChatengine_DeleteDuringTurnCancels`: `Manage{Op:"delete"}` mid-turn → the turn is cancelled, and no `chat_messages` or `chat_turn_steps` row is written after the delete commits.
  - `TestChatengine_ClaimsLegacyLeaseForOneRelease`: during a turn, `db.GetChatLease(conv)` has owner `hub`, id `chatengine`, and its heartbeat advances every 15 s of fake time; after the turn it is released.
  - `TestChatengine_StartupSweepMarksSessionLost` (moved from `TestChatrun_StartupSweepMarksSessionLost`).
  - `TestChatengine_SessionReadyPublishesRoutingLive`: the fake session emits `session_ready` and then the actual provider/model (the events `ai session` emits beside its own `SetChatRouting`/`SetChatActual` writes) → a subscriber gets `conversation_update` with the new routing and actual model, and a `list_update`, with no DB watch involved; T3 extends it to assert the `routing_note` part in the next `message_upsert`.
- [ ] **Step 3: Run them.** `go test ./internal/chatengine -run 'Chatengine|Chat01'`. Expected: FAIL (undefined `Engine`).
- [ ] **Step 4: Implement** the `Engine` above and the migration. A repeated key is looked up by `(conversation_id, client_key)` before the start transaction and, on a unique-index conflict inside it, answered from the existing owner row and its assistant reply (no second turn).
  - The per-conversation lock is a `map[int64]*turnState` under one mutex.
  - Live state replaces the runner's `Live`.
  - Each subscription has a 256-slot channel and a coalescing goroutine driven by `Config.Clock` timers (synctest drives them).
  - A repeated `client_key` is found by the unique index on `chat_messages (conversation_id, client_key)` (migration 00194); there is no in-memory key store.
- [ ] **Step 5: Rewire the hub minimally.**
  - `newChatRunner` returns `chatengine.New(...)` with `Exe`, `DBPath`, `Dir: <hub dir>` (until T4), the hub's store options and the title hook.
  - `OnChange` → `publishSoon(KindChatFeed, KindChatList)`, `OnTurnEnd` → `chatTurnEnded`.
  - The handlers call `Turn`.
  - Run `go test ./internal/hub/... -run 'Chat'` and `go test ./internal/db -run LIVE01`. Expected: PASS.
- [ ] **Step 6: Inventory.** In `docs/inventory/chat.md`:
  - CHAT-01 amendment (ask #1371, as §9.2): the engine writes the owner row before the turn; guards move to `chatengine`.
  - CHAT-03 amendment: one pool of 3 in the engine; the hub's 2 and the Desktop's 3 are gone once T8 lands.
  - The changelog line.
- [ ] **Step 7: Verify and commit.**
  - Run `go test ./internal/chatengine ./internal/chatstore ./internal/hub/... ./internal/db ./internal/logcanary`, `go test ./cmd/... -run 'Sync'` and `make lint-diff`.
  - Commit: `feat(chatengine): one engine absorbs chatrun and the feed builders (#1822 T1)`.

---

### Task T2: Engine operations the Mac has today

**Depends on:** T1

**Files:**
- Create:
  - `internal/chatengine/{compose.go,entities.go,projects.go,artifacts.go,attach.go}` + tests;
  - `internal/chatengine/testdata/{compose_cases.json,entity_search_cases.json}`;
  - Swift twin readers `WatchtowerDesktop/Tests/Core/{ComposeFixtureTests,EntitySearchFixtureTests}.swift`.
- Modify: `internal/chatstore/store.go` (`StartRequest.ArtifactCommentIDs`, `StartRequest.ProviderPrefix`), `internal/chatengine/ops.go`.

**Interfaces:**
- Consumes: T1's `Engine`, `Register` and `TurnRequest`.
- Produces:
  ```go
  type Mention struct {
      Kind  string `json:"kind"`
      ID    string `json:"id"`
      Label string `json:"label"`
  }
  type Quote struct {
      MessageID int64  `json:"message_id"`
      Text      string `json:"text"`
  }
  type Compose struct {
      Skill    string    `json:"skill,omitempty"`
      Mentions []Mention `json:"mentions"`
      Quotes   []Quote   `json:"quotes"`
  }
  // TurnRequest gains: Compose *Compose; ScreenContext string; ArtifactCommentIDs []int64; Mode adds "retry"|"continue"
  func ComposeOwnerText(text string, c Compose) string // ChatTurnComposer.compose + ChatQuoteReply.compose twin

  type EntityHit struct {
      Kind, ID, Label, Detail string
  }
  func (e *Engine) EntitySearch(ctx context.Context, q string, kinds []string) ([]EntityHit, error)

  type SkillSummary struct {
      Name, Description string
  }
  func (e *Engine) SkillsList(ctx context.Context) ([]SkillSummary, error) // skills.List(skills.Dir(workspace))

  type ProjectRequest struct {
      Op string // create|update|delete
      ID *int64
      Name, Instructions *string
      Sources []ProjectSource
  }
  func (e *Engine) ManageProject(ctx context.Context, r ProjectRequest) (int64, error)

  type ArtifactRequest struct {
      Op      string // keep|unkeep|comment_add|comment_delete
      Conversation int64
      Key     string
      Version int
      CommentID int64
      Comment *ArtifactComment
  }
  func (e *Engine) ManageArtifact(ctx context.Context, r ArtifactRequest) (int64, error)
  func (e *Engine) AttachPath(ctx context.Context, conv int64, path string) (int64, error)
  ```
  - New ops: `entity_search`, `skills_list`, `project_manage`, `artifact_manage` and `attach` (Mac `path` form).
  - The `screen_context` text is the client-rendered block of `ScreenContext.swift`, at most 8 KB.

- [ ] **Step 1: Shared fixtures.**
  - `compose_cases.json` (input text, skill, mentions, quotes → stored text) is generated from today's Swift `ChatTurnComposer.compose` + `ChatQuoteReply.compose` + `ArtifactCommentMessage.compose`. Add `ComposeFixtureTests` (Core) asserting the Swift output equals every case.
  - `entity_search_cases.json` holds seed rows + query → ordered hits, from `ChatEntitySearch`. Add `EntitySearchFixtureTests` (Core).
  - Run `make test-swift FILTER='ComposeFixtureTests|EntitySearchFixtureTests'`. Expected: PASS (Swift is the source of truth).
- [ ] **Step 2: Failing Go tests.**
  - `TestCompose_SharedCases`: `ComposeOwnerText` equals every case.
  - `TestEntitySearch_SharedCases`.
  - `TestChatengine_ScreenContextNeverStored`: `SendText` starts with the block, and the stored owner row equals the composed text without it.
  - `TestChatengine_ArtifactCommentsMarkedSentInStartTx`: the comments are `status='sent'` and `sent_at` equals the owner row's `created_at` in the same transaction; a refused start leaves them `open`.
  - `TestChatengine_RetryOnlyRetryable`: `retry` on a non-retryable `error_code` → `invalid`; on a retryable one → a new assistant sibling.
  - `TestChatengine_ContinueSendsContinueAfterPartial`: `continue` on a `partial`, non-`quota_exhausted` last reply → owner text `"Continue"`; otherwise `invalid`.
  - `TestChatengine_SkillsListReadsWorkspaceSkills`.
  - `TestChatengine_ProjectDeleteDropsWarmSessions`: the warm session of a chat in the deleted project is closed.
  - `TestChatengine_ArtifactKeepWritesKnowledgeRow`: a `chat_knowledge_artifacts` row; `unkeep` removes it.
  - `TestChatengine_AttachRefusesMissingAndOversize`: a missing path or a file over `chatstore.MaxAttachmentBytes` → `invalid` with `Rejection.Message()`, and no row or file.
  - `TestChatengine_AttachRefusesSymlinkAndDir`.
- [ ] **Step 3: Run them.** `go test ./internal/chatengine -run 'Compose|EntitySearch|Chatengine_(Screen|Artifact|Retry|Continue|Skills|Project|Attach)'`. Expected: FAIL.
- [ ] **Step 4: Implement.**
  - Port the Swift composer, quote batch and comment message onto `chatstore` helpers (`composer.go` already parses REFERENCED lines).
  - Port `ChatEntitySearch`'s five queries over `e.Read`.
  - Projects follow `ChatProjectQueries`' writes; artifacts follow `ArtifactPanelModel`'s keep and comment writes.
  - `AttachPath` does an `Lstat` (regular file only), reads the file, then `chatstore.ValidateAttachment` + `SaveAttachment`.
- [ ] **Step 5: Run them.** Expected: PASS. Then run the guard map's CHAT and LIVE-01 lines and `make lint-diff`.
- [ ] **Step 6: Commit.** `feat(chatengine): compose, pickers, projects, artifacts, attach by path (#1822 T2)`

---

### Task T3: Parts, fallbacks and the one question parser

**Depends on:** T1

**Files:**
- Create:
  - `internal/chatengine/parts.go` + `parts_test.go`, `internal/chatengine/testdata/parts.json`;
  - `internal/chat/questions.go` + test, `internal/chat/testdata/question_parse_cases.json`;
  - `WatchtowerChatText/Sources/WatchtowerChatText/ChatQuestionParser.swift`, `WatchtowerChatText/Tests/WatchtowerChatTextTests/QuestionParseFixtureTests.swift`.
- Modify:
  - `internal/chatengine/feed.go` (`FeedMessage.Parts`);
  - `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatQuestionCard.swift` (keeps `ownerReply`/`isAnswerable`/`ChatThreadIndex` as extensions; parsing delegates);
  - `docs/inventory/chat.md` (new CHAT-06, CHAT-05 amendment).

**Interfaces:**
- Consumes: T1's `FeedMessage`/`FeedConversation`/`FeedAction`/`Client`.
- Produces:
  ```go
  const (
      PartText = "text"; PartSteps = "steps"; PartSources = "sources"; PartArtifact = "artifact"
      PartApproval = "approval"; PartQuestion = "question"; PartError = "error"
      PartRememberMark = "remember_mark"; PartKnowledgeMark = "knowledge_mark"
      PartPublishedLink = "published_link"; PartAttachment = "attachment"; PartRoutingNote = "routing_note"
  )
  var PartKinds = []string{ /* the 12, in this order */ }

  type FallbackAction struct {
      Label  string `json:"label"`
      Action string `json:"action"` // chat_turn|open_url|none
      Text   string `json:"text,omitempty"`
      URL    string `json:"url,omitempty"`
  }
  type Fallback struct {
      Text    string           `json:"text"`
      Actions []FallbackAction `json:"actions"`
  }
  type Part struct {
      Kind     string          `json:"kind"`
      Payload  json.RawMessage `json:"payload,omitempty"`
      Fallback Fallback        `json:"fallback"`
  }
  // FeedMessage gains: Parts []Part `json:"parts"` (flat fields kept)
  func BuildParts(m FeedMessage, conv FeedConversation, actions []FeedAction) []Part
  func FilterParts(parts []Part, c Client) []Part // D15: unlisted kind → payload dropped

  // package chat
  type QuestionCard struct{ Questions []Question }
  func ParseQuestionCard(text string, final bool) (rest string, card *QuestionCard)
  func QuestionReadableText(text string) string
  ```
  - Swift (`WatchtowerChatText`, public): `ChatQuestionOption`, `ChatQuestion`, `ChatQuestionCard` and `enum ChatQuestionParser` with `parse(_:final:)`, `readableText(_:)`, `decodeCard(_:)` and `decodeOwnerAskQuestions(_:)`. These are moved from `WatchtowerCore`; signatures are unchanged apart from becoming `public`.
  - The `routing_note` part is rebuilt when the session's routing events arrive (T1's live routing state), so it appears without a DB re-read; extend `TestChatengine_SessionReadyPublishesRoutingLive` to assert it.
  - The engine builds the payloads of `approval`, `remember_mark`, `knowledge_mark`, `published_link` and `routing_note` from the same inputs today's Swift uses: `AgentActionCardView` + `ChatToolCatalog+Actions`, `RememberCommand`, `KnowledgePrefix`, `PublishedLink`, `ChatRoutingStatus`. The payload field names are the snake_case inputs of those Swift presenters.
  - The `text` part's fallback text is `QuestionReadableText(text)`.

- [ ] **Step 1: Move the Swift question parser** to `WatchtowerChatText` and write `question_parse_cases.json` (input, final → rest text, card JSON or null, readable text) from today's behaviour. `QuestionParseFixtureTests` reads the Go file by `#filePath` (the `ArtifactParseFixtureTests` pattern). Run `make chattext-test FILTER=QuestionParse` and `make test-swift FILTER='ChatQuestion|OwnerAsk'`. Expected: PASS.
- [ ] **Step 2: Failing Go tests.**
  - `TestQuestionParse_SharedCases`.
  - `TestCHAT06_EveryPartKindHasFallback`: for every `PartKinds` entry, `parts.json` has a sample, and `BuildParts` over the matching fixture message yields that kind with a non-empty `Fallback.Text`.
  - `TestParts_FixtureCoversEveryKind`: the kinds in `parts.json` equal `PartKinds` exactly.
  - `TestChat05_FallbackActionsOnlyOpenCopyOrFixedTurn`: every built action is one of the three; `open_url` URLs pass the CHAT-05 open/copy rules; `chat_turn` texts come from a fixed table.
  - `TestChatengine_UnlistedKindSendsFallbackOnly`: a `Client` listing only `text` gets an `approval` part with `Payload == nil` and the fallback.
  - `TestChatengine_FeedKeepsFlatFields`: `Feed` JSON still has `text`, `steps`, `attachments` and the conversation `artifacts`/`actions` beside `parts`.
  - `TestParts_ApprovalFallbackText`: a pending `send_slack_message` to `#general` → fallback text `"Send a Slack message to #general — waiting for your approval"` with one action `{Label:"Open on the Mac", Action:"none"}`.
- [ ] **Step 3: Run them.** `go test ./internal/chat ./internal/chatengine -run 'QuestionParse|CHAT06|Parts|Chat05_Fallback|Unlisted|FlatFields'`. Expected: FAIL.
- [ ] **Step 4: Implement** `BuildParts`, `FilterParts`, the payloads and `ParseQuestionCard`/`QuestionReadableText`. `Feed` fills `Parts` and filters them by the subscriber's `Client`.
- [ ] **Step 5: Run the tests and the guards.** Expected: PASS. Run `go test ./internal/chat -run 'Golden|Prompt'` (no prompt change expected), the hub chat sources (wire shape still matches `WatchtowerKit/Tests/Fixtures/workbench/chat_feed.json` plus `parts`; update that fixture with one `parts` array) and `make lint-diff lint-swift`.
- [ ] **Step 6: Inventory.**
  - Add **CHAT-06** with the Go guard (the Swift guard lands in T7).
  - CHAT-05 amendment: fallbacks may only open, copy or send a fixed owner text the owner taps.
- [ ] **Step 7: Commit.** `feat(chatengine): typed parts with fallbacks; one question parser (#1822 T3)`

---

### Task T4: `chat.sock`, its own DB handles, and daemon wiring

**Depends on:** T1

**Files:**
- Create:
  - `internal/platform/{peer_darwin.go,peer_linux.go,peer_other.go,listen.go}` (moved `PeerUID`, moved `ownerconfirm.peerPID` as `PeerPID`, `ListenLocked`);
  - `internal/chatengine/{server.go,conn.go,handles.go,paths.go}` + tests, `internal/chatengine/testdata/socket_paths.json`;
  - Swift twin `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatSocketPaths.swift` + `Tests/Core/ChatSocketPathsTests.swift`.
- Modify:
  - `internal/hub/control.go` and `internal/hub/transport/cloudkit/client.go` (import `internal/platform`);
  - `internal/hub/platform/*` (peer files removed);
  - `internal/ownerconfirm/{ownerconfirm.go,signature.go}` (`VerifySameTeamCLI`);
  - `internal/sessionhost/server.go` (`Listen` wraps `platform.ListenLocked`, still returns `ErrHostRunning`);
  - `cmd/sync.go` (`startChatEngine`, called in `runSyncDaemon` before `startGoHub`, stopped after it; `ChatTitle`/`ChatPreferredProvider` move to the engine config);
  - `internal/hub/hub.go` (`Options.ChatEngine *chatengine.Engine`; nil = chat off `runner_down`);
  - `internal/hub/wiring.go` (uses `o.ChatEngine`; no engine of its own).

**Interfaces:**
- Consumes: T1's `Engine.Do`, `Subscribe` and `Client`.
- Produces:
  ```go
  // internal/platform
  func PeerUID(c *net.UnixConn) (int, error)
  func PeerPID(c *net.UnixConn) (int, error)
  var ErrSocketBusy = errors.New("platform: another process serves this socket")
  func ListenLocked(socketPath string) (net.Listener, error) // <path>.lock flock, 0600 socket
  const MaxSocketPath = 103 // darwin; 107 linux (build tags)

  // internal/ownerconfirm
  func VerifySameTeamCLI(ctx context.Context, pid int) error // same Team ID; dev build: same executable path

  // internal/chatengine
  const SocketName = "chat.sock"
  const MaxRequestBytes = 2 << 20
  const ConnQueue = 256
  const ProtocolVersion = 1
  func SocketPath(workspaceDir, tempDir string) string                   // tempDir fallback when > MaxSocketPath
  func SessionSocketPath(workspaceDir, tempDir string, conv int64) string // same rule
  // ops served by the server itself: hello, subscribe, unsubscribe; the rest go to Engine.Do
  type ServerOptions struct {
      VerifyApp func(ctx context.Context, pid int) error // default ownerconfirm.VerifyDesktop
      VerifyCLI func(ctx context.Context, pid int) error // default ownerconfirm.VerifySameTeamCLI
  }
  func NewServer(e *Engine, o ServerOptions) *Server
  func (s *Server) Serve(ctx context.Context, l net.Listener) error
  func OpenHandles(dbPath string) (write, read *db.DB, err error) // OpenExistingRW + OpenExisting, read pool of 3
  ```
- Wire (one JSON object per line):
  - request `{"id":"<s>","op":"<op>","params":{…}}`;
  - answer `{"id":"<s>","ok":true,"result":{…}}` or `{"id":"<s>","ok":false,"error":{"code":"busy|not_found|invalid|forbidden|closed|internal","message":"…"}}`;
  - pushed `{"event":"snapshot|message_upsert|conversation_update|list_update|resync",…}` (T1's `Event`).
  - `hello` params `{"protocol":1,"client":"mac","part_kinds":[…]}` → result `{"protocol":1,"ops":[…]}`.
  - `subscribe` params `{"list":true}` or `{"conversation_id":N,"before_message_id":M?}` → result `{"subscription":"<s>"}`, then a `snapshot` event (the list, the latest page, or the 60-message page before `M`) and live events tagged with `"subscription":"<s>"`; `unsubscribe {"subscription":"<s>"}` → `ok`, no further events for it. Both are served by the server over T1's `Engine.Subscribe`/`Subscription.Close` (§5.2, §5.4); a connection may hold several.
  - The first line must be `hello`; anything else closes with `invalid`. A CLI peer may only send `hello` and `chat_shutdown` (the latter is registered by T10a).
  - Payloads are the feed/list JSON as the relay carries it (snake_case keys, `wiretime.Time` seconds).

- [ ] **Step 1: Move the peer helpers** to `internal/platform` with their tests (`platform_*_test.go` peer cases). Run `go test ./internal/platform ./internal/hub/... ./internal/ownerconfirm ./internal/sessionhost`. Expected: PASS.
- [ ] **Step 2: Failing tests** (`server_test.go`, `handles_test.go`, `paths_test.go`). They use a temp-dir socket and stub `VerifyApp`/`VerifyCLI`; no process is spawned.
  - `TestChatengine_UnsignedPeerRefused`: `VerifyApp` returns an error → answer `forbidden`, the connection is closed, and no row is written.
  - `TestChatengine_CLIPeerMayOnlyShutdown`: a CLI-verified peer → `chat_turn` is `forbidden`.
  - `TestServer_HelloRequired`.
  - `TestServer_OversizeLineRefused`: a 2 MiB + 1 line → `invalid` and close.
  - `TestServer_SlowConnectionGetsResyncThenSnapshot`.
  - `TestServer_SecondListenerRefused`: `ErrSocketBusy`.
  - `TestServer_SocketModes`: 0600 socket, 0700 folder.
  - `TestServer_AnswerEchoesID`.
  - Over a real socket (temp dir, in-process engine on a fake session): `TestServer_SubscribeConversationSnapshotThenEvents` (snapshot first, then `message_upsert` of a running turn), `TestServer_SubscribeListSnapshotThenUpdates`, `TestServer_UnsubscribeStopsEvents` (after the `ok`, a new turn produces no event for that subscription), `TestServer_SubscribeBeforeMessageIDReturnsThatPage` (60 messages ending just before `M`).
  - `TestChatengine_OwnHandleNotBlockedBySyncConn`: hold a write transaction on the daemon's `*db.DB` (single connection) → `engine.Feed` and `Turn` still complete on `OpenHandles`' handles.
  - `TestSocketPath_TooLongFallsBackToTempDir` + `socket_paths.json` cases (workspace, tempDir → path), also run by `ChatSocketPathsTests` (Swift, Core) — Review Focus 1.
  - `cmd`: `TestSyncDaemon_StartsChatEngineBeforeHub`: the engine starts before `startGoHub` and is stopped after the hub's stop; with the hub off (`hub.Resolve` refuses), `chat.sock` is still served.
- [ ] **Step 3: Run them.** `go test ./internal/chatengine -run 'Server|UnsignedPeer|CLIPeer|OwnHandle|SocketPath'` and `go test ./cmd/... -run TestSyncDaemon_StartsChatEngine`. Expected: FAIL.
- [ ] **Step 4: Implement** the server: one goroutine per connection, the request size cap through a bounded line reader, an `outFrame` channel of 256, and resync on overflow. Then `OpenHandles`, the path rule, and `startChatEngine(ctx, cfg, logger) (eng *chatengine.Engine, stop func())` in `cmd/sync.go`. The hub takes `o.ChatEngine`.
- [ ] **Step 5: Run the tests and the guards.** Expected: PASS. Then run `go test ./internal/hub/... -run Chat`, `go test ./cmd/... -run 'Sync|Hub'`, `make test-swift FILTER=ChatSocketPathsTests`, `make lint-diff` and `make lint-swift`.
- [ ] **Step 6: Commit.** `feat(chatengine): chat.sock for the signed app, own DB handles, daemon-owned engine (#1822 T4)`

---

### Task T5: The hub as an adapter over the engine

**Depends on:** T1, T2, T3, T4

**Files:**
- Modify:
  - `internal/hub/chat_wiring.go` (`chatAvailable` without `desktop_too_old`);
  - `internal/hub/chat_turn_watch.go` (push from `Engine.OnTurnEnd` for every turn; `desktopLeases` removed; pending-action check kept on the `agent_actions` kick);
  - `internal/hub/control.go` (the `chat_lease` heartbeat field is accepted and ignored for one release);
  - `internal/hub/state/recordings.go` (`HeartbeatChat`/`OldDesktopRuns`/`MetaDesktopChatLease` removed);
  - `internal/hub/wire/payloads.go` (`ChatOffDesktopTooOld` removed);
  - `internal/hub/actions/handlers/{chat.go,chat_turn.go,chat_manage.go,chat_feed_request.go,chat_attachment.go}` (engine calls; `ChatDeps.Store` removed);
  - new handlers `chat_entity_search` and `chat_skills_list`;
  - `internal/hub/slices/sources/{chat_feed.go,chat_list.go,registry.go}` (`tableKinds` drops every `chat_*` row and keeps `agent_actions`; sources read `Engine.Feed`/`List`/`Search` with `Client{Kind:"phone"}` and all kinds, D21);
  - `WatchtowerKit/Tests/Fixtures/chat/actions.json`;
  - `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` (drop the `chat_off_desktop_too_old` case, add the two action kinds to `action_effect_kinds`).

**Interfaces:**
- Consumes: `hub.Options.ChatEngine` (T4); `Engine.Turn`/`Cancel`/`Manage`/`Feed`/`List`/`Search`/`EntitySearch`/`SkillsList`/`OnChange`/`OnTurnEnd` (T1, T2); `Part` (T3).
- Produces: relay action kinds
  - `chat_entity_search {query, kinds[]}` → `applied`, result `{"hits":[{kind,id,label,detail}]}` (≤ 20);
  - `chat_skills_list {}` → `applied`, result `{"skills":[{name,description}]}`.
  - Both are idempotent and need the `chat` grant.

- [ ] **Step 1: Failing tests.**
  - `TestChatWiring_UsesDaemonEngine`: the hub builds no engine and runs turns on `Options.ChatEngine`.
  - `TestChatCapability_NoDesktopTooOld`: an old heartbeat no longer turns chat off.
  - `TestChatSources_NoChatTablesInChangeWatch`: `ChangeTables` holds no `chat_` table and still holds `agent_actions`.
  - `TestChatFeedSource_LiveTurnFromEngineEvents`: an engine `OnChange` publishes `chat_feed` with the live text.
  - `TestChatFeedSource_PartsWithPayloadAndFlatFields`: D21.
  - `TestChatPush_EveryEngineTurnEnd`: a turn started over `chat.sock` (a Mac turn) ends → a `chat_answer` push with the fixed body.
  - `TestChatEntitySearchAction_ResultInEcho`, `TestChatSkillsListAction_ResultInEcho`.
  - The existing `TestChatActionsFixture` and the hub contract tests with the updated fixtures.
- [ ] **Step 2: Run them.** `go test ./internal/hub/... -run 'Chat|Contract'`. Expected: FAIL.
- [ ] **Step 3: Implement** the adapter. Delete the now-unused hub code (lease meta, `desktopLeases`, the `chat_*` `tableKinds` rows). `internal/hub/chatrun` is already gone after T1.
- [ ] **Step 4: Run the tests and the guards.** Expected: PASS. Then run `go test ./internal/hub/... ./internal/db -run 'LIVE01'` (update the `displayOnlyReadersAt` keys) and `make kit-test FILTER='HubContract|ChatActionParams|ChatSliceMirror'` (the Kit still decodes; `desktop_too_old` stays a readable `OpenWireValue`), then `make lint-diff`.
- [ ] **Step 5: Commit.** `feat(hub): chat over the daemon's engine; no lease watch, no desktop_too_old (#1822 T5)`

---

### Task T6: `WatchtowerChat/ChatWire`

**Depends on:** T3

**Files:**
- Create: `WatchtowerChat/Package.swift` (tools 5.10, macOS 14 / iOS 17; products `ChatWire`, and `ChatUI` empty until T7; depends on `../WatchtowerKit` for `WatchtowerDesign` (ChatUI) and, test-only, `WatchtowerSync`), `WatchtowerChat/.swiftlint.yml` (copy of the Kit's), `WatchtowerChat/Sources/ChatWire/{Models/*.swift,ChatOperation.swift,ChatClient.swift,ChatWireCoder.swift,ChatFeedStore.swift,ChatListStore.swift,ChatPart.swift,FlatFieldsParts.swift,ChatAttachmentLimits.swift}`, `WatchtowerChat/Tests/ChatWireTests/*`
- Move: `WatchtowerKit/Sources/WatchtowerKit/Models/Chat{ActionParams,Feed,List,Page,Search}.swift` → `ChatWire/Models/`, and `ChatSliceMirrorTests`/`ChatActionParamsTests` → `ChatWireTests`. The fixtures stay in `WatchtowerKit/Tests/Fixtures/` and are read by `#filePath`, so the Go readers are unchanged.
- Create: `WatchtowerMobile/Sources/Features/Chats/ChatWireKitConformances.swift` (`extension ChatFeed: @retroactive SliceMirror` with `sliceKind`; the same for `ChatList`, `ChatPage` and `ChatSearch`; `ActionParams` with `actionKind` for every params type; plus `ChatEntitySearchParams`/`ChatSkillsListParams` for T5's kinds).
- Modify:
  - `WatchtowerDesktop/Package.swift` (`.package(path: "../WatchtowerChat")`; `WatchtowerCore` depends on `ChatWire`);
  - `WatchtowerDesktop/Tests/Core/PublicAPISurfaceTests.swift` (Core may import `ChatWire`, never `ChatUI` or the Kit);
  - `WatchtowerMobile/project.yml` (package + `ChatWire` product) and regenerate with `make mobile-gen`;
  - `Makefile` (`chat-test` target; `test-swift` runs it unfiltered; `lint-swift` lints `WatchtowerChat`);
  - `.github/workflows/ci.yml` (WatchtowerChat path filter, test and swiftlint steps).

**Interfaces:**
- Consumes: T3's `parts.json` and part kinds; the JSON of T4's wire.
- Produces (`ChatWire`, public):
  ```swift
  public protocol ChatClient: Sendable {
      func send(_ op: ChatOperation) async throws -> ChatEcho
      func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate>
      func list() -> AsyncStream<ChatListUpdate>
      var reachability: AsyncStream<ChatReachability> { get }
  }
  public enum ChatOperation: Sendable, Equatable {
      case new(projectID: Int64?, routing: ChatRouting)
      case turn(ChatTurnRequest)
      case cancel(conversationID: Int64, turnID: String)
      case page(conversationID: Int64, beforeMessageID: Int64)
      case search(query: String)
      case read(conversationID: Int64, messageID: Int64)
      case branchSelect(messageID: Int64)
      case manage(conversationID: Int64, op: ChatManageOp, title: String?, projectID: Int64?)
      case project(ChatProjectRequest)
      case artifact(ChatArtifactRequest)
      case attach(conversationID: Int64, source: ChatAttachSource) // .path(String) | .sealedUpload(…)
      case entitySearch(query: String, kinds: [String])
      case skillsList
      case shutdown // Mac only; T10b
  }
  public struct ChatTurnRequest: Sendable, Equatable, Codable {
      conversationID; mode: ChatTurnMode /* send|regenerate|edit|retry|continue */; messageID: Int64?; text: String
      attachmentIDs: [Int64]; routing: ChatRouting?; compose: ChatCompose?; screenContext: String?
      artifactCommentIDs: [Int64]; clientKey: String
  }
  public enum ChatEcho: Sendable, Equatable {
      case applied(ChatEchoResult)
      case refused(code: String, message: String) // busy|not_found|invalid|forbidden|closed|internal|unsupported
  }
  public enum ChatFeedUpdate: Sendable {
      case snapshot(ChatFeed)
      case messageUpsert(ChatFeed.Message)
      case conversation(ChatFeed.Conversation)
      case resync
  }
  public enum ChatListUpdate: Sendable {
      case snapshot(ChatList)
      case resync
  }
  public enum ChatReachability: Sendable, Equatable {
      case connected, starting, unavailable, stoppedOnPurpose, offline(reason: String)
  }
  public struct ChatPart: Hashable, Sendable, Decodable {
      public let kind: String
      public let payload: JSONValue?
      public let fallback: ChatPartFallback
  }
  public enum ChatPartKind { public static let all: [String] /* T3's 12 */ }
  extension ChatFeed.Message { public var resolvedParts: [ChatPart] } // parts, else built from flat fields (D22)
  // Also public, plain Codable values mirroring T2/T5 wire shapes: ChatRouting, ChatTurnMode, ChatCompose{skill, mentions, quotes},
  // ChatManageOp, ChatProjectRequest, ChatArtifactRequest, ChatAttachSource, ChatEchoResult, ChatEntityHit{kind,id,label,detail}, ChatSkill{name,description}.
  public enum ChatWireCoder {
      static func makeDecoder() -> JSONDecoder
      static func makeEncoder() -> JSONEncoder // = RelayCoder settings
  }
  @MainActor @Observable public final class ChatFeedStore {
      public func apply(_ u: ChatFeedUpdate)
      public private(set) var feed: ChatFeed?
  }
  @MainActor @Observable public final class ChatListStore { /* same for ChatList */ }
  ```

- [ ] **Step 1: Create the package and move the models** with their tests. Run `make chat-test` and `make kit-test`. Expected: PASS (moved tests green; the Kit no longer has chat models).
- [ ] **Step 2: Failing tests** in `ChatWireTests`.
  - `testPartsFixtureDecodesEveryKind`: decode `internal/chatengine/testdata/parts.json`; the kinds equal `ChatPartKind.all`.
  - `testFeedWithoutPartsBuildsPartsFromFlatFields`: the `chat_feed.json` fixture with `parts` stripped → `resolvedParts` has a `text`, a `steps` and an `attachment` part matching the flat fields.
  - `testWireCoderMatchesRelayCoder`: encoding every params fixture with both coders gives the same bytes (test-only `WatchtowerSync` import).
  - `testFeedStoreAppliesSnapshotThenUpsertByID`.
  - `testFeedStoreResyncClearsUntilSnapshot`.
  - `testTurnRequestWireKeys`: snake_case keys `conversation_id`, `client_key`, `artifact_comment_ids`, `screen_context`.
  - `testAttachmentLimitsSharedCases`: reads `internal/chatstore/testdata/attachment_limit_cases.json`.
- [ ] **Step 3: Run them.** `make chat-test FILTER=ChatWire`. Expected: FAIL.
- [ ] **Step 4: Implement** the types above.
- [ ] **Step 5: Run the tests and the guards.** Expected: PASS. Then run `make test-swift FILTER=PublicAPISurfaceTests`, `make kit-test FILTER=SeamBoundaryTests`, `make mobile-build`, `make mobile-test MOBILE_FILTER='ChatSendTests|ChatFeedTests'`, `make lint-swift` and `bash scripts/tests/test-kit-lint-guard.sh`.
- [ ] **Step 6: Commit.** `feat(chatwire): the shared chat wire package; models leave the Kit (#1822 T6)`

---

### Task T7: `ChatUI` — shared views and models

**Depends on:** T6, and the owner's answer to the T0 review ask.

**Files:**
- Create in `WatchtowerChat/Sources/ChatUI/`:
  - `Registry/ChatPartRegistry.swift`;
  - `Parts/{TextPartView,StepsPartView,SourcesPartView,ArtifactPartView,ApprovalPartView(+Slack,+Confluence,+Connector,+Decision),QuestionPartView,ErrorPartView,RememberMarkPartView,KnowledgeMarkPartView,PublishedLinkPartView,AttachmentPartView,RoutingNotePartView,FallbackPartView}.swift`;
  - `Feed/{ChatFeedView,ChatMessageRow,SystemRow}.swift`;
  - `Composer/{ChatComposerView,MentionPicker}.swift`;
  - `List/{ChatListRow,ChatSearchResultsView}.swift`;
  - `State/ChatStateLine.swift`;
  - `Models/{ChatConversationModel,ChatComposerModel,ChatListModel}.swift`;
  - `Artifacts/ArtifactViewer.swift`;
  - `Style/ChatUIStyle.swift`;
  - `Platform/macOS/{MarkdownTextRun,MarkdownTableText,ChatComposerField,ChatSelectionQuote,ArtifactPrinter,PresentWindow,SandboxedHTMLGlue,KeyboardShortcuts}.swift`;
  - `Platform/iOS/{MarkdownRuns,ComposerTextField,PassagePickerSheet,ScrollingTable,SandboxedArtifactWebView}.swift`.
- Create: `WatchtowerChat/Tests/ChatUITests/*`, `WatchtowerChat/.swiftlint.yml` `kit_*` custom rules included for `Sources/ChatUI/`.
- Move: the pure helpers the moved views import from `WatchtowerCore` (`CodeHighlighter`, `MarkdownTableColumns`, `CSVTable`, `StepsSummary`, `ChatSourceGrouping`, `ChatAutoScrollPolicy`, `PasteClassifier`, `MentionTokenizer`, `SourceLinkResolver`, `HTMLPreviewPolicy`) go into `ChatUI` (UI) or `WatchtowerChatText` (text-only). Core keeps a helper only while a non-chat Core caller needs it.
- Modify: `scripts/kit-lint-guard.sh` (third root `WatchtowerChat/Sources/ChatUI`), `scripts/tests/test-kit-lint-guard.sh`, `Makefile` (`lint-swift`), `.github/workflows/ci.yml`, `docs/inventory/chat.md` (CHAT-06 Swift guard).

**Interfaces:**
- Consumes: T6's `ChatClient`, `ChatOperation`, stores, `ChatPart`, `ChatReachability`; `WatchtowerChatText` (`ArtifactParser`, `ChatQuestionParser`, `MarkdownRunBuilder`, `ChatQuoteReply`, `ChatErrorText`); `WatchtowerDesign` tokens.
- Produces (`ChatUI`, public):
  ```swift
  public protocol ChatUIStyle {
      func primaryButton(_ title: String, action: @escaping () -> Void) -> AnyView
      func secondaryButton(_ title: String, action: @escaping () -> Void) -> AnyView
      func card<C: View>(@ViewBuilder _ content: () -> C) -> AnyView
      func chip(_ title: String) -> AnyView
  }
  extension EnvironmentValues { public var chatUIStyle: any ChatUIStyle } // default: plain, for tests

  public struct ChatPartRegistry {
      public static let registered: Set<String>
      public static func view(for part: ChatPart, context: ChatPartContext) -> AnyView // unknown → FallbackPartView
  }

  @MainActor @Observable public final class ChatConversationModel {
      public init(client: any ChatClient, conversationID: Int64?)
      public var store: ChatFeedStore
      public var reachability: ChatReachability
      public var isGone: Bool
      public func start()
      public func stop()
      public func regenerate(_ id: Int64) async
      public func edit(_ id: Int64, text: String) async
      public func retry(_ id: Int64) async
      public func continueStopped(_ id: Int64) async
      public func selectBranch(_ id: Int64) async
      public var onStartDaemon: (() -> Void)?
  }
  @MainActor @Observable public final class ChatComposerModel {
      public var draft: String
      public var canSend: Bool
      public var stateLine: ChatStateLine.Content?
      public func send() async     // text stays until .applied (CHAT-01)
      public func attach(_ s: ChatAttachSource) async
      public func search(entities q: String) async -> [ChatEntityHit]
  }
  @MainActor @Observable public final class ChatListModel {
      public func delete(_ id: Int64) // Undo bar 5 s; delete sent when it ends; refused → row back
      public func undo()
      public func pin(_:)
      public func rename(_:_:)
  }
  public enum ChatStateLine {
      public struct Content: Equatable {
          let text: String
          let action: String?
      }
      public static func content(for r: ChatReachability) -> Content?
  }
  ```
- Copy pinned in `ChatStateLine.content(for:)`:
  - `.starting` → ("Chat is starting…", nil);
  - `.unavailable` → ("Chat is unavailable — Watchtower's background service is not running", "Retry");
  - `.stoppedOnPurpose` → ("Chat needs Watchtower's background service, which is stopped", "Start").

- [ ] **Step 1: Failing tests** (`ChatUITests`, with a `FakeChatClient` that records ops and scripts echoes and streams; no sockets, no clock waits).
  - `testChat06EveryFixtureKindIsRegistered`: `ChatPartRegistry.registered` ⊇ the kinds of `parts.json`.
  - `testUnknownPartRendersFallback`: kind `"future_kind"` → `FallbackPartView`, showing the fallback text and one button per action.
  - `testDaemonUnreachableKeepsDraftAndShowsRetry`: reachability `.unavailable` → `canSend == false`, the draft is unchanged, and the state line is the exact copy with "Retry".
  - `testStoppedOnPurposeShowsStartAndDoesNotStartDaemon`: `.stoppedOnPurpose` → "Start" shown; `onStartDaemon` is called only on tap.
  - `testBusyEchoReturnsTextToComposer`: echo `.refused("busy")` → the draft equals the sent text.
  - `testRefusedSendRestoresDraft`.
  - `testChat01DraftStaysUntilApplied`: before the echo the draft is kept and Send is off; after `.applied` it clears.
  - `testDroppedEchoResendsWithSameKeyNoDuplicate`: the client throws a connection error, then reconnects → the resend carries the same `clientKey` (Review Focus 2).
  - `testReconnectAfterDropShowsSessionLost`: a snapshot after `.resync` has the reply `partial` + `session_lost` → `ErrorPartView` with Retry.
  - `testRemoteTurnShowsStopAndStreams`: upserts for a turn this client did not start stream text, and Stop is enabled.
  - `testChat02WaitingStepVisibleUntilEnd`.
  - `testConversationDeletedElsewhereShowsGoneAndKeepsDraft` (Review Focus 3).
  - `testListUndoDeleteSendsOnlyAfterUndoWindow`: injected clock.
  - `testChatUIImportsOnlyAllowedModules`: a source scan.
  - `testChat05FallbackAndArtifactActionsOnlyOpenOrCopy`: a source scan of `ChatUI` (today's `ArtifactChat05ScanTests` rules).
- [ ] **Step 2: Run them.** `make chat-test FILTER=ChatUI`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Port the Mac views from `WatchtowerDesktop/Sources/Views/Chat/` and the phone views from `WatchtowerMobile/Sources/Features/Chats/`, one view per part kind.
  - Platform differences live only in `Platform/` files behind `#if os(macOS)` / `#if os(iOS)` (D9). The Mac keeps the TextKit 2 answer text, the NSTextView composer, selection quote, print, Present and Open in Window (D10).
  - Do not port the read-only GRDB screens (artifact version history, project page, inspector), which stay in the app (D19).
- [ ] **Step 4: Run the tests and the guards.** Expected: PASS. Then run `make lint-swift` (the ChatUI `kit_*` rules), `bash scripts/tests/test-kit-lint-guard.sh` and `make chattext-test`.
- [ ] **Step 5: Inventory.** CHAT-06 Swift guard; note the CHAT-05 scan now covers `ChatUI`.
- [ ] **Step 6: Commit.** `feat(chatui): one chat UI for macOS and iOS (#1822 T7)`

---

### Task T8: The Mac on the engine

**Depends on:** T2, T4, T7

**Files:**
- Create:
  - `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/SocketChatClient.swift` + `Tests/Core/SocketChatClientTests.swift`;
  - `WatchtowerDesktop/Sources/Views/Chat/DesignKitChatStyle.swift`.
- Modify:
  - `Sources/ViewModels/ChatViewModel.swift`: a shell only, with the window state (split, sidebar, inspector, ⌘K/⌘N), the `SocketChatClient` and the ChatUI models;
  - `Sources/Views/Chat/{ChatView,ChatThreadView,ChatSidebarView,HelpChatPanel,ChatInspectorContent,ChatLandingView}.swift` (on ChatUI);
  - `Sources/App/{AppState.swift,AppState+Chat.swift}` (no `releaseEarlierLaunchesChatLeases`, no pool);
  - `ProjectDetailViewModel.swift` and `ArtifactPanelModel.swift` (writes go through `project_manage`/`artifact_manage`);
  - `WatchtowerCore/Services/HubControlClient.swift` (no `chat_lease`);
  - `Tests/DesignShots/*` (the T0 Mac mocks become real views; `chat-phone-turn` is removed only in Step 5, after the comparison);
  - `Package.swift` (the app depends on `ChatUI`).
- Delete:
  - `Sources/Services/Chat/{ChatSessionPool,ChatSessionClient}.swift`;
  - `WatchtowerCore/Services/Chat/{ChatTurnDriver,ChatTurnStore,ChatForeignTurnModel,ChatAttachmentStore,ChatSessionProcess,ChatEvent,ChatCommand,LiveTurn(main-chat use),NDJSONLineSplitter(if unused)}.swift`;
  - `WatchtowerCore/Database/Queries/ChatLeaseQueries.swift`;
  - the write methods of `ChatTreeQueries`, `ChatConversationQueries`, `ChatProjectQueries` and `ChatArtifactQueries` that only the main chat calls (grep each caller; embedded stores keep theirs);
  - `ChatHistoryViewModel(+PendingDeletes)` (replaced by `ChatListModel`);
  - the Swift fixture readers whose Swift twin is deleted: `ChatTurnStoreFixtureTests`, `ChatLeaseQueriesTests`, `ChatTurnLeaseTests`, `ChatForeignTurnModelTests`, `OutcomesBlockFixtureTests`, `ChatSearchQueriesFixtureTests`, plus `ChatIdeaRowsFixtureTests`/`KnowledgePrefixFixtureTests` when their Swift writer goes. The Go sides stay.

**Interfaces:**
- Consumes: T6 `ChatClient`/`ChatOperation`; T7 models and views; T4 wire and `ChatSocketPaths`.
- Produces:
  ```swift
  package final class SocketChatClient: ChatClient {
      package init(socketPath: String, markerPath: String,
                   startDaemon: @escaping @Sendable () async -> Void,   // AppState.ensureDaemonRunning chain
                   clock: any ChatClientClock,                          // injected; sleeps are clock calls
                   partKinds: [String] = Array(ChatPartRegistry.registered))
      package func shutdown() async -> Bool // T10b
  }
  package protocol ChatClientClock: Sendable {
      func sleep(for: Duration) async throws
      var now: ContinuousClock.Instant { get }
  }
  package enum ChatReachabilityPolicy {
      package static let stoppedMarkerName = "daemon.stopped"
      package static let unavailableAfter: Duration = .seconds(10)
      package static func backoff(attempt: Int) -> Duration // 100 ms doubling to 2 s
  }
  ```

- [ ] **Step 1: Failing tests** (`SocketChatClientTests`, against an in-test unix-socket server on a temp path with a fake clock).
  - `testHelloDeclaresRegisteredPartKinds`.
  - `testCrashedDaemonAutoStartsOnce`: no socket and no marker → `startDaemon` is called exactly once; reachability `.starting`, then `.unavailable` after 10 s of fake time.
  - `testStoppedOnPurposeShowsStartAndDoesNotStartDaemon` (client half): a marker is present → `.stoppedOnPurpose`, and `startDaemon` is never called.
  - `testClientReconnectsAndResubscribesAfterDrop`: the server closes → backoff 100, 200, 400 ms … 2 s; on reconnect the open feed is resubscribed, and a fresh snapshot arrives.
  - `testReconnectBackoffDoublesTo2s`.
  - `testWriteFailureTriggersReconnectAndResubscribe` (Review Focus 5).
  - `testForbiddenHelloSurfacesUnavailable`.
  - `ChatViewModelShellTests.testHelpPanelSendsScreenContext`: ⌘/ sends `screen_context`, and the stored text is unaffected.
- [ ] **Step 2: Run them.** `make test-swift FILTER='SocketChatClientTests|ChatViewModelShellTests'`. Expected: FAIL.
- [ ] **Step 3: Implement** the client (one connection, request ids, an `AsyncStream` fan-out per subscription, the marker read with `FileManager` only on unreachable) and the shell split. Then delete the files above.
- [ ] **Step 4: Re-home the guards.** Every deleted Swift CHAT guard keeps its assertion in Go or ChatUI. Record the mapping in `docs/inventory/chat.md`:

  | Deleted Swift guard | New home |
  |---|---|
  | `testChat01UserMessageIsPersistedBeforeTheTurnIsSent` | `TestChat01Go_OwnerRowBeforeTurn` + `testChat01DraftStaysUntilApplied` |
  | `testChat01PartialTextSurvivesProcessDeathAndTheNextTurnResumes` | `TestChatstore_ProcessDeathFinalizesPartial` + `TestChatengine_KilledMidTurnSweepsSessionLost` |
  | `testChat02WaitingStepIsVisibleUntilItEnds` | `testChat02WaitingStepVisibleUntilEnd` |
  | `testChat03NeverEvictsABusySessionQueuesInstead` | `TestChat03Go_PoolBound` (busy never evicted) |
  | `testChat04SessionArgvNeverCarriesContent` | `TestChat04_EngineSessionArgvCarriesNoContent` (add in this task, over `sessionConfig.argv`) |
  | `testSendAfterAStopReplaysTheStoppedReplysSavedText` | `TestChatengine_SendAfterStopReplaysSavedText` (add) |
  | `testSendRefusedWhileHubHoldsLeaseKeepsDraft`, `testConcurrentClaimOneWins` | `TestChatengine_SecondTurnBusy` + `testBusyEchoReturnsTextToComposer` |
  | `testDriverStopsWhenConversationDeleted` | `TestChatengine_DeleteDuringTurnCancels` |

- [ ] **Step 5: Shots.** The T0 mac names (`chat-daemon-*`, `chat-part-fallback`, `chat-remote-turn-live`) now render the real ChatUI views. Run `make desktop-shots DESKTOP_SHOTS=build/t8` and compare every `chat-*` entry with `build/unified-chat-before`. Expected: no visual change on unchanged screens, and `chat-remote-turn-live` matches the `chat-phone-turn` baseline except the retired "Answering from your iPhone" line (now the normal Stop). Only then delete the `chat-phone-turn` entry and its `IPhoneChatShotFixtures` pool setup.
- [ ] **Step 5b: Latency (anti-goal "not slower").**
  - Go: `BenchmarkChatengine_SendToFirstDelta` and `BenchmarkChatengine_PerDelta` in `internal/chatengine`, each with two sub-benchmarks in one run, `InProcess` (direct `Engine.Turn` + `Subscribe`) and `OverSocket` (a real `chat.sock` client on a temp path); fake session emitting deltas as fast as read.
  - `TestChatengine_SocketLatencyWithinTwiceInProcess`: runs both paths N=200 times in the same process via `testing.Benchmark` and asserts `overSocket ≤ 2 × inProcess + 2 ms` per op (a ratio of measured numbers, no wall-clock wait or timeout).
  - Swift: `SocketChatClientTests.testDecodePathWithinTwiceOfDirectStore` measures (with `ContinuousClock` around a fixed batch, no sleeps) 1 000 `message_upsert` lines decoded through `SocketChatClient` into `ChatFeedStore` vs the same messages applied directly, and asserts the same `≤ 2× + constant` ratio.
  - Controller manual check (after T8 merges, release build): type a long message and stream a long answer in the Mac chat on a loaded workspace; no visible typing lag and first text appears as quickly as on `main`; note the result in the phase report.
- [ ] **Step 6: Run the tests and the guards.** Run `make test-swift FILTER='Chat|Artifact|Project|HelpChat|PublicAPISurface|LIVE01'`, `make chat-test` and `make lint-swift`. Also run the Go guard (`go test ./internal/chatengine -run 'Chat04|SendAfterStop'`) and `make lint-diff`.
- [ ] **Step 7: Commit.** `feat(desktop): the Mac chat on the engine over chat.sock; Swift writer and pool deleted (#1822 T8)`

---

### Task T9: The phone on `ChatUI`

**Depends on:** T5, T7

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Chats/{RelayChatClient.swift,PhoneChatStyle.swift}`, `WatchtowerMobile/Tests/RelayChatClientTests.swift`
- Keep (shell): `ChatsCenter`, `ChatsGateModel`/`ChatsGateView`, `ChatOfflineCopy` and `ChatPrefetcher` (both in `ChatOfflineCopy.swift`), `ChatSendCoordinator` (wrapped), `ChatAttachmentPicker`, push routing.
- Delete:
  - `ChatApprovalCard`, `ChatArtifactSheet`, `ChatComposerModel`, `ChatConversationModel`, `ChatFeedItems`, `ChatFeedRows`, `ChatListModel`, `ChatMarkdownView`, `ChatSourcesSheet`, `ChatSearchModel`, `ChatRowActions`;
  - `SandboxedArtifactWebView` (now `ChatUI/Platform/iOS`);
  - the body of `ChatConversationView`/`ChatListView` (a thin shell over ChatUI remains).
  - Tests: `ChatConversationModelTests`, `ChatListModelTests`, `ChatSearchModelTests`, `ChatRowActionsTests` and `ChatFeedTests` move their generic assertions to ChatUI tests (already there from T7) and are deleted. `ChatSendTests`/`ChatSendRecoveryTests` (CHAT-01) stay, and so does `PhoneArtifactWebRTCTests` (CHAT-05, now importing ChatUI).
- Modify: `project.yml` (`ChatUI` product) + `make mobile-gen`, `ScreenshotTourTests` (the T0 phone frames become real views).

**Interfaces:**
- Consumes: T6/T7 types; T5's relay kinds and `parts`.
- Produces:
  ```swift
  final class RelayChatClient: ChatClient {
      init(center: ChatsCenter, sender: ChatSendCoordinator, replica: ReplicaStore, offline: ChatOfflineCopy)
  }
  // send(.turn) → ChatSendCoordinator (chat_outgoing kept, CHAT-01 phone half); .entitySearch/.skillsList → T5 kinds;
  // .shutdown/.project → .refused("unsupported"); feed(_) → chat_feed records as .snapshot; reachability from ChatsGateModel
  ```

- [ ] **Step 1: Failing tests** (`RelayChatClientTests`).
  - `testRelayClientMapsGateToReachability`: `notAllowed`/`needsRelay`/`offline` → `.offline(reason)`, with the gate's copy unchanged.
  - `testRelayClientSnapshotsFeedIntoStore`.
  - `testOfflineCopyPagesFeedStoreAsSnapshot`: offline, with a stored `ChatOfflineCopy` page (also one written by `ChatPrefetcher`) → `feed(_)` yields it as `.snapshot` and `ChatFeedStore.feed` equals the stored page; a later relay record replaces it.
  - `testRelaySendKeepsOutgoingUntilEcho`: CHAT-01, through `ChatSendCoordinator`.
  - `testEntitySearchOverRelayEcho`.
  - `testProjectEditUnsupportedOnPhone`.
- [ ] **Step 2: Run them.** `make mobile-test MOBILE_FILTER=RelayChatClientTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the client and switch the tab's conversation and list screens to ChatUI. Then delete the files above.
- [ ] **Step 4: Run the tests and the guards.** Run `make mobile-test MOBILE_FILTER='RelayChatClientTests|ChatSendTests|ChatSendRecoveryTests|ChatsGateModelTests|PhoneArtifactWebRTCTests|ChatAttachmentAndCopyTests'`, `make mobile-shots SHOTS_ONLY=chat SHOTS_DIR=build/t9` (compare with `build/unified-chat-before-phone`; the new `iphone-chat-question-card` and `iphone-chat-approval-slack` show the real cards) and `make lint-swift`.
- [ ] **Step 5: Commit.** `feat(mobile): the Chats tab on ChatUI over RelayChatClient (#1822 T9)`

---

### Task T10a: Turns outlive the daemon; the stopped marker; chat shutdown (Go)

**Depends on:** T1, T4

**Files:**
- Create:
  - `internal/daemon/stopped.go` + test;
  - `internal/chat/{listen.go,turnbuffer.go}` + tests;
  - `internal/chatengine/{reattach.go,shutdown.go}` + tests.
- Modify:
  - `internal/chat/session.go` (`attach` command; the buffer feeds every emitted event);
  - `cmd/ai_session.go` (`--listen <path>`);
  - `internal/chatengine/{pool.go,session.go,sweep.go}` (sessions spawned detached with `setsid` and `--listen`; `Process` over the session socket; pgid files in `<workspace>/chatengine/sessions/<conv>.pgid`; the sweep keeps the leases of reattached turns);
  - `cmd/sync.go` (`sync stop --internal`; owner stop = `chat_shutdown` over `chat.sock`, then SIGTERM, then the marker; `runSyncDaemon` removes the marker first; the daemon's stop calls `Engine.Detach`);
  - `cmd/chat.go` (`chat shutdown`);
  - `docs/inventory/chat.md` (CHAT-03 detached-session amendment).

**Interfaces:**
- Consumes: T1 `Engine`/`StartFunc`/`Process`; T4 `SessionSocketPath`, `Server` (registers `chat_shutdown`), `ownerconfirm.VerifySameTeamCLI`.
- Produces:
  ```go
  // internal/daemon
  const StoppedMarkerName = "daemon.stopped"
  type StoppedMarker struct {
      At time.Time `json:"at"`
      By string    `json:"by"`
  }
  func WriteStoppedMarker(workspaceDir string, at time.Time, by string) error // 0600, one line
  func RemoveStoppedMarker(workspaceDir string) error                         // absent = nil
  func ReadStoppedMarker(workspaceDir string) (StoppedMarker, bool, error)

  // internal/chat
  const TurnBufferCap = 600 << 10
  type TurnBuffer struct{ /* … */ }
  func (b *TurnBuffer) Add(ev Event)
  func (b *TurnBuffer) Replay() []Event // whole turn, or latest text snapshot + every step past the cap
  type ListenOptions struct {
      Path   string
      Verify func(ctx context.Context, pid int) error
      Clock  func() time.Time
      IdleTTL time.Duration // default 10 min
  }
  func ServeListen(ctx context.Context, o ListenOptions, s *Session) error // one client at a time; "attach" replays
  // new command type: {"type":"attach"}

  // internal/chatengine
  func (e *Engine) Detach(ctx context.Context) error   // close chat.sock, detach sessions, flush, close DB handles
  func (e *Engine) Shutdown(ctx context.Context) error // cancel, finalize partial, close, 2 s, SIGTERM, SIGKILL after 3 s
  func ShutdownSessions(ctx context.Context, workspaceDir, tempDir string) error // the CLI fallback, by pgid files
  // op "chat_shutdown" (app or CLI peer) → Shutdown
  ```

- [ ] **Step 1: Failing tests.**
  - `TestSyncStop_WritesStoppedMarker`: after a stopped daemon (fake pid), the marker exists with `by == "cli"` and mode 0600.
  - `TestSyncStop_InternalWritesNoMarker`.
  - `TestSyncStop_InternalLeavesSessionsRunning`: with a re-exec'd fake session listening (group reaped in `t.Cleanup`) and a recording fake `chat.sock`, `sync stop --internal` sends no `chat_shutdown`, writes no marker, and the session process is still alive; a new engine then `Start`s and reattaches to it.
  - `TestSyncStop_OwnerPathOrder`: the owner `sync stop` against a recording fake `chat.sock` and a fake daemon pid records `chat_shutdown`, then SIGTERM (through the `signalStop` seam), then the marker write, in that order; with `chat.sock` unreachable it runs `ShutdownSessions` before SIGTERM.
  - `TestSyncStop_InternalFlagRegistered`: cobra knows `--internal`.
  - `TestSyncDaemon_StartRemovesStoppedMarker`: removed before the daemon serves `chat.sock`.
  - `TestTurnBuffer_PastCapReplaysLatestTextAndEveryStep` (Review Focus 4).
  - `TestAISession_ListenIdleExit`: in-process `ServeListen` with a fake clock; the turn ends, no client for 10 min → it returns; the same for a running turn → it keeps running.
  - `TestAISession_ListenRefusesForeignPeer`.
  - `TestChatengine_RestartMidTurnReattachesAndFinishes`: engine A starts a turn on a re-exec'd fake session (its process group reaped in `t.Cleanup`) and `Detach`es; engine B `Start`s, reattaches, and the row ends `complete` with the whole text.
  - `TestChatengine_ReplayIsIdempotent`: replaying twice → the same rows (text set whole, steps upsert by id, artifacts by key+message).
  - `TestChatengine_ReplayPastCapStoresWholeText`.
  - `TestChatengine_TurnEndedWhileDetachedIsWrittenOnAttach`.
  - `TestChatengine_SweepWithoutSessionMarksLost`.
  - `TestChatengine_KilledMidTurnSweepsSessionLost`.
  - `TestChatengine_ShutdownReapsSessions`: every session gets `cancel` then `close`; a stubborn fake gets SIGTERM at 2 s and SIGKILL at 3 s (synctest); every row ends `partial`.
  - `TestChatShutdownCLI_ReapsWithoutEngine`.
  - `TestChat03_DetachedSessionBounded`: an orphan exits after `IdleTTL`.
- [ ] **Step 2: Run them.** `go test ./internal/daemon ./internal/chat ./internal/chatengine ./cmd/... -run 'StoppedMarker|SyncStop|SyncDaemon_Start|TurnBuffer|AISession_Listen|Restart|Replay|Detached|Sweep|Shutdown|Chat03'`. Expected: FAIL.
- [ ] **Step 3: Implement** the pieces above.
  - Start sessions with `syscall.SysProcAttr{Setsid: true}`.
  - The `Process` implementation dials `SessionSocketPath` (retry while the child binds, on the injected clock).
  - Reattach lists the socket folder, sends `attach`, and feeds the replay through the normal `Turn.Apply`.
  - The daemon's SIGTERM path calls `Detach`.
- [ ] **Step 4: Run the tests and the guards.** Expected: PASS. Then run `go test ./internal/chatengine -run TestFILES01`, `go test ./internal/chat -run 'Golden|Session|Chat0'`, `go test ./cmd/... -run 'Sync|AISession|Chat'` and `make lint-diff`.
- [ ] **Step 5: Inventory.** CHAT-03: a detached session exits 10 minutes after its turn with no engine attached; app quit, wipe and `sync stop` reap every session.
- [ ] **Step 6: Commit.** `feat(chatengine): turns survive daemon restarts; stopped marker; chat shutdown (#1822 T10a)`

---

### Task T10b: The app's stops end chat (Swift)

**Depends on:** T8, T10a

**Files:**
- Modify:
  - `WatchtowerCore/Services/DaemonManager.swift`: each of the three `["sync", "stop"]` becomes `["sync", "stop", "--internal"]`;
  - `App/QuitCoordinator.swift`: `closeChatSessions` becomes `shutdownChat`, which is `SocketChatClient.shutdown()`, else `watchtower chat shutdown`;
  - `App/TrayAppDelegate.swift`;
  - `App/AppState+DaemonStart.swift`: `stopDaemonAndRemoveEverything` and `disconnectSlackOnQueue` shut chat down first;
  - `WatchtowerCore/Services/DatabaseCompactionStep.swift`: `CompactionCLI.chatShutdown()` runs before the compaction check stops the daemon.
- Test: `Tests/QuitCoordinatorTests.swift`, `Tests/Core/DatabaseCompactionStepTests.swift`, `Tests/Core/DaemonManagerArgvScanTests.swift` (new), `Tests/AppStateDaemonStartTests.swift`.

**Interfaces:**
- Consumes: `SocketChatClient.shutdown()` (T8); `watchtower chat shutdown` and `sync stop --internal` (T10a).
- Produces: `package protocol CompactionCLI { … func chatShutdown() async }`; `QuitCoordinator.shouldTerminate(…, shutdownChat: @escaping () async -> Void, …)`.

- [ ] **Step 1: Failing tests.**
  - `testQuitFallsBackToCLIShutdown`: the client's `shutdown()` returns false → the CLI `chat shutdown` runs before `stopDaemon`.
  - `testQuitShutsDownChatBeforeStoppingDaemon`.
  - `testCompactionStepShutsDownChatSessionsFirst`.
  - `testWipeShutsDownChatFirst`, `testSlackDisconnectShutsDownChatFirst`.
  - `testEveryAppSyncStopIsInternal`: scan `Sources/` for `"sync", "stop"` argv; each one carries `"--internal"`.
- [ ] **Step 2: Run them.** `make test-swift FILTER='QuitCoordinatorTests|DatabaseCompactionStepTests|DaemonManagerArgvScanTests|AppStateDaemonStart'`. Expected: FAIL.
- [ ] **Step 3: Implement** the calls and argv changes.
- [ ] **Step 4: Run the tests and the guards.** Expected: PASS. Then run `make test-swift FILTER='Quit|Compaction|DaemonManager|Tray'`, `go test ./cmd/... -run SyncStop` (flag registered) and `make lint-swift`.
- [ ] **Step 5: Commit.** `feat(desktop): quit, wipe, Slack disconnect and compaction end chat first; internal stops (#1822 T10b)`

---

### Task T12: Embedded chats, Workchat and the owner-ask drawer through `ChatUI`

**Depends on:** T7, T8

**Files:**
- Create: `WatchtowerCore/Services/Chat/{EmbeddedChatFeedAdapter.swift,WorkchatFeedAdapter.swift}` + `Tests/Core/{EmbeddedChatFeedAdapterTests,WorkchatFeedAdapterTests}.swift`
- Modify:
  - `Views/Chat/Embedded/EmbeddedChatView.swift`;
  - `Views/Workbench/{SessionChatView,SessionChatRow,SessionChatSubagentView}.swift`;
  - `Views/Workbench/Asks/OwnerAskDrawer.swift` (ChatUI `QuestionPartView`);
  - the ChatQuestionCard callers (now `ChatQuestionParser`);
  - `Tests/Core/ArtifactChat05ScanTests.swift` (scans `WatchtowerChat/Sources/ChatUI` and what is left of `Views/Chat`);
  - `docs/inventory/chat.md` (CHAT-05 note).
- Delete: the `Views/Chat` row, feed, card and composer files with no caller left (`ChatMessageRow`, `ChatFeedView`, `ChatComposerBar`, `ChatComposerView`, `ChatComposerField`, `AgentActionCardView*`, `ArtifactCardView`, `StepsBlockView`, `SourcesSummaryRow`, `SourceItemViews`, `RememberMarkView`, `ChatKnowledgeMarkView`, `PublishedLinkCardView`, `ChatQuestionCardView`, `QuoteBatchView`, `AttachmentChipsView`, `StreamingIndicator`, `MentionPicker`, `PastingTextView`, `MarkdownTextRun`, `MarkdownTableText`, `CodeBlockView`, `ChatSelectionQuote`, `ArtifactPrinter`).
  - **Keep** `MarkdownView` and anything still used outside the chat surfaces (Inbox, Memory, Calendar, Automations, Spec review). Where such a view duplicates a ChatUI view, it becomes a thin wrapper over ChatUI's text run.

**Interfaces:**
- Consumes: T7 `ChatFeedView`, `QuestionPartView` and `ChatFeed.Message` + `resolvedParts` (D22 path); `EmbeddedChatEngine` rows + `LiveTurn`; the `sessionfeed` rows of `WorkchatModel`.
- Produces:
  ```swift
  package enum EmbeddedChatFeedAdapter {
      package static func messages(rows: [ChatMessageRecord], live: LiveTurn?) -> [ChatFeed.Message]
  }
  package enum WorkchatFeedAdapter {
      package static func messages(_ rows: [WorkchatRow]) -> [ChatFeed.Message] // subagent markers and Watchtower lines → role "system"
  }
  ```
  - The adapters build **no parts**. They map text, status, steps, sources and error field by field, and leave `parts` nil (D14).

- [ ] **Step 1: Failing tests.**
  - `testEmbeddedAdapterMapsRowsFieldByField`.
  - `testEmbeddedArtifactsAndQuestionsComeFromSharedParser`: a row whose text holds an artifact fence and a question block → ChatUI shows an artifact card and a question card, and the adapter's output has `parts == nil`.
  - `testWorkchatAdapterMapsFeedRows`: owner, agent text, ask answers, Watchtower lines, brief and subagent markers.
  - `testOwnerAskDrawerQuestionCardAnswers`: the same answer text is sent as before.
- [ ] **Step 2: Run them.** `make test-swift FILTER='EmbeddedChatFeedAdapterTests|WorkchatFeedAdapterTests|OwnerAskDrawer'`. Expected: FAIL.
- [ ] **Step 3: Implement** the adapters and switch the three surfaces. Then delete the files above.
- [ ] **Step 4: Shots.** Run `make desktop-shots DESKTOP_SHOTS=build/t12` and compare every `workchat-*`, `branch-review-*`, `tuning-chat-*`, `ask-raised-from-chat`, `approval-card-target-stuck`, `embedded-chat-*` and `owner-ask-question-card` entry with `build/unified-chat-before`. Expected: no visual change.
- [ ] **Step 5: Run the tests and the guards.** Run `make test-swift FILTER='Embedded|Workchat|OwnerAsk|SpecReview|Reviewer|ArtifactChat05|ChatQuestion'`, `make chat-test`, `make chattext-test` and `make lint-swift`.
- [ ] **Step 6: Commit.** `refactor(desktop): embedded chats, Workchat and asks render through ChatUI (#1822 T12)`

---

### Task T11: Inventory, feature notes, guide

**Depends on:** all

**Files:**
- Create: `docs/features/unified-chat.md`
- Modify:
  - `docs/inventory/chat.md`: final CHAT-01/03/05/06 text, the guard mapping, the changelog; and `docs/inventory/README.md` if the module map names `internal/hub/chatrun`;
  - `docs/features/README.md` (the chat-redesign and iphone-chat summaries, plus a new unified-chat line);
  - `docs/features/chat-redesign.md` (the engine and `ChatUI` replace the Swift turn path and pool);
  - `docs/features/iphone-chat.md` (D1, D5, D6, D11, D13 and D18 superseded; v1 limits updated: no 1 s DB re-read, one pool);
  - `CLAUDE.md` (a feature-list line for unified chat);
  - `docs/guide/features/ai-chat.md` and `docs/guide/features/iphone-chat.md` (the three Mac states with their exact copy; turns survive restarts; Start when stopped).

- [ ] **Step 1: Write `unified-chat.md`**:
  - architecture;
  - `chat.sock` wire and ops;
  - the part kinds and fallback rules;
  - the lifecycle (detach/reattach, the marker, the shutdown paths);
  - the Go↔Swift fixtures (`parts.json`, `question_parse_cases.json`, `compose_cases.json`, `entity_search_cases.json`, `socket_paths.json`, `artifact_parse_cases.json`);
  - the §12 v1 limits plus this plan's: no phone project editor and no `chat_turn_leases` drop yet; the `chat_messages.client_key` column (migration 00194).
- [ ] **Step 2: Update the notes, the inventory, CLAUDE.md and the guide.**
- [ ] **Step 3: Verify.** Run `go test ./docs/guide` (8 KB cap) and `bash scripts/leak-check.sh` over the diff, if run locally. Expected: PASS.
- [ ] **Step 4: Commit.** `docs: unified chat — inventory, feature notes, guide (#1822 T11)`

---

## Spec coverage

| Spec | Tasks |
|---|---|
| §2 G1/D2/D3 | T1, T4, T8 |
| §2 G2/D4 | T4, T6 |
| §2 G3/D8–D10 | T6, T7 |
| §2 G4 | T3, T7 |
| §2 G5/CHAT-06 | T3, T7 |
| §2 G6 | T1 |
| §2 non-goals (embedded rendering) | T12 |
| D5 | T1, T5, T8 |
| D6 | T1 |
| D7/D22 | T6 |
| D11/D13 | T8, T10a, T10b |
| D12 | T4 (no approval op), T5 (relay approval kept) |
| D14 | T3, T12 |
| D15/D21 | T3, T5 |
| D17 | T4 |
| D18 | T7 |
| D19 | T7, T8 |
| D20 | T4 |
| D23 | T10a |
| §4 | T1, T4, T5 |
| §5.1 | T4 |
| §5.2 | T1, T2, T10a (`chat_shutdown`) |
| §5.3 | T3, T6 |
| §5.4 | T1, T5, T6 |
| §6.1 | T6, T7 |
| §6.2 | T8 |
| §6.3/§6.4 | T5, T9 |
| §7 | T4, T10a, T10b |
| §8 rows | the named tests in T1, T2, T3, T4, T7, T8, T10a, T10b, T12 |
| §9 | T1, T3, T5, T7, T8, T10a, T11 |
| §10 | T0, T8, T9, T12 |
| §12 | T11 |
