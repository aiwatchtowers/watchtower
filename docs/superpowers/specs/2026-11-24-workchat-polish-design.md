# Workchat polish: quiet steps, agent-text highlighting, agent-finished row, clipboard paste, stuck line

Board: #2201. Approved design: [`docs/design/mockups/workchat-polish/`](../../design/mockups/workchat-polish/index.html) (v2, ask #1747).

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Turn steps collapsed by default; expanded quietly (no card fill, a thin left rule, finished steps grey, only the running one bright) | owner, conversation 2026-11-24; reverses C1 of `2026-11-19-workchat-agents-and-progress-design.md` |
| D2 | Highlighting in the agent's text in the Workchat, not in the terminal pane | ask #1748 |
| D3 | No fills, pills, coloured boxes or bold: colour only on the text, muted, like IDE syntax colouring | owner, conversation 2026-11-24 ("сильно пестро … как в раскраски IDE"); ask #1747 approved v2 |
| D4 | The "agent finished" notice is a quiet row with the result, not the raw `<task-notification>` dump | owner, conversation 2026-11-24; ask #1747 |
| D5 | ⌘V in the Workchat composer takes a screenshot/image and Finder-copied files | ask #1748 (both failed for the owner) |
| D6 | A line held because the terminal prompt "has text" must go once the owner erased it; when text really is there, say so and offer a way out | owner, conversation 2026-11-24; ask #1747 |
| C1 | Highlighting covers `#N` refs, commit hashes, file paths, commands; verdict words and durations are not coloured | author's call, from D3 (v2 dropped them) |
| C2 | Highlighting is Workchat-only (a `ChatFeedContext` flag); the AI chat and the phone are unchanged in v1 | author's call |
| C3 | The prompt-empty fix is a per-agent "draft length" model in both twins (Mac `TerminalCenter`, Go `sessionhost.promptState`, test fake `FakeHostDelivery`), not screen scraping. **Narrower than the v2 mockup's "read the line off the screen":** an erase releases the line when it was a Backspace or Ctrl+U erase of a draft typed straight (no cursor keys); after cursor or word-edit keys the line stays held as today, and the hold caption's actions are the way out | author's call, §6.1 — the owner confirms it by approving this spec |
| C4 | "Clear and send" is one Ctrl+C (the v2 mockup said Ctrl+U: in Claude Code Ctrl+U only clears the current line before the cursor, Ctrl+C clears the whole input), offered only while the agent is idle; while it works only "Send together" and Cancel | author's call, §6.3 (Ctrl+C interrupts a working agent) |
| C5 | The expanded steps list stays above the live line (as today), not below it as the HTML drew | author's call, mock shots |
| C6 | A pasted screenshot is an inline `Image #N` token (the #2065 paste tokens), not the HTML's thumbnail chip; only Finder files are chips | owner's earlier D7 of `2026-11-19-workchat-agents-and-progress-design.md` ("pastes go inline as tokens, as in Claude Code"); the v2 chip contradicted it |
| C7 | The Workchat error bar becomes quiet too (glyph, grey text, quiet Retry; no orange box), and the loading state reads "Reading the session…" | author's call, D3 applied to the screen's other states |
| C8 | `#N` refs are also coloured in the agent-finished row's title | author's call, matches the approved HTML |

## Intent

The Workchat is the owner's main window onto a session. Four things in it read badly or
break: the turn's steps shout over the dialog, the agent's text is a flat wall where the
target numbers, hashes and file names are hard to spot, a finished background agent
dumps a raw notification with ids and boilerplate, and two everyday actions fail —
pasting a screenshot or a Finder file does nothing, and a line can hang in "Queued"
forever after the owner typed into the terminal prompt and erased it.

## Goals

1. **Quiet steps** (D1). The live line's "This turn · N steps" is collapsed by default
   and shows the running step and its time inline; expanded, the list has no fill, a
   thin left rule, grey finished rows, `<1s` instead of `0:00`, and human labels for
   bare tool names (`SendMessage` → "Message to <agent>").
2. **Agent-text highlighting** (D2, D3, C1, C2). In agent bubbles only, plain-text spans
   get a muted colour: `#N` (opens the target on the board), a commit hash (click copies),
   a file path that exists in the session's folders (opens the code viewer), and shell
   commands in inline code. Code blocks, inline code other than commands, and links are
   untouched.
3. **Agent-finished row** (D4). A task notification is one quiet row: a status glyph
   (✓ green-tinted, ✕ red-tinted, through `Tone`), the agent's name, and one meta line
   (`finished · 9 tools · 43.5k tokens · 1m 29s`). Expanded: the result, then text
   buttons Open output and Details (task and tool-use ids). Claude Code's boilerplate
   (`note:`, the "delivered as a message" result) is never shown. A background command
   (`Bash` run in background) is the same row, smaller, `exit N` in the meta.
4. **Clipboard paste** (D5). ⌘V and Edit ▸ Paste put a screenshot/image in the field as
   an image token, Finder-copied files as file chips, long text as a text token. The
   paperclip menu gains "Paste from clipboard", titled by what the clipboard holds
   (screenshot / N files / text) and disabled when it holds nothing usable.
5. **No stuck line** (D6, C3, C4). Erasing the prompt text in the terminal with
   Backspace or Ctrl+U (no cursor keys before it) releases a held line; after cursor or
   word-edit keys the line stays held as today and its caption offers the way out. A line held by real prompt text shows why and the text itself, with
   "Clear and send" (idle only), "Send together" and Cancel.

## Non-goals

- No highlighting in the terminal pane, the AI chat or the phone (C2).
- No change to which records reach the feed (FEED-02) or to the entry kinds.
- No screen reading of the terminal (C3).
- Steps stay current-turn only (as in the 2026-11-19 spec).


## Design

### §1 Quiet steps

- `WorkchatPaneMemory.stepsOpen` defaults to `false` (today `true`); the per-pane toggle
  stays in memory as now.
- Collapsed bar: `chevron.right`, "This turn · N steps", a spinner and the running
  step's summary (middle-truncated), its elapsed time, then 👥 and the turn clock —
  `WorkchatLivePresentation.Row` already carries the current tool; the step's own time is
  added.
- Expanded `WorkchatStepsList`: no `Fill.card` background; `.overlay(alignment:
  .leading)` rule in `.quaternary`; rows `.tertiary`, the running row `.primary` with a
  `ProgressView().controlSize(.mini)` in place of its symbol; "N earlier steps" line when
  the cap cut steps. Height still fixed to six rows (no jumps).
- `WorkchatLivePresentation.stepTime`: under 1 s → `<1s`. `WorkchatActivityPresenter`
  gets labels for the bare tool names the steps show today (`SendMessage`,
  `TaskOutput`, `TodoWrite`, MCP `mcp__x__y` → `y` with underscores as spaces).

### §2 Agent-text highlighting

- A pure scanner in `WatchtowerChatText` (`AgentTextHighlights.spans(in: String) ->
  [Span]`, kinds `ref`, `hash`, `path`, `command`), run on each plain-text run of an
  agent message's Markdown (never inside code blocks or links; inside inline code only
  `command`).
  - `ref`: `#\d{1,6}` at a word boundary, not part of a URL or a heading marker.
  - `hash`: `\b[0-9a-f]{7,40}\b` with at least one digit and one letter.
  - `path`: a token with a `/` or a known source extension (`.swift .go .md .sql .yml
    .json .ts .py .sh`); kept only if `CodeRoot` resolves it in a session folder
    (checked lazily, cached per message).
  - `command`: inline code whose first word is in a small allow-list (`make go swift git
    gh xcodebuild npm ./scripts/…`).
