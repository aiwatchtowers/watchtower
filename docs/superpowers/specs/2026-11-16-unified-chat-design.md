# Unified chat — one Go engine, one protocol, one chat UI for the Mac and the iPhone — design

Date: 2026-11-16. Board: #1822. Status: draft for the owner's review; decisions in asks #1363 and #1371.
Builds on: `docs/superpowers/specs/2026-11-15-iphone-chat-design.md` (#1791, merged in PR #885) and `docs/features/iphone-chat.md`.

## 1. Why

The owner wants three things (conversation of 2026-11-16):
1. **Simpler to maintain** — the Mac chat and the phone chat are one piece of software, not two.
2. **Live sync** — a turn started on one device streams on the other without the one-second database poll.
3. **Chat features reach the phone automatically** — a new chat feature is written once and shows on both devices, without a separate phone task.

Today (after #1791) the chat is written twice on both layers:
- **Engine.** The Mac runs its own turns in Swift (`ChatViewModel` → `ChatTurnDriver`/`ChatTurnStore`/`ChatTreeQueries`, its own `ChatSessionPool` of `ai session` processes). The phone's turns run in the Go hub (`internal/chatstore` + `internal/hub/chatrun`), a port of the same Swift write path. Two writers of the `chat_*` tables are kept apart by the `chat_turn_leases` table, kept in step by eight shared fixtures, and watch each other's turns by re-reading the database every second (`ChatForeignTurnModel`, the hub's `data_version` watch).
- **UI.** The phone has its own chat UI (`WatchtowerMobile/Sources/Features/Chats/`, about 5 000 lines in 20 files), view by view a near-copy of the Mac's (`WatchtowerDesktop/Sources/Views/Chat/`). Only text logic is shared (`WatchtowerChatText`: artifact parser, Markdown runs, quote reply, error texts); no view is.

## 2. Goals, non-goals, anti-goals

**Goals**
- G1. One chat engine in Go, inside the daemon, always on (not tied to Mobile). It is the only writer of the main chat's rows.
- G2. One chat protocol. The Mac speaks it over a local socket, the phone over the relay (the hub forwards). Same operations, same data model.
- G3. One SwiftUI chat package for macOS and iOS: messages, parts, cards, steps, sources, artifacts, composer, chat list rows. Only the navigation shell (split view, inspector, tab bar) stays per app.
- G4. Every message part carries a fallback (text and generic buttons), so a client that does not know a part kind still shows something useful.
- G5. A guard makes "forgot the phone" a test failure: every part kind the engine can emit has a view in the shared package.
- G6. Turns stream live (≤ 150 ms coalescing) to every client, whichever device started them.

**Non-goals (v1)**
- Embedded chats (Target, Track, Ideas, Meeting, setup assistants, automation editor, Reviewer, spec review thread, tuning chat) keep their own engine (`EmbeddedChatEngine`, `ai query`). They move to the shared views in a later wave; until then they keep the current Mac views.
- Workchat (the workbench session feed) is not a main chat and keeps its own reader.
- Phase-2 phone items that need pickers over the Mac's data (`@` mentions, `/` skills, project editing) become *possible* on the phone through the protocol but get no phone UI in v1 unless the shared composer gives it for free (§6.4).
- No new chat features. This is a move, not a redesign: the Mac chat looks and behaves as today.

**Anti-goals** (failure even if it technically works)
- The Mac chat is slower or less reliable than today (typing lag, lost text, a turn that dies more often).
- Two code paths remain "for safety" (a Swift writer kept as a fallback, a second feed builder). Any second path defeats G1/G3.
- Mac polish regresses because the shared views are the lowest common denominator (e.g. the TextKit 2 answer text replaced by plain SwiftUI text on the Mac).

## 3. Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Engine: Go, approach B "shared SwiftUI package + fallback views" (not separate UIs, not server-driven UI). | conversation 2026-11-16 ("твой вариант. B с запасными видами") |
| D2 | The engine lives inside the daemon, outside the mobile hub, always on whenever the daemon runs. | ask #1363 |
| D3 | The engine is the only writer of the main chat's `chat_*` rows. The Swift write path (`ChatTurnDriver`, `ChatTurnStore`, the writes of `ChatTreeQueries`, `ChatConversationQueries`, `ChatProjectQueries`, `ChatArtifactQueries`, `ChatLeaseQueries`, `ChatAttachmentStore`) is deleted for the main chat. | conversation (G1, anti-goal "no second path") |
| D4 | The Mac talks to the engine over a new socket `chat.sock` served by the daemon; newline-delimited JSON, the framing of `hub.sock`. The phone keeps the relay; the hub calls the engine in-process. | decided by the agent |
| D5 | One turn per conversation is an in-memory lock in the engine. `chat_turn_leases`, the `chat_lease` heartbeat flag, `desktop_too_old` and `ChatForeignTurnModel` are retired (§9.3). | decided by the agent (follows from D3) |
| D6 | One session pool in the engine: at most 3 live `ai session` processes, 10-minute idle TTL, a running turn never cut (CHAT-03 back to one pool; the hub's separate pool of 2 is gone). | decided by the agent |
| D7 | The wire data model is the phone's `ChatFeed`/`ChatList` (#1791), extended with typed parts and fallbacks (§5.3). It moves from WatchtowerKit to a new Kit-free package so WatchtowerCore and the Mac app can use it. | decided by the agent |
| D8 | New local package `WatchtowerChat/` with two targets: `ChatWire` (Foundation only: models, operations, `ChatClient` protocol, feed store) and `ChatUI` (SwiftUI views, depends on `ChatWire` + `WatchtowerChatText`). macOS 14 / iOS 17. | decided by the agent |
| D9 | Platform differences live inside `ChatUI` behind `#if os(macOS)` / `#if os(iOS)` in `Platform/` files, not in the apps: a feature author writes one view and the package picks the platform part. | decided by the agent |
| D10 | The Mac keeps its polish through platform parts: TextKit 2 answer text, the NSTextView composer, selection quote, print, Present, Open in Window. | anti-goal |
| D11 | No offline read path on the Mac. While the daemon is down the chat screen shows a "Chat is starting" / "Chat is unavailable" state with Retry; the composer keeps its draft. | decided by the agent (simplicity; one read path) |
| D12 | `chat.sock` carries no approval verb. The Mac approves and rejects chat actions as today (`actions approve|reject` CLI with owner-confirm, AGENT-07). The phone approves through the hub as today (`chat_action_answer`). | decided by the agent (AGENT-07 unchanged) |
| D13 | The app's start chain is unchanged: the daemon is still restarted at every app launch. | ask #1371 ("как сейчас — всегда") |
| D14 | Question cards are parsed in Go (`internal/chat/questions_contract.go` already owns the block) and sent as a `question` part; Swift `ChatQuestionCard` parsing is removed. | decided by the agent (one parser, the phone gets the card for free) |
| D15 | Every client sends `hello{protocol, client, part_kinds}`. The engine always sends a part's fallback; for a kind the client did not list it sends only the fallback (no payload). | conversation ("клиенты сообщают, что умеют рисовать") |
| D16 | Contract changes (§9) go to the owner in a separate ask before the review. | workbench rule |
| D17 | `chat.sock` serves only the signed Watchtower app (the `ownerconfirm` peer check, reversed); any other same-user process is refused. | decided by the agent (builder check: an open socket would hand agents owner-attributed turns and prefixes) |
| D18 | `ChatUI` takes its look from a small `ChatTheme` (tones, fonts, spacing) injected through the environment: the Mac app builds it from `DesignKit`, the phone from its `DesignSystem`. `DesignKit` does not move. The Desktop style-guide lint rules (colours only through Tone, no stock look, no row separators) apply to `ChatUI` (`make lint-swift` covers the package). | decided by the agent |
| D19 | The feed, the list and search go over the protocol (they need live updates). Other main-chat screens that only read — artifact version history, the project page, the inspector — may keep read-only GRDB reads; **every write** goes through the engine. | decided by the agent (builder check) |
| D20 | The engine opens its own database handle (one write connection + a small read-only pool), not the daemon's single-connection pool, so chat never waits behind a sync cycle's queries. | decided by the agent (builder check: `SetMaxOpenConns(1)` in `internal/db/db.go`) |
| D21 | On the relay path the engine always sends a part's payload and its fallback (the phone declares no kinds; the hub publishes one record per conversation). D15's "fallback only" applies to `chat.sock` clients. | decided by the agent |
| D22 | A new phone must work with a Mac one version behind: `ChatWire` builds parts from the flat fields when a feed carries no `parts` (one release). | decided by the agent |
| D23 | A daemon restart is instant and never waits for a turn; the turn runs on in its own `ai session` process, and the restarted engine reattaches to it and streams on (§7). | ask #1371 ("перезапуск моментальный — отдельный поток: перезапустился, переподключил сокет и льём") |
| D24 | The contract changes of §9.2 (CHAT-01/03/05, new CHAT-06, the superseded iphone-chat decisions) are approved as written. | ask #1371 |

## 4. Architecture

```
Mac app                                   daemon (sync --daemon)                         watchtower.db
───────                                   ──────────────────────                         ─────────────
ChatUI views ─▶ SocketChatClient ──chat.sock──▶ chatengine.Server ─┐
                                                                    ├─▶ chatengine.Engine ──spawn──▶ ai session (v2)
iPhone app                                                          │     │ (one writer)
ChatUI views ─▶ RelayChatClient ──relay──▶ hub actions/slices ──────┘     └──────────────────────────▶ chat_* rows
```

- **`internal/chatengine`** (new; absorbs `internal/hub/chatrun` and wraps `internal/chatstore`): the pool, the runner, the per-conversation turn lock, the live state of every running turn, the subscription fan-out, every chat operation. No hub imports.
- **`chatengine.Server`**: the `chat.sock` listener (§5.1). `PeerUID` moves from `internal/hub/platform` to a neutral `internal/platform` so `chatengine` keeps no hub imports.
- **Hub adapter**: `internal/hub/actions/handlers/chat_*.go` and `internal/hub/slices/sources/chat_*.go` stay, but call the in-process engine instead of `chatrun`/`chatstore` directly; the feed source reads the engine's snapshot (no `data_version` watch for chat).
- **Daemon wiring**: `cmd/sync.go` starts the engine before the hub and stops it after the hub (§7).

## 5. The protocol

### 5.1 Transport: `chat.sock`

- Path `<workspace>/chat.sock`, 0600, its folder 0700, peer UID checked (`platform.PeerUID`), one listener guarded by `chat.sock.lock` as `sessionhost.Listen` does.
- Framing: one JSON object per line, both ways; request lines ≤ 2 MiB (attachments are not sent inline, §5.2 `attach`).
- A connection starts with `hello` and then carries any number of requests and subscriptions. Each request has an `id`; its answer echoes the `id`. Pushed events have no `id`.
- Backpressure: a bounded queue of 256 events per connection. A connection that falls behind gets one `resync` event and its subscriptions are reset to a fresh snapshot (not dropped), so a slow Mac never misses the end of a turn.
- **Only the Watchtower app may connect (D17).** Today `ai session` writes no message rows, so an open `chat.sock` would give any same-user process (a workbench agent included) powers it lacks today: owner-attributed turns, `remember:`/`решили:` prefixes that store instructions and ideas, deletes, `attach` of any readable file. The engine therefore checks the connecting peer (pid from the socket) the way `internal/ownerconfirm` checks its peer, in reverse: the peer must be the Watchtower app signed by the CLI's own team, with ownerconfirm's existing dev-build rule. Any other peer is closed after `hello` with `forbidden`. The phone path is unaffected (relay, paired device, `chat` grant). Approvals are not on this socket either way (D12).

### 5.2 Operations

The phone's vocabulary (#1791, `ChatActionParams`) plus what only the Mac has today:

| Op | Params | Notes |
|---|---|---|
| `hello` | `protocol`, `client` (`mac`/`phone`), `part_kinds[]` | answer: engine protocol version, capabilities |
| `chat_new` | `project_id?`, `routing` | |
| `chat_turn` | `conversation_id`, `mode send\|regenerate\|edit\|retry\|continue`, `message_id?`, `text`, `attachment_ids[]`, `routing?`, **`compose`** `{skill?, mentions[], quotes[]}`, **`screen_context?`**, **`artifact_comment_ids[]`** | `compose` moves `ChatTurnComposer.compose` to Go (skill + REFERENCED lines, quote batch); `screen_context` is prefixed to the provider text only and never stored (⌘/ help); artifact comments are composed into the owner message and marked sent in the start transaction |
| `chat_cancel` | `conversation_id`, `turn_id` | |
| `subscribe` / `unsubscribe` | `list` or `conversation_id` (+ `before_message_id` for an older page) | snapshot, then events (§5.4) |
| `chat_page` | `conversation_id`, `before_message_id` | 60 messages |
| `chat_search` | `query` | `chat_fts` |
| `chat_read` | `conversation_id`, `message_id` | |
| `chat_branch_select` | `message_id` | |
| `chat_manage` | `conversation_id`, `op pin\|unpin\|rename\|delete\|move`, `title?`, `project_id?` | |
| `project_manage` | `op create\|update\|delete`, fields of `ChatProjectQueries` | drops warm sessions of the project's chats, as today |
| `artifact_manage` | `op keep\|unkeep\|comment_add\|comment_delete`, ids | Add to Knowledge and artifact comments |
| `attach` | `conversation_id`, `path` (Mac) or the sealed upload (phone, unchanged) | Mac: the engine copies the file the app picked (the app passes a path it holds; the engine validates and stores as `ChatAttachmentStore` does today) |
| `entity_search` | `query`, `kinds[]` | the `@` picker (`ChatEntitySearch` moves to Go) |
| `skills_list` | — | the `/` picker |

`chat_action_answer` exists only on the relay path (D12).

### 5.3 The feed model and parts

The phone's `ChatFeed.Message` gains `parts[]`; the old flat fields (`text`, `steps`, `artifacts`, …) stay populated for one release so a phone that is one version behind still works.

```json
{"kind": "approval",
 "payload": { ...kind-specific... },
 "fallback": {"text": "Send a Slack message to #general — waiting for your approval",
              "actions": [{"label": "Open on the Mac", "action": "none"}]}}
```

Part kinds in v1: `text`, `steps`, `sources`, `artifact`, `approval`, `question`, `error`, `remember_mark`, `knowledge_mark`, `published_link`, `attachment`, `routing_note`.
- The engine builds parts (one Go builder, `chatengine/parts.go`); clients never re-derive them from raw rows.
- A fallback's `actions` may only use generic, already-supported operations (`chat_turn` with a fixed text, `open_url` limited to the CHAT-05 open/copy rules, `none`). A fallback can never send or write anything an artifact could not (CHAT-05).
- The shared fixture `internal/chatengine/testdata/parts.json` lists every kind with one sample; Go and `ChatWire` both decode it.

### 5.4 Streaming

- `subscribe{conversation_id}` answers with a snapshot (the latest page, as `chat_feed` today), then pushes `message_upsert{message}` (whole message, by id) and `conversation_update{…}` events, coalesced to ≤ 150 ms while a turn runs.
- `subscribe{list}` pushes `list_update` (whole list, coalesced to ≤ 500 ms).
- The engine holds every running turn's live text and steps in memory (as `chatrun.Live` does), so a subscriber sees a turn live whoever started it (G6).
- The hub adapter turns the same events into the `chat_feed-<id>` / `chat_list` records it publishes today; the phone's record cadence (urgent, ~150 ms) is unchanged.
- Swift: one `ChatFeedStore` in `ChatWire` applies `snapshot` + `message_upsert` by id. On the phone the relay records arrive as snapshots; the same store takes them.

## 6. The Swift side

### 6.1 Package `WatchtowerChat/`

- `ChatWire` (Foundation): the models (moved from `WatchtowerKit/Models/Chat*.swift`), operations, `ChatFeedStore`, `ChatListStore`, and
  ```swift
  public protocol ChatClient: Sendable {
      func send(_ op: ChatOperation) async throws -> ChatEcho
      func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate>
      func list() -> AsyncStream<ChatListUpdate>
      var reachability: AsyncStream<ChatReachability> { get }
  }
  ```
  WatchtowerKit depends on `ChatWire` (no cycle: `ChatWire` imports nothing of ours). WatchtowerCore stays Kit-free (`PublicAPISurfaceTests` gains "may import ChatWire").
- `ChatUI` (SwiftUI): the conversation screen body (feed + composer), message rows, one view per part kind registered in `ChatPartRegistry`, `FallbackPartView`, artifact viewer, sources, steps, approval card (the Mac's per-connector cards included), question card, chat list row, search results, error and state lines. View models live here too (`ChatConversationModel`, `ChatComposerModel`, `ChatListModel`), written against `ChatClient`.
- `ChatUI/Platform/macOS`: TextKit 2 answer text (`MarkdownTextRun`, `MarkdownTableText`), `ChatComposerField` (NSTextView), `ChatSelectionQuote`, `ArtifactPrinter`, Present / Open in Window, `SandboxedHTMLView` glue, keyboard shortcuts.
- `ChatUI/Platform/iOS`: SwiftUI text runs (today's `ChatMarkdownView`), `TextField` composer with the phone's attachment picker, passage-picker quote sheet, sideways-scrolling tables, `SandboxedArtifactWebView`.
- The duplicated logic collapses into one: `ChatSourceGroups`/`ChatSourceGrouping`, `ArtifactHTMLPolicy`/`HTMLPreviewPolicy`, `ChatAttachmentLimits`/`AttachmentValidator` (validation moves to Go; the client only pre-checks size for a fast error), `ChatArtifactActions`/`ArtifactActions`.

### 6.2 The Mac

- `ChatViewModel` (1 524 lines) is split: UI state moves to `ChatUI`'s models; DB writes, pool and client are deleted; what stays in the app is `SocketChatClient` and the window shell (`ChatView` split, sidebar layout, inspector, ⌘K/⌘N, ⌘/ help panel).
- Deleted from the main chat: `ChatSessionPool`, `ChatSessionClient`, `ChatTurnDriver`, `ChatTurnStore`, `ChatLeaseQueries`, `ChatForeignTurnModel`, the write half of the chat queries, `releaseEarlierLaunchesChatLeases`, the `chat_lease` heartbeat flag. The read queries behind the feed, the list and search go too (the engine serves them); read-only queries of other screens stay (D19).
- The ⌘/ help popup uses the same `SocketChatClient` with `screen_context`.
- New state: **daemon unreachable** — "Chat is starting…" for the first 10 s after launch, then "Chat is unavailable — Watchtower's background service is not running" with **Retry** (restarts the daemon through the existing start chain). The draft stays; Send is off.
- Live: a turn started on the phone streams on the Mac at ≤ 150 ms with the normal Stop (no "answering from your iPhone, read-only" mode; Send is off only while that conversation's turn runs, as for a Mac turn).

### 6.3 The phone

- `WatchtowerMobile/Sources/Features/Chats/` keeps only the phone shell: the tab and its gate (`ChatsGateModel`), navigation, offline copy and prefetch (`ChatOfflineCopy`, `ChatPrefetcher`), `RelayChatClient` (wraps today's `ChatSender`/`ReplicaStore`/upload ledger), push routing. Everything inside a conversation and a list row comes from `ChatUI`.
- The offline copy stores `ChatFeed` pages as today; `ChatFeedStore` reads them.
- Chat stays relay-only (iphone-chat D4) and needs the `chat` grant (D9 there); this spec does not change the gate.

### 6.4 What reaches the phone for free

Because the composer and the parts are shared: question cards, remember / knowledge marks, published-link cards, per-connector approval cards, routing notes, and the `@` / `/` pickers (they run `entity_search` / `skills_list` over the protocol). Project editing, artifact comments and Add to Knowledge are shell UI on the Mac (inspector, artifact panel); on the phone they get the shared artifact viewer's controls in v1 and no project editor (v1 limit).

## 7. Daemon lifecycle

- The engine starts after the database opens and before the hub; `chat.sock` is served for the daemon's whole life, whatever the Mobile setting or MDM `MobileSync` (POLICY-03 still stops the hub and its published data; the Mac chat does not depend on it).
- **Turns outlive the daemon (D23).** A turn's `ai session` is no longer a child on the daemon's pipes:
  - The engine starts it detached (own process group, `setsid`) with a new flag `ai session --listen <workspace>/chatengine/sessions/<conversation>.sock` (0600 in a 0700 folder). Protocol v2 is unchanged; only the transport moves from stdio to that socket. The session accepts one client at a time and checks that the peer is the Watchtower CLI signed by the same team (as D17).
  - The session keeps the current turn's events in memory (the whole turn, capped like the feed record, 600 KB of text; past the cap it keeps the latest text snapshot plus every step event).
  - **Reattach.** On start the engine lists `chatengine/sessions/*.sock`, connects to each, sends `attach`, and the session replays the current turn's events from its start. The engine's writes are idempotent (text is set whole, steps upsert by id, artifacts by key and message), so a replay rewrites the same rows. Then the stream continues live. No turn waits for a restart, and nothing waits for a turn.
  - **Gap.** While no engine is attached nothing is written; the rows hold the last flush (≤ 1 s before the old engine went away). Clients reconnect to `chat.sock` with backoff (100 ms doubling to 2 s), resubscribe and get a fresh snapshot, then live events — the owner sees the answer pause for the length of the restart (about a second) and continue.
  - **Orphans.** A session with no attached engine keeps running its turn. After its turn ends it waits for an engine 10 minutes (idle TTL, CHAT-03), then exits. A session whose turn ended while detached hands the whole turn over on the next `attach`, so its final text and status are written by the next engine.
- **Restarts from the app** (`restartOnChain`: Turn on, the feature offer, Settings, Confluence spaces, the Inbox action strip, built-in automations; and every app launch, D13) are instant and need no change in the app. The engine stops without touching sessions: close `chat.sock`, detach from the session sockets, flush, close its database handle.
- **Stops that must end the chat** close the sessions first, through `chat_shutdown` on `chat.sock` (`cancel` each running turn, finalize `partial`, `close` each session, 2 s grace, SIGTERM, SIGKILL after 3 s): app quit (`QuitCoordinator`, where it calls `closeChatSessions` today), the data wipe, a Slack or account removal that purges data (PURGE), and `watchtower sync stop`. Compaction at launch runs before any session exists.
- **Startup sweep**: before reattaching, a `partial` assistant row of a running turn with no live session socket (the session died too) gets `error_code='session_lost'` (as `chatrun.Sweep` does today); stale socket files and pgid files of dead processes are removed.
- **App quit**: unchanged — the `QuitCoordinator` still stops the daemon, so turns end with the app (as today for Mac turns). Keeping the daemon after quit is out of scope.

## 8. Failure paths

| Failure | Behaviour | Test |
|---|---|---|
| Daemon not running when the Mac sends | Send is off; the draft stays; state line with Retry | `testDaemonUnreachableKeepsDraftAndShowsRetry` (ChatUI, fake client) |
| Socket drops mid-turn (daemon killed) | Client shows unreachable; on reconnect `subscribe` returns the row as `partial` with `session_lost` and the error card with Retry | `TestChatengine_KilledMidTurnSweepsSessionLost`, `testReconnectAfterDropShowsSessionLost` |
| `ai session` dies mid-turn | `partial`, `session_lost`, next turn replays (existing `TestChatstore_ProcessDeathFinalizesPartial`) | kept |
| Slow subscriber | `resync` + fresh snapshot, final state always delivered | `TestChatengine_SlowSubscriberResyncsAndSeesTurnEnd` |
| Two devices send to one conversation at once | First accepted wins; the other gets `busy` and its text stays in its composer (CHAT-01) | `TestChatengine_SecondTurnBusy`, `testBusyEchoReturnsTextToComposer` |
| Owner text when the engine refuses or fails before commit | Not written, returned to the composer | `TestChat01_RefusedTurnWritesNothing`, `testRefusedSendRestoresDraft` |
| Conversation deleted during a turn (from the other device) | Turn cancelled, no rows written after the delete | `TestChatengine_DeleteDuringTurnCancels` |
| Daemon restart while a turn runs (Settings, launch, update) | The session keeps running; the new engine reattaches, replays the turn and streams on; clients reconnect and resubscribe | `TestChatengine_RestartMidTurnReattachesAndFinishes`, `TestChatengine_ReplayIsIdempotent`, `testClientReconnectsAndResubscribesAfterDrop` |
| Turn ends while no engine is attached | Its end is written on the next `attach` | `TestChatengine_TurnEndedWhileDetachedIsWrittenOnAttach` |
| Session with no engine for 10 min after its turn | Exits; nothing left running | `TestAISession_ListenIdleExit` |
| Session and engine both die | Sweep marks `session_lost` | `TestChatengine_SweepWithoutSessionMarksLost` |
| App quit / wipe / `sync stop` | `chat_shutdown` ends every turn `partial` and reaps every session | `TestChatengine_ShutdownReapsSessions` |
| Unknown part kind on an older client | Fallback view | `testUnknownPartRendersFallback`, `TestChatengine_UnlistedKindSendsFallbackOnly` |
| Old phone (flat fields) on a new engine | Flat fields still filled for one release | `TestChatengine_FeedKeepsFlatFields` |
| A same-user process that is not the signed app dials `chat.sock` | `forbidden`, connection closed, nothing written | `TestChatengine_UnsignedPeerRefused` |
| A sync cycle holds the daemon's main DB handle | Chat reads/writes go on the engine's own handle | `TestChatengine_OwnHandleNotBlockedBySyncConn` |
| New phone, Mac one version behind (no `parts`) | `ChatWire` builds parts from flat fields | `testFeedWithoutPartsBuildsPartsFromFlatFields` |
| Attachment path the Mac passes is gone or too big | `attach` refused with the validator's reason; nothing stored | `TestChatengine_AttachRefusesMissingAndOversize` |

## 9. Writers, contracts and what is retired

### 9.1 Writers of the main chat's data

| Data | Writer after this change | Others |
|---|---|---|
| `chat_conversations`, `chat_messages`, `chat_steps`, `chat_artifacts`, `chat_attachments`, `chat_projects`, `chat_artifact_comments` (main chat) | `chatengine` | `ai session` itself writes the routing columns of `chat_conversations` (`SetChatRouting`/`SetChatActual`, `cmd/ai_session_routing.go`) — disjoint columns, the engine never writes them after start; `watchtower chat title` (title only, under `needsAITitle`, never over `title_source='user'`); embedded chats write their own rows (`context_type` not null) through `EmbeddedChatStore` — disjoint rows |
| `ideas` (chat-born), `instruction_chat_lines` | `chatengine` (prefixes, in-process) | the other existing writers of those tables, unchanged |
| `agent_actions` | `ai session` (propose), approve/reject as today | unchanged |

There is no race left between two chat writers: the engine serialises a conversation's writes on its turn goroutine and its operations under the conversation lock.

### 9.2 Contracts touched (owner approval needed, separate ask)

- **CHAT-01**: the owner row is written by the engine before the turn is sent; on the client the text stays in the composer until the engine's echo is `applied`. Guards move from the Swift `ChatViewModel` tests to Go `chatengine` + `ChatUI` model tests; assertions kept.
- **CHAT-02**: unchanged in meaning; guards move with the turn store (already twinned in Go).
- **CHAT-03**: one pool of 3 in the engine; the hub's pool of 2 and the Desktop's pool are gone.
- **CHAT-04**: unchanged (`ai session` spawn is the existing Go argv).
- **CHAT-05**: extended to fallbacks: a fallback action can only open or copy, or send a fixed owner text the owner taps. `ArtifactChat05ScanTests` moves to scan `ChatUI`.
- **New CHAT-06**: every part kind the engine emits has a registered `ChatUI` view and a non-empty fallback; guard `TestCHAT06_EveryPartKindHasFallback` (Go) + `testChat06EveryFixtureKindIsRegistered` (ChatUI).
- **iphone-chat D1, D5, D6, D11, D13, D18** are superseded (one engine, no lease table, one pool, live for every turn, no `desktop_too_old`).
- **CHAT-03** also gains: a detached session is bounded too — it exits 10 minutes after its turn with no engine attached; app quit, wipe and `sync stop` reap every session.

### 9.3 Retired

`chat_turn_leases` stops being written in this release and is dropped by a migration in the next one (an older app still running against a new daemon reads it; one release of overlap). `chat_lease` heartbeat flag, `chat_reason=desktop_too_old`, the hub's `data_version` chat watch, the eight Go↔Swift turn-store fixtures (kept only where a Swift reader remains: `artifact_parse_cases.json` for the streaming fence hider).

## 10. Mockups

New or changed states, each a `DesignShotCatalog` entry made in Task T0 before the screens change, compared with the snapshots after implementation:
- `chat-daemon-starting`, `chat-daemon-unavailable` (Mac; Retry).
- `chat-part-fallback` (Mac and phone: an unknown kind's fallback text and buttons).
- `chat-remote-turn-live` (Mac: a phone-started turn streaming with Stop).
- Phone: `iphone-chat-question-card`, `iphone-chat-approval-slack` (new on the phone, shared views).
- Unchanged screens are checked against today's shots (`chat-*` entries) for no visual change.

All interface texts (state lines, busy, unreachable, fallbacks built by the engine) are set in the model or the Go part builder and covered by a test.

## 11. Plan outline

| Task | What | Depends on |
|---|---|---|
| T0 | Design shots for §10 | none |
| T1 | `internal/chatengine`: absorb `chatrun`, wrap `chatstore`, in-memory lock, one pool of 3, live state, subscriptions, startup sweep, stop | none |
| T2 | Go composer (`compose` skill/mentions/quotes), `screen_context`, artifact comments in the start tx, `continue`/`retry`; `entity_search`, `skills_list`; `project_manage`, `artifact_manage`, `attach` by path | T1 |
| T3 | Part builder + fallbacks + `parts.json`; question parsing in Go | T1 |
| T4 | `chat.sock` server, framing, hello, backpressure/resync, signed-peer check (D17), own DB handle (D20); `PeerUID` move; daemon wiring | T1 |
| T5 | Hub adapter on the engine; flat fields kept; drop the `data_version` chat watch | T1, T3 |
| T6 | `WatchtowerChat/ChatWire`: models moved from the Kit, `ChatClient`, stores; Kit and Core depend on it | T3 |
| T7 | `ChatUI` shared views and models + platform parts; `ChatTheme` (D18); `ChatPartRegistry`; CHAT-06 guard; flat-fields adapter (D22) | T6 |
| T8 | Mac: `SocketChatClient`, split `ChatViewModel`, switch the chat screen and ⌘/ to `ChatUI`, delete the Swift writer and pool | T4, T7 |
| T9 | Phone: `RelayChatClient`, switch to `ChatUI`, delete the duplicated views | T5, T7 |
| T10 | `ai session --listen`, turn event buffer, idle exit; engine detach/reattach and replay; `chat_shutdown` from `QuitCoordinator`, wipe, purge, `sync stop` | T1 |
| T11 | Inventory, feature notes (`chat-redesign.md`, `iphone-chat.md`, new `unified-chat.md`), guide | all |

Every promise above maps to a task and a test in §8 or §9.2.

## 12. v1 limits

- Embedded chats and Workchat keep their own engines and the old Mac views.
- No chat on the Mac while the daemon is down (seconds at launch and during compaction; longer only if the daemon fails).
- Turns still end when the app quits (`chat_shutdown`); they survive every daemon restart.
- The phone gets no project editor.
- `chat_turn_leases` lingers one release before it is dropped.

## 13. Left to the builder

- Exact Go type names and file split inside `chatengine`.
- Coalescing implementation (timer vs ticker) within the stated bounds.
- How `ChatUI` registers platform parts (environment values vs protocol witnesses), as long as a feature view is written once.
