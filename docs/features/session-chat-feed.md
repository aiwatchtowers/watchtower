# Session chat feed — the dialog of a workbench session (2026-10-16, phases 1-3)

Spec: `docs/superpowers/specs/2026-10-16-session-chat-feed-design.md`. Contracts: FEED-01..05 in [docs/inventory/session-feed.md](../inventory/session-feed.md).

A workbench session's transcript holds hundreds of tool calls; the owner wants the conversation only. The feed is built on demand by a deterministic Go reader from the Claude Code transcript JSONL. No AI call, no transcript text stored anywhere, nothing written to the transcript files.

## Pieces

| Piece | Where |
|---|---|
| Reader | `internal/sessionfeed/` (`parse.go` record rules, `feed.go` `Build`/`LocateAll`/cursor, `subagent.go` subagent markers and feeds, `entry.go` types) |
| Ledger | migration `00127_*` `terminal_session_agent_sessions`, `internal/db/terminal_session_agent_sessions.go` (`ListTerminalAgentSessions`) |
| CLI | `watchtower workbench session-feed --session N [--after C] [--subagent TOOL_USE_ID] [--json]` (`cmd/workbench_session_feed.go`) |
| Desktop model/store/poller | `WatchtowerCore` `Models/SessionFeed.swift`, `Services/SessionFeedStore.swift`, `Services/SessionFeedPoller.swift` |
| Desktop views | `Views/Workbench/SessionChatView.swift`, `SessionChatSubagentSheet.swift` |

The Desktop runs the CLI with `--json` and decodes it; there is no Swift twin of the filter rules (the Go reader is the only parser).

## Entry kinds (agent-neutral)

`owner`, `agent`, `ask_answer`, `watchtower` (`via` = `review` or `handoff`), `brief`, `subagent`, `separator`. Every entry has a stable `id`, an `at` time, `text` and the tab's `conversation` (agent session id).

Record rules (`parse.go`):
- `user` records with string or `text` content are `owner`. Dropped: `isMeta`, `isCompactSummary`, any record holding a `tool_result` block, `<local-command…>` wrappers, `[Request interrupted…` lines, and sidechain records outside a subagent file. `<system-reminder>` blocks are stripped; images become `[image]` (unless the text already has an `[Image #N]` marker); a slash command becomes `/name args`.
- `Ask #N answered …` is `ask_answer`; the CLI joins it to `owner_asks` (title and answer text), **only for an ask of the session's own workbench** (FEED-04). An ask that cannot be read keeps the bare typed line.
- `Review round #…` and `From a Watchtower code question:` lines are `watchtower` entries (`via` review / handoff). Hook feedback is not a chat line and is dropped with the meta records.
- The start brief is not a `user` record: it is an `attachment` with `hookEvent` `SessionStart` whose `stdout` starts `Watchtower workbench #`; other SessionStart outputs are dropped. One collapsed `brief` entry.
- `assistant` records: only `text` blocks, one entry per message id, the last streamed version wins. `tool_use` and `thinking` never reach the feed (FEED-02).
- An `Agent` tool call becomes one `subagent` marker (type, description, status). Unknown record types are counted in `unknown_records`, never shown; an overlong line (over 8 MiB) or invalid JSON is skipped and counted in `skipped`; a final line without `\n` is left for the next read.

## Cursor and upsert contract

The cursor is `<agent session id>:<byte offset after the last complete line>`. `--after C` returns the entries that follow it; an entry whose message grew after the cursor is re-emitted with the same `id` and the new text, so a caller upserts by id (the Desktop store does). A poll reads only the tail after the cursor: the cursor's conversation is parsed from its offset, later conversations from 0, earlier ones not at all. `subagents` lists every subagent marker of the tab and comes from the sidecar `subagents/*.meta.json` files (tool use id, type, description, finished), not from a transcript parse.

## Subagents

