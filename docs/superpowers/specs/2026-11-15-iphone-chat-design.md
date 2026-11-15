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
- titles, read state and a push when an answer is ready;
- the whole history of a chat, paged (§4.6);
- search over the chats (titles and text, the Mac's `chat_fts`);
- pin, rename and delete, with Undo;
- quote-reply ("Ask about this" on a selected passage of an answer).

**Phase 2 (not in this spec's plan) — exactly the list agreed in ask #1327:**
- editing projects;
- `@` mentions and `/` skills (they need pickers over the Mac's database);
- artifact comments;
- Add to Knowledge.

## 2. Decisions

| # | Decision | Source |
|---|---|---|
| D1 | A turn started on the phone is run by the Go hub in the daemon, not by the Desktop app. Go becomes a second writer of the chat tables. | ask #1327 |
| D2 | v1 is the list in §1; the rest is phase 2. | ask #1327 |
| D3 | Mac offline: read what the phone holds; sending is off with a plain line. Nothing is queued. | ask #1327 |
| D4 | Relay only. The hub advertises `capabilities.chat = "on"` only while its transport is the relay. The phone shows chat only on an explicit `"on"`, so an old hub (key absent) is not a chat host. | conversation (owner's first message: "only through the relay") |
| D5 | The hub runs turns by spawning the existing `watchtower ai session` (protocol v2), unchanged. A Go turn store ports the Swift write path: `ChatTreeQueries`, `ChatTurnDriver`/`ChatTurnStore`, `LiveSlackMark`, the artifact persistence and the actions-outcome block. All backends, routing and the claude.ai gate come with `ai session` for free. | decided by the agent |
| D6 | One turn at a time per conversation, across processes: a `chat_turn_leases` row claimed in the same transaction that writes the owner's message. The first commit wins; the other side is refused with "busy" and can watch or Stop. | decided by the agent |
| D7 | Stop from the other device goes through the lease (`cancel_requested_at_ms`). The lease owner sends `cancel` to its own session. Nobody signals another process. | decided by the agent |
| D8 | `ArtifactParser`, `MarkdownRunBuilder` and `ChatQuoteReply` (pure Foundation, now in WatchtowerCore) move to a new local package `WatchtowerChatText/` (not WatchtowerKit, see "Changed during implementation"), shared by the Mac and the phone. Go gets an artifact parser twin over the same fixture. | decided by the agent |
| D9 | A new device grant `chat` lets a phone use chat. Approving actions also needs the existing `permissions` grant, never implied by `chat`. It is **on by default** for already linked and new phones; the owner can turn it off per phone. | decided by the agent; default: ask #1340 |
| D10 | The phone keeps its own copy of every chat page it loaded, plus a background prefetch of the 20 most recent chats' latest pages while the Mac is reachable. The budget is 200 MB per hub, evicted by last opened. That copy and the stored `chat_list` are what offline reading shows. The hub does not publish every chat's feed all the time. | decided by the agent |
| D15 | v1 also covers search, pin/rename/delete and quote-reply; phase 2 is exactly ask #1327's "later" list. | conversation ("со всем функционалом") + spec review round 1 |
| D16 | A chat's whole history is readable from the phone, in pages of 60 messages (`chat_page`). | spec review round 1 |
| D17 | Branch selection is never refused, on either device, even during a turn: a turn's rows are written by message id, so moving the leaf cannot corrupt them; the feed follows the leaf. | spec review round 1 (no Mac behaviour change) |
| D18 | The hub turns chat on only while the running Desktop app (if any) reports that it honours the lease. An old app still running after an update keeps chat off on the phone, with "Update Watchtower on your Mac". | spec review round 1 |
| D19 | The push covers every turn that ends while the owner is away and the phone is not looking, whether the hub or the Mac ran it. | spec review round 1 |
| D20 | The contract changes of §9 (CHAT-01/02/03/05, LIVE-01, the `chat` grant, the protocol rule) are approved as written. | ask #1340 |
| D11 | The feed streams from memory for hub-run turns (≤ 150 ms per update) and from the database for Mac-run turns (about 1 s, the Swift flush interval). | decided by the agent |
| D12 | Dictation is the iOS keyboard's mic. No speech code in the app. | decided by the agent (simplest) |
| D13 | Hub chat sessions are capped at 2 live processes, separately from the Desktop's 3. An idle session is evicted at once to make room for a new turn, so a turn waits only while 2 other hub turns are mid-answer. | decided by the agent |
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

- **Pool.** At most 2 live `ai session` processes (D13), a 10-minute idle TTL on a 30 s check. A new turn evicts the least recently used idle session at once; a running turn is never cut. Only when both live sessions are mid-turn does a third conversation's turn wait in a queue, visible as "Waiting for a free slot"; it starts as soon as either turn ends.
- **Spawn.** `<os.Executable()> ai session --conversation N --surface main [--provider P --model M] [--project-id K] --db-path <db>`, in the daemon's working directory and with the daemon's environment. It runs in its own process group, killed and waited for on close, as `sessionhost/ensure.go` does. A routing change (provider or model) recycles the session, as `ChatSessionConfig.isCompatible` does.
- **Replay.** It reuses `ChatContinuity` semantics: `replay: true` unless this process's last completed turn is the current tip. So after a Mac-run turn, the hub's next turn replays.
- **Cancel watcher.** While a turn runs, the runner reads `chat_turn_leases.cancel_requested_at_ms` every 1 s. A set value sends `cancel`. With no `turn_done` within 7 s, it finalises `partial`, then SIGTERM and SIGKILL, the same numbers as `ChatSessionClient`.
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
  started_at_ms       INTEGER NOT NULL,   -- Unix epoch milliseconds, UTC
  heartbeat_at_ms     INTEGER NOT NULL,   -- Unix epoch milliseconds, UTC
  cancel_requested_at_ms INTEGER          -- set by the other side's Stop
);
```

**Time format.** Every time in this table is an integer of Unix epoch milliseconds, compared as a number. Both writers run on the same machine and read the same clock. There is no text timestamp to parse, so Swift and Go cannot disagree on fractions or zones. A shared case fixture (`chat_lease_cases.json`: claim, stale, cancel, release) is run by both the Go and the Swift lease code.

**Claim.** Inside the start transaction: `INSERT … ON CONFLICT(conversation_id) DO UPDATE … WHERE heartbeat_at_ms < :now_ms − 60000`. If no row changed, the claim is refused and the transaction rolls back.

**Conversation deleted during a turn.** A delete (Mac ✕, phone delete, or the cascade of a deleted project's chats) removes the lease and the turn's rows by the existing cascades. Foreign keys are on in both writers (`connPragmas`, GRDB's default). The lease holder treats any of these as "conversation gone": an `UPDATE` by message id that changes 0 rows, a foreign-key failure on a step, artifact or lease write, or a missing lease at heartbeat. It then rolls back the write, sends `cancel`, closes the session and writes nothing more. No orphan rows are possible: every child insert is checked by its foreign key, and the finalize transaction rolls back as a whole. Archiving only sets `archived_at`; the turn continues and finishes normally.

**Release.** `DELETE … WHERE conversation_id = ? AND turn_id = ?`, inside the finalize transaction.

**Stale.** A heartbeat older than 60 s means anyone may take the lease. The dead owner's rows stay `partial`.

**Writers:**
- the Swift turn store (claim, heartbeat, release, honouring cancel);
- the Go turn store (the same);
- either side's Stop, which sets `cancel_requested_at_ms` only, under `WHERE turn_id = ?`.

**Race.** Both writers claim in `BEGIN IMMEDIATE`, so SQLite serialises them and the first commit wins (§8).

### 4.5 Actions

All of these require the `chat` grant (`watchtower hub allow <device> chat [--revoke]`; there is no `deny` verb). A refusal names the missing grant; a server hub adds the `watchtower hub allow` line. They are registered in `handlers.Register` and the nudge table, and are additive per protocol spec §8.

| Kind | Params | Non-idempotent | Result / refusals |
|---|---|---|---|
| `chat_new` | `client_key` (uuid), `project_id?`, `routing {mode auto\|pinned, provider?, model?}` | yes | `{conversation_id}`; `invalid_params`, `not_found` (project) |
| `chat_turn` | `conversation_id`, `mode send\|regenerate\|edit`, `message_id?` (regenerate/edit), `text` (≤ 32 000 chars), `attachment_ids[]`, `routing?` | yes (+ `received` echo) | `{user_message_id, assistant_message_id, turn_id}` once the start transaction committed (the turn then runs in the background); `conversation_busy` (lease held), `not_found`, `invalid_params`, `attachment_missing` |
| `chat_cancel` | `conversation_id`, `turn_id` | no | `{}`; `not_found` when no such running turn |
| `chat_feed_request` | `conversation_id`, `purpose open\|prefetch` | no | `open`: watches the feed for 5 min; the phone repeats it every 60 s while the screen is open (the `session_chat_request` model). `prefetch`: publishes the feed once and deletes the record 2 min later; it never counts as the phone looking (§4.7). A missing `purpose` reads as `open`. |
| `chat_read` | `conversation_id`, `message_id` | no | `{}` |
| `chat_branch_select` | `message_id` | no | `{}`; allowed during a turn (D17) |
| `chat_page` | `conversation_id`, `before_message_id` | no | publishes one `chat_page` record (§4.6) for 5 min; `not_found` |
| `chat_search` | `query` (≤ 200 chars) | no | publishes one `chat_search` record (§4.6) for 5 min; a Go port of the Mac's ⌘K reader (`ChatSearchQueries`: FTS `MATCH` over `chat_fts` and the title index, snippet, `bm25` order and its filters on context type and archived chats), pinned by a shared case fixture `chat_search_cases.json` run by both the Swift `ChatSearchQueries` tests and the Go port, so the phone and the Mac return the same hits |
| `chat_manage` | `conversation_id`, `op pin\|unpin\|rename\|delete`, `title?` | yes | `pin`/`unpin`/`rename` write what the Mac's panel writes (`rename` sets `title_source='user'`). `delete` deletes the row and, after the commit, removes the conversation's attachment folder, exactly as the Mac's ✕ does (`ChatAttachmentStore.removeFiles(for: .conversation(id))`: the whole `<chat_files>/<owner directory>` folder; Go ports `directoryName` and the removal with a twin test over the same names). The 5 s Undo lives on the phone, as on the Mac (`PendingChatDeletes` is in-app state there too): the phone hides the row and sends `delete` only when the Undo bar ends. A delete during a turn follows §4.4 "Conversation deleted during a turn". |
| `chat_action_answer` | `action_id`, `decision approve\|reject`, `args_sha256` | yes | needs `permissions` too; approve goes through `Registry.ApproveSeen` with the hash of the args the phone showed, reject through the new `tools.Registry.Reject` (the approval-writers guard allows only the registry); a stale hash → `failed/changed` ("The action changed — look again") |

**Attachments, phone to hub.** A new upload frame, `chat_attachment`, is modelled on `recording_upload`.
- **Descriptor:** `upload_id`, `conversation_id`, `name`, `mime`, `size`.
- **Validation:** the hub decrypts and checks the Mac's limits: images png/jpeg/gif/webp ≤ 5 MB, PDF ≤ 32 MB, text ≤ 256 KB, one message ≤ 30 MB encoded. These checks are ported from `ChatAttachmentStore`, with the phone twin pinned by a shared case fixture.
- **Storage:** 0600 under `<workspace>/chat_files/`, sha256-deduplicated per conversation, with a `chat_attachments` row (`message_id NULL`).
- **Echo:** `applied {attachment_id}`.
- **Before upload:** the phone converts HEIC to JPEG and downsizes images over 5 MB, as `PastedContent` does on the Mac.

### 4.6 Slices

Four new kinds (`chat_list`, `chat_feed`, `chat_page`, `chat_search`) go into `AllKinds`, the `dataKinds` in `secure` and the Kit `SliceKind`, each with a Kit fixture read by both sides.

**`chat_list`**
- One record, published while a linked phone holds the `chat` grant.
- It holds up to 200 non-archived conversations. Each has:
  - `id`, `title`, `pinned`, `updated_at`;
  - `project {id,name}?`;
  - `state` (`waiting|answering|unread|read`, the Mac's precedence; `waiting` = any pending `agent_actions` row of the conversation, as the Mac's `panelRows`, `answering` = a live lease);
  - `last_line` (≤ 120 chars);
  - `lease_owner?`.
- It also holds `projects[]` (id and name) and `models[]` (from the provider catalog: provider, model, display name and the capabilities the composer needs, i.e. images and PDF), plus `error?` when the read failed (mockup 1h).
- It is rebuilt on the `data_version` change. It is not urgent.

**`chat_feed`**
- One record per watched conversation (`chat_feed-<id>`), in memory only, deleted when the watch ends (the `session_chat` model).
- Payload:
  - conversation meta: title, project, routing, actual provider and model, `live_slack_since`, `lease {owner, turn_id, waiting_slot?}`;
  - the active branch's last 60 messages (older ones come in `chat_page` records on request), each with `id`, `role`, `text`, `status`, `error_code`, `error_message`, `created_at`, `siblings {index,count,ids}` (`ids` = the sibling message ids, only when count > 1, so `chat_branch_select` can name one), `attachments[] {id,name,mime,size}`, `steps[] {name, ok?, summary, sources[]}`;
  - the latest version of each artifact key, with content;
  - the pending and recent `agent_actions` of those turns: `id`, `tool`, `title`, display args, `args_sha256`, `status`, reason.
- Cap: 600 000 bytes, for every chat record (list, feed, page, search) encoded, for any input. Over the cap, the oldest messages are dropped first (the phone then shows **Load earlier messages**, which sends `chat_page`), then artifact contents (marked "Open on your Mac"). One message's text is capped at 40 000 chars, with the cut marked.

**`chat_page`** — one page of older history, `chat_page-<conversation>-<before_message_id>`: the 60 active-branch messages before that id, the same per-message shape and caps as the feed, plus `has_more`. In memory only, deleted 5 min after its request. The phone stitches pages under the feed and keeps them in its copy (§6.4), so a whole chat is readable page by page, online and later offline.

**`chat_search`** — `chat_search-<query hash>`: up to 50 hits (conversation id, title, a snippet ≤ 200 chars, message id, date) from the Go port of `ChatSearchQueries` (§4.5, shared fixture). The port lives in `internal/db/chat_search.go` and joins LIVE-01's `displayOnlyReaders` (it only shows text on the phone). In memory only, deleted 5 min after its request. A hit opens the chat and loads pages until that message is on screen.
- Urgent kind, ordered after the ask kinds.
- Source of the live text:
  - for a hub-run turn, the runner's memory, with `OnChange` → `PublishSoon`; at relay spacing that is 150 ms;
  - for a Mac-run turn, the database on the `data_version` watch (D11).

### 4.7 Push

A new work-alert event, `chat_answer`, with a new optional `conversation_id` field. It is sent for any turn, run by the hub or by the Mac app (D19), that ended `complete`, `error` or `partial` after a cancel, or that started waiting for an approval, when no `chat_feed_request` with `purpose: open` for that conversation arrived in the last 90 s (the phone is not looking; a prefetch never counts). The hub sees a Mac-run turn end through the `data_version` watch: the lease row with `owner='desktop'` disappears and the assistant row's status is final; a new pending `agent_actions` row for a chat turn is the approval case. Each (turn, event) pushes at most once, keyed in the existing `alert_pushes` ledger as `chat:<turn_id>:<event>`. The owner-away rule keeps a push off while the owner is at the Mac.
- Title: the conversation title, clipped.
- Body: fixed text. "Answer ready", "The answer stopped" or "Waiting for your approval" (D14).
- Owner-away rules and the paying-slot targets are as today.
- The phone's router opens the conversation (phone side in T11, Kit `WorkAlertContent` event in T9).
- `TestAlertPushPayloadKeysMatchTheKit` and `go-sealed.json` gain the field.

### 4.8 Capability and the relay-only gate

**Heartbeat.**
- `capabilities.chat` is `"on"` while the hub's transport is the relay and `chatrun` started.
- It is `"off"` on CloudKit or when the runner failed to start; the failure reason goes to the log.
- It is also `"off"` while a Desktop app is running that does not honour the lease (D18). The Desktop heartbeats over the hub's control socket (`desktop_heartbeat`), so the new app adds `"chat_lease": 1` there (the `hub desktop heartbeat --chat-lease 0|1` flag is the CLI twin). The hub keeps the latest Desktop heartbeat's flag: a fresh heartbeat (≤ 2 min) without the flag means an old app is running, so chat is off with the reason `desktop_too_old`, which the phone shows as "Update Watchtower on your Mac" (mockup 1f). The heartbeat's `capabilities` carries the reason as `chat_reason`: `not_relay`, `runner_down`, `desktop_too_old` or `policy` (MDM `MobileSync` `workbench_only`). Chat sources publish only under `MobileSync` `allowed`, never under `workbench_only`: chat is not workbench data. No running Desktop (no fresh heartbeat, or a headless host) means chat may be on. The app and the daemon ship in one bundle, so the window is only the time between an update and the old app's relaunch.
- A `Deps.ChatAvailable()` seam lets every `chat_*` handler refuse with `not_supported` when chat is not on, so a stale phone cannot run a turn over CloudKit.

**Protocol spec.** `2026-10-31-hub-phone-protocol-design.md` §7.2 and §9 gain the new kinds and the "explicit on" rule.

## 5. Desktop changes

**Lease in the Swift turn store.**
- `persistTurnStart` claims (refused → no rows are written, and the composer shows the busy line);
- the driver sends a heartbeat every 15 s and checks `cancel_requested_at_ms` every 1 s (a set value runs the existing Stop path);
- `finalizeTurn` releases.
- A conversation deleted during the app's own turn (for example from the phone) ends that turn as §4.4 "Conversation deleted during a turn" says: the driver stops writing on the first 0-row update or foreign-key failure, and sends `cancel`.
- The app's `hub desktop heartbeat` call gains `--chat-lease 1` (D18).
- Branch selection stays as it is today, allowed during any turn (D17).
- The app's `owner_id` is a uuid per launch. At launch, the app releases its own stale leases left by a crash: a lease with `owner='desktop'` whose `owner_id` is not the current launch.

**A turn run elsewhere.** While a live lease with `owner='hub'` holds the open conversation:
- the thread reloads from the database every 1 s and once more at the release;
- the composer shows **Answering from your iPhone — you can watch here**, with Stop, which sets `cancel_requested_at_ms` (mockup 4a);
- Send is off until the release. The draft is kept.
- The Chats panel shows "answering" for hub leases (`ChatHistoryQueries.panelRows` reads the lease).

The line texts are set in the model and tested.

**Settings → Mobile → a phone.** A **Chat** toggle (the `chat` grant), beside the existing typing and permissions toggles, with the line "Chat on this iPhone: ask, approve with Permissions" (mockup 4b).

**Design shots.** `DesignShotCatalog` entries `chat-phone-turn` (4a) and `settings-mobile-phone-chat` (4b).

## 6. The phone

### 6.1 Tab and gate

A fourth tab, **Chats**, between Workbench and Calendar. The gate is checked in this order, with each state's text set in a model and tested:

| State | When | Mockup |
|---|---|---|
| needs update | no `capabilities.chat` key, or `chat` off with reason `desktop_too_old` (D18) | 1f |
| needs Relay | route is CloudKit | 1e |
| not allowed | `chat_*` refused with `device_not_allowed`, or the `device_grant` record says no chat | 1g |
| loading | no `chat_list` record yet | 1c |
| error + Retry | `chat_list.error` with no rows (Retry re-requests the publish through `chat_feed_request` with id 0) | 1h |
| empty | zero conversations | 1b |
| offline (read only) | heartbeat stale (the existing Mac status chip rule) or relay unreachable | 1d / 2e |
| ready | — | 1a |

### 6.2 Screens

- **List** (1a): Pinned / Recent (7 days) / "▸ N older", with dots in the Mac's precedence. Orange is only `waiting`, so `OrangeToneTests` gains the case. ✎ starts a new chat (2h).
  - **Search** (1i): typing filters the held list by title at once; after 300 ms of no typing it also sends `chat_search` and shows the Mac's hits under "In messages", with a "Searching on your Mac…" line until the record arrives (30 s → "The Mac did not answer" + Retry). Offline: titles only, with the line "Searching messages needs your Mac".
  - **Row actions** (1j): swipe or long-press → Pin/Unpin, Rename, Delete. Delete hides the row and shows an Undo bar for 5 s, then sends `chat_manage delete`.
- **Conversation:**
  - Owner bubbles (`ChatBubble.owner`) with attachment thumbnails or file pills.
  - Answers rendered by the shared `MarkdownRunBuilder` (moved to `WatchtowerChatText`, D8) into SwiftUI text runs, with headings, lists, code, quotes and tables. Tables scroll sideways on the phone; the Mac does not change.
  - A collapsed steps row and a sources chip that opens the sources sheet (3c).
  - Artifact cards, ‹ i/n ›, Regenerate and Copy on the last answer. Long-press on an owner bubble → Edit.
  - **Ask about this** (2i): a long-press on a finished answer opens a passage picker sheet (selectable text; no in-place selection or floating chip on the phone) and the chosen passage joins the per-conversation quote batch shown above the composer and goes out with the next message, composed by the shared `ChatQuoteReply.compose` (D8), the Mac's exact format.
  - **Load earlier messages** at the top when the feed or the last page says there is more; it sends `chat_page`.
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

**Opening a chat.** The phone sends `chat_feed_request` and shows the held copy at once, if any, else the loading state (2g). With no `chat_feed` record 30 s after the request, the screen shows "The Mac did not answer" with Retry, which sends the request again. The text is set in the model and tested.

**Streaming.** The feed record updates and the view diffs it by message id. While a turn runs, the view hides a partial `:::artifact` fence with the shared `ArtifactParser`, as the Mac does.

### 6.4 Offline copy (D10)

**Chat list.** The `chat_list` record is a slice record, so it lives in the phone's `ReplicaStore` like every other kind: it survives an app relaunch while the Mac sleeps, and the offline list (1d) is that record. It is deleted with the hub link.

**Chats.** The phone writes every chat page it decoded (the feed and every `chat_page`) to its own GRDB file, per hub, with file protection `completeUntilFirstUserAuthentication`. While the Mac is reachable and the app is in the foreground, it also prefetches the latest feed of the 20 most recent chats in the list with `chat_feed_request purpose: prefetch` (so prefetching never silences a push), one request at a time, at most once per chat per hour. The budget is 200 MB per hub, evicted by chat in order of last opened. The file is deleted with the hub link.
- Offline, a chat that was opened or prefetched reads in full as far as its pages were loaded; a chat never loaded shows "Open this chat once while your Mac is awake to read it here" (mockup 2e note).
- This is a display copy only. Nothing on the phone reads it except the conversation screen and the title search.
- The Mac's `live_slack_since` rule is unchanged, and the copy keeps Live turns for display only (see ask #1340, §9).

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
| Stop from the other device | `cancel_requested_at_ms` is set; the owner cancels within ≤ 1 s, then within 7 s finalises; a cancel for an ended turn is a no-op (`turn_id` guard) | `TestChatrun_RemoteCancelStopsTurn`, `testDriverHonoursRemoteCancel` |
| Approval answered, but the session died | The gate already expires the row (`TestChat05_DeadSessionNeverRunsAnApprovedCall`); `chat_action_answer` gets the row's final state | `TestChatActionAnswer_DeadSessionRowIsFinal` |
| Approval args changed since the phone showed them | `ApproveSeen` hash mismatch → `failed/changed` | `TestChatActionAnswer_StaleHashRefused` |
| Attachment upload cut mid-way | The relay attachment is never applied; no row is written; the phone shows Retry on that pill; `chat_turn` with a missing id → `attachment_missing` | `TestChatAttachment_PartialUploadWritesNothing` |
| Attachment over the limits | Refused with the Mac's reason text | shared case fixture, both sides |
| Feed over 600 KB | Oldest messages dropped first, then artifact contents, with markers | `TestChatFeed_CapsDropOldestThenArtifacts` |
| Hub switches to CloudKit while a phone is in a chat | The capability turns `off`; handlers refuse with `not_supported`; a running turn finishes and is visible on the Mac | `TestChatHandlers_RefuseWhenNotOnRelay` |
| Phone unlinked | Watches are dropped; the feed records are deleted; the offline copy is deleted with the link | `TestChatFeed_UnlinkDropsWatches`; phone `ChatOfflineCopyTests` |
| Third concurrent hub conversation | Only when both hub sessions are mid-turn: queued, "Waiting for a free slot" in the feed's lease | `TestChatrun_PoolQueuesBeyondTwo` |
| Conversation deleted (Mac ✕, phone delete, project delete) during a hub turn | The cascade removes the lease and rows; the Go store's next write changes 0 rows or fails its foreign key; it rolls back, cancels, closes the session and writes nothing more; no orphan steps or artifacts | `TestChatstore_ConversationDeletedMidTurnStopsCleanly` (deletes between a step and finalize) |
| Conversation deleted during a Mac-run turn (from the phone) | The same in the Swift driver | `testDriverStopsWhenConversationDeleted` |
| Conversation archived during a turn | Only `archived_at` changes; the turn finishes and is written normally | `TestChatstore_ArchiveMidTurnFinishes` |
| Old Desktop app still running after an update (knows no lease) | Its heartbeat lacks `--chat-lease`; the hub keeps chat off (`desktop_too_old`); the phone shows "Update Watchtower on your Mac"; turns on as soon as the new app heartbeats | `TestChatCapability_OffWhileOldDesktopRuns`, `TestChatCapability_OnWithoutDesktop` |
| Branch selected during a turn | The turn finishes by message id; the feed follows the new leaf; the next turn starts from the leaf current at its start | `TestChatstore_BranchSelectMidTurn` |
| Mac-run turn ends while the owner is away | One `chat_answer` push, never twice (ledger key) | `TestChatPush_DesktopTurnEndPushesOnce` |
| `chat_page` / `chat_search` request unanswered | The phone shows "The Mac did not answer" + Retry after 30 s | phone `ChatPagingModelTests`, `ChatSearchModelTests` |
| Delete undone on the phone | Nothing is sent; the row comes back | phone `ChatRowActionsTests` |
| Delete from the phone | The row cascades; the conversation's attachment folder is removed after the commit; a failed removal leaves only the folder behind (logged with the conversation id), as on the Mac | `TestChatManage_DeleteRemovesAttachmentFolder` |
| Prefetch while a turn ends | The push is still sent (prefetch is not looking) | `TestChatPush_PrefetchDoesNotCountAsLooking` |

## 8. Writers of the same data, and who wins

| Data | Writers | Race rule |
|---|---|---|
| `chat_messages`, `chat_turn_steps`, `chat_artifacts`, `chat_attachments.message_id` of a turn | Swift turn store, Go turn store | Only the lease holder writes a turn's rows. The claim is in the owner-row transaction, so the first commit wins. |
| `chat_turn_leases` | both turn stores (claim, heartbeat, release); either Stop (`cancel_requested_at_ms`) | Claim by conditional upsert; Stop only under `turn_id`; release only by its own `turn_id` |
| `chat_conversations.active_leaf_message_id` | both stores; branch select (Mac UI, `chat_branch_select`) | Last write wins on the leaf. A turn never writes the leaf after its start transaction (flushes and finalize update by message id), so a branch select during a turn cannot corrupt it; the feed follows the leaf (D17). The next turn starts from whatever leaf is current when its start transaction commits. |
| `chat_conversations.read_at` | Swift `markRead`, Go `chat_read` | `MAX(…)`, never backwards: both orders converge |
| `chat_conversations.title`/`title_source` | Go title (both hub and CLI paths), Swift rename | The existing rule: AI never writes over `title_source='user'` |
| `chat_conversations.pinned`, `title`/`title_source='user'` (rename) | Swift Chats panel, Go `chat_manage` | Last write wins, as with two Mac windows today; each write is one row update |
| conversation delete | Swift Chats panel (after its Undo), Go `chat_manage delete` (after the phone's Undo), project delete | The cascade; a running turn's holder stops cleanly (§4.4) |
| `chat_conversations.live_slack_since` | both stores | Set once (`WHERE live_slack_since IS NULL`), first wins |
| `agent_actions` status | the chat MCP server (propose), Desktop approve, `chat_action_answer`, the gate | The existing compare-and-set in `ApproveSeen`/`ClaimSessionCall`; the second decision gets the row's current state |
| `chat_attachments` rows (new) | Swift `ChatAttachmentStore`, Go upload intake | Each upload is its own row (no unique key exists, none is added). Only the file is deduplicated by sha256 per conversation, so two rows may share one path. The file is written to a temp name and renamed into place, so a concurrent writer of the same bytes leaves one whole file. Files live in one folder per owner (`ChatAttachmentStore.directoryName`) and are removed only with their conversation or project, the whole folder at once, by whichever store deleted it (Swift `removeFiles`, Go's port) — never per row. |
| `ideas` (chat-born) | Swift `IdeaQueries.createFromChat`, Go `db.CreateIdeaFromChat` | Each runs only for the owner row its own store wrote, so there are no duplicates |

## 9. Contracts touched (approved in ask #1340)

- **CHAT-01:** "the Swift turn store is the writer" → "the lease holder's turn store (Swift or Go)". The same order and `partial` rules apply, with Go guards added. No Swift guard changes.
- **CHAT-02:** the Go store writes steps at once. New Go guard.
- **CHAT-03:** a second bounded pool in the daemon (2 processes, reaped on daemon stop). New guards.
- **CHAT-05:** the phone's artifact sheet only opens or copies. A source scan over the phone's artifact files: no `URLSession`, no action enqueue, no `send`.
- **LIVE-01:** the mechanism gains the Go store (the same mark points). The phone's offline copy is a display copy (like `chat_messages` itself). The feed builder joins `displayOnlyReaders`.
- **Hub grants:** the new `chat` grant, on by default for linked and new phones (ask #1340).
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
| Lease time format shared by Swift and Go | T1, T8 | `chat_lease_cases.json` in both |
| Conversation deleted mid-turn: clean stop, no orphans | T3, T8 | `TestChatstore_ConversationDeletedMidTurnStopsCleanly`, `testDriverStopsWhenConversationDeleted` |
| Chat off while an old Desktop runs | T5, T8 | `TestChatCapability_OffWhileOldDesktopRuns` |
| Whole history readable (paging) | T5, T6, T11 | `TestChatPage_…`, `ChatPagingModelTests` |
| Search, pin/rename/delete, quote-reply | T5, T10, T11 | `chat_search_cases.json` (Swift `ChatSearchQueriesFixtureTests` + Go `TestChatSearch_SharedCases`), `TestChatManage_DeleteRemovesAttachmentFolder`, `TestChatManage_…`, `ChatRowActionsTests`, `ChatQuoteReplyTests` (Kit, moved) |
| Push for Mac-run turns, once | T7 | `TestChatPush_DesktopTurnEndPushesOnce` |
| A prefetch never silences a push | T5, T7 | `TestChatPush_PrefetchDoesNotCountAsLooking` |
| Push opens the chat on the phone | T9, T11 | `NotificationRouterChatTests` |
| Offline list survives relaunch; prefetch budget | T11 | `ChatOfflineCopyTests` |

## 11. Plan outline

| Task | Title | Depends on |
|---|---|---|
| T1 | Migration `chat_turn_leases` + Go lease API | none |
| T2 | Move `ArtifactParser`, `MarkdownRunBuilder` and `ChatQuoteReply` to the `WatchtowerChatText` package; Go artifact parser twin | none |
| T3 | Go turn store (`internal/chatstore`) | T1, T2 |
| T4 | Hub chat runner (`internal/hub/chatrun`) | T3 |
| T5 | Hub actions (incl. `chat_manage` with the attachment-folder removal, `chat_page`, `chat_search` with the Go port of `ChatSearchQueries`), the `chat` grant, the attachment upload frame, the capability with the Desktop lease flag | T4 |
| T6 | Slices `chat_list`, `chat_feed`, `chat_page`, `chat_search`; Kit mirrors and fixtures | T3 |
| T7 | `chat_answer` push for hub- and Mac-run turns | T5, T6 |
| T8 | Desktop: lease in the Swift store, conversation-gone stop, foreign-turn view, Stop, `--chat-lease` heartbeat flag, the Chat toggle, DesignShots 4a/4b | T1 |
| T9 | Kit: action params, the frozen kind lists, the `chat_answer` event in `WorkAlertContent` | T5 |
| T10 | Phone: Chats tab, gate, list, search, row actions with Undo | T6, T9 |
| T11 | Phone: conversation, paging, composer, quote-reply, attachments, approvals, artifacts, sources, branches, offline copy and prefetch, the push router opening a chat | T10 |
| T12 | Docs: feature note, guide pages (iPhone → Chat), inventory amendments, protocol spec §7/§9 | all |

Lanes run in parallel where the dependencies allow: T1, T2 and T8 start together; T6 and T4 run side by side after T3.

## 12. v1 limits

- Phase 2 items (§1) are not in v1.
- A new chat's model and project are fixed after the first message, as on the Mac.
- Edited messages keep their attachments on the original, as on the Mac.
- A Mac-run turn streams to the phone at about 1 s, not 150 ms.
- Offline, only chats opened or prefetched (the 20 most recent) can be read, as far as their pages were loaded; search over message text needs the Mac.
- The hub's 2-session pool is separate from the Desktop's 3. With both busy, up to 5 provider processes run on one Mac.
- An html artifact on the phone has WebRTC removed by a document-start script in the page and in script-made iframes (a simulator test, `PhoneArtifactWebRTCTests`, proves it); the phone sets no private `WKPreferences` selector, which the Mac does.
- A Mac-run turn shorter than the hub's check cadence may go without a push: a vanished desktop lease is kept for at most 6 checks until its assistant row shows, then dropped.
- Dark list screenshots show the iOS 26 glass tab-bar lens over "Now"; that is a capture artifact of the screenshot host, the screen content is right.
- A message edited on the phone is stored as typed plus the original's skill and REFERENCED lines (`internal/chatstore/composer.go`, the port of `ChatTurnComposer`).

## 13. Changed during implementation

The approved text above was kept where it held; these points differ in the shipped code (the feature note `docs/features/iphone-chat.md` has the details).

- **D8:** the shared text code lives in a new dependency-free local package `WatchtowerChatText/` (swift-markdown only), not in WatchtowerKit, because WatchtowerCore must stay Kit-free (`PublicAPISurfaceTests`). It also holds `ArtifactLinks` (mailto, Google Calendar template and Slack link builders) and `ChatErrorText`, which the Mac's `ArtifactActions` and `ChatErrorPresentation` now delegate to, so the Mac and the phone share one builder and one error table.
- **§4.6:** `chat_list` `waiting` is any pending `agent_actions` row of the conversation (the Mac's `panelRows`), not the last turn's; `siblings` gains `ids`; every chat record is at most 600 000 bytes encoded, for any input (long text is cut with `text_cut`, then steps and actions are dropped, titles clip at 200).
- **§4.8:** the heartbeat carries `chat_reason` (`not_relay`, `runner_down`, `desktop_too_old`, `policy`); the Desktop sends `chat_lease` on the control-socket heartbeat (the `--chat-lease` CLI flag exists as a twin); chat sources publish only under `MobileSync` `allowed`.
- **§4.5:** the grant verb is `hub allow <device> chat [--revoke]`; reject goes through the new `tools.Registry.Reject`.
- **§6.2:** Ask about this is a long-press on a finished answer plus a passage picker sheet.
- **§7/§12:** see the v1 limits above (WebRTC proof, vanished-lease checks, glass tab-bar lens).
