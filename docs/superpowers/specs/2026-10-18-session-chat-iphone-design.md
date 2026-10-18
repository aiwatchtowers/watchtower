# Session chat feed on the iPhone — phase 3 design

**Board:** #486 (phase 3 of #475). **Parent spec:** `docs/superpowers/specs/2026-10-16-session-chat-feed-design.md` (phases 1–2 shipped in PR #327). **Transport:** `docs/features/mobile-companion.md`, `docs/superpowers/specs/2026-10-07-mobile-poc-design.md`.

## Goal

On the phone, a workbench session shows the same chat as the Mac's Chat pane: the owner's lines, the agent's text, ask answers, Watchtower lines, the brief line, and subagent markers that open the subagent's own chat. The phone gets it through the Mac hub, end-to-end encrypted, in the owner's own iCloud. Phase 3 does not change what the feed contains (FEED-02).

## The policy change this needs (owner decision)

The mobile POC spec has invariant **I-4 No transcript**: "No session transcript, terminal buffer or screen text is published, ever (owner directive)". The chat feed is dialog text taken from the transcript, so phase 3 cannot ship under I-4 as written. The parent spec says the owner accepted the text crossing to the phone; this design asks for that to be recorded as an amendment:

> **I-4 (amended 2026-10-18, board #486):** No raw transcript, terminal buffer or screen text is published. The one exception is the session chat feed (FEED-02 entries only: no tool calls, tool output, thinking or hook feedback), published **only while the phone has the Chat screen of that session open** and removed from the zone when it stops asking (§Lifetime).

`PalettedTerminalView.screenRows()` stays private; the terminal itself still never reaches the phone. FEED-01 (nothing stored in SQLite) is unchanged: the hub keeps the payload in memory only (ruling in the plan, approved with ask #380), never in `watchtower.db` and not in the sidecar; a restart drops it and the phone's next request rebuilds it.

## Design

### On demand, not pushed

The Mac does **not** publish chats of all recent sessions. A chat is published only for a session whose Chat screen is open on the phone:

1. Opening Chat on the phone enqueues a relay action `session_chat_request` `{session_id, subagent_id?}`. While the screen stays open the phone repeats it every 60 s (the same throttle as `SessionReportRequester`).
2. On the Mac, `SessionChatRequestHandler` (idempotent, replies `.applied()` at once, no grant needed — it only reads) tells `SessionChatRunner` to watch that session (or that subagent) for the next **5 minutes** from the last request.
3. `SessionChatRunner` (a `HubCompanion`, pattern of `SessionReportRunner`) runs `watchtower workbench session-feed --session N --json` (or `--subagent id`) off the main actor, every **10 s** for a watched session whose agent is live and once for a finished one, CLI timeout 30 s. It keeps the clipped result in memory only.
4. `SessionChatSlice` (kind `session_chat`, record `session_chat-<session_id>` or `session_chat-<session_id>-<agent_id>`) publishes what the runner keeps, on the normal 30 s full tick. It is not an urgent kind: no fast lane, no extra silent pushes.

So a live chat is at most ~40 s behind on the phone, and nothing about a session is in iCloud unless the owner opened its chat in the last 5 minutes.

### Lifetime

A watch expires 5 minutes after the last request. The runner then drops the in-memory payload, the record leaves the slice's window, and the publisher deletes it from the zone (the usual missing-from-window rule). Unlinking the phone or turning the hub off removes it like every other record.

### Size

One record must fit `Envelope.maxBytes` (900 000) and I-8 says the slice caps itself:

- the newest **300 entries** of the feed (older ones: `entries_more` = how many were cut, shown as "N earlier messages — open on the Mac");
- each entry's `text` clipped at **4000** characters (`text_clipped`);
- titles, subagent descriptions at 200;
- a payload over **600 000** bytes after that drops the oldest entries until it fits (counted into `entries_more`).

No paging in this phase: the phone shows the tail. A subagent's chat is its own record with the same caps.

### Wire model

Kit mirror `SessionChat: SliceMirror` in `WatchtowerKit/Sources/WatchtowerKit/Models/SessionChat.swift`, pinned by `Tests/Fixtures/workbench/session_chat.json`:

`session_id`, `agent_id` (absent for the main feed), `updated_at`, `live`, `entries_more`, `entries` — each entry `id`, `kind` (open wire value: owner, agent, ask_answer, watchtower, brief, subagent, separator), `at` (Unix seconds), `text`, `text_clipped`, `ask_id`, `title`, `via`, `subagent` {`agent_id`, `type`, `description`, `status`}.

The Mac maps the CLI JSON (FEED-03 keys) to this payload; the Desktop `SessionFeed` model stays in WatchtowerCore and is not shared with the Kit.

### Phone screen

- **Session detail** gets a **Chat** row (above the report card) that pushes `SessionChatRoute(sessionID)`.
- **`SessionChatView`** follows the Mac mockup: owner bubbles right, agent text left, ask answers and Watchtower lines marked "via Watchtower", the brief as one collapsed line, separators between conversations, subagent markers as tappable rows that push the subagent's chat. It scrolls to the newest entry when it opens.
- While waiting for the first record: "Asking your Mac…"; after 60 s with none: "Your Mac has not sent this chat yet. Is it awake?".
- At the bottom the existing **Tell the session…** bar, shown under the same rule as on the session detail (a device allowed to type, PROJ-16); a sent line shows as a pending bubble until it appears in the feed.

### What stays out

No search, no paging into older entries, no chat of sessions the owner did not open, no copy of the feed in the phone's own database beyond the replica record (the replica is deleted with the record).

## Contracts

- **FEED-05 (new, `docs/inventory/session-feed.md`):** the chat reaches the phone only on request: a `session_chat` record exists only for a session (or subagent) the phone asked for in the last 5 minutes, and only with FEED-02 entries. Guard tests: the slice publishes nothing without a watch, drops the record when the watch expires, and its payload carries no tool, thinking or hook text.
- **I-4** amended as above; `docs/features/mobile-companion.md` notes the exception.
- FEED-01..04, PROJ-16 unchanged.

## Testing

- Mac: `SessionChatSliceTests` (caps, 300-entry tail, 600 KB trim, fixture parity with the Kit, no window without a watch, expiry), `SessionChatRunnerTests` (10 s live cadence, single run when finished, CLI failure keeps the last payload and logs), `SessionChatRequestHandlerTests`.
- Kit: fixture test for `SessionChat`, `SliceKindTests` gains `session_chat`, `ActionKind` gains `session_chat_request` in `RelayPayloadTests`.
- Phone: `SessionChatWiringTests` (request on appear, 60 s repeat, stop on disappear, subagent push), demo seed for the simulator screenshots.

## Owner decisions in this review

1. Amend I-4 as written above (the chat crosses to iCloud, on request only).
2. On demand only (no background publishing of recent sessions), 5-minute watch.
3. Tail of 300 entries, no paging in this phase.
