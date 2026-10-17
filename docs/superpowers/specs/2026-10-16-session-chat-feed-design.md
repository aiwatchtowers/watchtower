# Session chat feed — the dialog of an agent session, without the noise

Date: 2026-10-16. Status: design approved by the owner (ask #224).

## Intent and the why

The owner works with Claude Code sessions in Watchtower workbenches, steps away, and comes back: to the Mac after a pause, to the phone while the agent keeps working, or after the session is done. The terminal is useless for catching up. It holds hundreds of tool calls, diffs and command output, and the actual conversation is buried in them.

The owner wants to read **the dialog**: their own messages and the agent's text replies, the way a normal chat app shows it, with no tool calls in between. From that they want to understand what was done in the session and how, and to spot where it went wrong. Subagents are the one exception: the owner wants to open a subagent and read what it was asked and what it reported.

The feed is built **deterministically, without any AI call**: a script reads the session transcript the agent already writes and filters it.

This is a separate feature from #298 (history analytics: metrics, cost, the event timeline). #298 is about numbers; this is about meaning. They share the transcript discovery code, nothing else.

## Goals

1. A chat-like feed for one agent session: owner messages and agent text replies in order, with timestamps.
2. Owner answers to asks appear in the feed as the owner's message, with the answer text, instead of the bare "Ask #N answered" line the terminal receives.
3. A subagent appears in the feed as one marker (its type and short description) at the point it was launched. Opening the marker shows the subagent's own feed: the task it was given, its text replies, and the final report it returned. Nested subagents open the same way.
4. Works while the session is still running (new messages appear) and after it finished.
5. Three surfaces, in this order: a CLI command, a view on the Mac inside the workbench session, the same feed on the iPhone app.

## Non-goals

- No tool calls, command output, diffs, file lists or counts between messages ("nothing in between" — owner's answer). No collapsed "did 5 things" rows.
- No model's internal reasoning (thinking blocks). Only text the agent actually showed in the session.
- No AI summary, no rewording of messages. The text is shown as written.
- No search across sessions, no export, no sharing in v1.
- Codex sessions are out of v1 (Claude Code only, like `internal/agentlog` v1). The design must not make Codex harder to add later.
- Not a replacement for the terminal or for #298's timeline.

## Anti-goals (would be a failure even if it works)

- The feed is noisy: system reminders, hook output, `<command-…>` wrappers, tool results or "Ask #N answered" lines leak in as messages.
- Messages are duplicated (streaming writes the same assistant message several times) or out of order.
- Transcript text gets copied into the shared SQLite. AGENTLOG-01 ("no transcript text") stays as it is: the Mac reads the JSONL when asked and keeps nothing.
- The feed writes to or locks the agent's transcript files (read-only, like AGENTLOG-05).
- Opening the feed of a long session is slow on the Mac or makes the phone sync exceed its envelope budget.

## Constraints and facts from the code

- Transcripts: `~/.claude/projects/<slug>/<session-uuid>.jsonl`. Subagents: `<slug>/<session-uuid>/subagents/agent-<id>.jsonl` plus `agent-<id>.meta.json` with `agentType`, `description`, `toolUseId` (the parent's `Agent` tool call). `internal/agentlog/discover.go` already finds the candidate directories for a workbench folder, including worktrees.
- A workbench terminal session row (`terminal_sessions`) records `claude_session_id`, which names the transcript.
- Record shapes seen in a live transcript: `user` records with string or `text` content are owner messages, unless `isMeta`, `isCompactSummary`, a `tool_result` block, or a `<local-command…>` / `<command-…>` wrapper; `assistant` records carry `text`, `tool_use` and `thinking` blocks; many other record types (`attachment`, `system`, `mode`, `file-history-snapshot`, `api-request*`, `ai-title`, …) are not dialog. `internal/agentlog/claude.go` already decodes most of these fields. The format is undocumented; the parser degrades by skipping and counting, as agentlog does.
- Asks: the owner's answer reaches the session as a typed line ("Ask #N answered …"); the answer itself lives in `owner_asks` in the shared DB.
- Phone: the Mac publishes records to the phone over the owner's iCloud with end-to-end encryption; one record must fit `Envelope.maxBytes` = 900 000 bytes. See `docs/features/mobile-companion.md`.
- Owner preference: the simplest design that gives correct results (no machinery unless skipping it gives silently wrong output).

## Decided with the owner

- What it shows: the dialog only, "like a normal chat"; nothing between messages; subagents can be opened.
- Separate from #298.
- Order: CLI command → Mac → iPhone, as three phases.
- The text crosses to the phone (E2E, the owner's own iCloud), which the owner accepted by asking for the phone feed.

## The shape (my calls, open to the owner's review)

### Core: one Go reader

A new Go package (working name `internal/sessionfeed`) turns a transcript into a list of entries. It runs on demand and stores nothing.

Entry kinds:

| Kind | From | Shown as |
|---|---|---|
| `owner` | a `user` record that is real owner input; `<system-reminder>` blocks stripped; images as `[image]`; a slash command as `/name args` | owner bubble |
| `ask_answer` | the "Ask #N answered" typed line, joined to `owner_asks` by id | owner bubble with the ask title and the answer text |
| `agent` | the `text` blocks of an `assistant` message, one entry per message, deduped by message id (the last streamed version wins) | agent bubble |
| `subagent` | an `Agent` tool call in the parent, matched to its subagent file through `meta.json` `toolUseId` | a marker: agent type, description, finished or running |

Inside a subagent's feed, the first entry is the task (the prompt the parent gave it, shown as the "owner" side), then its `agent` entries, then the final report (the parent's tool result for that call) as the last agent entry.

Everything else is dropped. Records of unknown types are counted, not shown, so format drift is visible in the CLI's JSON output.

Each entry carries a stable id (the record uuid, or message id) and a timestamp. The feed also returns a cursor (byte offset of the last complete line read), so a caller can ask for "what is new since the cursor" while the session runs.

**Entries that change (my call).** An entry can change after it was first returned: a streamed agent message grows, a subagent marker flips from running to finished, its report arrives later. The reader re-emits the entry with the same id and the new content; callers upsert by id. Text an agent writes before a tool call ("Let me check…") is an ordinary `agent` entry.

**One terminal session, several transcripts (open, see Questions for the owner).** `/clear` and similar start a new Claude session uuid inside the same terminal tab; `terminal_sessions.claude_session_id` keeps only the latest (`internal/db/terminal_sessions.go`, the update on a changed id). A reader of that one id silently shows only the part after the last `/clear`.

**Text Watchtower types into the session (open, see Questions for the owner).** Besides ask answers, Watchtower types the start brief / handoff prompt, mobile handoff text, diff-review rounds, and hook feedback (ask guard, Stop hook). They arrive as ordinary `user` records.

### Phase 1: CLI

`watchtower session feed` with a way to pick the session: a workbench terminal session id (the normal case), or a Claude session uuid. Plain output is a readable chat transcript for the terminal; `--json` gives entries with pinned keys; `--after <cursor>` returns only new entries; a subagent's feed is opened by its id. Exact flags are the builder's.

### Phase 2: Mac

A chat view for a workbench session, reachable from the session in the workbench (where exactly in the UI is the builder's call, following the existing session panel). It gets its data by running the CLI with `--json` (the Go reader is the only parser — no Swift twin of the filter rules). While the session is live it refreshes with `--after`; it opens scrolled to the newest message, like a chat. A subagent marker opens that subagent's feed.

### Phase 3: iPhone

The Mac publishes the feed of recent sessions to the phone as encrypted records, and the phone shows the same chat view. Because of the 900 KB envelope limit the phone gets the newest part of a long feed, and subagent feeds on demand; how exactly (tail size, paging, which sessions count as "recent") is decided in phase 3's own plan against the mobile sync design. Phase 3 does not change what the feed contains.

## Owner decisions on review (ask #224, approved with the recommendations)

1. A terminal tab after `/clear`: one feed for the whole tab, with a separator at each new conversation. A small table remembers every Claude session id the tab had, written where `claude_session_id` changes today.
2. Text Watchtower typed for the owner: the start brief as one collapsed "Watchtower: brief" entry; diff-review rounds and handoff text as the owner's message marked "via Watchtower"; hook feedback hidden. Recognising these lines may need a stable marker on the Go side that types them; that is the builder's call.

## Findings from the spike (2026-10-16)

A throwaway script built the feed of a live session and a UI mockup on top of it (owner approved the mockup, ask #225). Two record facts the reader must follow:

- The start brief is not a `user` record: it is an `attachment` of type `hook_success` with `hookEvent` `SessionStart` whose `stdout` begins `Watchtower workbench #`. Other SessionStart outputs (skill plugins) are not the brief and are dropped.
- A background subagent's report is not a `text` block: it is the subagent's `SubagentHandback` tool call, with the text in `input.message`. A foreground subagent's report is the parent's `tool_result` for the `Agent` call. `meta.json` `finished` tells whether it is done.
- Also seen: subagent hand-backs and task notifications reach the parent as `isMeta` user records and are dropped with the rest of the meta records.

The mockup's layout is the reference for phases 2 and 3: owner messages right in a tinted bubble, agent text left without a bubble, the ask answer as an owner bubble labelled with the ask number and question, the brief as one collapsed line, the subagent as a card that opens a side sheet with its task and report.

## Left to the builder

- Package and command names, flag spelling, JSON key names (pinned once chosen).
- The exact noise filter rules beyond the ones listed, found by running against real transcripts — with tests built from fabricated records, never live data (public repo hygiene).
- Where the chat view lives in the Mac UI and how it looks, within the house SwiftUI conventions.
- Refresh mechanism for the live Mac view (poll with the cursor, or a trigger off the existing session agent-state hooks).
- Phase 3 transport details.
- Whether behaviour contracts for this feature go into `docs/inventory/` and under what id.