- Colours: a new token `SyntaxTint` in `WatchtowerKit/Sources/WatchtowerDesign/` (re-exported by
  `DesignKit`), its values pinned in `WatchtowerKit/Tests/WatchtowerDesignTests/TokenTests.swift` (`ref` = `Color.accentColor`, `hash` =
  `.purple`, `path` = `.orange`, `command` = `.green`), each at opacity 0.7, foreground
  only — no background, no weight (D3); the style guide's token table gains the
  `SyntaxTint` line. Light and dark checked in the shots.
- Actions: `ref` → `WorkbenchesViewModel.showTargetOnBoard`; `hash` → copy, with the
  existing "Copied" toast; `path` → `openFile(_:root:preview:)`. Hover shows a pointing
  hand and an underline only on hover.
- Enabled by `ChatFeedContext.highlightsAgentText` (default `false`), set in
  `WorkchatFeed.context()`.

### §3 Agent-finished row

- Go (`internal/sessionfeed/parse.go` `noticeEntry`): a task notification also fills a
  new optional `task` object on the entry: `task_id`, `tool_use_id`, `status`,
  `summary`, `result` (empty when it is the "delivered … as a message" boilerplate),
  `output_file`, `tokens`, `tool_uses`, `duration_ms`, `kind` (`agent` | `command`,
  from the summary's "Agent …" / "Background command …"), `exit_code` when given. `text`
  and `title` stay as today (FEED-03: an additive key, the pinned keys unchanged; the
  inventory entry gains a line for `task` with owner approval through this spec's
  review).
- When `result` is the boilerplate and the feed has the subagent's handback for the same
  `tool_use_id`, the CLI fills `result` with the handback's first paragraph.
- Swift: `SessionFeedEntry.task`; `AgentFinishedPresentation` builds the title (agent:
  its description, `#N` coloured per C8; command: "Background command · <summary>"), the
  meta line (`finished · 9 tools · 43.5k tokens · 1m 29s`; failed → `failed · 2 tools ·
  1.2k tokens · 12s`; command → `exit 0 · 3m 34s`) and the status tone (✓ success, ✕
  failure through `Tone`, glyph only, caption size for a command); `SessionChatRow.eventLine` draws it when `task`
  is set, else today's line (teammate messages unchanged).
- Open output opens the file in the code viewer read-only when it is under the session's
  temp dir, else reveals it in Finder; Details shows the ids as `.caption2 .tertiary`.

### §4 Clipboard paste

Root cause (confirmed for images): the composer's `PastingTextView` is plain text
(`isRichText = false`), and AppKit enables Edit ▸ Paste — hence ⌘V — only when the
pasteboard holds one of the view's `readablePasteboardTypes`, which for a plain-text view
lists no image type. A screenshot-only pasteboard therefore never reaches
`PastingTextView.paste(_:)`; the unit tests call `paste(nil)` directly and miss it.
The Finder-file failure is not explained by the code read (`NSFilenamesPboardType` is
readable and `PasteClassifier` returns `.attachFiles`); Task 4 starts by reproducing it
through the menu path and records the cause in this section.

- `PastingTextView` overrides `readablePasteboardTypes` (adds `public.png`,
  `public.tiff`, `public.jpeg`, `public.heic`, `public.file-url`, `com.adobe.pdf` when
  `onPasteData` is set) and `validateUserInterfaceItem` for `paste(_:)` so the item is
  enabled for those types. Its own `paste(_:)` still decides what happens.
- Tests go through `NSApp.sendAction(#selector(NSText.paste(_:)), …)` and
  `validateUserInterfaceItem` with a private pasteboard, not `paste(nil)`.
- Paperclip menu: "Paste screenshot" / "Paste N files" / "Paste text" from
  `PasteClassifier` on the menu's open (a user action — no TCC concern), disabled when
  the classifier says nothing usable.

### §5 Stuck line — root cause

`TerminalCenter.ownerInput` (and its Go twin `sessionhost.promptState.ownerInput`) keep a
boolean "the prompt holds a draft": every owner key that is not a submitting Return or
Shift+Tab sets it — Backspace included — and only a submitting Return clears it. Type
text, erase it, and the flag stays: `workchatLineCheck` returns
`.hold(.promptHasText)` forever, the bubble says "Queued · sends in a moment", and the
host holds the same line for `hold_if_prompt_text`.

### §6 Stuck line — fix

1. **Draft length model (C3).** Both twins replace the boolean with
   `DraftModel { count: Int, exact: Bool }` per run, fed by the same key decoder:
   - printable runes and a bracketed paste add their rune count;
   - Backspace subtracts 1 (floor 0) while `exact`;
   - Ctrl+U while `exact` and the draft holds no line break sets `{0, true}` (the cursor
     is at the end, so it clears the whole line);
   - a submitting Return, and Ctrl+C on a non-empty draft while the agent is idle (Claude
     Code clears the input), set `{0, true}`;
   - any other cursor or word-edit key (arrows, Home/End, Ctrl+A/E/W/K, Ctrl+U on a
     multi-line draft, Option+Backspace, Esc) sets `exact = false`: from then on only a
     submit or a clear empties it.
   - Input while a permission dialog is up (`inputAnswersDialog` on the Mac, the host's
     dialog state in Go) changes nothing, as today — the dialog's y/n never counts as
     draft text.
   - `holdsText` = `count > 0 || !exact` (so an unknown state holds, as today).
   A delivery's own paste and "left typed" set `exact = false` as today's flag does.
   Agents whose profile is not Claude Code keep `exact = false` after any key (today's
   behaviour). Three copies implement the rule and change together, from one shared
   table of key cases: `internal/sessionhost/prompt.go` (`promptState`, the authority),
   `TerminalCenter.ownerInput` (the Mac mirror) and the test fake
   `WatchtowerDesktop/Tests/FakeHostDelivery.swift` (its boolean `draft` becomes the
   model, so the Desktop delivery tests check the new rule).
2. **Re-check on change.** Every line held for `promptHasText` re-runs its check when
   the draft model changes (today it waits for the next state tick): the Workchat's
   `workchatLineCheck`, and `SessionLineDelivery`'s `lineCheck` for ask answers and the
   other Mac deliveries. The host re-tries its own held phone and agent-message lines on
   the same change.
3. **Hold caption and actions (C4).** `WorkchatOutgoing.caption` takes the hold reason
   and says it for each: `needsApproval` → "Waiting: answer the permission prompt in the
   terminal", `agentBusy` (a line just submitted) → "Queued · sends in a moment", and
   `promptHasText` → "Waiting: the terminal prompt holds text", plus the prompt's last line when the
   Mac terminal buffer can show it (read-only display, never a decision). Actions:
   - **Clear and send** (idle only): one Ctrl+C into the session, wait for the next
     prompt redraw (≤ 1 s, else give up and leave the line held), then the line. The
     app's own Ctrl+C sets the draft model to `{0, true}` whatever its state (exact or
     not), so the held line is released by it and never waits for a second clear. The
     action runs at most once per held line (the button disappears after the click), and
     the app never sends a Ctrl+C within 3 s of its previous one to the same session — so
     a Ctrl+C that landed on an already empty prompt (Claude Code then arms "press again
     to exit") can never be followed by a second one from the app. Test: a fake clock and
     a fake session assert one Ctrl+C per line and none inside the 3 s window.
   - **Send together**: the existing beside-text delivery (`sharedPrompts`), the line
     pasted after the draft with one Return.
   - **Cancel**: as today.

### §7 Quiet error and loading (C7)

`SessionChatView.errorBar` loses its orange fill: an `exclamationmark.triangle` glyph in
`Tone` warning, the message in `.secondary`, Retry as a quiet text button. The loading
state shows "Reading the session…" in `.tertiary` with a small spinner. Both strings in
the pane's presentation, with tests.

## Failure and races

- **Writers of the prompt state.** The owner (keys in the terminal, either client), the
  app's own deliveries (Workchat, ask answers, phone lines through the hub, agent
  messages) — all through the session host, which owns `promptState`; the Mac's
  `TerminalCenter` model is a mirror for its own pre-checks. The host wins: a delivery
  the Mac thought free is held by the host with `held(prompt_has_text)` and stays queued.
