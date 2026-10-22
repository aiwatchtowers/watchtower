# Workchat polish — one toggle, asks in the current mode, a live action line, send while busy, paste (2026-10-21)

Follows `docs/superpowers/specs/2026-10-18-workchat-design.md` (#711) and `docs/features/session-chat-feed.md`. Owner decisions: ask #481.

## Why

The owner now drives sessions from the Workchat day to day, and five things still push them back to the terminal:

1. The session strip's `[Terminal | Workchat]` is two buttons. The owner wants one toggle that names the other mode.
2. Opening an ask (stack card, banner, notification, `ask #N` link) shows the session's **terminal**, even when the owner keeps that session in Workchat.
3. While the agent works, the Workchat shows nothing but a "working" state. The owner wants to see what the agent is doing right now, nicely presented, and **not** kept in the history.
4. A line typed while the agent works waits until the agent stops ("Queued · sends when the agent stops"). In the terminal the owner can type while the agent works and Claude Code picks the line up at its next step. The owner wants the same, including sending several lines in a row.
5. ⌘V of an image or a file does nothing useful in the composer. The terminal accepts both.

## Decisions (owner, ask #481)

- **Toggle:** one button instead of two. It is labelled with the mode it switches **to**: in the terminal it reads **Workchat**, in the Workchat it reads **Terminal**. The mode stays remembered per session, as it is today (`WorkspaceLayout.workchatSessions`).
- **Live action:** one live line under the feed, above the composer, showing the agent's current step, for example "Running go test ./internal/db", "Editing WorkchatModel.swift" or "Reading 3 files". It changes at every step, has a timer, and goes away when the agent answers. It is never an entry and is never in the history.
- **Lines while busy:** sent at once, the way the terminal does it. Claude Code queues the line itself and reads it at its next step. The bubble shows as queued until the agent has read it.

## Goals

- One toggle button on the session strip. ⌃` and the View menu keep working as they do now.
- Every way of opening an ask opens the session in the mode it was last shown in.
- A live action line, derived from the transcript at read time and kept in memory only.
- A line sent while the agent works is pasted and submitted at once. Several lines in a row each go in turn.
- ⌘V of an image or of files copied in Finder attaches them to the draft. They are sent as paths the agent can read.

## Non-goals

- The tool calls themselves (input, output, diffs) stay out of the Workchat. FEED-02 stands: the live line is a single summary, not a step log.
- No change to the phone. The phone's `session_chat` slice does not carry the live line, and the phone's Tell keeps its own gate (PROJ-16 unchanged for the phone).
- No drag and drop and no attach button (the owner asked for paste only). The builder may add drag and drop if it costs nothing extra on top of paste. That is the builder's call.
- No change to how the terminal's own typing works.

## Anti-goals (a failure even if it works)

- A tool call, or a list of past steps, ends up in the feed or in its history. That breaks FEED-02 and the owner's "not in the history".
- A line lands inside a permission prompt, or is mixed into text the owner is typing in the terminal. The `needsApproval` and `promptHasText` holds stay.
- The live line flickers or jumps between polls, or it stays on screen after the agent has answered or stopped.
- A pasted image is written somewhere the agent cannot read, or into the repository.

## Design

### 1. The toggle (Swift, `WorkbenchSessionStrip`)

`modeToggle("Terminal") + modeToggle("Workchat")` becomes one button. Its label and icon are those of the other mode, and its action is what the other half does today (`vm.showSession(sessionID, workchat: !current, inPane: pane, …)`). The help text names the shortcut (⌃`). The design kit has no segmented-to-single pattern, so a plain strip button matches Report and Review. Built from the design kit per `docs/design/desktop-style-guide.md`.

### 2. Asks open the current mode (Swift)

`showAsk` → `revealTerminal` is meant to respect the remembered mode ("Its terminal or its Workchat, whichever mode it opened in (#711)"). But the owner sees the terminal, so at least one path forces it. Known suspect: `WorkbenchesViewModel+Panel.swift` `revealTerminal(_:keeping:in:)` calls `layout.setMode(false, …)` unless the kept pane is that session's Workchat. Also check the live-session branch (`open(subject, placement: .show, …)`), `openTerminalAskLink`, the notification click and the Home/phone hand-offs. Rule: a session opened **for an ask** shows in `layout.isWorkchat(sessionID)`'s mode. Only an explicit "Show Terminal" / "Open in Terminal" forces the terminal. The ask drawer already sits beside either pane (`WorkchatAskDrawerHost`). Each path gets a test in the existing `WorkbenchesViewModel` ask tests.

### 3. The live action line

**Go (`internal/sessionfeed`).** At read time the reader derives an `activity` value from the transcript tail. It is not an entry. When the newest assistant message of the main conversation ends in one or more `tool_use` blocks that have no `tool_result` yet, `activity` describes the newest of them:

