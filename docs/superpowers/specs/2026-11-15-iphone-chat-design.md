# AI chat on the iPhone, over the relay — design

Date: 2026-11-15. Board: #1791 (under the mobile umbrella #2). Status: draft for the owner's review.
Mockups: [`docs/design/mockups/iphone-chat/index.html`](../../design/mockups/iphone-chat/index.html).

## 1. Goal and scope

The owner uses Watchtower's main AI chat from the iPhone. The answer comes from the hub, which is the Go hub in the daemon, on the Mac or on a headless host. It has the whole database, every tool and the owner's own provider plan. The Mac and the phone show the same chats. A chat started on one can be continued on the other.

Chat works **only over the hosted relay**. On a CloudKit link the tab says so (§6.1, mockup 1e). While the Mac is asleep or the relay is unreachable, the phone reads what it already holds, and sending is off with a plain line (ask #1327).

**v1 (ask #1327 "as described"):**
- the chat list (pinned / recent / folded older, state dots, unread);
- the conversation feed with Markdown, tool steps, sources, error cards with Retry and Stop;
- attachments: photo, camera, files and PDF, within the Mac's limits; dictation through the keyboard's own mic;
- approvals of the chat's actions: Slack send, Jira writes, claude.ai connector writes;
- artifacts: view; open or copy only;
- choosing a project and a model for a new chat;
- regenerate, edit and branches ‹ i/n ›;
- the `запомни:`/`remember:` and `решили:`/`факт:` prefixes;
- titles, read state and a push when an answer is ready.

**Phase 2 (not in this spec's plan):**
- editing projects;
- `@` mentions and `/` skills (they need pickers over the Mac's database);
- quote-reply ("Ask about this") and artifact comments;
- Add to Knowledge;
- pin, rename and delete from the phone;
- search inside the chats.

## 2. Decisions

| # | Decision | Source |
|---|---|---|
| D1 | A turn started on the phone is run by the Go hub in the daemon, not by the Desktop app. Go becomes a second writer of the chat tables. | ask #1327 |
| D2 | v1 is the list in §1; the rest is phase 2. | ask #1327 |
| D3 | Mac offline: read what the phone holds; sending is off with a plain line. Nothing is queued. | ask #1327 |
| D4 | Relay only. The hub advertises `capabilities.chat = "on"` only while its transport is the relay. The phone shows chat only on an explicit `"on"`, so an old hub (key absent) is not a chat host. | conversation (owner's first message: "only through the relay") |
| D5 | The hub runs turns by spawning the existing `watchtower ai session` (protocol v2), unchanged. A Go turn store ports the Swift write path: `ChatTreeQueries`, `ChatTurnDriver`/`ChatTurnStore`, `LiveSlackMark`, the artifact persistence and the actions-outcome block. All backends, routing and the claude.ai gate come with `ai session` for free. | decided by the agent |
| D6 | One turn at a time per conversation, across processes: a `chat_turn_leases` row claimed in the same transaction that writes the owner's message. The first commit wins; the other side is refused with "busy" and can watch or Stop. | decided by the agent |
| D7 | Stop from the other device goes through the lease (`cancel_requested_at`). The lease owner sends `cancel` to its own session. Nobody signals another process. | decided by the agent |
| D8 | `ArtifactParser` and `MarkdownRunBuilder` (pure Foundation, now in WatchtowerCore) move to WatchtowerKit, shared by the Mac and the phone. Go gets an artifact parser twin over the same fixture. | decided by the agent |
| D9 | A new device grant `chat` lets a phone use chat. Approving actions also needs the existing `permissions` grant, never implied by `chat`. The default of the `chat` grant is asked in the contract ask (§9). | decided by the agent; default → contract ask |
| D10 | The phone keeps its own copy of the last feed of up to 30 conversations it opened (file-protected, per hub). That copy is what offline reading shows. The hub does not publish every chat's feed all the time. | decided by the agent |
| D11 | The feed streams from memory for hub-run turns (≤ 150 ms per update) and from the database for Mac-run turns (about 1 s, the Swift flush interval). | decided by the agent |
| D12 | Dictation is the iOS keyboard's mic. No speech code in the app. | decided by the agent (simplest) |
| D13 | Hub chat sessions are capped at 2 live processes, a 10-minute idle TTL and a queue beyond that, separately from the Desktop's 3. | decided by the agent |
| D14 | The push for a finished answer carries the conversation title and a fixed body, never answer text, like work alerts today. | decided by the agent |

## 3. Architecture

```
iPhone (Kit + app)                         Go hub (daemon)                              watchtower.db
─────────────────                          ───────────────                              ─────────────
Chats tab ── actions ──relay──▶ actions/handlers/chat_*.go ──▶ chatrun.Runner ──spawn──▶ ai session (protocol v2)
   ▲                                   │                         │  events                    │
   │                                   │                         ▼                            │
   └── chat_list / chat_feed ◀─relay── slices/sources/chat_*.go ◀── chatstore (Go turn store) ─┼─▶ chat_* rows
                                                                                               │
Desktop ChatViewModel ── Swift turn store ──────────────────────────────────────────────────────┘
         └── chat_turn_leases (one turn per conversation, either writer)
```

New Go packages:
- `internal/chatstore`: the turn store, leases, artifact parser twin, outcome block, prefix commands and title hook. It has no hub imports, so it can be tested alone.
- `internal/hub/chatrun`: the session pool and turn runner, the cancel watcher and the startup sweep.
- Handlers in `internal/hub/actions/handlers/chat_*.go`.
- Sources in `internal/hub/slices/sources/chat_list.go` and `chat_feed.go`.

## 4. The hub

### 4.1 Turn store (`internal/chatstore`)

This is a port of the Swift write path with the same rows, order and statuses (recon of 2026-11-15; the Swift files are named in brackets).

**Start.** One `BEGIN IMMEDIATE` transaction does the following (`ChatViewModel.persistTurnStart`):
1. Claim the lease (§4.4); if it is refused, nothing else is written.
2. Insert the owner row: `role=user`, `status=complete`, `parent_id=tip`, `turn_id`. Regenerate skips this and reuses the owner row.
3. Link the attachments: `chat_attachments.message_id`.
4. Set the prefix title (first 80 chars, only when `title_source='prefix' AND title=''`).
5. Set routing when pinned.
6. Insert the assistant row: `text=''`, `status=partial`.

Every insert moves `active_leaf_message_id` and `updated_at` (`ChatTreeQueries.insert`). Only after the commit does the runner send `turn`.

**Edit.** Edit inserts a sibling owner row (`parent_id = original.parent_id`) and a new assistant row under it. As on the Mac, attachments stay on the original message (v1 limit, unchanged). Regenerate re-sends the owner's attachments with `replay: true`. Branch select moves the leaf to the newest leaf under the chosen sibling (`ChatTreeQueries.selectSibling`).

**During the turn** (`ChatTurnDriver`; writes in event order on one goroutine):
- `session_ready`: actual provider and model, as `saveActual` does.
- `text_delta`: flush the text every 1 s as `partial`, with the tokens.
- `tool_start`: upsert a step at once (CHAT-02), then `LiveSlackMark.markIfSlackStep`.
- `tool_end`: finish the step with its sources, then force a flush.
- `tool_wait`: make sure a step exists.
- `usage`: kept for the next write.

**End.** One transaction (`finalizeTurn`) writes:
- the text, status, tokens, error code and message;
- the model;
- the Live Slack backstop mark;
- the artifacts, unless the status is `error`; this uses the Go `ArtifactParser` twin and `saveVersion` semantics (overwrite the same message's version, else `MAX(version)+1`);
- the lease release.

The status mapping is the Swift one:
- `turn_done complete` → `complete`;
- interrupted, Stop or process death → `partial`;
- a turn error → `error`, except quota with text → `partial`.

**Owner text sent to the session.** The owner's text, prefixed with the actions-outcome block (a port of `AgentActionFeed.outcomesBlock(after:)`) when actions settled since the previous owner message. The stored owner row holds only what the owner typed, as on the Mac.

**After the owner row is on disk** (not on regenerate or retry):
- `instructions.ParseRemember` leads to the same Go code the `instructions remember` CLI runs.
- `ideas.ParseKnowledgePrefix` leads to a new `db.CreateIdeaFromChat`. It is the Go twin of Swift `IdeaQueries.createFromChat`, pinned by a shared fixture with the same columns, `chat_born=1` and status.

Both run in-process, never through the CLI.

**After the first `complete` answer:** the same Go function `watchtower chat title` calls, under the same `needsAITitle` condition. It never writes over `title_source='user'`.

**Read state.** `chat_read` does what `ChatConversationQueries.markRead` does: `read_at = MAX(read_at, created_at of the last complete answer on the active branch)`, and `updated_at` is untouched.

### 4.2 Artifact parser twin

Go `chatstore.ParseArtifacts(text, final)` follows the grammar of `ArtifactParser.swift`: `:::artifact key="…" kind="…" title="…"` fences, kinds `document|table|email|slack|event|code|html`, and the last block of a key wins. Both sides read one new fixture, `internal/chat/testdata/artifact_parse_cases.json`. The existing `artifacts_examples.md` stays the prompt-side fixture.

### 4.3 Runner (`internal/hub/chatrun`)

- **Pool.** At most 2 live `ai session` processes (D13), a 10-minute idle TTL on a 30 s check, and LRU eviction of idle sessions only; a running turn is never cut. A third conversation's turn waits in a queue and is visible as "Waiting for a free slot".
- **Spawn.** `<os.Executable()> ai session --conversation N --surface main [--provider P --model M] [--project-id K] --db-path <db>`, in the daemon's working directory and with the daemon's environment. It runs in its own process group, killed and waited for on close, as `sessionhost/ensure.go` does. A routing change (provider or model) recycles the session, as `ChatSessionConfig.isCompatible` does.
- **Replay.** It reuses `ChatContinuity` semantics: `replay: true` unless this process's last completed turn is the current tip. So after a Mac-run turn, the hub's next turn replays.
- **Cancel watcher.** While a turn runs, the runner reads `chat_turn_leases.cancel_requested_at` every 1 s. A set value sends `cancel`. With no `turn_done` within 7 s, it finalises `partial`, then SIGTERM and SIGKILL, the same numbers as `ChatSessionClient`.
- **Lease heartbeat.** Every 15 s while a turn runs.
- **Startup sweep.** Before the first claim, every lease with `owner='hub'` and this hub's id is released. Its assistant rows are already `partial`, with the text flushed at most 1 s before the death. Those turns get `error_code='session_lost'` for the error card.
- **Daemon stop.** It closes the sessions before the database closes: `close`, a 2 s grace, SIGTERM, then SIGKILL after 3 s. It waits for the store's last write.
- **Logs.** Ids and counts only (FILES-01). `chatrun` gets a `TestFILES01_*` canary.

### 4.4 Turn lease (`chat_turn_leases`, migration)

```sql
CREATE TABLE chat_turn_leases (
  conversation_id     INTEGER PRIMARY KEY REFERENCES chat_conversations(id) ON DELETE CASCADE,
  owner               TEXT NOT NULL CHECK (owner IN ('desktop','hub')),
  owner_id            TEXT NOT NULL,      -- desktop: app launch uuid; hub: hub id
  turn_id             TEXT NOT NULL,
  started_at          TEXT NOT NULL,
  heartbeat_at        TEXT NOT NULL,
  cancel_requested_at TEXT                -- set by the other side's Stop
);
```

**Claim.** Inside the start transaction: `INSERT … ON CONFLICT(conversation_id) DO UPDATE … WHERE heartbeat_at < now − 60 s`. If no row changed, the claim is refused and the transaction rolls back.

**Release.** `DELETE … WHERE conversation_id = ? AND turn_id = ?`, inside the finalize transaction.

**Stale.** A heartbeat older than 60 s means anyone may take the lease. The dead owner's rows stay `partial`.

**Writers:**
- the Swift turn store (claim, heartbeat, release, honouring cancel);
- the Go turn store (the same);
- either side's Stop, which sets `cancel_requested_at` only, under `WHERE turn_id = ?`.

**Race.** Both writers claim in `BEGIN IMMEDIATE`, so SQLite serialises them and the first commit wins (§8).

### 4.5 Actions

All of these require the `chat` grant. A refusal names the missing grant; a server hub adds the `watchtower hub allow` line. They are registered in `handlers.Register` and the nudge table, and are additive per protocol spec §8.

| Kind | Params | Non-idempotent | Result / refusals |
|---|---|---|---|
| `chat_new` | `client_key` (uuid), `project_id?`, `routing {mode auto\|pinned, provider?, model?}` | yes | `{conversation_id}`; `invalid_params`, `not_found` (project) |
| `chat_turn` | `conversation_id`, `mode send\|regenerate\|edit`, `message_id?` (regenerate/edit), `text` (≤ 32 000 chars), `attachment_ids[]`, `routing?` | yes (+ `received` echo) | `{user_message_id, assistant_message_id, turn_id}` once the start transaction committed (the turn then runs in the background); `conversation_busy` (lease held), `not_found`, `invalid_params`, `attachment_missing` |
| `chat_cancel` | `conversation_id`, `turn_id` | no | `{}`; `not_found` when no such running turn |
| `chat_feed_request` | `conversation_id` | no | watches the feed for 5 min; the phone repeats it every 60 s while the screen is open (the `session_chat_request` model) |
| `chat_read` | `conversation_id`, `message_id` | no | `{}` |
| `chat_branch_select` | `message_id` | no | `{}`; refused while a turn runs in that conversation |
| `chat_action_answer` | `action_id`, `decision approve\|reject`, `args_sha256` | yes | needs `permissions` too; approve goes through `Registry.ApproveSeen` with the hash of the args the phone showed; a stale hash → `failed/changed` ("The action changed — look again") |

**Attachments, phone to hub.** A new upload frame, `chat_attachment`, is modelled on `recording_upload`.
- **Descriptor:** `upload_id`, `conversation_id`, `name`, `mime`, `size`.
- **Validation:** the hub decrypts and checks the Mac's limits: images png/jpeg/gif/webp ≤ 5 MB, PDF ≤ 32 MB, text ≤ 256 KB, one message ≤ 30 MB encoded. These checks are ported from `ChatAttachmentStore`, with the phone twin pinned by a shared case fixture.
- **Storage:** 0600 under `<workspace>/chat_files/`, sha256-deduplicated per conversation, with a `chat_attachments` row (`message_id NULL`).
- **Echo:** `applied {attachment_id}`.
- **Before upload:** the phone converts HEIC to JPEG and downsizes images over 5 MB, as `PastedContent` does on the Mac.

### 4.6 Slices

Two new kinds go into `AllKinds`, the `dataKinds` in `secure` and the Kit `SliceKind`, each with a Kit fixture read by both sides.

**`chat_list`**
- One record, published while a linked phone holds the `chat` grant.
- It holds up to 200 non-archived conversations. Each has:
  - `id`, `title`, `pinned`, `updated_at`;
  - `project {id,name}?`;
  - `state` (`waiting|answering|unread|read`, the Mac's precedence; `waiting` = a pending `agent_actions` row of its last turn, `answering` = a live lease);
  - `last_line` (≤ 120 chars);
  - `lease_owner?`.
- It also holds `projects[]` (id and name) and `models[]` (from the provider catalog: provider, model, display name and the capabilities the composer needs, i.e. images and PDF), plus `error?` when the read failed (mockup 1h).
- It is rebuilt on the `data_version` change. It is not urgent.

**`chat_feed`**
- One record per watched conversation (`chat_feed-<id>`), in memory only, deleted when the watch ends (the `session_chat` model).
- Payload:
  - conversation meta: title, project, routing, actual provider and model, `live_slack_since`, `lease {owner, turn_id, waiting_slot?}`;
  - the active branch's last 60 messages, each with `id`, `role`, `text`, `status`, `error_code`, `error_message`, `created_at`, `siblings {index,count}`, `attachments[] {id,name,mime,size}`, `steps[] {name, ok?, summary, sources[]}`;
  - the latest version of each artifact key, with content;
  - the pending and recent `agent_actions` of those turns: `id`, `tool`, `title`, display args, `args_sha256`, `status`, reason.
- Cap: 600 000 bytes. Over the cap, the oldest messages are dropped first (with a "Earlier messages are on your Mac" marker), then artifact contents (marked "Open on your Mac"). One message's text is capped at 40 000 chars, with the cut marked.
- Urgent kind, ordered after the ask kinds.
- Source of the live text:
  - for a hub-run turn, the runner's memory, with `OnChange` → `PublishSoon`; at relay spacing that is 150 ms;
  - for a Mac-run turn, the database on the `data_version` watch (D11).

### 4.7 Push

A new work-alert event, `chat_answer`, with a new optional `conversation_id` field. It is sent for a **hub-run** turn that ended `complete`, `error` or `partial` after a cancel, or that started waiting for an approval, when no `chat_feed_request` for that conversation arrived in the last 90 s (the phone is not looking).
- Title: the conversation title, clipped.
- Body: fixed text. "Answer ready", "The answer stopped" or "Waiting for your approval" (D14).
- Owner-away rules and the paying-slot targets are as today.
- The phone's router opens the conversation.
- `TestAlertPushPayloadKeysMatchTheKit` and `go-sealed.json` gain the field.

### 4.8 Capability and the relay-only gate

**Heartbeat.**
- `capabilities.chat` is `"on"` while the hub's transport is the relay and `chatrun` started.
- It is `"off"` on CloudKit or when the runner failed to start; the failure reason goes to the log.
- A `Deps.ChatAvailable()` seam lets every `chat_*` handler refuse with `not_supported` when chat is not on, so a stale phone cannot run a turn over CloudKit.

**Protocol spec.** `2026-10-31-hub-phone-protocol-design.md` §7.2 and §9 gain the new kinds and the "explicit on" rule.

## 5. Desktop changes

**Lease in the Swift turn store.**
- `persistTurnStart` claims (refused → no rows are written, and the composer shows the busy line);
- the driver sends a heartbeat every 15 s and checks `cancel_requested_at` every 1 s (a set value runs the existing Stop path);
- `finalizeTurn` releases.
- The app's `owner_id` is a uuid per launch. At launch, the app releases its own stale leases left by a crash: a lease with `owner='desktop'` whose `owner_id` is not the current launch.

**A turn run elsewhere.** While a live lease with `owner='hub'` holds the open conversation:
- the thread reloads from the database every 1 s and once more at the release;
- the composer shows **Answering from your iPhone — you can watch here**, with Stop, which sets `cancel_requested_at` (mockup 4a);
- Send is off until the release. The draft is kept.
- The Chats panel shows "answering" for hub leases (`ChatHistoryQueries.panelRows` reads the lease).

The line texts are set in the model and tested.

**Settings → Mobile → a phone.** A **Chat** toggle (the `chat` grant), beside the existing typing and permissions toggles.

**Design shots.** A `DesignShotCatalog` entry, `chat-phone-turn`, for 4a.

## 6. The phone

### 6.1 Tab and gate

A fourth tab, **Chats**, between Workbench and Calendar. The gate is checked in this order, with each state's text set in a model and tested:

| State | When | Mockup |
|---|---|---|
| needs update | no `capabilities.chat` key | 1f |
| needs Relay | route is CloudKit | 1e |
| not allowed | `chat_*` refused with `device_not_allowed`, or the `device_grant` record says no chat | 1g |
| loading | no `chat_list` record yet | 1c |
| error + Retry | `chat_list.error` with no rows (Retry re-requests the publish through `chat_feed_request` with id 0) | 1h |
| empty | zero conversations | 1b |
| offline (read only) | heartbeat stale (the existing Mac status chip rule) or relay unreachable | 1d / 2e |
| ready | — | 1a |

### 6.2 Screens

- **List** (1a): Pinned / Recent (7 days) / "▸ N older", with dots in the Mac's precedence. Orange is only `waiting`, so `OrangeToneTests` gains the case. ✎ starts a new chat (2h).
- **Conversation:**
  - Owner bubbles (`ChatBubble.owner`) with attachment thumbnails or file pills.
  - Answers rendered by the shared `MarkdownRunBuilder` (moved to the Kit, D8) into SwiftUI text runs, with headings, lists, code, quotes and tables. Tables scroll sideways on the phone; the Mac does not change.
  - A collapsed steps row and a sources chip that opens the sources sheet (3c).
  - Artifact cards, ‹ i/n ›, Regenerate and Copy on the last answer. Long-press on an owner bubble → Edit.
  - Error card with Retry for retryable codes (2d).
  - Approval cards (2c), orange, with Approve and Reject. Without the `permissions` grant they show "Approve on the Mac".
- **Composer:**
  - Text, the + sheet (3a: camera, photo library, Files) and Send, which becomes Stop while a turn runs, on either device (2b, 2f).
  - Model and project chips above it, editable until the first message (2h).
  - Off while offline (2e).
  - A draft is kept per conversation in memory.
- **Artifact sheet** (3b):
  - `document`, `table` and `code` as Markdown;
  - `html` in a sandboxed `WKWebView`: non-persistent store, a content rule blocking every non-local load, no message handlers, navigation pinned (the Mac's `HTMLPreviewPolicy` rules);
  - `email` → Open in Mail (`mailto:`), `event` → Google Calendar template URL, `slack` → Copy and open Slack;
  - Copy and Share on all of them.
  - Nothing sends (CHAT-05).

### 6.3 Sending and streaming

**Send.**
1. A new chat first sends `chat_new`.
2. Attachments upload; each pill shows its own progress and failure.
3. Then `chat_turn`.

The owner bubble shows pending until the `chat_turn` echo is `applied`. A refused echo puts the text back into the composer with the reason (CHAT-01 on the phone: the owner's text is never lost).

**Streaming.** The feed record updates and the view diffs it by message id. While a turn runs, the view hides a partial `:::artifact` fence with the shared `ArtifactParser`, as the Mac does.

### 6.4 Offline copy (D10)

The phone writes the last decoded `chat_feed` per conversation to its own GRDB file: per hub, with file protection `completeUntilFirstUserAuthentication`, at most 30 conversations by last opened, evicted LRU. It is deleted with the hub link.
- This is a display copy only. Nothing on the phone reads it except the conversation screen.
- The Mac's `live_slack_since` rule is unchanged, and the copy keeps Live turns for display only (see the contract ask, §9).

## 7. Failure paths

| Path | What happens | Test |
|---|---|---|
| Daemon quits mid-turn | Sessions close (grace, then kill); the last flush is ≤ 1 s old; the row stays `partial`; the lease is released at the next start (sweep), or taken by the Mac after 60 s | `TestChatrun_DaemonStopLeavesPartialAndSweepReleases` |
| Daemon killed (no clean stop) | The same, without the clean close; the `ai session` child dies with its group or is reaped by the sweep's group check; the next hub start sweeps the lease and marks `session_lost` | `TestChatrun_StartupSweepMarksSessionLost` |
| `ai session` crashes mid-turn | `partial` with `session_lost`; the next turn replays | `TestChatstore_ProcessDeathFinalizesPartial` (twin of `testChat01PartialTextSurvivesProcessDeath…`) |
| Relay drops mid-stream | The hub keeps running the turn and writing rows; the phone shows the Mac chip state and resyncs the feed on reconnect (the last record wins) | Kit `ChatFeedReconnectTests` |
| Phone sends the same `chat_turn` twice (retry) | The exactly-once ledger replays the stored echo; a crash mid-apply answers `outcome_unknown` and never runs twice | `TestChatTurn_RepeatReplaysEcho`, `TestChatTurn_CrashMidApplyIsOutcomeUnknown` |
| Phone and Mac send at the same moment | `BEGIN IMMEDIATE` serialises the claims; the loser writes nothing: the phone gets `conversation_busy` and its text back, the Mac shows the busy line | `TestLease_ConcurrentClaimOneWins` (Go, two connections); Swift `ChatTurnLeaseTests` |
| Owner of the lease dies | After 60 s without a heartbeat the other side may claim; the dead turn's row stays `partial` | `TestLease_StaleIsClaimable` |
| Stop from the other device | `cancel_requested_at` is set; the owner cancels within ≤ 1 s, then within 7 s finalises; a cancel for an ended turn is a no-op (`turn_id` guard) | `TestChatrun_RemoteCancelStopsTurn`, `testDriverHonoursRemoteCancel` |
| Approval answered, but the session died | The gate already expires the row (`TestChat05_DeadSessionNeverRunsAnApprovedCall`); `chat_action_answer` gets the row's final state | `TestChatActionAnswer_DeadSessionRowIsFinal` |
| Approval args changed since the phone showed them | `ApproveSeen` hash mismatch → `failed/changed` | `TestChatActionAnswer_StaleHashRefused` |
| Attachment upload cut mid-way | The relay attachment is never applied; no row is written; the phone shows Retry on that pill; `chat_turn` with a missing id → `attachment_missing` | `TestChatAttachment_PartialUploadWritesNothing` |
| Attachment over the limits | Refused with the Mac's reason text | shared case fixture, both sides |
| Feed over 600 KB | Oldest messages dropped first, then artifact contents, with markers | `TestChatFeed_CapsDropOldestThenArtifacts` |
| Hub switches to CloudKit while a phone is in a chat | The capability turns `off`; handlers refuse with `not_supported`; a running turn finishes and is visible on the Mac | `TestChatHandlers_RefuseWhenNotOnRelay` |
| Phone unlinked | Watches are dropped; the feed records are deleted; the offline copy is deleted with the link | `TestChatFeed_UnlinkDropsWatches`; phone `ChatOfflineCopyTests` |
| Third concurrent hub conversation | Queued, "Waiting for a free slot" in the feed's lease | `TestChatrun_PoolQueuesBeyondTwo` |

## 8. Writers of the same data, and who wins

| Data | Writers | Race rule |
|---|---|---|
| `chat_messages`, `chat_turn_steps`, `chat_artifacts`, `chat_attachments.message_id` of a turn | Swift turn store, Go turn store | Only the lease holder writes a turn's rows. The claim is in the owner-row transaction, so the first commit wins. |
| `chat_turn_leases` | both turn stores (claim, heartbeat, release); either Stop (`cancel_requested_at`) | Claim by conditional upsert; Stop only under `turn_id`; release only by its own `turn_id` |
| `chat_conversations.active_leaf_message_id` | both stores; branch select (Mac UI, `chat_branch_select`) | Branch select is refused while a lease is live, so nobody moves the leaf under a running turn |
| `chat_conversations.read_at` | Swift `markRead`, Go `chat_read` | `MAX(…)`, never backwards: both orders converge |
| `chat_conversations.title`/`title_source` | Go title (both hub and CLI paths), Swift rename | The existing rule: AI never writes over `title_source='user'` |
| `chat_conversations.live_slack_since` | both stores | Set once (`WHERE live_slack_since IS NULL`), first wins |
| `agent_actions` status | the chat MCP server (propose), Desktop approve, `chat_action_answer`, the gate | The existing compare-and-set in `ApproveSeen`/`ClaimSessionCall`; the second decision gets the row's current state |
| `chat_attachments` rows (new) | Swift `ChatAttachmentStore`, Go upload intake | Each upload is its own row (no unique key exists, none is added). Only the file is deduplicated by sha256 per conversation, so two rows may share one path. The file is written to a temp name and renamed into place, so a concurrent writer of the same bytes leaves one whole file. Deleting a row never deletes a path another row still uses (the existing rule). |
| `ideas` (chat-born) | Swift `IdeaQueries.createFromChat`, Go `db.CreateIdeaFromChat` | Each runs only for the owner row its own store wrote, so there are no duplicates |

## 9. Contracts touched (filed as a separate ask before the review)

- **CHAT-01:** "the Swift turn store is the writer" → "the lease holder's turn store (Swift or Go)". The same order and `partial` rules apply, with Go guards added. No Swift guard changes.
- **CHAT-02:** the Go store writes steps at once. New Go guard.
- **CHAT-03:** a second bounded pool in the daemon (2 processes, reaped on daemon stop). New guards.
- **CHAT-05:** the phone's artifact sheet only opens or copies. A source scan over the phone's artifact files: no `URLSession`, no action enqueue, no `send`.
- **LIVE-01:** the mechanism gains the Go store (the same mark points). The phone's offline copy is a display copy (like `chat_messages` itself). The feed builder joins `displayOnlyReaders`.
- **Hub grants:** the new `chat` grant and its default.
- **Mobile protocol:** new kinds, plus the explicit-`on` capability rule.

## 10. Testing and traceability

| Promise | Task | Test(s) |
|---|---|---|
| Owner row before the turn; `partial` on Stop/crash (CHAT-01) | T3 | `TestChat01Go_OwnerRowBeforeTurn`, `TestChatstore_ProcessDeathFinalizesPartial`, `TestChatstore_StopKeepsPartial` |
| Same rows as Swift for a scripted event stream | T3 | `TestChatstore_MatchesSwiftFixture`: a Go-written database from `chat_turn_cases.json` compared with the Swift `ChatTurnStoreFixtureTests` over the same fixture |
| Steps written as they happen (CHAT-02) | T3 | `TestChat02Go_StepPersistedOnStart` |
| Artifact grammar twin | T2 | `artifact_parse_cases.json` in Go and Kit |
| Prefix commands and chat-born ideas twin | T3 | `knowledge_prefix_cases.json` (existing), new `chat_idea_rows.json` |
| Lease: one winner, stale claim, cancel | T1, T3, T8 | §7 rows |
| Pool bound, queue, reap (CHAT-03) | T4 | `TestChat03Go_PoolBound`, `TestChatrun_DaemonStopLeavesPartialAndSweepReleases` |
| Actions: grants, refusals, exactly-once | T5 | per-kind handler tests; `TestChatHandlers_RefuseWithoutChatGrant`, `TestChatActionAnswer_NeedsPermissions` |
| Relay-only | T5 | `TestChatHandlers_RefuseWhenNotOnRelay`, heartbeat case in `hub_contract_cases.json` |
| Slices: payload keys, caps | T6 | Kit fixtures `workbench/chat_list.json`, `chat_feed.json` (Go and Kit); `TestChatFeed_Caps…` |
| Push payload | T7 | `TestAlertPushPayloadKeysMatchTheKit`, `go-sealed.json` |
| Desktop busy line, foreign turn reload, cancel | T8 | `ChatTurnLeaseTests`, `ChatForeignTurnModelTests` (texts), DesignShot `chat-phone-turn` |
| Phone gate states and texts | T10 | `ChatsGateModelTests` |
| Phone feed, composer, CHAT-01 on the phone, approvals | T11 | `ChatConversationModelTests`, `ChatSendTests`, `ChatApprovalWiringTests` |
| Phone artifacts never send (CHAT-05) | T11 | `PhoneArtifactChat05ScanTests` |
| Offline copy | T11 | `ChatOfflineCopyTests` |
| Screens match the mockups | T10, T11 | new `ScreenshotTourTests` shots (`SHOTS_ONLY=chat`), compared with this spec's mockups before review |
| Logs carry no chat content | T4 | `TestFILES01_Chatrun` |

## 11. Plan outline

| Task | Title | Depends on |
|---|---|---|
| T1 | Migration `chat_turn_leases` + Go lease API | none |
| T2 | Move `ArtifactParser` + `MarkdownRunBuilder` to the Kit; Go artifact parser twin | none |
| T3 | Go turn store (`internal/chatstore`) | T1, T2 |
| T4 | Hub chat runner (`internal/hub/chatrun`) | T3 |
| T5 | Hub actions, the `chat` grant, the attachment upload frame, the capability | T4 |
| T6 | Slices `chat_list` + `chat_feed`; Kit mirrors and fixtures | T3 |
| T7 | `chat_answer` push | T5, T6 |
| T8 | Desktop: lease in the Swift store, foreign-turn view, Stop, the Chat toggle, DesignShot | T1 |
| T9 | Kit: action params and the frozen kind lists | T5 |
| T10 | Phone: Chats tab, gate and list | T6, T9 |
| T11 | Phone: conversation, composer, attachments, approvals, artifacts, sources, branches, offline copy | T10 |
| T12 | Docs: feature note, guide pages (iPhone → Chat), inventory amendments, protocol spec §7/§9 | all |

Lanes run in parallel where the dependencies allow: T1, T2 and T8 start together; T6 and T4 run side by side after T3.

## 12. v1 limits

- Phase 2 items (§1) are not in v1.
- A new chat's model and project are fixed after the first message, as on the Mac.
- Edited messages keep their attachments on the original, as on the Mac.
- A Mac-run turn streams to the phone at about 1 s, not 150 ms.
- The offline copy holds only the conversations opened on this phone, at most 30.
- The hub's 2-session pool is separate from the Desktop's 3. With both busy, up to 5 provider processes run on one Mac.