`--subagent T` prints the feed of the subagent started by tool call `T`, read whole (empty cursor): its task as the first entry, its text replies, then the final report. A foreground subagent's report is the parent's `tool_result` for the `Agent` call; a background one reports through its `SubagentHandback` call (text in `input.message`). A background subagent without a hand-back has no report (the parent's result is only a launch notice). Nested subagents open the same way: the Desktop shows the feed in a sheet, and a nested marker inside it opens a further sheet.

## The ledger (migration 00127)

`terminal_sessions.claude_session_id` holds only the latest id (`/clear` and resume swap it). `terminal_session_agent_sessions (terminal_session_id, agent_session_id, first_seen_at)` keeps every id the tab had, so the feed stitches the tab's transcripts in time order with a `separator` entry where a new conversation starts. Ids and times only, no text (FEED-01); rows cascade with the tab.

The rows are written by **SQL triggers on `terminal_sessions`** (`AFTER INSERT` and `AFTER UPDATE OF claude_session_id`), not by Go code: the creating INSERT is in Swift (`TerminalSessionQueries.create`), and a trigger is the one place that sees every write path. Consequences:
- A future migration that **recreates `terminal_sessions`** (the SQLite table-recreation dance) must recreate both triggers (`terminal_session_agent_sessions_ai`, `_au`), or the ledger silently stops filling.
- `internal/db/schema.sql` mirrors the table but not the triggers (only a comment points at 00127).
- The migration backfills one row per existing tab with an id (`created_at` as `first_seen_at`).

Locating transcripts: `LocateAll` lists the workbench's candidate directories (`agentlog.CandidateDirs`, worktrees included) under `<claude dir>/projects` once per call and resolves every ledger id from that one listing. A missing transcript is skipped, not an error.

## Entry points in the app

Session row context menu **Show Chat**; the session header **Chat** toggle; the pane picker **Chat**. The pane opens scrolled to the newest message, reads the feed once when shown or when the session's state changes and every 3 s while the agent works or has background subagents (`SessionFeedStore.follow`; `SessionFeedPoller` serializes polls: a refresh asked during a run folds into exactly one more run). Any of these reads — the one on open, the one on a state change, each 3 s tick — is skipped while the main window is hidden, minimised or covered (`isTabOnScreen`), so a pane nobody sees spawns no CLI; when the app's windows come back on screen (`AppState.uiVisibility`, #731) after a skipped read, the feed is read at once (`SessionFeedStore.screenChanged`, `ForegroundRefreshGate`, board #589). The store and its CLI lookup are built once per pane, not on each render. It shows `watchtower` entries as the owner's bubble marked "via Watchtower".

## v1 limits

- Codex sessions (2026-10-17): `sessionfeed.ParseCodex`/`LocateCodex` read the rollout (`$CODEX_HOME/sessions/*/*/*/rollout-*-<id>.jsonl`, the stored `transcript_path` first) in both owner dialects (paginated `item_completed` `UserMessage`/`AgentMessage`, legacy `user_message`/`agent_message`); user text is classified like Claude's (brief, ask answer, Watchtower line). Legacy lines carry no id, so their entry id is `L<line byte offset>`. No subagent markers for Codex; a zstd-compressed rollout yields no entries (`unknown_records["<zstd>"]`).
- No search, export or sharing. The iPhone shows the tail of a feed only (phase 3 below), no paging into older entries.
- Zero time means no time: the separator, a report entry and a meta-only subagent marker may carry `0001-01-01T00:00:00Z`; the Desktop treats it as unknown and shows no timestamp.
- `--after` and `--subagent` are mutually exclusive (the command refuses both). `skipped` and `unknown_records` count only what that call read.
- A marker whose `meta.json` is not written yet is missing from `subagents` until it appears (it is still in `entries` when its call is after the cursor); a meta-only marker has no time or parent report until its transcript part is parsed.
- A background subagent without a `SubagentHandback` has no report.
- `unknown_records` is noisy on live data (several expected Claude Code record types are not yet on the ignore list); it is a drift signal, not an error.
- An owner message with a pasted image can read `[Image #1] …` followed by `[image]`.
- The in-flight CLI read is not cancelled when the pane goes away; the result is discarded.
- The format of the transcripts is undocumented: a drift degrades to skipped/unknown counts, never a failure.

## Phase 3 — the chat on the iPhone (2026-10-18, board #486)

Spec: `docs/superpowers/specs/2026-10-18-session-chat-iphone-design.md`. Contract: FEED-05; the mobile POC's I-4 is amended for this one exception (the chat crosses to the owner's iCloud, on request only). Transport: [mobile-companion.md](mobile-companion.md).

**Flow.** Opening **Chat** on a session's detail screen enqueues the relay action `session_chat_request` `{session_id?, subagent_id?, tool_use_id?}` (entity = the `terminal_session-<id>` record; `SessionChatRequestHandler` needs no grant, since it only reads). The phone repeats it every 60 s while the screen is open (`SessionChatRequester`, stop keyed by screen so a push/pop does not stop the top screen's loop). An unknown session answers `.notFound` with message `unknown_session`. A subagent request carries both ids (`subagent_id` names the record, `tool_use_id` is what the CLI's `--subagent` takes; one without the other is `invalid_params`), and a `session_id` that differs from the entity is `invalid_params`. The handler replies `.applied()` at once and tells `SessionChatRunner` to watch the session or subagent. The watch counts from when the phone asked (`created_at`): a request older than the watch plus the relay's clock skew applies without opening a watch, a younger one ends `created_at` + 5 min (`.sessionChatRequest` is a session request kind for the relay's 24 h expiry). The phone does not queue a repeat while an earlier `session_chat_request` for the same chat still waits in its outbox.

**Lifetime.** A watch lasts 5 minutes from the last request. The runner runs `watchtower workbench session-feed --session N --json` (or `--subagent <tool_use_id>`) off the main actor, every 10 s while the agent is live and once per watch for a finished session, bounded at 30 s. The result is clipped to the caps and kept **in memory only**: never in the clear on disk (not in `watchtower.db`, FEED-01; not in the hub sidecar) — only the sealed slice record waits in the hub's transport queue. When the watch expires the entries leave the slice window and the publisher deletes the record from the zone. Stopping the runner, and any time no phone is linked, drops every payload for good. `SessionChatSlice` (kind `session_chat`, record `session_chat-<session id>` or `session_chat-<session id>-<agent id>`) publishes on the normal 30 s full tick: not an urgent kind, no fast lane. A live chat is up to ~40 s behind.

**Caps** (`SessionChatPayload`, I-8): FEED-02 kinds only (a tool call, thinking or a kind a newer CLI adds is dropped before the cut and not counted), newest 300 entries (`entries_more` counts the cut ones), entry text 4000 characters (`text_clipped`), titles and subagent descriptions 200, and a payload over 600 000 bytes drops the oldest entries until it fits (counted into `entries_more`; each entry is measured once and the payload is encoded once). The payload carries no clock, so an unchanged feed is byte-identical and is not uploaded again. A subagent marker carries `tool_use_id` besides `agent_id`; the phone shows no link for a marker missing either.

**Phone.** Kit mirror `SessionChat` (`Models/SessionChat.swift`, fixtures `session_chat.json`, `session_chat_subagent.json`). Session detail has a **Chat** row; `SessionChatView` shows owner bubbles right, agent text left, ask answers and Watchtower lines marked "via Watchtower", the brief collapsed, separators, and subagent markers that push the subagent's own chat. Waiting states: "Asking your Mac…", then after 60 s without a record "Your Mac has not sent this chat yet. Is it awake?". **The Tell bar (`TellSessionBar`) shows only on the main chat**, and only for a device allowed to type (PROJ-16): a line typed from a subagent screen would reach the main agent, not the subagent. A sent line shows as a pending bubble while it waits in the outbox, then as a local bubble after the Mac applied it, until an `owner` entry with the same text dated at or after the send arrives or 90 s pass.

| Piece | Where |
|---|---|
| Payload and caps | `Services/MobileHub/Slices/SessionChatPayload.swift` |
| Runner | `Services/MobileHub/Slices/SessionChatRunner.swift` |
| Slice | `Services/MobileHub/Slices/SessionChatSlice.swift` |
| Request handler | `Services/MobileHub/Handlers/SessionChatRequestHandler.swift` |
| Kit | `WatchtowerKit/Models/SessionChat.swift`, `SessionChatRequestParams` in `WorkbenchActionParams.swift` |
| Phone | `WatchtowerMobile/Sources/Features/Workbench/{SessionChatView,SessionChatViewModel,TellSessionBar}.swift` |

Limits: no search, no paging, no chat of a session the owner did not open, no copy beyond the replica record.