```json
"activity": {"tool": "Bash", "summary": "go test ./internal/db", "started_at": "<RFC 3339 of the tool_use record>"}
```

Otherwise `activity` is `null`. When the agent is mid-turn with no open tool (thinking or streaming text) the Desktop shows "Thinking…" from the session state (point below), not from Go.

Summary rules, deterministic, in one table in Go:

| Tool | Summary |
|---|---|
| Bash | `input.description` if set, else the first line of `input.command`, cut to 120 runes |
| Edit, Write, MultiEdit, NotebookEdit | file basename (`input.file_path` / `notebook_path`) |
| Read | basename; several open Reads in one message → "N files" |
| Grep, Glob | `input.pattern` |
| Agent / Task | `input.description` |
| WebFetch / WebSearch | host / query |
| MCP `mcp__<server>__<tool>` | `<tool>` with the server's short name |
| anything else | the tool name |

Codex sessions: the same field from `ParseCodex` when its records give an open call (`function_call` without its `function_call_output`). If that is not cheap, `null` for Codex in this round, and the note says so.

- It is computed on every read, including `--after C` tail reads. A tail read that holds no new records keeps the last `activity` the caller has, so the reader also returns `activity` on an empty tail. The builder picks the cheapest correct way, for example carrying the open-tool state in the cursor or re-scanning the last few KiB. The rule is that a poll must not turn the line off while the tool is still open.
- Text is clipped. Nothing is stored (FEED-01) and nothing goes to the phone (FEED-05: the `SessionChatPayload` builder ignores the field).
- `--json` gains the top-level key `activity`. That is an additive change to FEED-03's pinned keys, so the inventory gets an amendment line (the owner's ask #481 is the approval). Subagent feeds (`--subagent`) also get `activity`, so that an open subagent pane shows its own live line.

**Swift.** `SessionChatView` shows the line between the feed and the composer while `SessionControl.isWorking(status)` (Working / Running / Agents working):

- `activity` present: tool icon (SF Symbol per tool family: terminal, pencil, doc, magnifier, person.2 for Agent, globe, plug for MCP) + summary + elapsed time since `started_at` (ticks each second, `TimelineView`), with a subtle shimmer or pulse built from the design kit.
- `activity` null while working: "Thinking…" with the same timer, counted from the session state's `at`.
- `Agents working` (background) with no open tool: "Agents working" + the running subagent count, if the feed's `subagents` gives it.
- The line goes away the moment the session is not working (stopped, waiting, needs approval, where the permission card takes the place) or when the feed shows a newer agent text entry than `started_at`. Changes animate without the layout jumping: fixed height, crossfade.

### 4. Lines go while the agent works

`SessionControl.lineCheck` gets a Workchat variant (or a parameter) that drops the `.agentBusy` hold, and only for the Mac's Workchat lines. It keeps `needsApproval`, `promptHasText`, `sessionGone` and the `justSubmitted` settle. The phone's gate is unchanged. Every Workchat line still goes through `SessionLineDelivery`'s per-session queue, so lines sent quickly go one after another, each its own paste + Return and never sharing a prompt.

Bubble states:

