# Workchat — drive a workbench session from its chat (board #711)

Mockups: [2026-10-18-workchat-mockups.html](2026-10-18-workchat-mockups.html) (open it in the code viewer's **Preview**). The numbers below refer to its four states.

Builds on the session chat feed (`docs/features/session-chat-feed.md`, FEED-01..05).

## Why

The owner opens a session's **Chat** pane to follow what the agent says, and it lets them down in four ways (Linear AI-12):

1. **The pane only reads.** To answer the agent, stop it or allow a command, the owner switches to the terminal. The owner's decision (ask #390): the chat is a second way to drive the session, on a par with the terminal.
2. **Raw markdown.** Agent text is parsed as inline markdown only (`SessionChatText`, `inlineOnlyPreservingWhitespace`), so headings and lists show as `##` and `-`.
3. **Noise posing as the owner.** Claude Code writes its own notices into the transcript as `user` records: `<task-notification>` (a background task or subagent finished) and `<teammate-message>` (a message from another session). The parser takes them for owner messages. In the largest session on the owner's machine (a 133 MB transcript) 113 of 119 "owner" entries were such notices.
4. **Slow on long sessions.** The Go read is fine: that 133 MB transcript parses in 0.75 s into 700 entries (~630 KB of JSON), and later polls read only the tail. The cost is on the Swift side. Every 3 s poll republishes `entries`, and each evaluated row builds `SessionChatText` again, which re-parses its markdown in `init`. Rows are not `Equatable`, and 700 selectable texts sit under a bottom-anchored `LazyVStack`.

Also, a subagent opens in a modal sheet with a **Done** button, and a nested one opens in another sheet stacked on top.

## Decisions (owner, ask #390)

- **Name:** the pane keeps a chat name. It is **Workchat**, because it lives in the workbench and drives the session. Every place that says **Chat** for this pane says **Workchat**: the pane picker, the session row menu (**Show Workchat**) and the header toggle. The phone's session **Chat** row is out of scope and keeps its name.
- **Subagents** open in the same pane, with a path bar and **‹ Back** (state 3).
- **Claude Code notices** show as one grey event line (state 1, callout 3), never as an owner bubble.
- **Volume:** render optimisation plus lazy loading, the way AI Chat avoids re-rendering. No fixed cap on what can be read.
- **Mockups first.** This document and the mockups are reviewed together.

## Goals

- Read the whole dialog of a session with markdown rendered as AI Chat renders it.
- Write to the agent, stop it, answer its permission prompt and open its asks from the pane (states 1, 2 and 4).
- Open a session of several hundred entries at once and scroll it smoothly while the agent works.
- Notices take no space beyond one line each.

## Non-goals

- No change to the phone: its chat screen, slice, caps and FEED-05 stay as they are. The phone drops the new entry kind (see "Event entries").
- No search, export or copy-all.
- No slash-command autocomplete. A line starting with `/` is typed as written.
- No tool calls, tool output or thinking in the feed. FEED-02 stays "dialog only".
- No Resume button for a finished session.
- No new storage. Nothing about the transcript lands in SQLite (FEED-01).

## Anti-goals (a failure even if it works)

- A line from the Workchat lands inside a permission prompt, or is half-typed into a busy agent's input.
- The pane spawns more CLI processes than today, or polls while nobody sees it.
- The Workchat and the terminal disagree about what was sent: a line shown as sent that never reached the session.

## Design

### 1. Event entries (Go, `internal/sessionfeed`)

New entry kind `event`. A `user` record whose text, after `<system-reminder>` stripping and trimming, starts with one of these wrappers becomes an event, not an owner line:

| Wrapper | `event_type` | `title` | `text` |
|---|---|---|---|
| `<task-notification>` | `task` | the `<summary>` element | the wrapper with tags removed, one `tag: value` per line |
| `<teammate-message …>` | `teammate` | the `summary="…"` attribute, else the first line of the body | the body |

- A record is an event only when its text **starts** with the wrapper. A record that has owner text before a wrapper stays an owner line.
- Any other user text that starts with an XML-like tag stays an owner line, as today. The list grows only by adding a row to the table, with a fixture of the real shape.
- Fixtures are synthetic, in the real shape. Public-repo hygiene allows no live transcript text.
- `event` entries get the same `id`/`at`/`conversation` as other entries.
- New JSON keys on the entry: `event_type` and `title`. `title` already exists for ask answers.
- **FEED-02 amendment** (needs the owner's approval with this review): "The feed holds … and Claude Code notices as `event` entries (a background task finished, a message from another session); a notice never appears as an owner entry." New guard `TestParse_NoticesAreEvents`. FEED-03 lists the two keys.
- **Codex:** no notices of this shape. Nothing changes.
- **Phone:** `SessionChatPayload` already drops kinds it does not know before the cut (`testOnlyFeedKindsPublished`). The phone loses no owner lines, it only stops seeing the notices as owner bubbles. Adding `event` to the phone is a follow-up, not this work.

### 2. Rendering (Swift)

- **Markdown:** agent text, owner text, the brief and event bodies render with the AI Chat renderer (`MarkdownView` over `MarkdownDocument.parse`, code blocks via `CodeBlockView`). Links follow AI Chat's link gating. `SessionChatText` goes away.
- **Parse once:** the parsed document is cached per entry id and text, in the store or a small cache next to it. A poll that re-emits an entry with the same text reuses it. A grown message re-parses only that entry.
- **Equatable rows:** `SessionChatRow` becomes `Equatable` over the fields it shows and is applied with `.equatable()`, the `ChatMessageRow` pattern. An unchanged row never re-renders.
- **Lazy window:** the store keeps every entry (memory is cheap: 700 entries ≈ 630 KB). The view renders only the newest window: 120 entries on open. When the top of the list comes into view, the window grows by 120 and the scroll position stays on the entry that was at the top (`scrollPosition(id:)`). While the window has not reached the first entry, a "Loading earlier messages…" row sits at the top (state 4, callout 1). Following the bottom works as in AI Chat: it follows while the owner is at the bottom (`ChatAutoScrollPolicy`/`ChatFollowTracker` or the same rule) and stays put while they read older text.
- **Events:** one centered grey line: an icon by `event_type` (task, message), the `title`, and a chevron. A click expands the body under it as small text. Expanded state is per pane and not stored.
- **Polling** keeps today's contract: once on open and on a state change, every 3 s while the agent works or has background subagents, never while the window is off screen (`isTabOnScreen`, `UIVisibilityCenter`). The Workchat spawns no more CLI processes than the Chat pane does now.

The 120 window and the grow step are the builder's to tune by measurement. The goal: a 700-entry session opens and scrolls without visible stutter on the owner's machine.

### 3. Subagents in place (state 3)

- The pane holds a navigation path of subagent entries. Empty = the main feed.
- Opening a subagent card pushes it. The bar becomes **‹ Back**, then `Workchat › <type> › <nested type>…`. Each part is clickable and pops to that level. Esc and ⌘[ pop one level when the pane has focus.
- A subagent's feed is read when it opens (`session-feed --subagent`). While its marker says `running` and the pane is on screen, it is read again every 3 s through the same poller rule, so a running subagent fills in. A finished one is read once.
- Headings **Task** and **Report** stay as today.
- No composer inside a subagent. In its place: "Subagents are read-only. Write to the agent in the main Workchat." This is the phone's rule: a line would reach the main agent.
- Leaving the session or switching panes resets the path.
- While a subagent is open, the main feed is not on screen and is not polled. **‹ Back** reads it once, then the normal rule applies. So the pane runs at most one CLI process at a time, as today.
- `SessionChatSubagentSheet` goes away.

### 4. The composer (states 1 and 2)

The bottom of the main feed holds a multi-line field and one round button.

**Sending.** Return sends. Shift-Return adds a new line. The line goes through `SessionLineDelivery.deliverLine` with a new key `.workchat(UUID)`. It is the same pipeline as the phone's Tell, ask answers and review rounds: bracketed paste, a settle pause, a separate Return, withheld when the prompt holds a draft, hooks have not reported, or a permission prompt appeared. The gate is the phone's `session_input` gate:

- the agent is idle (not working, background or needs-approval);
- the prompt holds no text (`TerminalCenter.promptDrafts` holds no entry for the session; it tracks the owner's keystrokes and pastes into the terminal);
- otherwise the line is held.

The gate lives in the phone's `SessionInputHandlers` today. **The first task extracts it**, with the interrupt guard and the permission answer from `PermissionAnswerHandlers`, into one Mac-side service. Both the phone handlers and the Workchat call that service. Phone behaviour must not change: the existing phone handler tests (PROJ-16/17/21 guards) are the safety net and must pass unchanged. The device grants, `ActionRequestPayload` and board-session checks stay in the phone handlers.

The Workchat's held lines and their outcomes are owned by one Workchat model per session, held by `WorkbenchesViewModel`, not by the pane view. It subscribes to `onHeldEvent` for `.workchat` keys only, next to the existing consumers.

The owner at the Mac needs no grant. PROJ-16's grants are for the phone.

**What the owner sees**, per `Delivery` result:

| Result | In the feed |
|---|---|
| `submitted` | A pending bubble that turns into the real owner entry when the feed shows an `owner` entry with the same text (compared with whitespace collapsed; a `/name args` line matches the parser's slash-command entry) dated at or after the send. After 90 s without one it stays as a plain local bubble, the phone's rule. A `/clear` shows no owner entry, and it falls back the same way. |
| `held` / `queued` | A dashed bubble "Queued · sends when the agent stops · Cancel" (state 1, callout 5). **Cancel** calls `dropHeld` for that key. |
| `typed` | The bubble with "Typed into the terminal, not sent: press Return there · Show in Terminal". |
| `copied` | "Copied to the clipboard: the terminal does not accept pasted text · Show in Terminal". |
| `noSession` | The composer is gone already. The line stays in the field. |

- Held lines live in memory in `SessionLineDelivery`, as today. A quit drops them. The bubble says so only if that turns out to confuse; it is not built up front.
- A line starting with `/` is typed as written, so `/clear` and `/compact` work. After `/clear` the feed shows a separator, as today.
- Empty or whitespace-only lines are not sent.
- The draft in the field survives pane switches and is lost when the app quits.

**Stop.** While the agent works or has background subagents, the round button is **Stop** (■), and Esc in the empty field does the same. It calls `TerminalCenter.sendInterrupt(sessionID:)` through the extracted guard: it is refused while a pending `permission_requests` row exists, because an Esc would reject the prompt. When refused, the permission card is what the owner sees. The check is not atomic with the hook writing the row. The phone accepts the same race (`PermissionAnswerHandlers`, the interrupt comment), and so does the Workchat.

**Permission prompt (state 2).** When the session has a pending `permission_requests` row, a card closes the feed: what the agent wants to do (the row's summary, the command in a code block), **Allow**, **Deny**, **Show in Terminal**.

- Allow and Deny run the phone's guarded `UPDATE … WHERE status='pending'` (`PermissionAnswerHandlers`), shared, not copied. If the row was answered in the meantime, the card disappears.
- `PermissionAllowBlock` applies: for a shortened summary or a settings path, only **Deny** and **Show in Terminal** are shown.
- Detection is the existing one: the hooks write the row. A prompt the hooks did not report shows no card, and the status pill still says what `SessionAgentStateCenter` knows.
- Codex sessions write no rows. They get the composer (through the session's `inputProfile`) and Stop: Esc interrupts a Codex turn too. This is my call, and the manual check covers it. They get no permission card.

**Asks (state 4).** Each open ask of this session (`owner_asks` with this terminal session) shows as a card at the end of the feed: kind, `Ask #N`, title, **Open Ask**. The button opens it in the existing ask drawer. Once answered, the card leaves. The answer itself appears in the feed as today (`ask_answer`).

**Finished or stopped session.** No composer and no Stop. A line instead: "Session finished. The history stays readable." (state 4, callout 3).

### 5. Header

The bar shows the session title, a status pill from `SessionAgentStateCenter` (Working, Needs approval, Waiting on you, Agents working, Ready to check, Finished, Stopped, Error; the same words and colours as the sessions panel), and the **Terminal | Workchat** switch that exists today as the pane picker.

## Constraints

- FEED-01: nothing from transcripts in SQLite, and the transcripts stay read-only.
- FEED-02 is amended as above, nothing more. FEED-03: new keys added, none renamed.
- Line delivery reuses `SessionLineDelivery` (PROJ-12/13 delivery rules) and adds no second typing path.
- Interrupt and permission answers reuse the phone's guards.
- Swift house rules: `docs/review/review-rules.md`, "Swift / Desktop conventions".
- The user guide gets a Workchat section in `docs/guide/features/workbench/sessions.md` (none exists for the chat today). `docs/features/session-chat-feed.md` gets the event kind, the composer and the in-place subagents.

## Left to the builder

- Window size and grow step, measured on a real long session.
- Where the parsed-markdown cache lives (store or a view-model next to it).
- Icons, exact spacing and colours, following the mockups and the sessions panel.
- Splitting the work into tasks. The Go event kind (1) is independent of the Swift work. Rendering (2) comes before the subagent path (3) and the composer (4).

## Tests

- Go: `TestParse_NoticesAreEvents` (both wrappers, real-shaped fixtures, title and type extracted, no owner entry), the existing FEED-02 guards unchanged, a CLI JSON key test for `event_type`/`title`.
- Swift (Core): the markdown cache reuses a parse for an unchanged entry and re-parses a grown one; window growth keeps the anchor entry; pending bubble matching (same text, at or after the send, 90 s); composer gate decisions (idle → go, working/needs-approval/prompt text → hold); Stop refused with a pending permission row.
- Manual check by the owner at the end: a long live session with subagents, a permission prompt answered from the Workchat, a line queued while the agent works, Stop, an ask card.