- **Host closes while a line is held:** the line turns `notSent`, its text back in the
  field (existing path). Test: `WorkchatModel` held → session gone → `notSent`.
- **Clear and send, agent starts working between check and Ctrl+C:** the action
  re-checks `isIdle` right before the Ctrl+C and refuses (line stays held, button
  disabled). Test with a fake `SessionControl`.
- **Clear and send, prompt never redraws:** after 1 s the line stays held, caption
  unchanged. Test with a fake clock (no wall time).
- **Restart:** a relaunched run starts `{0, true}` (as today's empty flag). The Mac
  mirror resets on re-attach.
- **Paste of an image the save fails for:** `attachmentError` shown, nothing inserted
  (existing path); test through the menu path.
- **Highlight path no longer exists:** the click shows the code viewer's "file not
  found" (existing); the span is only drawn when it resolved at render.
- **Task notification with unknown fields or malformed usage:** the row falls back to
  today's title-only line. Go test with a truncated notification.

## Promises → tasks and tests

| Promise | Task | Test |
|---|---|---|
| Steps collapsed by default, quiet expanded, `<1s`, tool labels | T1 | `WorkchatStepsPresentationTests`, `WorkchatPaneMemoryTests`, `WorkchatActivityPresenterTests` |
| Highlight spans (ref/hash/path/command, never in code blocks/links) | T2 | `AgentTextHighlightsTests` (`make chattext-test`) |
| Highlights drawn only with the flag, actions wired | T2 | `SessionChatViewTests` (flag on/off), `ChatUITests` |
| `task` object parsed; boilerplate dropped; handback fills result | T3 | Go `parse_test` / `feed_test`, `TestSessionFeedJSON_PinnedKeys` updated |
| Finished row presentation (ok/failed/command, meta strings) | T3 | `AgentFinishedPresentationTests` |
| ⌘V screenshot and Finder files through the menu path | T4 | `PastingTextViewTests` via `sendAction` + `validateUserInterfaceItem` |
| Paperclip "Paste …" item title/disabled | T4 | `WorkchatComposerTests` |
| Draft model: erase releases, cursor keys hold, submit/clear empty, dialog input ignored | T5 | Go `prompt_state_test`, Swift `TerminalCenterPromptDraftTests`, `FakeHostDelivery` (one shared case table) |
| Held ask answers re-check on draft change | T6 | `SessionLineDeliveryTests` |
| Hold captions per reason | T6 | `WorkchatOutgoingTests` |
| `SyntaxTint` values | T2 | `TokenTests` (`make kit-test FILTER=TokenTests`) |
| Held line re-checks on draft change; caption and actions | T6 | `WorkchatModelTests`, `WorkchatOutgoingTests` |
| Clear and send refuses when working, gives up after 1 s | T6 | `WorkchatModelTests` with fake control/clock |
| Quiet error bar and loading copy (C7) | T1 | `SessionChatViewTests` (strings, Retry) |
| PROJ-16 / PROJ-23 guards stay green (never over a draft) | T5 | existing guards + a new `TestProj23_…ErasedDraftReleases` |

All strings in presentation models (`WorkchatLivePresentation`,
`AgentFinishedPresentation`, `WorkchatOutgoing`, the paste menu) and covered by tests.

## Mockups (DesignShotCatalog)

Committed PNGs: [`docs/design/mockups/workchat-polish/shots/`](../../design/mockups/workchat-polish/shots/).
Rendered by `DesignShotsTests/testWorkchatPolishMockShotsRender`
(`DesignShotFixtures+WorkchatPolishMock.swift`), light and dark:
01 steps collapsed (working), 02 steps expanded, 03 steps narrow, 04 agent text with
highlights, 05 agent-finished row collapsed / expanded / failed / command, 06 composer
paperclip menu with "Paste screenshot", 07 composer after paste (image token + file chip
+ text token), 08 held line: prompt has text (idle: three actions), 09 held line while
working (no Clear), 10 empty Workchat (no steps, no rows), 11 loading, 12 error with
Retry. Colours through `Tone`/`SyntaxTint`, no row separators. The real views are
compared against these after the build.

## Inventory touched

- FEED-03 (session-feed): **a contract change the owner approves with this spec:** an
  additive optional `task` object on event entries (no key renamed or removed); the
  inventory text and `TestSessionFeedJSON_PinnedKeys` gain it, with a change-log line
  naming this spec's ask.
- PROJ-16 / PROJ-23 (workbench): the "prompt holds text" input is now the draft model;
  no guard relaxed — an unknown state still holds; the new guard covers the erased draft.

## Left to the builder

SF Symbols for the status glyphs, the `command` allow-list beyond the listed words.
