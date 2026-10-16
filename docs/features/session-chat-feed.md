# Session chat feed — the dialog of a workbench session (2026-10-16, phases 1-2; iPhone pending)

Spec: `docs/superpowers/specs/2026-10-16-session-chat-feed-design.md`. Contracts: FEED-01..04 in [docs/inventory/session-feed.md](../inventory/session-feed.md).

A workbench session's transcript holds hundreds of tool calls; the owner wants the conversation only. The feed is built on demand by a deterministic Go reader from the Claude Code transcript JSONL. No AI call, no transcript text stored anywhere, nothing written to the transcript files.

## Pieces

| Piece | Where |
|---|---|
| Reader | `internal/sessionfeed/` (`parse.go` record rules, `feed.go` `Build`/`LocateAll`/cursor, `subagent.go` subagent markers and feeds, `entry.go` types) |
| Ledger | migration `00125_*` `terminal_session_agent_sessions`, `internal/db/terminal_session_agent_sessions.go` (`ListTerminalAgentSessions`) |
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

## The ledger (migration 00125)

`terminal_sessions.claude_session_id` holds only the latest id (`/clear` and resume swap it). `terminal_session_agent_sessions (terminal_session_id, agent_session_id, first_seen_at)` keeps every id the tab had, so the feed stitches the tab's transcripts in time order with a `separator` entry where a new conversation starts. Ids and times only, no text (FEED-01); rows cascade with the tab.

The rows are written by **SQL triggers on `terminal_sessions`** (`AFTER INSERT` and `AFTER UPDATE OF claude_session_id`), not by Go code: the creating INSERT is in Swift (`TerminalSessionQueries.create`), and a trigger is the one place that sees every write path. Consequences:
- A future migration that **recreates `terminal_sessions`** (the SQLite table-recreation dance) must recreate both triggers (`terminal_session_agent_sessions_ai`, `_au`), or the ledger silently stops filling.
- `internal/db/schema.sql` mirrors the table but not the triggers (only a comment points at 00125).
- The migration backfills one row per existing tab with an id (`created_at` as `first_seen_at`).

Locating transcripts: `LocateAll` lists the workbench's candidate directories (`agentlog.CandidateDirs`, worktrees included) under `<claude dir>/projects` once per call and resolves every ledger id from that one listing. A missing transcript is skipped, not an error.

## Entry points in the app

Session row context menu **Show Chat**; the session header **Chat** toggle; the pane picker **Chat**. The pane opens scrolled to the newest message, refreshes every 3 s while shown (`SessionFeedPoller` serializes polls: a refresh asked during a run folds into exactly one more run), and shows `watchtower` entries as the owner's bubble marked "via Watchtower".

## v1 limits

- Claude Code only. A Codex session returns `codex sessions are not supported yet`; the entry kinds are agent-neutral so it can be added.
- No search, export or sharing. The iPhone chat is pending (phase 3: tail of a feed in the 900 000-byte envelope, subagent feeds on request).
- Zero time means no time: the separator, a report entry and a meta-only subagent marker may carry `0001-01-01T00:00:00Z`; the Desktop treats it as unknown and shows no timestamp.
- `--after` and `--subagent` are mutually exclusive (the command refuses both). `skipped` and `unknown_records` count only what that call read.
- A marker whose `meta.json` is not written yet is missing from `subagents` until it appears (it is still in `entries` when its call is after the cursor); a meta-only marker has no time or parent report until its transcript part is parsed.
- A background subagent without a `SubagentHandback` has no report.
- `unknown_records` is noisy on live data (several expected Claude Code record types are not yet on the ignore list); it is a drift signal, not an error.
- An owner message with a pasted image can read `[Image #1] …` followed by `[image]`.
- The in-flight CLI read is not cancelled when the pane goes away; the result is discarded.
- The format of the transcripts is undocumented: a drift degrades to skipped/unknown counts, never a failure.
