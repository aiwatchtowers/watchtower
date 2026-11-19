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
- The umbrella branch is `feature/unified-chat`. Each task is one implementer agent working in its own worktree on `feature/unified-chat-tN-<slug>`, branched from the umbrella. Its PR goes **into `feature/unified-chat`**, never into `main`. The umbrella PR into `main` stays a draft until T11 and the addendum's T16 (asks #1409 and #1411; T16 follows T17) are merged and the owner has answered T16's review ask.
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
  - E (addendum, asks #1409 and #1411): T13, T14, T15, T17, T16 — the Mac composer, approval cards and routing pill move into `ChatUI`.
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

> **Addendum (ask #1409).** The umbrella's final review (finding I3) found the Mac's composer (`Views/Chat/ChatComposerView`, `ChatComposerBar`, `ChatComposerField`, `AttachmentChipsView`, `MentionPicker`, `QuoteBatchView`) and approval cards (`Views/Chat/AgentActionCardView*`) still in the app beside `ChatUI`'s own. That breaks G3, §6.1 and §6.4: a composer or approval-card feature written once reaches one device only. In ask #1409 the owner decided they move into `ChatUI` **in this branch, before it merges to main**. Tasks T13–T16 below do it, in phase E, after T12 and T11. They follow T12's approach: one implementation in `ChatUI`; the Mac's look comes through `ChatUIStyle` hooks (`DesignKitChatStyle`); Mac-only capabilities come as injected services or `Platform/macOS` parts; no view is kept twice. T13 and T14 run in parallel lanes. T15 follows T14 and may run beside T13. T16 runs last.
>
> **Ask #1411.**
> - The owner decided that the Mac's routing pill and the phone's model and project chips also become one `ChatUI` view in this branch. The routing pill includes the model menu, the actual-provider and capability lines, the provider fallback preview and the routing error. **T17** does it after T13, so a model-picker feature written once reaches both devices while the Mac looks and behaves as today (spec §2).
> - In the same ask the owner confirmed two v1 limits on the phone: **no approval editing** (no Slack edit, no workspace pick, no connector-input edit) and **no bulk approval verbs** (no Approve all, no Dismiss, no Retry). T15 leaves those capabilities nil on the phone, and T16 records them in `unified-chat.md`.

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

## Addendum tasks (asks #1409 and #1411): the composer, the approval cards and the routing pill in `ChatUI`

**Why.** Spec G3, §6.1 and §6.4 put the composer and the per-connector approval cards in `ChatUI`. After T12 the Mac still draws its own, so a feature written once reaches one device only. Ask #1411 adds the routing pill (T17).

**Lanes and order.**
- **T13 ∥ T14.** Two parallel lanes in their own worktrees. T13 is the composer: Swift, Desktop and phone. T14 is the approval data: Go plus `ChatWire`.
- **T15 after T14.** It may run beside T13.
  - Both T13 and T15 add lines to the same few files: `Style/ChatUIStyle.swift`, `Views/Chat/DesignKitChatStyle.swift`, `Features/Chats/PhoneChatStyle.swift`, `DesignShotCatalog.swift`, `ScreenshotTourTests.swift` and `ChatUISourceScanTests.swift`.
  - The second of the two to merge rebases on the umbrella and resolves these additive conflicts. No other file is shared.
- **T17 after T13.** It may run beside T14 and T15.
  - It shares additive lines with T13 and T15 in `Style/ChatUIStyle.swift`, `DesignKitChatStyle.swift`, `PhoneChatStyle.swift`, `DesignShotCatalog.swift`, `ScreenshotTourTests.swift` and `ChatUISourceScanTests.swift`. It also shares lines with T14 in `internal/chatengine/feed.go` (T14 adds `FeedAction` fields, T17 adds `FeedConversation.RoutingReason`).
  - The later lane to merge rebases on the umbrella and resolves these additive conflicts.
- **T16 after T13, T14, T15 and T17.**
- **Phone lanes** use their own `-derivedDataPath`, as the plan header says.

**Rules for every addendum task** (on top of the Global Constraints):
- **One view.**
  - Each composer piece and each approval-card piece exists once, in `ChatUI`.
  - The Mac's look comes through `ChatUIStyle` hooks implemented by `DesignKitChatStyle`.
  - The phone's look comes through the same hooks implemented by `PhoneChatStyle`. Each hook's phone implementation draws exactly what the phone draws today.
  - No `#if os(...)` outside `Platform/`. No Desktop copy kept "for safety" (anti-goal 2).
- **Where the Mac-only input lives.**
  - **`ChatUI/Platform/macOS`:**
    - NSTextView key handling: Enter, Shift+Enter, Esc, ↑ in an empty field, and the picker keys;
    - paste classification and the long-paste offer;
    - the file drop and the open panel;
    - the connector-input JSON editor.
    - `ExpandingTextInput`, `PastingTextView` and `PastedContent` are already there.
  - **Injected by the Mac app** (`ChatUI` cannot import them):
    - dictation (`DictationCenter` and the FluidAudio ML stack);
    - the routing accessory (`AIProvider`, `ProviderFallbackPreview`). T13 keeps it as a Mac accessory; T17 then moves it into `ChatUI` (ask #1411), with only the data readers left injected;
    - Reconnect Slack (`AppState.reconnectSlack`);
    - in-app navigation (`AgentActionDestination` → `AppState`);
    - the `save_automation` card body (`SaveAutomationCardModel`);
    - the Inbox target-button row (`ArtifactTargetButtonState`).
- **Mac look and behaviour as today (spec §2).**
  - Before a task changes a view, its first commit adds design shots of every state of that view, rendered with today's views. These are the base shots.
  - After the change, the same shot names render the `ChatUI` views. These are the HEAD shots.
  - Every pair is compared by eye, side by side. The task report lists each name as "same" or names the difference.
  - Any Mac difference is either fixed through a hook, or listed for the owner's review ask (T16 Step 1). Nothing is accepted silently.
- **Phone look kept.**
  - A phone frame that exists today renders the same at HEAD.
  - A state the phone gains through the shared view gets a new frame. Examples: comments on quotes, removable mention chips, the richer approval cards.
  - The new frames go to the owner in the same review ask. The owner's answer may hide an element on the phone through a `PhoneChatStyle` hook.
- **Copy.**
  - Every user-facing string in `ChatUI` outside `Platform/macOS` must pass `TowerWordGuardTests` ("say tower", #1783). Copy that names the host goes through `ChatHostText`.
  - A Mac-only line lives in `Platform/macOS` or is passed in by the Mac app.
- **CHAT-05.** Every new file under `Composer/` and `Parts/` is covered by the `ChatUISourceScanTests` enumeration. It has no `URLSession`, no `send(` to a client, no `enqueue`, and no script message handler. Links only open or copy, through `ChatPartActions.openURL`.
- **Guards are never weakened.**
  - A Desktop test whose view moves keeps its class name, its test names and its assertions. Only its subject changes: the `ChatUI` view, through the Mac adapter.
  - A pure-logic test moves (`git mv`) to the package that now holds the logic, with its assertions unchanged.
  - Any change that would relax a guard stops the task, and the owner is asked.

### Task T13: The composer in `ChatUI` — every Mac surface and the phone

**Depends on:** T12 merged (the umbrella at or after `39ed511`). Runs in parallel with T14.

**Behaviours the Mac has today that must survive** (each one names the test that pins it after the move):

| # | Behaviour (today's source) | Pinned by |
|---|---|---|
| C1 | Enter sends; Shift+Enter adds a line (`ExpandingTextInput`) | `ChatComposerFieldViewTests` (kept, subject switched) |
| C2 | Esc stops the turn. Main chat: `chatVM.stop()`. Embedded: `onEscape`, else `engine.stop()`. Workchat: Esc in an empty field while the agent works is Stop. | `ChatComposerFieldViewTests`, `WorkchatComposerTests.testEscapeInEmptyFieldWhileWorkingStops` (new) |
| C3 | ↑ in an empty field edits the last owner message, never while a turn runs | `ChatComposerModelPickerTests.testArrowUpEditsLastOwnerMessageOnlyWhenIdle` (new) |
| C4 | The round Send ↔ Stop button. Stop is live only when `onStop` is non-nil; the labels "Send" and "Stop"; Send is off when `sendBlocked` (unreachable or gone) | `ChatComposerFieldViewTests` |
| C5 | Send is enabled by text, or by attachments alone, or by pending quotes alone (`hasPendingContent`) | `ChatComposerFieldViewTests` |
| C6 | The field grows to `maxHeight`: about 40 % of the window in the main chat, 120 in Discuss, `density.composerMaxHeight` in embedded chats. Each surface has its own placeholder. | shots `composer-main-*`, `composer-embedded-*` |
| C7 | Dictation: the mic button and the highlight of the field being dictated into, per `dictationTargetID` (`"chat.workspace"`, each embedded surface's id); the dictation hotkey writes into the focused target | `DictationButtonTests`, `DictationHighlightTests` (kept); `ChatComposerFieldViewTests.testDictationHookGetsTargetIDAndText` (new) |
| C8 | The paperclip's help and the open panel follow the provider's capabilities (U1): text only; images and text; or everything | `ChatComposerFieldAttachmentTests` (kept) |
| C9 | Dropping file URLs attaches them. A kind the provider refuses is not added, and its reason shows. Non-file URLs are ignored. | `ChatComposerFieldAttachmentTests` |
| C10 | ⌘V of image or PDF data, or of Finder files, attaches. A refused kind shows its reason. A long text paste is inserted, then offered as a file (`LongPasteOffer`); the offer goes away once that text is edited. | `ChatComposerFieldAttachmentTests`, `PastedContentTests` |
| C11 | Attachment chips: a type icon (photo, doc.richtext, doc.text), the name truncated in the middle, and a remove button that is off while removing. Files being imported show with progress. "Sending once the files are attached…" shows while Send waits for them. | `ChatComposerFieldAttachmentTests`, shot `composer-main-attachments-importing` |
| C12 | The attachment error line (red) and the refused-kind notice (secondary) | `ChatComposerFieldAttachmentTests` |
| C13 | The status line above the field: queued with Cancel (embedded); "Applying the reply's changes…" (embedded); the "elsewhere" line; an error with the warning triangle. The main chat's error is `composer.notice ?? conversation.notice`. | `EmbeddedChatViewTests` (composer cases kept) |
| C14 | The state line (starting / unavailable + Retry / stopped + Start) above the composer | `testDaemonUnreachableKeepsDraftAndShowsRetry` (kept); shots `chat-daemon-*` |
| C15 | The `@` and `/` pickers. The list sits over the field. Up, Down, Enter, Tab and Esc go to the picker first. A mouse pick resolves the trigger at the last caret. The selected row is highlighted. A result that arrives after the text moved on is dropped. Esc suppresses the picker until the trigger changes. | `ComposerPickerModelTests` (moved, assertions kept) |
| C16 | Mention and skill chips with remove. On send, only the mentions still in the text go along (`MentionTokenizer.liveMentions`). | `ComposerPickerModelTests`, `testSendCarriesOnlyLiveMentionsAndSkill` (new) |
| C17 | The quote batch: each quote in two italic lines, with an editable comment and a remove button. The whole batch goes as one message. | `QuoteBatchViewTests` (kept, subject switched) |
| C18 | The routing accessory: the actual model, the missing capabilities, the fallback preview with its action, the routing error, and the model pill (off while busy). It refreshes on a chat change, on app activation and at a turn's end. | shots `other-provider`, `other-provider-failed`, `chat-composer-ollama-capabilities` |
| C19 | The first keystroke warms the session or makes the landing draft (`draftStarted`) | `ChatMacShellModelTests` (kept) |
| C20 | Focus requests (⌘N, a quote added, the ⌘/ panel's `autoFocus`) put the caret at the end | `ChatComposerFieldViewTests` |
| C21 | CHAT-01: the text stays until `.applied`. A refusal shows the notice and keeps the text. Text typed meanwhile stays (`remainder`). | `testChat01DraftStaysUntilApplied`, `testRefusedSendRestoresDraft`, `testBusyEchoReturnsTextToComposer` (kept) |
| C22 | Workchat: the hold caption, the stop error, the placeholder "Message the agent… (/ for commands)", and attachments to its own store with paste and drop | `WorkchatComposerTests` (kept), shot `workchat-hold-caption` |
| C23 | The ⌘/ help panel sends `screen_context`; the stored text is the typed text only | `ChatViewModelShellTests.testHelpPanelSendsScreenContext` (kept) |
| C24 | The spec review thread, the target brief and the project page use the same field | shots `spec-review-thread-replying`, `composer-target-brief`, `chat-project-page-*` |

**Writers of the same data** (unchanged by this task; the shared view writes nothing itself — it edits a binding and calls closures):
- **Main-chat draft text:**
  - `ChatComposerModel.draft`, in memory, on both devices;
  - the phone's `ChatsCenter.drafts` (kept on the phone) and its `chat_outgoing` send ledger;
  - the Mac's landing-draft id in `UserDefaults`.
- **The owner row** (`chat_messages`): the engine only (CHAT-01).
- **`chat_attachments`:** the engine only, through `attach` (the Mac by path, a paste through a 0600 temp file; the phone by sealed upload) and `attach_discard` (remove chip).
- **Embedded-chat draft:**
  - `EmbeddedChatEngine.draft`;
  - a queued message is kept in `chat_queued_drafts` (the Desktop's `EmbeddedChatStore`).
- **Workchat draft and files:** `WorkchatModel` and its own attachment store.
- **The spec review thread, the target brief and the help panel:** each its own model.
- **Dictation:** writes only into the bound text, through the Mac's `DictationCenter`.

**Failure paths and their tests:**

| Failure | Behaviour | Test |
|---|---|---|
| The host goes away mid-send (`chat.sock` drops before the echo) | Text, quotes, attachment chips and mention/skill chips stay. The resend after reconnect carries the same `client_key`. | `testHostGoneMidSendKeepsDraftQuotesAndChips` (new), `testDroppedEchoResendsWithSameKeyNoDuplicate` (kept) |
| A lost answer, then Send pressed again while the draft is unchanged (final-review M1) | The same `client_key` again: answered with the first turn, never a second turn | `testLostEchoResendReusesKeyWhileDraftUnchanged` (new) |
| A lost answer, then the draft edited before Send | A new key: it is a new message | `testEditedDraftAfterLostEchoGetsNewKey` (new) |
| An import still running when Send is pressed, and the import is refused (the provider, a missing file, or the host gone) | Send goes on with what was attached. A refused import shows its reason and its chip goes away. If the send itself is refused, the text stays. | `testSendWaitingForImportProceedsWhenImportFails` (new) |
| The chat is unreachable or stopped | Send is off, the draft is kept, and the state line shows | `testDaemonUnreachableKeepsDraftAndShowsRetry`, `testStoppedOnPurposeShowsStartAndDoesNotStartDaemon` (kept) |
| The conversation is deleted on the other device while text is typed | The "gone" state; the draft is kept; Send is off | `testConversationDeletedElsewhereShowsGoneAndKeepsDraft` (kept) |
| A picker result arrives after the text moved on | Dropped; the list follows the current text | `ComposerPickerModelTests.testStaleSearchResultIsDropped` (new, beside the moved tests) |
| A dropped or pasted kind the provider refuses | Not added; the reason shows | `ChatComposerFieldAttachmentTests` (kept) |
| A queued embedded message is cancelled | Its text comes back into the field | `EmbeddedChatEngineTests`, `EmbeddedChatViewTests` (kept) |

**Files:**
- Create in `WatchtowerChat/Sources/ChatUI/`:
  - `Composer/ChatComposerField.swift`: the one input row every surface uses. It holds no model, only a `ChatComposerFieldConfig` and closures, and the platform part draws the text view.
  - `Composer/ChatComposerBar.swift` and `ChatComposerStatus`: the status line plus the field plus the accessory.
  - `Composer/AttachmentChipsView.swift`: the chips plus `AttachmentProgress`.
  - `Composer/QuoteBatchView.swift`.
  - `Composer/ComposerPickerList.swift`: today's `MentionPicker.swift` (`MentionPicker`, `SkillPicker`) and the Mac's `ComposerPickerList` become one list, plus `ComposerChipsRow`.
  - `Composer/ComposerAttachmentRules.swift`: the pure U1 refusal rules, `kind(_:)`, `refusal(of:attach:pdf:)` and the paperclip help, moved from the Desktop's `ChatComposerFieldContent`.
  - `Models/ComposerPickerModel.swift`: moved from `WatchtowerCore/Services/Chat/`. It now works on `ChatEntityHit` and `ChatCompose.Mention` instead of Core's `MentionCandidate`.
  - `Style/ChatComposerServices.swift`: the environment value for the Mac-injected capabilities.
  - `Platform/macOS/ComposerFileInput.swift`: the drop destination and `NSOpenPanel`.
  - `Platform/iOS/ComposerFileInput.swift`: an empty modifier, so the shared view needs no `#if`. The phone's picker stays in its shell, through `onAttach`.
- Modify:
  - `Composer/ChatComposerView.swift`: the main-chat composer is rebuilt on the pieces above. It takes the Mac's behaviours C3, C14–C18, C21 and an `accessory` slot.
  - `Models/ChatComposerModel.swift`:
    - owns a `ComposerPickerModel`;
    - reuses the unanswered send's `client_key` while the draft is unchanged (M1);
    - `search(entities:)` and `skillHits` feed the picker model.
  - `Platform/macOS/ChatComposerField.swift` → `git mv` to `Platform/macOS/ChatComposerTextInput.swift`, so the basename does not clash with the shared `Composer/ChatComposerField.swift`. This file is the NSTextView part that spec §6.1 calls `ChatComposerField`. `ChatComposerTextInput` takes the C1–C3, C10, C15 and C20 parameters.
  - `Platform/iOS/ComposerTextField.swift`.
  - `Style/ChatUIStyle.swift`: the composer hooks below.
  - `WatchtowerChat/Tests/ChatUITests/ChatUISourceScanTests.swift`: `Composer/` is enumerated.
- Modify (Mac):
  - `Views/Chat/DesignKitChatStyle.swift`: the composer hooks with today's Mac look.
  - `Views/Chat/{ChatView,ChatLandingView,ProjectDetailView,HelpChatPanel}.swift`;
  - `Views/Chat/Embedded/EmbeddedChatView.swift` (`EmbeddedChatComposer`);
  - `Views/Workbench/WorkchatComposer.swift`;
  - `Views/Workbench/Asks/SpecReview/SpecReviewThreadView.swift`;
  - `Views/Targets/TargetDetailView.swift`;
  - `ViewModels/ChatViewModel.swift`: the picker moves into `ChatComposerModel`. `chatVM.picker` goes; `sendDraft` reads the model's picker.
  - `App/` or the root view that sets `.environment(\.chatComposerServices, …)` with dictation.
- Create (Mac): `Views/Chat/ChatComposerAccessory.swift`. It is today's `routingState` plus `ChatModelPicker`, moved out of the deleted `ChatComposerView.swift`. `ChatModelPicker` stays the Mac's: `CodeQuestionPopover` and `QuestionsView` use it too. (This is an interim state: T17 replaces it with `ChatUI`'s routing accessory and pill. T13 moves it unchanged.)
- Modify (phone):
  - `Features/Chats/PhoneChatStyle.swift`: the composer hooks with today's phone look.
  - `Features/Chats/ChatConversationView.swift`: the attachment pills become `AttachmentChipsView` chips with the phone's upload state. The `accessory` pills are removed.
- Delete (Mac): `Views/Chat/{ChatComposerView,ChatComposerBar,ChatComposerField,AttachmentChipsView,MentionPicker,QuoteBatchView}.swift` and `WatchtowerCore/Services/Chat/ComposerPickerModel.swift`. `MentionCandidate` goes too once nothing uses it; grep first.
- Tests:
  - move `Tests/Core/ComposerPickerModelTests.swift` → `WatchtowerChat/Tests/ChatUITests/ComposerPickerModelTests.swift` (`git mv`; the assertions are kept, the types are adapted);
  - keep `ChatComposerFieldViewTests`, `ChatComposerFieldAttachmentTests`, `QuoteBatchViewTests`, `WorkchatComposerTests` and `EmbeddedChatViewTests` in `WatchtowerDesktop/Tests`, inspecting the `ChatUI` views (the `ChatUIMacRowTests` precedent);
  - create `WatchtowerChat/Tests/ChatUITests/ChatComposerModelPickerTests.swift`.
- Shots:
  - `Tests/DesignShots/DesignShotFixtures+Composer.swift` (new) and `DesignShotCatalog.swift`;
  - `WatchtowerMobile/Tests/ScreenshotTourTests.swift` (new phone frames).

**Interfaces:**
- Consumes:
  - T7's `ChatComposerModel`, `ChatConversationModel`, `ChatStateLine`, `ChatUIStyle` and `ChatHostText`;
  - `WatchtowerChatText`'s `MentionTokenizer` (`ComposerPickerKey`, `ComposerKeyResult`) and `ChatQuoteDraft`;
  - `ChatWire`'s `ChatEntityHit`, `ChatSkill`, `ChatCompose.Mention` and `ChatAttachmentLimits`.
- Produces (`ChatUI`, public):
  ```swift
  public struct ChatComposerFieldConfig {
      public var placeholder: String
      public var maxHeight: CGFloat = 120
      public var dictationTargetID: String?          // nil: no mic
      public var attachUnavailableReason: String?    // U1
      public var pdfUnavailableReason: String?
      public var hasPendingContent = false
      public var autoFocus = false
      public var focusRequest: UUID?
      public var sendBlocked = false
  }
  public struct ChatComposerField: View {
      public init(text: Binding<String>, isStreaming: Bool, config: ChatComposerFieldConfig,
                  onSend: @escaping () -> Void, onStop: (() -> Void)? = nil,
                  onEscape: (() -> Void)? = nil, onArrowUpWhenEmpty: (() -> Void)? = nil,
                  attachments: [ChatComposerAttachment] = [], attachmentProgress: AttachmentProgress = .init(),
                  attachmentError: String? = nil,
                  onAttachFiles: (([URL]) -> Void)? = nil,              // nil: no paperclip, no drop
                  onPasteData: ((Data, String) async -> Bool)? = nil,   // nil: ⌘V inserts text
                  onRemoveAttachment: ((Int64) -> Void)? = nil,
                  onRetryAttachment: ((Int64) -> Void)? = nil,          // the phone's refused upload
                  onCursorChange: ((String, Int) -> Void)? = nil,
                  onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)? = nil)
  }
  public enum ChatComposerStatus: Equatable { case queued, error(String), finishing, elsewhere(String) }
  public struct ChatComposerBar<Accessory: View>: View {
      public init(status: ChatComposerStatus?, onCancelQueued: @escaping () -> Void = {},
                  input: ChatComposerField, @ViewBuilder accessory: () -> Accessory)
  }
  public struct AttachmentProgress: Equatable {
      public var importing: [String]; public var removing: Set<Int64>; public var sendWaits: Bool
      public var failed: Set<Int64>                                     // the phone's refused uploads (Retry)
  }
  public struct ChatComposerServices {                                  // environment \.chatComposerServices
      /// Wraps the field with the Mac's dictation (button + highlight); nil draws the field alone.
      public var dictation: ((_ field: AnyView, _ text: Binding<String>, _ targetID: String) -> AnyView)?
  }
  // ChatUIStyle, new hooks (defaults = the phone's look today):
  //   func composerFieldBackground(_ field: AnyView) -> AnyView
  //   func sendStopButton(isStreaming: Bool, active: Bool, action: @escaping () -> Void) -> AnyView
  //   func attachmentChip(_ chip: ChatAttachmentChipContent) -> AnyView
  //   func composerChip(_ chip: ChatComposerChipContent) -> AnyView      // mention / skill, with remove
  //   func quoteRow(_ quote: ChatQuoteDraft, comment: Binding<String>, onRemove: @escaping () -> Void) -> AnyView
  //   func pickerList(_ rows: [ComposerPickerItem], selected: Int, onPick: @escaping (Int) -> Void) -> AnyView
  public struct ChatComposerView: View {
      public init(model: ChatComposerModel, field: ChatComposerFieldConfig,
                  onAttach: (() -> Void)? = nil, accessory: AnyView? = nil,
                  onAttachFiles: (([URL]) -> Void)? = nil, onPasteData: ((Data, String) async -> Bool)? = nil)
  }
  // ChatComposerModel gains: public let picker: ComposerPickerModel; public func beginEditingLast();
  // the unanswered send's client_key is reused while draft, quotes, attachments, mentions and skill are unchanged.
  ```

- [ ] **Step 1: Base shots** (first commit, no view change). Add `DesignShotFixtures+Composer.swift`, which renders today's Desktop views under these names, light and dark:
  - `composer-main-empty`, `composer-main-typing`, `composer-main-streaming`, `composer-main-narrow`;
  - `composer-main-attachments`, `composer-main-attachments-importing`, `composer-main-attachment-error`, `composer-main-refused-kind`;
  - `composer-main-long-paste`, `composer-main-quotes`;
  - `composer-main-mention-picker`, `composer-main-skill-picker`, `composer-main-chips`;
  - `composer-main-notice`, `composer-main-editing`, `composer-main-dictation-active`;
  - `composer-embedded-queued`, `composer-embedded-finishing`, `composer-embedded-error`;
  - `composer-help-panel`, `composer-target-brief`, `composer-workchat-attachments`.

  Then render `make desktop-shots DESKTOP_SHOTS=build/t13-base` and `make mobile-shots SHOTS_ONLY=chat SHOTS_DIR=build/t13-base-phone`. The existing `chat-daemon-*`, `other-provider*`, `chat-composer-ollama-capabilities`, `workchat-hold-caption`, `spec-review-thread-replying`, `chat-project-page-*`, `embedded-chat-*` and phone `C2a`–`C2i`, `C3a` are in the base set too. Commit: `test(shots): composer base shots before the ChatUI move (#1822 T13)`.
- [ ] **Step 2: Failing tests.**
  - `ChatComposerModelPickerTests` (ChatUI, `FakeChatClient`, no clock waits):
    - `testArrowUpEditsLastOwnerMessageOnlyWhenIdle`: with a turn running, `beginEditingLast()` leaves `editing == nil` and the draft unchanged; when idle, `editing` is the last owner message's id and the draft is its body.
    - `testSendCarriesOnlyLiveMentionsAndSkill`: pick two mentions and delete one's `@Label` from the text, then send → `compose.mentions` holds the remaining one; `compose.skill` is the picked skill; after `.applied` the picker's mentions and skill are empty.
    - `testPickerKeysGoToPickerFirst`: picker open, `.down` then `.enter` → `consumed == true` and the second row is inserted; picker closed → `.enter` is not consumed.
    - `testHostGoneMidSendKeepsDraftQuotesAndChips`: the client throws a connection error on `send` → the draft, the quotes, the attachments, `picker.mentions` and `picker.skill` are unchanged, and `notice` is set.
    - `testLostEchoResendReusesKeyWhileDraftUnchanged`: the first send throws after it went out, the second `send()` with the same draft → both recorded `chat_turn` ops have the same `clientKey`.
    - `testEditedDraftAfterLostEchoGetsNewKey`: as above, but the draft is edited in between → the keys differ.
    - `testSendWaitingForImportProceedsWhenImportFails`: an `attach` is pending, `send()` waits (`isWaitingForAttachments == true`); the `attach` echo is `.refused` → the send goes on with `attachmentIDs == []`; `importing` is empty; `notice` names the refused file.
  - `ComposerPickerModelTests` (moved): every existing test passes on the ChatUI types. New `testStaleSearchResultIsDropped`: a search answering after the text changed leaves `items` as the newer search set them.
  - Desktop (ViewInspector over `ChatUI.ChatComposerField`, `ChatUI.QuoteBatchView` and `ChatUI.ChatComposerBar`):
    - `ChatComposerFieldViewTests`, `ChatComposerFieldAttachmentTests`, `QuoteBatchViewTests`, `EmbeddedChatViewTests` and `WorkchatComposerTests` switch their subject. Each keeps its test names and assertions.
    - New `ChatComposerFieldViewTests.testDictationHookGetsTargetIDAndText`: a `ChatComposerServices.dictation` stub receives `"chat.workspace"`, and its binding writes into the draft. With `dictationTargetID == nil` it is never called.
    - New `WorkchatComposerTests.testEscapeInEmptyFieldWhileWorkingStops`: the stop closure fires once; with text in the field it does not fire.
  - Phone (`make mobile-test`):
    - `ChatSendTests`, `ChatSendRecoveryTests`, `ChatApprovalWiringTests` and `ChatAttachmentAndCopyTests` are unchanged;
    - new `ChatAttachmentAndCopyTests.testDraftFilesRenderAsSharedChipsWithUploadState`: an uploading file → a chip with progress and remove off; a failed one → Retry calls `center.retryAttachment`.
- [ ] **Step 3: Run them.** `make chat-test FILTER='ChatComposerModelPickerTests|ComposerPickerModelTests'` and `make test-swift FILTER='ChatComposerField|QuoteBatchView|WorkchatComposer|EmbeddedChatView'`. Expected: FAIL.
- [ ] **Step 4: Implement.**
  - Build the `ChatUI` pieces. Rebuild `ChatComposerView` on them.
  - Add the hooks to `DesignKitChatStyle`, drawing today's Mac look: the 18 pt rounded field on `textBackgroundColor`, the 24 pt round Send/Stop button, the capsule chips, the accent mention chips, the `controlBackgroundColor` quote rows and the bordered picker list.
  - Add the hooks to `PhoneChatStyle`, drawing today's phone look.
  - Switch every Mac surface named in Files and the phone conversation screen. Set `\.chatComposerServices` at the app root with the `DictationButton` + `dictationHighlight` closure.
  - Delete the Desktop files.
- [ ] **Step 5: HEAD shots and comparison.**
  - Run `make desktop-shots DESKTOP_SHOTS=build/t13-head` and `make mobile-shots SHOTS_ONLY=chat SHOTS_DIR=build/t13-head-phone`.
  - Compare each name with its base.
    - Expected: every Mac name is the same.
    - Every existing phone frame is the same.
    - The new phone frames `iphone-chat-composer-quotes`, `iphone-chat-composer-mentions` and `iphone-chat-composer-attachments` (add them in `testTheChatShots`) show the states the phone gains. They go to T16's review ask.
  - Fix any Mac difference through its hook before hand-back.
- [ ] **Step 6: Run the tests and the guards.**
  - `make chat-test`
  - `make chattext-test`
  - `make test-swift FILTER='Chat|Composer|QuoteBatch|Workchat|Embedded|Dictation|PastedContent|HelpChat|TargetComposer|SpecReview|PublicAPISurface|ArtifactChat05|LIVE01'`
  - `make kit-test FILTER=SeamBoundaryTests`
  - `make mobile-test MOBILE_FILTER='TowerTextTests|TowerWordGuardTests|ChatSendTests|ChatSendRecoveryTests|ChatApprovalWiringTests|ChatAttachmentAndCopyTests|RelayChatClientTests|ChatsGateModelTests'`
  - `make lint-swift`
  - `bash scripts/tests/test-kit-lint-guard.sh`
  - CHAT-01/05/06 Swift guards are inside `make chat-test`: `ChatConversationModelTests`, `ChatUISourceScanTests` and `ChatPartRegistryTests`.
  - No Go changes; `make lint-diff` stays clean.
- [ ] **Step 7: Inventory.** In `docs/inventory/chat.md`:
  - a changelog line: the composer moved to `ChatUI`, no guard relaxed or renamed, `ComposerPickerModelTests` moved with its assertions, the CHAT-05 scan covers `Composer/`;
  - CHAT-01's guard list gains `testHostGoneMidSendKeepsDraftQuotesAndChips` and `testLostEchoResendReusesKeyWhileDraftUnchanged`.
- [ ] **Step 8: Commit.** `refactor(chat): one composer in ChatUI for the Mac and the iPhone (#1822 T13, ask #1409)`

---

### Task T14: Approval data on both devices (Go payload + one action model in `ChatWire`)

**Depends on:** T12 merged. Runs in parallel with T13.

**Why:** the Mac card reads the whole `agent_actions` row. The phone's `approval` part carries only `id`, `tool`, `title`, `args_display`, `args_sha256`, `status` and `reason`. One card needs one action model, and the phone's payload needs the fields the card reads. The per-tool logic is Foundation-only and lives in Core today (`SlackSendProposal`, `ConnectorCallProposal`, `ReactionToolCatalog`, `AgentActionDestination`, the summary lines). It moves to `ChatWire`, which Core and `ChatUI` both import, so the tool names and the summaries exist once.

**Writers of the same data** (`agent_actions`), all unchanged:
- **Proposals:** `Registry.Propose`, called by `ai session` / MCP chat tools, automation runs and reactions.
- **Status transitions:** `Registry` only.
  - The Mac goes through `watchtower actions approve|reject|apply|dismiss` (`AgentActionFeed`, owner-confirm, AGENT-07), from chat cards, the Inbox, the target chat, the automation editor and Inbox row actions.
  - The phone goes through the hub's `chat_action_answer` (`Registry.ApproveSeen` with the shown `args_sha256`, or `Reject`).
  - A session-applied call is run and finished by its own chat session.
- **The engine** only reads `agent_actions` into the feed. The card writes nothing.

**Files:**
- Modify (Go):
  - `internal/chatengine/feed.go`:
    - `FeedAction` gains `External bool \`json:"external"\``, `Error string \`json:"error,omitempty"\``, `Result map[string]string \`json:"result,omitempty"\``, `TurnID string \`json:"turn_id,omitempty"\`` (today unexported `turnID`) and `ArgsComplete bool \`json:"args_complete"\``.
    - `chatFeedActionsTx` reads `external`, `error` and `result_json`.
    - The result is cut down to the keys the card shows: `url`, `label`, `key`, `target_id`, `board_name`, `version` and `warning`, each value clipped to 512 bytes.
  - `internal/chatengine/parts.go`: `approvalPart` copies the new fields into the payload; the fallback text is unchanged.
  - `internal/chatengine/testdata/parts.json`: the `approval` sample carries the new fields.
- Create (Swift, `WatchtowerChat/Sources/ChatWire/Actions/`):
  - `ChatAgentAction.swift`: one action model for both devices.
  - Moved from `WatchtowerCore/Services/Actions/` (`git mv`, `package` → `public`, `AgentAction` → `ChatAgentAction`): `SlackSendProposal.swift`, `ConnectorCallProposal.swift`, `AgentActionDestination.swift` (+ `SlackMessageRef`), `ActionToolCatalog.swift` (the `ReactionToolInfo` table and `title(for:)`, from `ReactionToolCatalog.swift`), `ActionSummaryLines.swift` (`summaryLines(for:)` and its Jira, Linear, wave-two, dismiss-tracks, Slack and Confluence helpers, out of `AgentActionCardView*.swift`), `ConfluenceEditProposal.swift` (the `ConfluenceEdit` model and `ConfluenceEditMemo`) and `DecodeCounter.swift`.
- Modify (Core):
  - `WatchtowerCore/Models/AgentAction.swift` becomes `package typealias AgentAction = ChatAgentAction` plus `extension ChatAgentAction: FetchableRecord { init(row:) }`, so one model is used;
  - `ReactionToolCatalog.swift` keeps `ReactionDictionaryTools` and reads the titles from `ActionToolCatalog` (no copy);
  - every Core caller compiles on the moved types: `AgentActionFeed`, `AgentActionQueries`, `WorkbenchQueries+Activity`, `AppState+Chat` and `InboxRowActionsView`.
- Tests:
  - `git mv` `Tests/Core/{SlackSendProposalTests,ConnectorCallProposalTests,AgentActionDestinationTests,AgentActionCardLabelTests}.swift` to `WatchtowerChat/Tests/ChatWireTests/`, assertions unchanged;
  - `ReactionToolCatalogTests` stays in Core (it pins the facade);
  - create `WatchtowerChat/Tests/ChatWireTests/ChatAgentActionTests.swift`.

**Interfaces:**
- Produces (`ChatWire`, public):
  ```swift
  public struct ChatAgentAction: Identifiable, Equatable, Sendable {
      public let id: Int64, tool: String, external: Bool, argsJSON: String, argsSHA256: String
      public let argsComplete: Bool        // false: args_display was clipped; editors and the Confluence diff are off
      public let reason: String, surface: String, conversationID: Int64, contextType: String, contextID: String
      public let turnID: String, status: String, trustAtCreate: String, resultJSON: String, error: String
      public let createdAt: String, decidedAt: String, appliedAt: String, dismissedAt: String
      public init(payload: ChatApprovalPayload)     // the phone, and a Mac card whose row is not loaded yet
      // isPending, isTerminal, isExecuting, canRetry, isSessionApplied, args, result, argString, resultString,
      // resultWebURL, destination, sourceMessageURL: moved with their bodies unchanged
  }
  ```
  `ChatApprovalPayload` gains `external`, `error`, `result`, `turnID` and `argsComplete`, decoded with defaults, so a payload without them, from a daemon one version behind, still decodes (D22).

- [ ] **Step 1: Failing Go tests** (`internal/chatengine`).
  - `TestChatengine_FeedActionCarriesCardFields`: a row with `external=1`, `error='boom'`, `result_json` `{"url":"https://example.com/acme-1","label":"ACME-1","warning":"mirror failed"}` and a turn id → `External`, `Error`, `Result["url"]`, `Result["label"]`, `Result["warning"]` and `TurnID` are set.
  - `TestChatengine_FeedActionResultKeepsOnlyCardKeys`: `result_json` with an extra `token` key and a 4 KB `label` → no `token`; `label` is at most 512 bytes.
  - `TestChatengine_FeedActionArgsCompleteFalseWhenClipped`: args over `maxActionArgsBytes` → `ArgsComplete == false`; small args → `true`.
  - `TestCHAT06_EveryPartKindHasFallback` and `TestChat05_FallbackActionsOnlyOpenCopyOrFixedTurn` (kept) pass on the new `parts.json`.
- [ ] **Step 2: Failing Swift tests.**
  - `ChatAgentActionTests.testFromPayloadMapsEveryField`: every payload field → its property; absent new fields → `external == false`, `error == ""`, `resultJSON == ""`, `argsComplete == false`.
  - `ChatAgentActionTests.testClippedArgsYieldNoEditableProposal`: `argsComplete == false` and a Slack tool → `SlackSendProposal(action:)` is still read for display, but `editable == false`.
  - `ChatPartPayloadsTests.testApprovalPayloadDecodesCardFields` (ChatUI, new file): the `parts.json` approval sample decodes every new field.
  - `AgentActionChatMappingTests.testRowInitReadsEveryColumn` (Desktop Core, a GRDB row fixture): every column → `ChatAgentAction`.
  - The moved tests pass unchanged.
- [ ] **Step 3: Run them.** `go test ./internal/chatengine -run 'FeedAction|CHAT06|Chat05'`, `make chat-test FILTER='ChatAgentActionTests|ChatPartPayloadsTests'` and `make test-swift FILTER=AgentActionChatMappingTests`. Expected: FAIL.
- [ ] **Step 4: Implement** the Go fields, the payload and the Swift move.
- [ ] **Step 5: Run the tests and the guards.**
  - `go test ./internal/chatengine ./internal/chatstore -run 'Chat|CHAT|LIVE01|Lease|Feed|Parts'`
  - `go test ./internal/hub/... -run 'Chat|Contract|Fixture'`: the feed record still fits its cap with the new fields; `TestChatActionAnswer_*` is unchanged.
  - `make lint-diff`
  - `make chat-test`
  - `make test-swift FILTER='AgentAction|SlackSend|ConnectorCall|ReactionToolCatalog|SaveAutomation|Approval01|NeedsApproval|InboxRefStateApprovals|PublicAPISurface'`
  - `make kit-test FILTER=SeamBoundaryTests`
  - `make mobile-test MOBILE_FILTER='ChatApprovalWiringTests|RelayChatClientTests|ChatWireKitConformancesTests'`
  - `make lint-swift`
- [ ] **Step 6: Inventory.**
  - `docs/inventory/README.md`: the Agent actions row names `WatchtowerChat/Sources/ChatWire/Actions/` beside `WatchtowerCore/Services/Actions/`.
  - `docs/inventory/agent-actions.md` changelog: the action model and the per-tool card logic moved to `ChatWire`. AGENT-01..07 are unchanged; `testApprovePinsTheShownArgsDigest` stays in `AgentActionFeedTests`.
- [ ] **Step 7: Commit.** `feat(chat): one agent-action model in ChatWire; the approval part carries the card's fields (#1822 T14, ask #1409)`

---

### Task T15: The approval card in `ChatUI` — chat, Inbox, target chat, automation editor and the phone

**Depends on:** T14. It may run beside T13 (see "Lanes and order").

**Behaviours the Mac card has today that must survive** (`AgentActionCardView*.swift`, `ChatThreadView.agentActionCard`). The guard of each:

| # | Behaviour | Pinned by |
|---|---|---|
| A1 | The title from the one tool-name catalog. The header icon: external vs checklist. The status label: "Awaiting your approval", "Approved", "Executing…", "Done", "Rejected", "Failed", and the session-call labels. | `AgentActionCardViewTests` (kept), `AgentActionCardLabelTests` (moved in T14) |
| A2 | The context label (an automation run): a link when it can be opened, else plain text | `AgentActionCardViewTests` |
| A3 | The per-tool body: the `save_automation` details (a Mac hook); a connector call with Edit Input / Revert (JSON editor); the Slack recipient line and text; the pending Slack editor with the workspace pick; the summary lines (target, Jira create and the four Jira writes, Linear, wave-two, dismiss tracks); else the raw args | `AgentActionCardViewTests`, `SaveAutomationCardModelTests`, `ConnectorCallProposalTests`, `SlackSendProposalTests` |
| A4 | The Confluence edit: the diff of its changes, decoded once (a render never re-decodes, `argsDecodes`); applied → "Saved as version N"; the version-checked retry note | `AgentActionCardViewConfluenceTests`, `…ConfluencePreviewTests`, `…ConfluenceLinkTests` (kept) |
| A5 | The proposal's reason (italic), the row's error unless the status label already says it, and the failed-external retry note | `AgentActionCardViewTests` |
| A6 | The outcome: an http/https result link only; "Task #N created"; "Board X connected"; the orange warning | `AgentActionCardViewTests`, `AgentActionDestinationTests` |
| A7 | In-app **Open →** (`onOpen`), and **Slack message ↗** for a reaction's source | `AgentActionDestinationTests`, `InboxReadingPaneTests` |
| A8 | The gesture error (red, selectable). It is hidden once the row is terminal or when the row's own error says the same; the `tracks start` failure is kept. After a failed approve, Approve becomes Retry. | `AgentActionCardViewTests`, `testGestureErrorHiddenOnceRowSettles` (new) |
| A9 | Reconnect Slack, on a token without the send grant: progress, then the result line | `AgentActionCardViewTests` |
| A10 | The decision row. Executing → spinner (none for a session call whose session is gone). Pending → Approve, or "Approve & send" (off until the text and the pick are valid), or the connector's plain or edited Approve, or the unreadable-connector note; plus Reject. Settled → Retry (`offersRetry`), or Dismiss with its note. In flight → spinner and the row off. | `AgentActionCardViewTests`, `AgentActionFeedTests` |
| A11 | The Inbox target button: stuck → "Didn't finish" + Try again; creating → progress | `AgentActionCardStuckTargetTests` (kept), shot `approval-card-target-stuck` |
| A12 | A session call whose chat session ended: "Chat session ended", no Approve | `ConnectorCallProposalTests`, `AgentActionCardViewTests` |
| A13 | Approve pins the args shown (`--args-sha256`, AGENT-07). Edits go as `--patch`. An edit that cannot be encoded is reported, never dropped. | `AgentActionFeedTests.testApprovePinsTheShownArgsDigest` (kept), `testApproveWithChangedArgsShowsRefusalOnRow` (kept) |
| A14 | In the chat: a card the running turn waits on is outlined; **Approve all** under a reply with two or more bulk-approvable cards; cards of an interrupted turn in the feed footer; the reviewed actions under a quota-stopped reply | `ChatUIMacRowTests` (new cases below), `testApproveAllPendingForTurn` (kept) |
| A15 | The look: an accent 0.06 background, radius 10, padding 10 | shots below |
| P1–P5 | The phone: buttons only with the `permissions` grant, else the "approve elsewhere" line with the host's name; the answer-in-flight line; "The action changed — look again"; off while offline; the settled outcome; orange only while waiting | `ChatApprovalWiringTests` (kept), shots `C2c`, `iphone-chat-approval-slack` |

**Placement:**
- In `ChatUI`, shared:
  - the card, its header, body, outcome, links, gesture-error rule and decision row;
  - the Slack recipient line, the Slack editor and the workspace pick;
  - the Confluence diff;
  - the awaited outline;
  - **Approve all**.
- In `ChatUI/Platform/macOS`: the connector input's `PlainJSONEditor` (NSTextView). On iOS the connector input is read-only text.
- Injected by the Mac (`ChatApprovalServices`): Reconnect Slack, in-app Open, the `save_automation` body, the Inbox target-button row, Dismiss, Retry/apply, the reviewed-actions accessory, and the decision itself (CLI `actions …`).
- The phone injects only the decision (hub `chat_action_answer`) and its state line.
- **A capability that is nil hides its control:**
  - `approveEdited` is nil on the phone, because the relay answer has no patch. So the Slack editor, the workspace pick and Edit Input do not show on the phone. This is a v1 limit the owner confirmed in ask #1411.
  - `approveAll`, `dismiss` and `retry` are nil on the phone. This is a v1 limit the owner confirmed in ask #1411; T16 records it.

**Writers:** as in T14. The card calls only the injected `decide`/`retry`/`dismiss`/`approveAll` closures. On the Mac they are `AgentActionFeed` (the CLI with owner-confirm); on the phone, `RelayChatClient.decide` (`chat_action_answer`). There is no new writer, and no approval verb on `chat.sock` (D12).

**Failure paths and their tests:**

| Failure | Behaviour | Test |
|---|---|---|
| A lost answer on the Mac (the CLI died, the owner-confirm window was denied or timed out) | `AgentActionFeed.rowErrors` → the gesture error and Retry on the card; the row observation shows the real status, and the error hides once the row settles | `testGestureErrorHiddenOnceRowSettles` (new, Desktop), `AgentActionFeedTests` (kept) |
| A lost answer on the phone (the relay dropped after the answer went) | "answer on its way" until the feed shows the row's status; a repeated approve is answered "Already approved", never run twice | `ChatApprovalWiringTests` (kept), `TestChatActionAnswer_RepeatedApproveAnswersAlreadyApproved` (add in `internal/hub/actions/handlers` if absent) |
| The host goes away while a card is shown: the Mac's `chat.sock` drops | The Mac card stays live: Mac approvals go through the CLI, not `chat.sock` (D12) | `testMacApprovalLiveWhileChatUnreachable` (new, `ChatUIMacRowTests`) |
| The host goes away on the phone (offline) | Buttons off, the card kept, the line shown | `ChatApprovalWiringTests` (kept), `testApprovalOfflineDisablesButtonsKeepsCard` (new, ChatUI) |
| The args changed after they were shown | The approve is refused by the digest: the Mac shows the refusal on the row, the phone "The action changed — look again" | `testApproveWithChangedArgsShowsRefusalOnRow` (kept), `ChatApprovalWiringTests` (kept) |
| The row settles elsewhere while the Slack text is being edited | The editor goes away with the pending state, and the edits are dropped; no approve with stale args | `testSlackEditDroppedWhenRowSettlesElsewhere` (new, Desktop) |
| An approval part whose Mac row is not loaded yet (or is gone) | The card is drawn from the payload (`ChatAgentAction(payload:)`) with the decision row from the services; the card never disappears | `testApprovalPartWithoutMacRowDrawsFromPayload` (new, `ChatUIMacRowTests`) |
| Clipped args on the phone (`argsComplete == false`) | No editor and no Confluence diff; the summary lines or raw args are shown; Approve still pins `args_sha256` | `testClippedArgsHideEditorsAndDiff` (new, ChatUI) |
| Reconnect Slack fails | "Reconnect failed: …" on the card | `AgentActionCardViewTests` (kept) |

**Files:**
- Create in `WatchtowerChat/Sources/ChatUI/Parts/Approval/`:
  - `AgentActionCard.swift`: header, body, reason, outcome, links, errors, retry note;
  - `AgentActionCard+Decision.swift`;
  - `AgentActionCard+Slack.swift`: `SlackRecipientLine`, `SlackSendEditor`;
  - `AgentActionCard+Confluence.swift`: `ConfluenceEditChangesView`;
  - `AgentActionCard+Connector.swift`: `ConnectorCallDetails`;
  - `ApprovalServices.swift`;
  - `ApproveAllRow.swift`.
- Create: `ChatUI/Platform/macOS/ConnectorInputEditor.swift` and `ChatUI/Platform/iOS/ConnectorInputEditor.swift` (read-only).
- Modify:
  - `Parts/ApprovalPartView.swift`: it draws `AgentActionCard` from `services.resolve(payload) ?? ChatAgentAction(payload:)`;
  - delete `Parts/ApprovalPartView+{Slack,Confluence,Connector,Decision}.swift`, absorbed into the card. Their ChatUI tests (`ChatUIPhoneParityTests` and others) move to `AgentActionCardModelTests` with their assertions kept;
  - `Registry/ChatPartContext.swift`: `ChatPartActions.decide`, `approvalCard` and `approvalState` are replaced by `approvals: ChatApprovalServices`;
  - `Feed/ChatFeedView.swift` and `Feed/ChatFeedLayout.swift`: the awaited outline from `turnID == runningTurnID`, and **Approve all** under a reply;
  - `Style/ChatUIStyle.swift`: `func approvalCard(_ content: AnyView, outlined: Bool) -> AnyView`; the default is the phone's card look.
- Modify (Mac):
  - `Views/Chat/DesignKitChatStyle.swift`: `approvalCard` with A15's look;
  - `Views/Chat/ChatThreadView.swift`: the services from `chatVM.actionFeed`; `messageAccessory` keeps only the reviewed actions;
  - `Views/Inbox/ActionStripView.swift`, `Views/Targets/TargetChatView.swift` (both cards) and `Views/Automations/AutomationEditorPanel.swift`: each draws `MacAgentActionCard`.
- Create (Mac): `Views/Actions/MacAgentActionCard.swift`. A thin adapter with no layout of its own: `AgentAction` + `AgentActionFeed` + `AppState` → `ChatUI.AgentActionCard` with `ChatApprovalServices`. It keeps today's `AgentActionCardView` parameters, so the call sites change only their type name.
- Delete (Mac): `Views/Chat/AgentActionCardView{,+Confluence,+Connector,+Decision,+Slack}.swift`. `SaveAutomationCardDetails` moves to `Views/Automations/SaveAutomationCardDetails.swift` (the injected body).
- Modify (phone):
  - `Features/Chats/ChatConversationView.swift`: `approvals: ChatApprovalServices` from `RelayChatClient` and `ChatApprovalCardModel.state`;
  - `PhoneChatStyle.swift`: `approvalCard` with today's phone card.
- Tests:
  - the Desktop `AgentActionCardView*Tests`, `AgentActionCardStuckTargetTests`, `InboxReadingPaneTests` and `InboxMessagePaneTests` switch their subject to `MacAgentActionCard`. Test names and assertions are kept.
  - new cases in `ChatUIMacRowTests`;
  - new `WatchtowerChat/Tests/ChatUITests/AgentActionCardModelTests.swift`.
- Shots: `Tests/DesignShots/DesignShotFixtures+ApprovalCards.swift` (new) and `ScreenshotTourTests.swift`.

**Interfaces:**
- Consumes: T14's `ChatAgentAction` and the moved proposals; T7's `ChatPartContext` and `ChatHostText`.
- Produces (`ChatUI`, public):
  ```swift
  public enum ChatApprovalAnswer: Equatable, Sendable { case approve(patch: String?), reject }
  public struct ChatApprovalServices {
      public var resolve: ((ChatApprovalPayload) -> ChatAgentAction?)?     // Mac: the feed's row; nil: from the payload
      public var decide: (ChatAgentAction, ChatApprovalAnswer) -> Void     // gets the snapshot it showed (A13)
      public var state: ((ChatAgentAction) -> ChatApprovalState?)?         // in flight, gesture error, grant, line
      public var approveEdited: Bool = false                               // the Slack editor and Edit Input
      public var retry: ((ChatAgentAction) -> Void)?
      public var dismiss: ((ChatAgentAction) -> Void)?
      public var approveAll: ((_ turnID: String) -> Void)?
      public var reconnectSlack: ((Int64) async -> String?)?
      public var openDestination: ((AgentActionDestination) -> Void)?
      public var sessionHoldsCall: ((ChatAgentAction) -> Bool)?
      public var details: ((ChatAgentAction) -> AnyView?)?                 // Mac: save_automation
      public var decisionOverride: ((ChatAgentAction) -> AnyView?)?        // Mac: the Inbox target-button row
  }
  public struct AgentActionCard: View {
      public init(action: ChatAgentAction, services: ChatApprovalServices, contextLabel: String? = nil,
                  onOpenContext: (() -> Void)? = nil, outlined: Bool = false, offersRetry: Bool = true)
  }
  // ChatApprovalState gains: public let inFlight: Bool; public let gestureError: String?; public let approveFailed: Bool
  ```

- [ ] **Step 1: Base shots** (first commit, no view change). Add `DesignShotFixtures+ApprovalCards.swift`, which renders today's `AgentActionCardView` under these names:
  - `approval-plain-pending`, `approval-jira-pending`, `approval-linear-pending`;
  - `approval-slack-pending-edit`, `approval-slack-workspace-pick`, `approval-slack-reconnect`;
  - `approval-confluence-diff`, `approval-confluence-applied`;
  - `approval-connector-pending`, `approval-connector-editing`, `approval-connector-session-ended`, `approval-connector-dismiss`;
  - `approval-executing`, `approval-in-flight`, `approval-applied-link-warning`, `approval-failed-retry-note`, `approval-gesture-error`, `approval-rejected`;
  - `approval-context-label`, `approval-save-automation`;
  - `approval-chat-awaited-outline`, `approval-chat-approve-all`, `approval-chat-interrupted-turn`.

  The existing `approval-card-target-stuck`, `inbox-chat-decision-card`, `inbox-b-approvals-*`, `needs-approval`, `automation-editor-review` and phone `C2c` and `iphone-chat-approval-slack` are in the base set. Render `make desktop-shots DESKTOP_SHOTS=build/t15-base` and `make mobile-shots SHOTS_ONLY=chat SHOTS_DIR=build/t15-base-phone`. Commit: `test(shots): approval card base shots before the ChatUI move (#1822 T15)`.
- [ ] **Step 2: Failing tests.**
  - `AgentActionCardModelTests` (ChatUI, pure: the card's decisions are computed in static functions, the `pendingApproval`/`settledOffer`/`targetRow` precedent):
    - `testApprovalOfflineDisablesButtonsKeepsCard`: state `canAnswer == false` → the decision is `.disabled`, the body is unchanged.
    - `testClippedArgsHideEditorsAndDiff`: `argsComplete == false` → `editsSlack == false`, `confluenceEdit == nil`, `connectorEditable == false`.
    - `testApproveCarriesTheShownSnapshot`: `decide` receives the exact `ChatAgentAction` the card was built with (its `argsJSON` and `argsSHA256`).
    - `testNilCapabilityHidesItsControl`: `approveEdited == false`, `retry == nil`, `dismiss == nil` and `reconnectSlack == nil` → no editor, no Retry, no Dismiss and no Reconnect, on a row that would offer each.
    - `testAwaitedOutlineFollowsRunningTurn`: pending and `turnID == runningTurnID` → outlined; otherwise not.
  - Desktop (`ChatUIMacRowTests`, ViewInspector):
    - `testMacApprovalLiveWhileChatUnreachable`: reachability `.unavailable` → Approve on a pending card is enabled and calls `AgentActionFeed.approve`.
    - `testApprovalPartWithoutMacRowDrawsFromPayload`: no feed row for the payload's id → the card shows the payload's title and status.
    - `testApproveAllShowsForTwoBulkApprovable`: one card → no button; two → **Approve all** calls `approveAllPending(forTurn:)`.
  - Desktop (`AgentActionCardViewTests`, subject `MacAgentActionCard`):
    - `testGestureErrorHiddenOnceRowSettles`: a gesture error, then the row is `applied` → no error line.
    - `testSlackEditDroppedWhenRowSettlesElsewhere`: the text is edited, then the row is `rejected` → no editor; `onApproveEdited` was never called.
  - The existing card tests switch their subject (Step 4), with assertions unchanged.
- [ ] **Step 3: Run them.** `make chat-test FILTER=AgentActionCardModelTests` and `make test-swift FILTER='ChatUIMacRowTests|AgentActionCardViewTests'`. Expected: FAIL.
- [ ] **Step 4: Implement.**
  - Port the card's layout from `AgentActionCardView*.swift` into `Parts/Approval/`, unchanged except for the services.
  - Draw its frame through `style.approvalCard`.
  - Write `MacAgentActionCard` and switch the four Mac surfaces and the chat thread.
  - Wire the phone's services.
  - Delete the Desktop card files and the four `ApprovalPartView+*` files.
- [ ] **Step 5: HEAD shots and comparison.**
  - Run `make desktop-shots DESKTOP_SHOTS=build/t15-head` and `make mobile-shots SHOTS_ONLY=chat SHOTS_DIR=build/t15-head-phone`.
  - Expected:
    - every Mac name is the same, in the chat and in the Inbox, the target chat and the automation editor;
    - `C2c` and `iphone-chat-approval-slack` keep their frame and colours;
    - the content the phone gains (summary lines, outcome, links) shows in the new frames `iphone-chat-approval-jira`, `iphone-chat-approval-confluence`, `iphone-chat-approval-connector`, `iphone-chat-approval-settled` and `iphone-chat-approval-no-permission`. They go to T16's review ask.
  - Fix any Mac difference through its hook before hand-back.
- [ ] **Step 6: Run the tests and the guards.**
  - `make chat-test`
  - `make chattext-test`
  - `make test-swift FILTER='AgentAction|ChatUIMacRow|Inbox|NeedsApproval|Approval01|InboxRefStateApprovals|TargetChat|AutomationEditor|SaveAutomation|SlackSend|ConnectorCall|ArtifactChat05|LIVE01|PublicAPISurface'`
  - `make kit-test FILTER=SeamBoundaryTests`
  - `make mobile-test MOBILE_FILTER='TowerTextTests|TowerWordGuardTests|ChatApprovalWiringTests|ChatSendTests|RelayChatClientTests|ChatsGateModelTests'`
  - `go test ./internal/hub/actions/... -run 'ChatActionAnswer'` and `go test ./cmd/... -run 'Actions|Agent07'` (AGENT-07 unchanged)
  - `make lint-swift`
  - `make lint-diff`
  - `bash scripts/tests/test-kit-lint-guard.sh`
- [ ] **Step 7: Inventory.**
  - `docs/inventory/README.md`: the Agent actions row names `WatchtowerChat/Sources/ChatUI/Parts/Approval/` instead of `Views/Chat/AgentActionCardView.swift`.
  - `docs/inventory/agent-actions.md`, `reaction-commands.md` and `inbox-folders.md`: their `AgentActionCardView` mentions name `MacAgentActionCard` / `ChatUI.AgentActionCard`. No contract text changes.
  - `docs/inventory/chat.md` changelog:
    - the approval card moved to `ChatUI` for both devices, no guard relaxed or renamed;
    - the CHAT-05 scan covers `Parts/Approval/`;
    - the phone gains read-only per-connector bodies; editing stays Mac-only (relay has no patch).
- [ ] **Step 8: Commit.** `refactor(chat): one approval card in ChatUI for the chat, the Inbox and the iPhone (#1822 T15, ask #1409)`

---

### Task T16: Docs, inventory close-out, guide, and the owner's review of the new states

**Depends on:** T13, T14, T15, T17.

**Files:**
- Modify:
  - `docs/features/unified-chat.md`:
    - Architecture: the composer, the approval card and the routing pill (`ChatRoutingModel`, `ChatRoutingAccessory`, `ChatRoutingPill`) live in `ChatUI`. The Mac injects dictation, its routing data readers (`AIModelCatalog`, `ai routing-status`), Reconnect Slack, Open, the `save_automation` body and the Inbox target row. The phone's routing data comes from the `chat_list` record's optional `routing`.
    - Protocol: `chat_manage use_preferred`, the feed's `routing_reason` and the `chat_list` `routing` object (D22 defaults).
    - the I3 item is gone from the open items;
    - v1 limits:
      - the phone has no approval editing (no Slack edit, no workspace pick, no connector-input edit) and no bulk approval verbs (no Approve all, no Dismiss, no Retry), because there is no relay verb (owner-confirmed, ask #1411);
      - clipped args show no Confluence diff on the phone;
      - the phone's model menu lists the registry's models only, with no live Ollama list;
      - the phone's provider availability refreshes with the `chat_list` record (any engine change), not on app activation, and it has no "check again".
  - `docs/features/README.md`: the unified-chat summary.
  - `docs/features/agent-actions.md`, `slack-send.md`, `voice-dictation.md` and `chat-redesign.md`: the file paths of the card, the composer and the dictation hook. Grep each for `AgentActionCardView`, `ChatComposerField` and `ChatComposerBar`.
  - `docs/features/provider-fallback.md` ("Desktop chat intent and actual execution"): the production routing component is `ChatUI`'s `ChatRoutingAccessory` on both devices. Use preferred is `chat_manage use_preferred`. The writers table gains `chatstore.UsePreferred`.
  - `docs/features/model-provider-registry.md`: the chat model picker is `ChatUI`'s `ChatRoutingPill`, fed by `AIModelCatalog` on the Mac and by `chat_list.routing` + `models[]` on the phone. No model names are hardcoded in Swift.
  - `docs/guide/features/iphone-chat.md`: the phone's approval cards show the connector's details; quotes take a comment; mentions show as chips; the model pill changes between turns, and it shows the fallback card with Use preferred. Keep the 8 KB cap.
  - `docs/guide/features/ai-chat.md`: only if a Mac-visible change was accepted in Step 1.
  - `docs/inventory/chat.md`: one closing changelog line for the addendum, with the guard moves of T13, T15 and T17.
  - The plan's Spec coverage rows, if a task moved a promise.

- [ ] **Step 1: Owner review ask (controller).**
  - File one **review** ask with the PNGs of every phone frame T13, T15 and T17 added (`iphone-chat-composer-*`, `iphone-chat-approval-*`, `iphone-chat-routing-*`).
  - Add every existing phone frame T17 reported as changed (the model chip now reads the Mac's copy, and a saved chat's pill is a menu), with base and HEAD side by side.
  - Add any Mac pair a task reported as different, with the base and HEAD side by side: `composer-main-editing` (the editing and over-limit lines that `ChatUI`'s composer shows), and anything else listed.
  - The umbrella PR stays a draft until the owner answers.
  - An element the owner rejects is hidden through its `PhoneChatStyle` or `DesignKitChatStyle` hook in a follow-up commit on this task's branch, and its shot is re-rendered.
- [ ] **Step 2: Write the docs** above.
- [ ] **Step 3: Verify.**
  - `go test ./docs/guide` (the 8 KB cap)
  - `bash scripts/leak-check.sh`, if run locally
  - `grep -rn 'AgentActionCardView\|ChatComposerField(\|ChatComposerBar(\|ChatModelPicker\|ChatRoutingStatusView' WatchtowerDesktop/Sources docs/inventory`: no hits except the adapter's history notes.
  - Controller phase gate for phase E: `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` and `make mobile-test`.
- [ ] **Step 4: Commit.** `docs: unified chat addendum — composer, approval cards and routing pill in ChatUI (#1822 T16, asks #1409 and #1411)`

---

### Task T17: One routing pill in `ChatUI` — the Mac's model pill and fallback preview, the phone's model and project chips (ask #1411)

**Depends on:** T13 (the composer's `accessory` slot). It may run beside T14 and T15 (see "Lanes and order").

**Why.** In ask #1411 the owner decided that the Mac's routing accessory and the phone's composer chips become one `ChatUI` view in this branch. The Mac's accessory is the model pill (`ChatModelPicker`), the actual-provider line, the missing-capabilities line, the fallback preview card (`ChatRoutingStatusView` over `ProviderFallbackPreview`) and the routing error. The phone's chips are the model chip and the project chip (`ChatComposerView.newChatChips`). After T17, a model-picker feature written once reaches both devices. The Mac looks and behaves as today (spec §2).

**Code facts this task starts from** (recon on the umbrella at `3feab04`):
- **The Mac's data is local.**
  - `ChatViewModel` holds the pick: `selectedProvider`, `selectedModel` and `automaticRouting`.
  - It builds `ChatRoutingPresentation` from `AIModelCatalog.shared` (`ai models --json`: providers, display names, capabilities, `reserve_peer`, live Ollama models) and from `ai routing-status`, which it reads through `CLIRunner` on a chat change, on app activation and at a turn's end.
  - The model menu's entries are `AIModelCatalog.suggestions(for:)`, and the providers are `AIProvider.offered(by:current:)`.
- **The phone's data comes over the relay, and only part of it.**
  - The `chat_list` record carries `models[]` (`chatengine.RegistryChatModels`: provider, model, `display_name`, `images`, `pdf`) and `projects[]`.
  - It carries no fallback pair, no preferred provider, no `fallback.enabled`, no availability (`ai routing-status`) and no `read_folder` or `claude_ai_tools` capability.
  - The live Ollama list is not there either; reading it needs a network call.
- **Both devices lack the routing reason.**
  - `FeedConversation` (`internal/chatengine/feed.go`) carries `routing`, `actual_provider` and `actual_model`, but not `chat_conversations.routing_reason`.
  - The Mac passes `reason: nil` to `ChatRoutingPresentation`. Since T8 its preview therefore shows only the `pinned` state. The `fallback`, `recovered` and `unsupported` states and the claude.ai-tools notice never show; on `main` they read `routingReason` from the row.
  - T17 restores them for both devices.
- **"Use preferred" does nothing on an automatic chat.**
  - On the umbrella, `requestAutomaticRouting` only sets `composer.routing = auto` for the next turn. `chatstore.writeRoutingTx` writes an automatic config only when a *pinned* chat switches to it, so the sticky reserve is never cleared.
  - On `main` the Mac's **Use preferred** closed the idle session and wrote `preferred_reserve` with the actual pair and the reason cleared (`ChatConversationQueries.setRouting`). `provider-fallback.md`: "Use preferred between turns clears sticky metadata and retires the idle host."
  - T17 brings this back as one engine operation, so both devices have it.
- **The phone locks its chips once the first message has gone; the Mac lets the pick change between turns.** One view means one rule. T17 takes the Mac's rule and the Mac's copy, and the phone's changed frames go to the owner (see "Phone frames" and T16 Step 1).
- **The pill is also used outside the chat.** `CodeQuestionPopover` and `QuestionsView` draw `ChatModelPicker` too. They switch to the shared pill, so no copy of the pill is kept.
- **The C18 shot names in T13 are wrong.** C18 names `other-provider` and `other-provider-failed`, but those are onboarding shots. The routing base set is the list in Step 1 below.

**Data the phone gets, and its fallback when the data is absent:**

| Data | How it reaches the phone | When it is absent (an older Mac daemon, or a failed read) |
|---|---|---|
| Providers, display names, models, the fallback pair (`reserve_peer`), capabilities (`images`, `pdfs`, `read_folder`, `claude_ai_tools`) | New optional `routing.providers[]` on the `chat_list` record | `ChatRoutingCatalog(list:)` builds the providers from `models[]` alone: no pair and only `images`/`pdf`. The pill offers the model choice, with no preview card and no capability line. This is today's phone. |
| Preferred provider, `fallback.enabled`, availability per quota provider | New optional `routing.status`, the same DTO `ai routing-status` prints (decoded by the same `ChatRoutingStatus` parser), with `application` and `saved_version` left out | No preview card. The pill still works. |
| A failed availability read | `routing.error`: "Couldn't read provider availability" (fixed copy, so no path or stderr crosses the relay) | The line shows under the pill, as the Mac's does. |
| Why the chat runs where it runs | New `routing_reason` on the feed's conversation, on both transports (live from the session's `session_ready.reason`, else the row) | `""`: no `fallback`/`recovered`/`unsupported` state. This is the umbrella's state today. |
| Use preferred | New `chat_manage` op `use_preferred`, on `chat.sock` and through the hub's `chat_manage` action | An older daemon answers `invalid_params`. The phone never offers the action there anyway, because `recovered` needs `routing.status`, which only a new daemon sends. |

The `routing` object is optional and decoded with defaults (D22). It is filled by the hub's `chat_list` source (like `models`), not by `chatengine.ReadList`: the Mac keeps its local readers, because they also list the live Ollama models and refresh on app activation. No new hub action kind is added.

**Behaviours that must survive or reach the phone** (each with the test that pins it after the move):

| # | Behaviour | Pinned by |
|---|---|---|
| R1 | The pill's label: "Preferred + reserve · Auto"; "Only <Provider> · <model>"; "Only <Provider> · Auto" | `ChatRoutingModelTests.testLabelsMatchTheMacPicker` (new) |
| R2 | The menu: "Preferred + reserve · Auto model"; a Provider section ("Only <Provider>" for each provider the policy allows, and the current one); a Model section ("Auto" plus the provider's models). A provider pick resets the model to Auto. | `testMenuEntriesMatchTheMacPicker` (new) |
| R3 | A pick only sets the next turn's routing (`composer.routing`). Nothing is written until a turn starts. The pill is off while busy. | `testPickWritesComposerRoutingOnly`, `testPillAndActionOffWhileBusy` (new) |
| R4 | A saved chat shows its own routing until a pick. A new chat shows the landing's pick. | `testSavedChatPillShowsItsRoutingUntilAPick` (new) |
| R5 | "Current provider: <Provider> · <model>" | `ChatRoutingPresentationTests` (moved, assertions kept) |
| R6 | "No images / PDFs / file reading with this provider." (U3) | `testMissingCapabilitiesNamePDFsForAnImagesOnlyProvider` (moved) |
| R7 | The fallback preview card for `pinned`, `fallback`, `recovered` (with **Use preferred**) and `unsupported`, with the next-check time. The action is off while busy. | `ChatRoutingPresentationTests` (moved), shots `provider-chat-*` |
| R8 | The claude.ai-tools notice on a quota-selected reserve without them | `testQuotaReserveNoticeFollowsActualCapabilitiesAfterReopenAndRecovery` (moved) |
| R9 | The routing error line, in warning tone | `testHealthErrorShowsLine` (new) |
| R10 | The status is re-read on a chat change, on app activation and at a turn's end (the Mac). The phone gets it with each `chat_list` record. | `testRefreshOnChatChangeActivationAndTurnEnd` (new) |
| R11 | **Use preferred** clears the sticky reserve between turns and retires the idle session. It is refused while a turn runs. | `TestChatengine_UsePreferredClearsStickyAndRetiresIdleSession`, `TestChatengine_UsePreferredRefusedWhileTurnRuns` (new) |
| R12 | The phone's project chip: a menu on a new chat, locked text once the chat is saved. The Mac passes no projects, so it shows no project menu, as today. | `ChatUIPhoneParityTests` (kept), `testProjectMenuOnlyWithProjectsOnANewChat` (new) |
| R13 | The code-question header and the Questions view use the same pill, with no automatic choice | shots `routing-pill-code-question`, `routing-pill-questions-view`; `CodeQuestionSurfaceTests` (kept) |

**Writers of the routing** (T17 adds one engine path, `use_preferred`; the pill itself writes nothing, it only sets a binding and calls closures):
- **`chat_conversations.routing_mode`, `provider`, `model`:**
  - the engine, through `chatstore.writeRoutingTx` on `chat_new`/`chat_turn` with `routing`;
  - the engine, through the new `chatstore.UsePreferred` on `chat_manage use_preferred`, under the conversation's turn lock;
  - `ai session` itself (`SetChatRouting`, `cmd/ai_session_routing.go`), with the config it was started with.
- **`actual_provider`, `actual_model`, `routing_reason`:**
  - the engine (`chatstore.Turn.recordActual`, from the session's event);
  - `ai session` (`SetChatActual`).
  - All three routing writers above clear them (`writeRoutingTx` on a pin, `UsePreferred`, `SetChatRouting`).
- **`chat_messages.provider`, `model`:** `Turn.recordActual` only.
- **The next turn's intent** (in memory, no row):
  - `ChatComposerModel.routing`, set only by `ChatRoutingModel`;
  - on the phone, also `ChatsCenter.drafts` (`draft.routing`) and the `chat_outgoing` send ledger;
  - on the Mac, the landing's pick lives in `ChatRoutingModel`, moved out of `ChatViewModel`.
- **Read-only for the pill:**
  - the AI config (`ai.provider`, `ai.fallback.*`), written by Settings `ConfigService.save` and the CLI;
  - the provider-health store, written by routed callers. The pill never passes `--check-again`, and the engine's catalog uses `Router.Status`, never `CheckStatus`.
- **The code questions' choice:** `CodeQuestionCenter.setModelChoice` (unchanged, its own store).
- **Who wins:**
  - Two devices picking for one chat: each device's pick is its own, in memory. The turn that starts writes its routing under the turn lock, so the last turn to start wins. `use_preferred` while a turn runs is refused `busy`, and the row is unchanged.
  - `use_preferred` writes the row first and then retires the idle session, so the next session reads the new row.

**Failure paths and their tests:**

| Failure | Behaviour | Test |
|---|---|---|
| The phone's `chat_list` has no `routing` (an older daemon) | The pill offers models from `models[]` only, with no card and no capability line. Sends work. | `ChatRoutingCatalogTests.testListWithoutRoutingBuildsProvidersFromModels`, `ChatRoutingModelTests.testCatalogWithoutStatusShowsChoiceOnly` (new) |
| No list yet on the phone (cold start, nothing kept offline) | No pill, as today without `newChatChoices`. The draft is kept. | `testNoCatalogHidesPill` (new) |
| The Mac's `AIModelCatalog` is unread (`ai models` failed) | The providers come from `AIProvider.offered`, and the Model section has only "Auto", as today. There is no capability line. | `ChatRoutingMacAdapterTests.testUnreadCatalogOffersProvidersAndAutoOnly` (new), shot `routing-catalog-unread` |
| A pinned model the catalog no longer lists (models changed, or the MDM policy dropped the provider) | The label keeps the pin, so the owner sees what is set. The send goes, and the engine refuses it by policy or model with the existing error part. The menu offers the current choices. | `testPinnedModelMissingFromCatalogKeepsLabel` (new); POLICY-02 `TestPolicy_ForbiddenProviderNeverReachableByCapability` (kept) |
| Stale availability (the status read some time ago) | The Mac re-reads on chat change, activation and turn end (R10). The phone gets a fresh read with every `chat_list` record, which is rebuilt on any engine change (a turn's end, `use_preferred`, a chat change). | `TestChatList_RoutingStatusReadOnEveryBuild` (new, hub) |
| The availability read fails | Mac: "Couldn't read provider availability: …" (today). Phone: `routing.error` with the fixed copy, and the providers are still listed. | `testHealthErrorShowsLine` (new), `TestChatengine_RoutingCatalogStatusErrorIsSanitized` (new) |
| The relay is down (phone offline) | The pill stays editable, because a pick is local and goes with the queued send. **Use preferred** is off, and the card stays as last read. | `testUsePreferredOffWhileUnreachable` (new, `.unavailable` and `.offline`) |
| `chat.sock` is down (Mac) | The same as offline: the pill is editable and **Use preferred** is off | `testUsePreferredOffWhileUnreachable` |
| `use_preferred` refused (`busy`, `gone`, or `invalid_params` from an older daemon) | The pick is unchanged, and the notice reads "Couldn't change provider choice: <reason>" (`main`'s copy). `gone` leads to the conversation's gone state. | `testUsePreferredRefusedKeepsSelectionAndShowsNotice` (new), `TestChatengine_UsePreferredOnGoneConversation` (new) |
| A feed without `routing_reason` (an older daemon) | `""`: no `fallback`/`recovered`/`unsupported` state, and no crash | `ChatFeedTests.testConversationWithoutRoutingReasonDecodes` (new, ChatWire) |

**Files:**
- Modify (Go):
  - `internal/chatengine/feed.go`:
    - `FeedConversation` gains `RoutingReason string \`json:"routing_reason"\``, read from `c.routing_reason`;
    - `LiveRouting` gains `Reason`, which `applyLiveRouting` copies;
    - `internal/chatengine/live.go` fills it from `readyLive.Reason`.
  - `internal/chatengine/engine.go`: `ManageUsePreferred = "use_preferred"`. `Manage` refuses it with `chatstore.ErrBusy` while the conversation's turn runs. Otherwise it calls `store.UsePreferred`, then retires that conversation's idle session (`retire = true`, `poke()`, as `Warm` does), and publishes the change.
  - `internal/chatstore/store.go`: `UsePreferred(ctx, conv)` writes `routing_mode = 'preferred_reserve'`, `provider = NULL`, `model = NULL`, `actual_provider = ''`, `actual_model = ''`, `routing_reason = ''` for a main-chat row. No row means `ErrConversationGone`.
  - `internal/chatengine/routing.go` (new): `RoutingCatalog`, `RoutingProvider` and `ReadRoutingCatalog`.
  - `internal/providerrouting/status_read.go` (new): `ReadStatus`, the loop moved out of `cmd/ai_routing_status.go`. The command prints the same bytes; the `application` fields stay the command's.
  - `cmd/ai_routing_status.go`: it calls `providerrouting.ReadStatus`.
  - `internal/hub/slices/sources/chat_list.go`: `ChatListOptions.Routing func(context.Context) *chatengine.RoutingCatalog` (nil leaves the key out); `Items` sets `payload.Routing`. `chatengine.List` gains `Routing *RoutingCatalog \`json:"routing,omitempty"\``.
  - `internal/hub/slices/sources/registry.go` and the hub wiring: they pass `ReadRoutingCatalog` over the daemon's current AI config and `providerhealth.Installation()`.
  - `internal/hub/actions/handlers/chat_manage.go`: it allows `use_preferred`; the message becomes "op must be pin, unpin, rename, delete or use_preferred".
  - `internal/chatengine/testdata/routing_catalog.json` (new, written by `-update`).
  - `WatchtowerKit/Tests/Fixtures/chat/actions.json`: a `chat_manage use_preferred` case.
- Create (Swift, `WatchtowerChat/Sources/ChatWire/Routing/`):
  - `ChatRoutingCatalog.swift` (new);
  - moved from `WatchtowerCore` with `git mv` (`package` → `public`; Core keeps `package typealias`es, the T14 precedent):
    - `Services/ProviderFallbackPreview.swift`, the one copy table that Settings and the chat both read;
    - `Services/Chat/ChatRoutingStatus.swift`, holding `ChatRoutingStatus` and `ChatRoutingPresentation`. `ChatRoutingPresentation.capabilities` becomes `ChatProviderCaps`.
  - `ChatWire/Models/ChatFeed.swift`: `Conversation.routingReason` (default `""`). `ChatList.swift`: `routing: ChatList.Routing?`.
  - `ChatWire/Models/ChatActionParams.swift`: `ChatManageOp.usePreferred` (`"use_preferred"`).
- Create (Swift, `WatchtowerChat/Sources/ChatUI/`):
  - `Models/ChatRoutingModel.swift`: the pick, the presentation, the menu, and the one `send` (`chat_manage use_preferred`). `Models/` is where the composer model sends, too. The CHAT-05 scan keeps `send(` out of `Composer/`.
  - `Composer/Routing/ChatRoutingAccessory.swift`: the lines, the card, the error, the pill and the phone's project menu.
  - `Composer/Routing/ChatRoutingPill.swift`: the menu. The code questions use it too.
  - `Platform/macOS/AppActivation.swift` (`NSApplication.didBecomeActiveNotification`) and `Platform/iOS/AppActivation.swift` (`scenePhase == .active`), as one `.onAppActivation` modifier, so the shared view needs no `#if`.
  - `Style/ChatUIStyle.swift`: the routing hooks below.
- Modify (ChatUI):
  - `Composer/ChatComposerView.swift`: `newChatChips` is deleted; the composer draws `ChatRoutingAccessory` when a `ChatRoutingModel` is given.
  - `Composer/ChatComposerChips.swift`: `modelChip`, `modelLabel` and `modelOptions` are deleted. `projectChip` and `ChatNewChatChoices.projects` stay for the project menu.
  - `WatchtowerChat/Tests/ChatUITests/ChatUISourceScanTests.swift`: `Composer/Routing/` is enumerated.
- Modify (Mac):
  - `ViewModels/ChatViewModel.swift`: `selectedProvider`, `selectedModel`, `automaticRouting`, `routingRequest`, `switchProvider`, `selectModel`, `requestAutomaticRouting` and `routingPresentation` move into `ChatRoutingModel` (`chatVM.routing`). `refreshRoutingStatus()` stays as the Mac's refresh closure (the `ai routing-status` CLI read). `attachUnavailableReason` and `pdfUnavailableReason` read `routing.capabilities`.
  - `WatchtowerCore/Services/Chat/ChatRoutingCatalog+Mac.swift` (new): `ChatRoutingCatalog(models: AIModelCatalog, offered: [String], status: ChatRoutingStatus?, statusError: String?)`.
  - `Views/Chat/DesignKitChatStyle.swift`: the routing hooks, drawing today's look:
    - `ProviderFallbackStatus` for the card;
    - `.caption` secondary lines and the `Tone.warning` error;
    - the borderless-button menu label in `.caption`.
  - `Views/Chat/{ChatView,ChatLandingView,ProjectDetailView}.swift`: `modelSuggestions` goes, because the catalog carries them.
  - `Views/Workbench/CodeNav/{CodeQuestionPopover,QuestionsView}.swift`: `ChatUI.ChatRoutingPill` with `automatic: nil`.
  - `Views/Chat/ChatComposerAccessory.swift` (from T13) becomes the one line that hands `chatVM.routing` to the composer, or is deleted if T13 left nothing else in it.
  - `Tests/DesignShots/DesignShotFixtures+ProviderFallback.swift` and `+ProviderCapabilities.swift`: the same scene names, drawn through `ChatRoutingAccessory`.
- Delete (Mac): `ChatModelPicker` (in `ChatComposerView.swift` or T13's `ChatComposerAccessory.swift`) and `Views/Chat/ChatRoutingStatusView.swift`. `ProviderFallbackStatus` stays: Settings and the Mac's card hook use it.
- Modify (phone):
  - `Features/Chats/ChatsCenter.swift`:
    - `conversation(_:)` gives the composer a `ChatRoutingModel` whose catalog is `ChatRoutingCatalog(list:)`, refreshed on every list update;
    - `newChatChoices` keeps only the projects.
  - `Features/Chats/PhoneChatStyle.swift`: the routing hooks, drawing the chip on `Fill.card` for the pill and `Card` for the preview.
- Tests:
  - `git mv` `WatchtowerDesktop/Tests/Core/{ChatRoutingPresentationTests,ProviderFallbackPreviewTests}.swift` → `WatchtowerChat/Tests/ChatWireTests/`, assertions unchanged;
  - new `ChatWireTests/ChatRoutingCatalogTests.swift`, `ChatUITests/ChatRoutingModelTests.swift`, `WatchtowerDesktop/Tests/Core/ChatRoutingMacAdapterTests.swift` and `WatchtowerMobile/Tests/ChatRoutingPhoneTests.swift`;
  - Go tests in `internal/chatengine`, `internal/chatstore`, `internal/providerrouting` and `internal/hub/...` (Step 2).
- Shots: `Tests/DesignShots/DesignShotFixtures+RoutingPill.swift` (new), `DesignShotCatalog.swift` and `ScreenshotTourTests.swift`.

**Interfaces:**
- Consumes:
  - T13's `ChatComposerView` `accessory` slot and `ChatComposerModel.routing`;
  - T7's `ChatUIStyle`, `ChatHostText` and `FakeChatClient`;
  - T2's `chat_manage`.
- Produces (Go):
  ```go
  type RoutingProvider struct {
      ID          string `json:"id"`
      DisplayName string `json:"display_name"`
      ReservePeer string `json:"reserve_peer,omitempty"`
      Images      bool   `json:"images"`
      PDFs        bool   `json:"pdfs"`
      ReadFolder  bool   `json:"read_folder"`
      ClaudeAI    bool   `json:"claude_ai_tools"`
  }
  type RoutingCatalog struct {
      Providers []RoutingProvider        `json:"providers"` // policy-allowed only (providers.Allowed)
      Status    *providerrouting.Output  `json:"status,omitempty"` // the `ai routing-status` DTO, application/saved_version cleared
      Error     string                   `json:"error,omitempty"`  // fixed copy; never the cause's text
  }
  func ReadRoutingCatalog(ctx context.Context, cfg *config.Config, r *providerrouting.Router) *RoutingCatalog
  // providerrouting: func ReadStatus(ctx context.Context, cfg *config.Config, r *Router, checkAgain bool) (Output, error)
  ```
- Produces (`ChatWire`, public):
  ```swift
  public struct ChatProviderCaps: Equatable, Sendable { public var images, pdfs, readFolder, claudeAITools: Bool }
  public struct ChatRoutingCatalog: Equatable, Sendable {
      public struct Provider: Equatable, Sendable {
          public let id: String; public let displayName: String; public let reservePeer: String?
          public let models: [String]; public let caps: ChatProviderCaps
      }
      public var providers: [Provider]
      public var status: ChatRoutingStatus?        // nil: no preview card
      public var statusError: String?
      public init(list: ChatList)                  // phone: models[] + routing (routing nil → models only, D22)
      public init(providers: [Provider], status: ChatRoutingStatus?, statusError: String?)
      public func pair(preferred: String) -> ProviderFallbackPreview.Pair?
  }
  ```
- Produces (`ChatUI`, public):
  ```swift
  @MainActor @Observable public final class ChatRoutingModel {
      public init(client: any ChatClient, composer: @escaping () -> ChatComposerModel,
                  onRefresh: (() async -> Void)? = nil)    // Mac: ai routing-status; phone: nil (the list carries it)
      public var catalog: ChatRoutingCatalog?              // nil: no pill (R12 / no list yet)
      public private(set) var automatic: Bool
      public private(set) var provider: String
      public private(set) var model: String                // "" = Auto
      public private(set) var notice: String?
      public var label: String                             // R1
      public var menu: [ChatRoutingMenuSection]            // R2
      public var presentation: ChatRoutingPresentation?    // R5–R8
      public var capabilities: ChatProviderCaps?
      public func selectAutomatic(); public func selectProvider(_ id: String); public func selectModel(_ model: String)
      public func usePreferred() async                     // saved chat: chat_manage use_preferred; landing: auto only
  }
  public struct ChatRoutingMenuSection: Equatable { public let title: String?; public let items: [ChatRoutingMenuItem] }
  public struct ChatRoutingPill: View {
      public init(label: String, menu: [ChatRoutingMenuSection], enabled: Bool, onPick: @escaping (ChatRoutingMenuItem) -> Void)
  }
  public struct ChatRoutingAccessory: View {
      public init(model: ChatRoutingModel, isBusy: Bool, reachable: Bool,
                  projects: ChatNewChatChoices? = nil, projectID: Binding<Int64?>? = nil)
  }
  // ChatUIStyle, new hooks (defaults = the phone's look):
  //   func routingPillLabel(_ label: String, enabled: Bool) -> AnyView
  //   func routingCaption(_ text: String, warning: Bool) -> AnyView
  //   func routingStatusCard(_ copy: ProviderFallbackPreview.Copy, actionEnabled: Bool, onAction: (() -> Void)?) -> AnyView
  ```

- [ ] **Step 1: Base shots** (first commit, no view or data change). Add `DesignShotFixtures+RoutingPill.swift`. It renders today's Desktop views (`ChatModelPicker`, `ChatRoutingStatusView` and the composer's `routingState`) under these names, light and dark:
  - `routing-pill-auto`, `routing-pill-pinned-model`, `routing-pill-pinned-auto-model`, `routing-pill-busy`;
  - `routing-actual-line`, `routing-preview-unsupported`, `routing-preview-recovered-busy`, `routing-native-tools-notice`;
  - `routing-status-error`, `routing-catalog-unread`, `routing-accessory-narrow` (360 pt: the actual line, the missing capabilities and the recovered card);
  - `routing-pill-code-question`, `routing-pill-questions-view`.

  The base set also includes the existing `provider-chat-{fallback,recovered,stopped,pinned}-{claude,codex}`, their `-narrow` twins, `provider-chat-historical-*-narrow`, `chat-composer-ollama-capabilities` and `provider-fallback-*`, plus T13's `composer-main-*`, and the phone frames `C2a`–`C2i` and `C3a`. Render them with `make desktop-shots DESKTOP_SHOTS=build/t17-base` and `make mobile-shots SHOTS_ONLY=chat SHOTS_DIR=build/t17-base-phone`. Commit: `test(shots): routing pill base shots before the ChatUI move (#1822 T17)`.
- [ ] **Step 2: Failing tests.**
  - Go (`internal/chatengine`, `internal/chatstore`, synctest or an injected clock):
    - `TestChatengine_FeedCarriesRoutingReason`: a row with `routing_reason = 'quota_exhausted'` → `FeedConversation.RoutingReason == "quota_exhausted"`. A live `session_ready` with `reason: "required_capability_missing"` overlays it before the row is written.
    - `TestChatengine_UsePreferredClearsStickyAndRetiresIdleSession`: an automatic chat sticky on the reserve (`actual_provider` = the reserve, `routing_reason = 'quota_exhausted'`) with an idle warm session → `Manage(use_preferred)`. Then the row has `routing_mode = 'preferred_reserve'`, `provider` and `model` NULL, and `actual_provider`, `actual_model` and `routing_reason` empty. The session is retired, and a subscriber gets one `conversation_update`. A pinned chat becomes automatic in the same way.
    - `TestChatengine_UsePreferredRefusedWhileTurnRuns`: a running turn → `ErrBusy`; the row is byte-for-byte unchanged and the session is not retired.
    - `TestChatengine_UsePreferredOnGoneConversation`: a deleted id → `ErrConversationGone`; an embedded row (`context_type` set) → `ErrConversationGone`, unchanged.
    - `TestChatengine_RoutingCatalogCarriesPairCapsAndStatus`: with a fake health store where claude is `quota_wait` → `providers` has claude and codex with `reserve_peer` pointing at each other and their capability rows; `status.providers[0].state == "quota_wait"`; `status.application == nil`.
    - `TestChatengine_RoutingCatalogPolicyDropsProvider`: `AllowedAIProviders = claude` → no codex row and no claude `reserve_peer`.
    - `TestChatengine_RoutingCatalogStatusErrorIsSanitized`: the reader fails with an error that holds a path → `error == "Couldn't read provider availability"`, the text holds no `/`, and the providers are still listed.
    - `TestChatengine_RoutingCatalogFixture` (`-update` writes `testdata/routing_catalog.json`).
  - Go (`internal/providerrouting`, `cmd`):
    - `TestReadStatus_SameOutputAsCommand`: `ReadStatus` and `watchtower ai routing-status` print equal JSON for one config and store.
    - The existing `go test ./cmd -run 'RoutingStatus|AIModels'` passes unchanged.
  - Go (hub):
    - `TestChatList_CarriesRoutingCatalog`: with the option set, the `chat_list` record has `routing.providers` and `routing.status`, and still fits `MaxChatFeedBytes`.
    - `TestChatList_RoutingNilOmitted`: without the option, there is no `routing` key.
    - `TestChatList_RoutingStatusReadOnEveryBuild`: two builds → the reader is called twice (a counting fake).
    - `TestChatManage_UsePreferredAllowed`: the handler passes `use_preferred` to the engine; `busy` → the refusal reason the phone maps.
  - Swift, `ChatWire`:
    - `ChatRoutingCatalogTests.testDecodesGoFixture`: `routing_catalog.json` → `providers`, `pair(preferred: "claude")`, `status` and `caps`.
    - `testListWithoutRoutingBuildsProvidersFromModels`: `models[]` for claude (`opus`, `haiku`) and codex → two providers with their models, no `reservePeer`, `status == nil`, and caps from `images`/`pdf`.
    - `ChatFeedTests.testConversationWithoutRoutingReasonDecodes`.
    - The moved `ChatRoutingPresentationTests` and `ProviderFallbackPreviewTests` pass unchanged.
  - Swift, `ChatUI` (`ChatRoutingModelTests`, `FakeChatClient`, no clock waits):
    - `testLabelsMatchTheMacPicker`: automatic → "Preferred + reserve · Auto"; `selectProvider("codex")` → "Only Codex · Auto"; `selectModel("gpt-5.6-sol")` → "Only Codex · gpt-5.6-sol".
    - `testMenuEntriesMatchTheMacPicker`: the sections are `[nil: ["Preferred + reserve · Auto model"]]`, `["Provider": ["Only Claude", "Only Codex"]]` and `["Model": ["Auto"] + the selected provider's models]`; with `automatic: nil` (the code questions) there is no first section.
    - `testPickWritesComposerRoutingOnly`: each pick sets `composer.routing` to the matching `ChatRouting`, and `client.ops` stays empty.
    - `testPillAndActionOffWhileBusy`: busy → the picks are ignored and `presentation.canUsePreferred == false`.
    - `testSavedChatPillShowsItsRoutingUntilAPick`: a saved feed pinned to `codex`/`gpt-5.6-sol` → that label; after `selectAutomatic()` → the automatic label; switching to another chat → its own routing.
    - `testUsePreferredSendsManageAndTurnsAutomatic`: a saved chat in the `recovered` state → exactly one `.manage(op: .usePreferred)` op; `.applied` → `automatic == true` and `composer.routing == auto`. On the landing → no op, and the routing is auto.
    - `testUsePreferredRefusedKeepsSelectionAndShowsNotice`: `.refused("busy")` → the pick is unchanged and `notice` starts with "Couldn't change provider choice:". A thrown connection error does the same.
    - `testUsePreferredOffWhileUnreachable`: reachability `.unavailable` → the card's action is off, the picks still set `composer.routing`, and `usePreferred()` sends nothing.
    - `testCatalogWithoutStatusShowsChoiceOnly`, `testNoCatalogHidesPill`, `testPinnedModelMissingFromCatalogKeepsLabel`, `testHealthErrorShowsLine` (`statusError` → one warning caption).
    - `testRefreshOnChatChangeActivationAndTurnEnd`: a counting `onRefresh` → +1 on a conversation change, +1 on busy going to idle, +1 on the activation modifier's action; nothing when `onRefresh` is nil.
    - `testProjectMenuOnlyWithProjectsOnANewChat`.
  - Swift, Desktop:
    - `ChatRoutingMacAdapterTests.testMacCatalogMapsPairCapsAndSuggestions` (the `ai_models_capabilities.json` fixture plus a routing-status fixture): the pair is `AIModelCatalog.fallbackPair`, the models are `suggestions(for:)`, and the caps are mapped from `ProviderCapabilities`.
    - `testUnreadCatalogOffersProvidersAndAutoOnly`.
    - `ViewModelTests`' routing cases switch their subject to `chatVM.routing`; their names and assertions are kept.
  - Swift, phone (`make mobile-test`):
    - `ChatRoutingPhoneTests.testCatalogFollowsListUpdates`: a list update that adds `routing` → the model's `catalog.status` is set without reopening the screen.
    - `testSavedChatPillEditableBetweenTurns`: the next `chat_turn` the coordinator sends carries the picked routing.
    - `testUsePreferredGoesThroughChatManage`: `RelayChatClient` sends the hub `chat_manage` action with `op: "use_preferred"`.
- [ ] **Step 3: Run them.**
  - `go test ./internal/chatengine ./internal/chatstore ./internal/providerrouting -run 'RoutingReason|UsePreferred|RoutingCatalog|ReadStatus'`
  - `go test ./internal/hub/... -run 'ChatList|ChatManage'`
  - `make chat-test FILTER='ChatRoutingCatalogTests|ChatRoutingModelTests|ChatFeedTests'`
  - `make test-swift FILTER='ChatRoutingMacAdapterTests|ViewModelTests'`
  - Expected: FAIL.
- [ ] **Step 4: Implement.**
  - The Go fields, `UsePreferred`, the catalog and the hub wiring.
  - The Swift moves; `ChatRoutingModel` and the two views.
  - The hooks in `DesignKitChatStyle`, drawing today's Mac look, and in `PhoneChatStyle`, drawing the phone's chip and card.
  - Switch the main chat, the landing, the project page, the code-question popover, the Questions view and the phone conversation screen.
  - Delete `ChatModelPicker` and `ChatRoutingStatusView`.
  - A Mac difference is fixed through a hook. A copy change on the Mac is not allowed: the Mac's strings are the table.
- [ ] **Step 5: HEAD shots and comparison.**
  - Run `make desktop-shots DESKTOP_SHOTS=build/t17-head` and `make mobile-shots SHOTS_ONLY=chat SHOTS_DIR=build/t17-head-phone`.
  - Mac: every name in Step 1 must be the same. The one deliberate difference is that `provider-chat-fallback-*`, `-recovered-*` and the native-tools scenes now come from a real `routing_reason`. Their pixels must still equal the base, because the fixtures always passed a reason. Report each name as "same", or name the difference.
  - Phone frames:
    - `C2a`–`C2i` and `C3a` are the same, except the frames that show the model chip: their label now reads the Mac's copy, and a saved chat's pill is a menu. Name each changed frame.
    - New frames in `testTheChatShots`: `iphone-chat-routing-new-chat` (pill plus project menu), `iphone-chat-routing-saved` (editable between turns), `iphone-chat-routing-fallback`, `iphone-chat-routing-recovered` (with **Use preferred**), `iphone-chat-routing-unsupported`, `iphone-chat-routing-missing-caps`, `iphone-chat-routing-status-error`, `iphone-chat-routing-offline` (action off) and `iphone-chat-routing-no-catalog` (an older daemon: model choice only).
    - The new frames and the changed ones go to T16's review ask.
- [ ] **Step 6: Run the tests and the guards.**
  - Go:
    - `go test ./internal/chatengine ./internal/chatstore -run 'Chat|CHAT|LIVE01|Lease|Feed|Parts|Routing|Manage|UsePreferred'`
    - `go test ./internal/providerrouting ./internal/providers ./internal/transporttest` (LLMTRANSPORT-01 Go, POLICY-02)
    - `go test ./internal/hub/... -run 'Chat|Contract|Fixture'`
    - `go test ./cmd/... -run 'RoutingStatus|AIModels|AISession|Chat'`
    - `go test ./internal/chat -run 'Golden|Prompt|Routing'` (`routing_v2.jsonl` unchanged)
    - `make lint-diff`
  - Swift:
    - `make chat-test` (with `ChatUISourceScanTests`, `ChatPartRegistryTests`, `ChatConversationModelTests` and `ChatUIPhoneParityTests`)
    - `make chattext-test`
    - `make test-swift FILTER='ChatRouting|ProviderFallback|ProviderCapabilities|AIModelCatalog|ProviderSettings|LLMTransportGuard|ViewModel|ChatComposerField|CodeQuestion|Questions|TuningChat|PublicAPISurface|ArtifactChat05|LIVE01'`
    - `make kit-test FILTER='SeamBoundaryTests|HubContract'`
    - `make mobile-test MOBILE_FILTER='TowerTextTests|TowerWordGuardTests|ChatRoutingPhoneTests|ChatSendTests|ChatSendRecoveryTests|RelayChatClientTests|ChatsGateModelTests|ChatWireKitConformancesTests'`
    - `make lint-swift`
    - `bash scripts/tests/test-kit-lint-guard.sh`
  - **LLMTRANSPORT-01 Swift.** `LLMTransportGuardTests` scans `WatchtowerDesktop/Sources`, `WatchtowerKit/Sources` and `WatchtowerChatText/Sources`, but not `WatchtowerChat/Sources`, where T17 moves the routing presentation. Add `WatchtowerChat/Sources` to its roots. This strengthens the guard; its baseline must not grow.
    - A name check that the scan then finds is rewritten to read the catalog row (`reservePeer`, `caps`), as the moved code already does.
    - A hit that cannot be rewritten stops the task, and the owner is asked.
- [ ] **Step 7: Inventory.**
  - `docs/inventory/chat.md` changelog:
    - the routing pill moved to `ChatUI` for both devices, with no guard relaxed or renamed;
    - `ChatRoutingPresentationTests` and `ProviderFallbackPreviewTests` moved with their assertions;
    - the CHAT-05 scan covers `Composer/Routing/`;
    - the new `chat_manage use_preferred` op, and its writer, `chatstore.UsePreferred`;
    - `routing_reason` on the feed.
  - `docs/inventory/llm-transport.md` changelog: the Swift guard also scans `WatchtowerChat/Sources`, and the baseline is unchanged.
- [ ] **Step 8: Commit.** `refactor(chat): one routing pill in ChatUI for the Mac and the iPhone (#1822 T17, ask #1411)`

---

## Spec coverage

| Spec | Tasks |
|---|---|
| §2 G1/D2/D3 | T1, T4, T8 |
| §2 G2/D4 | T4, T6 |
| §2 G3/D8–D10 | T6, T7, T13, T15, T17 |
| §2 G4 | T3, T7 |
| §2 G5/CHAT-06 | T3, T7 |
| §2 G6 | T1 |
| §2 non-goals (embedded rendering) | T12, T13 (embedded, Workchat, spec review and target brief composers) |
| §2 anti-goals (no second path; Mac polish kept) | T13, T15, T17 (base/HEAD shots of every composer, card and routing-pill state; `ChatModelPicker` and `ChatRoutingStatusView` deleted) |
| D5 | T1, T5, T8 |
| D6 | T1 |
| D7/D22 | T6, T17 (optional `chat_list.routing` and feed `routing_reason`, decoded with defaults) |
| D11/D13 | T8, T10a, T10b |
| D12 | T4 (no approval op), T5 (relay approval kept), T14, T15 (one card; the Mac still decides through `actions approve\|reject`, the phone through `chat_action_answer`) |
| D14 | T3, T12 |
| D15/D21 | T3, T5 |
| D17 | T4 |
| D18 | T7, T13, T15, T17 |
| D19 | T7, T8 |
| D20 | T4 |
| D23 | T10a |
| §4 | T1, T4, T5 |
| §5.1 | T4 |
| §5.2 | T1, T2, T10a (`chat_shutdown`), T17 (`chat_manage use_preferred`) |
| §5.3 | T3, T6, T17 (`routing_reason` on the feed's conversation) |
| §5.4 | T1, T5, T6 |
| §6.1 | T6, T7, T13 (composer, `ChatComposerField` in `Platform/macOS`), T15 (approval card with the per-connector bodies), T17 (routing pill and fallback preview) |
| §6.2 | T8 |
| §6.3/§6.4 | T5, T9, T13 (the shared composer and pickers on the phone), T14, T15 (per-connector approval cards on the phone), T17 (the shared routing pill, fallback card and capability line on the phone) |
| §7 | T4, T10a, T10b |
| §8 rows | the named tests in T1, T2, T3, T4, T7, T8, T10a, T10b, T12, T13, T15, T17 |
| §9 | T1, T3, T5, T7, T8, T10a, T11, T14 (writers of `agent_actions` unchanged), T17 (writers of the routing columns; one new engine writer, `chatstore.UsePreferred`), T16 |
| §10 | T0, T8, T9, T12, T13, T15, T17, T16 (review ask) |
| §12 | T11, T16 (v1 limits confirmed in ask #1411) |
| Final review I3 (ask #1409: composer and approval cards into `ChatUI` before main) | T13, T14, T15, T16 |
| Final review M1 (a new `client_key` on every Send press) | T13 |
| Ask #1411: the routing pill (model menu, fallback preview) and the phone's model and project chips are one `ChatUI` view | T17, T16 (docs, owner review of the phone frames) |
| Ask #1411: phone v1 limits (no approval editing, no bulk approval verbs) | T15 (nil capabilities on the phone), T16 (`unified-chat.md` v1 limits) |