- Submitted while working → a "Queued · the agent reads it at its next step" caption. **Cancel** is gone for a line already submitted (it is in Claude Code's own queue by then). Cancel stays for a line still held by our queue.
- The bubble leaves on its echo as today. **Builder check needed:** how Claude Code records a line it took mid-turn. It may write a normal `user` record when the line is read, or an attachment-style record (`queued_command` or similar). The reader must turn that record into an `owner` entry (FEED-02 already allows owner lines), or else the bubble never finds its echo. Verify against a real transcript, add the record type to the parser and a fixture, and widen the echo window for lines sent while busy (it should count from when the agent read it, not 90 s after delivery). Codex: verify that Return during a Codex turn queues the input (Codex CLI steers or queues). If it does not, Codex keeps the old hold, and the note says so.
- PROJ-16 / PROJ-12 and the Workchat spec's anti-goal "half-typed into a busy agent's input" get amended for Mac Workchat lines (owner ask #481). Read `docs/inventory/` for the PROJ-12/16 entries and their guard tests first. A guard test that asserts "Workchat holds while busy" changes only with that amendment line, and is not weakened otherwise.

### 5. Paste images and files

`WorkchatComposer`'s text view intercepts ⌘V (`NSTextView` `paste:` / `readSelection(from:type:)`, or SwiftUI `onPasteCommand`, whichever works with the current field):

- **Image data on the pasteboard** (PNG/TIFF, screenshots with ⌃⇧⌘4): written as PNG to `<workspace>/workchat-attachments/<session id>/<timestamp>-<n>.png`. That is outside the repo and readable by the agent (it reads absolute paths). Files older than 7 days are removed at launch.
- **File URLs** (copied in Finder): their absolute paths are used as they are, with no copy.
- **Plain text**: unchanged.

Each attachment shows as a chip above the field (thumbnail for images, icon + name for files, ✕ to remove). On send, the line is the text followed by the paths, one per line, each wrapped in quotes when it holds spaces. Claude Code turns a pasted image path into an image of the prompt (`[Image #N]`), and other paths the agent reads with its tools.

**Builder check needed:** the echo. If Claude Code replaces an image path with `[Image #N]` in the owner record, `WorkchatOutgoing.matches` must ignore attachment paths and image markers when matching, so the bubble still finds its echo. The owner entry renders `[image]` markers as today (the builder may show the thumbnail chip in the echo if that is cheap).

## Constraints

- FEED-01/02/05 hold. FEED-03 gets one additive key. PROJ-12/16 get the amendment for Mac Workchat lines while busy. Each amendment goes into `docs/inventory/` with ask #481.
- `docs/guide/` pages for Workchat updated in the same PR (`docs/guide/WRITING.md`, `go test ./docs/guide`).
- `docs/features/session-chat-feed.md` updated: the toggle, the live line, sending while busy, paste, and the new v1 limits.
- The 3 s Workchat poll stays. The live line rides on it; no new process or timer beyond the elapsed-time tick.
- Desktop code follows `docs/review/review-rules.md` (Swift conventions); swiftlint per brief.

## Calls made after the builder check (author's calls, not the owner's)

- **Claude Code mid-turn lines.** Claude Code accepts input while it works and either takes it at its next step or right after the turn. Either way the line counts as "sent at once" for the owner, so the feature does not depend on which. The builder only has to find the record the line leaves in the transcript and make it an owner entry. If a Claude Code version writes no record for it, the owner entry comes when the agent's next turn starts, as today.
- **A queued bubble with no echo.** It waits until the agent's next stop, plus the existing 90 s. Then it stays as a plain sent bubble, the way a `/clear` line does today. It is not shown as failed and there is no resend.
- **Attachments and permission prompts.** A pasted image path is attached by Claude Code itself, with no Read tool call and no permission prompt, so `<workspace>/workchat-attachments/<session id>/` stays. A Finder file the agent then reads may prompt exactly as it would in the terminal. Nothing new, and the permission card handles it. Codex: paths go in as text. If Codex does not attach images from paths, the note records that limit.
- **Attachment lifetime.** Files older than 7 days are removed at launch, except the folders of sessions that are still live.
- **Which ask paths.** Every path that opens a session to show an ask (stack card, banner, notification, Home, `ask #N` link, phone hand-off). The session shows where it would show anyway (same pane placement as today), in its remembered mode. A session that was never put in Workchat opens in the terminal, as today.
- **Several open tools.** One open → its summary. Several → the newest one's summary + "· N more", and Reads together → "N files". The line keeps its fixed height, so a call closing changes only the text.
- **Who decides "working".** `SessionControl.isWorking` decides. An open tool in the transcript after Esc or a stop shows nothing. Sidechain records are ignored for the main feed's `activity`.
- **Cursor.** The cursor format stays (FEED-03). An empty tail read re-scans a bounded window before the cursor (for example the last 256 KiB) to rebuild `activity`.
- **Scope of the PROJ-16 amendment.** Mac Workchat lines to live Claude Code and Codex agent sessions only. Nothing else changes.

## Left to the builder

- The exact icons, the shimmer style and the copy of the live line (English UI, like the rest of the app).
- How the Go reader keeps `activity` right across tail reads (cursor state vs a small re-scan).
- Whether `lineCheck` gets a parameter or a second function.
- Drag and drop on top of paste, if it is free.

## Tests

- Go: `sessionfeed` fixtures for an open Bash/Edit/Read×3/Agent/MCP call, a closed call (`null`), an empty tail read keeping the open call, Codex open call (or `null`), clipping, the mid-turn queued-line record → owner entry. CLI JSON key test (FEED-03).
- Swift Core/Desktop: toggle label and action per mode; `showAsk` from each path keeps Workchat mode; the live line model (working + activity, working + none → Thinking, not working → hidden, newer agent text → hidden); `lineCheck` Workchat variant (busy → go; approval and prompt text → hold; phone gate unchanged); several lines in a row each delivered once and in order; paste of image data writes a PNG under the attachments dir and adds a chip; file URLs add their paths; send composes text + paths; echo matching with `[Image #N]`.
- Manual check by the owner at the end: a long session in Workchat. Watch the live line through several steps, send two lines while it works, paste a screenshot and a Finder file, open an ask from the stack while in Workchat, and flip the toggle.
