# Workchat polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Quiet turn steps, IDE-style highlighting of the agent's text, a quiet agent-finished row, working ⌘V for screenshots and Finder files, and no line stuck behind an erased terminal draft.

**Architecture:** Presentation changes stay in `WatchtowerCore` presentation types (strings tested there) and their SwiftUI views; the highlight scanner is pure in `WatchtowerChatText`; the task-notification fields are parsed in Go (`internal/sessionfeed`, the only parser) and decoded by the Desktop; the draft model replaces a boolean in the session host (authority) and its two Swift mirrors, driven by one shared JSON case table.

**Tech Stack:** Go 1.26, SwiftUI (macOS 14+), AppKit (`NSTextView`), WatchtowerKit `WatchtowerDesign` tokens.

**Spec:** `docs/superpowers/specs/2026-11-24-workchat-polish-design.md` (approved, ask #1757). Mock shots: `docs/design/mockups/workchat-polish/shots/`.

## Global Constraints

- D3: no fills, pills, coloured boxes or bold for highlights or status — colour only on text, muted (`SyntaxTint` opacity 0.7), status colours through `Tone`.
- C2: highlighting only in the Workchat (`ChatFeedContext.highlightsAgentText`, default `false`); AI chat and phone unchanged.
- FEED-03: the `task` key is additive and optional; no feed key renamed or removed.
- PROJ-16 / PROJ-23: an unknown draft state still holds a line; nothing is ever pasted over a draft the model cannot prove empty.
- All user-visible strings live in presentation types and are covered by tests.
- Tests never wait on wall-clock time (fake clocks); subprocess-spawning tests reap their process group.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make chattext-test`, `make kit-test FILTER=…`, `make lint-diff`, swiftlint on touched Swift files). The full gate runs once before each task's merge into the umbrella.

## Review Focus

1. **A draft edited with cursor keys, then erased** — must stay held (exact = false), never pasted over. Test in T6's case table (`left-then-backspace-all` → holds).
2. **⌘V with a screenshot while the composer is not first responder** — the menu item validates against the composer only when it is focused; pasting into the feed must do nothing. Test in T5 (`validate` returns false for a view that is not first responder is AppKit's; assert our override never enables paste without `onPasteData`).
3. **A `#N` inside a URL or a Markdown heading, a hash-like word (`deadbeef` all letters), a path that does not resolve** — no highlight. Tests in T2's scanner table.
4. **A task notification from an older Claude Code with no `<usage>`** — the row still draws with title and status; meta omits missing parts. Test in T3 and T4.
5. **Clear and send clicked twice fast, or while a hook flips the agent to Working** — one Ctrl+C at most, none while working. Tests in T7 with a fake clock and a fake control.

---

### Task 1: Quiet steps, quiet error and loading

Depends on: none

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatPaneMemory.swift` (`stepsOpen` default `false`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatLivePresentation.swift` (collapsed row carries the running step's summary and time; `<1s`; error/loading strings)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatActivityPresenter.swift` (`label(forTool:)`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkchatStepsList.swift`, `WorkchatLiveLine.swift`, `SessionChatView.swift` (`errorBar`, loading)
- Test: `WatchtowerDesktop/Tests/Core/WorkchatPaneMemoryTests.swift`, `WorkchatStepsPresentationTests.swift`, `WorkchatActivityPresenterTests.swift`, `WatchtowerDesktop/Tests/SessionChatViewTests.swift`

**Interfaces:**
- Produces: `WorkchatLivePresentation.Row.stepSummary: String?`, `Row.stepElapsed: String?`; `WorkchatLivePresentation.stepTime(_ seconds: TimeInterval) -> String` (`< 1` → `"<1s"`); `WorkchatLivePresentation.StepsSlot.earlierLine: String?` (`"35 earlier steps"`); `WorkchatActivityPresenter.label(forTool: String, summary: String) -> String`; `SessionChatPresentation.loadingText = "Reading the session…"`.

- [ ] **Step 1: Failing tests**
  - `testStepsClosedByDefault`: `WorkchatPaneMemory().stepsOpen("p") == false`; after `toggle` → `true`.
  - `testCollapsedRowShowsRunningStep`: snapshot with a running step "Run full Go test suite for #2188 gate" started 214 s ago → `row.stepSummary == that`, `row.stepElapsed == "3:34"`, `row.chevron == "chevron.right"`.
  - `testSubSecondStep`: `stepTime(0.4) == "<1s"`, `stepTime(41) == "0:41"`.
  - `testEarlierLine`: 41 steps with 6 shown → `earlierLine == "35 earlier steps"`; ≤ 6 → `nil`.
  - `testToolLabels`: `label(forTool: "SendMessage", summary: "Codex verify round 3") == "Message to Codex verify round 3"`; `"mcp__watchtower-workbench__update_target"` with empty summary → `"update target"`; `TodoWrite` → `"Update the task list"`; `TaskOutput` → `"Read a background task's output"`.
  - `testLoadingText`: `SessionChatPresentation.loadingText == "Reading the session…"`.
- [ ] **Step 2:** `make test-swift FILTER='WorkchatPaneMemoryTests|WorkchatStepsPresentationTests|WorkchatActivityPresenterTests'` → FAIL.
- [ ] **Step 3:** Implement the interfaces above. Views: `WorkchatStepsList` drops `.background(Fill.card…)`, adds a leading 1 pt rule in `.quaternary`, finished rows `.tertiary`, running row `.primary` with `ProgressView().controlSize(.mini)` in the symbol slot, `earlierLine` on top in `.tertiary`. The collapsed live line shows spinner + `stepSummary` (middle truncation) + `stepElapsed`. `errorBar`: no fill; `exclamationmark.triangle` in `Tone` warning, text `.secondary`, Retry as `KitQuietButtonStyle`. Loading: small spinner + `loadingText` in `.tertiary`.
- [ ] **Step 4:** same command → PASS; `make test-swift FILTER=SessionChatViewTests` PASS; swiftlint on touched files clean.
- [ ] **Step 5:** `make desktop-shots DESKTOP_SHOTS=<scratch>` filtered to the workchat shots; compare with mock 01–03, 10–12; fix drift.
- [ ] **Step 6: Commit** `feat(workchat): quiet turn steps and quiet error state (#2201)`.

### Task 2: Agent-text highlighting

Depends on: none

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerDesign/SyntaxTint.swift`; Modify: `WatchtowerKit/Tests/WatchtowerDesignTests/TokenTests.swift`; `docs/design/desktop-style-guide.md` (token table line)
- Create: `WatchtowerChatText/Sources/WatchtowerChatText/AgentTextHighlights.swift`; Test: `WatchtowerChatText/Tests/WatchtowerChatTextTests/AgentTextHighlightsTests.swift`
- Modify: `WatchtowerChat/Sources/ChatUI/Feed/ChatFeedView.swift` (`ChatFeedContext.highlightsAgentText`, `ChatPartActions.openHighlight`), the assistant text renderer that consumes `MarkdownRunBuilder` runs
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/SessionChatRow.swift` (`WorkchatFeed.context()` sets the flag and the action)
- Test: `WatchtowerChat/Tests/ChatUITests/…HighlightTests.swift`, `WatchtowerDesktop/Tests/SessionChatViewTests.swift`

**Interfaces:**
- Produces: `public enum SyntaxTint { static let opacity = 0.7; static let ref, hash, path, command: Color }` (accent, `.purple`, `.orange`, `.green`, each `.opacity(opacity)`).
- Produces: `public enum AgentTextHighlights { public enum Kind: Sendable, Equatable { case ref(Int), hash, path, command }; public struct Span: Equatable, Sendable { let range: Range<String.Index>; let kind: Kind; let text: String }; public static func spans(inPlain text: String) -> [Span]; public static func commandSpan(inCode code: String) -> Span? }` — `path` spans are candidates; resolution happens in the app.
- Produces: `ChatFeedContext.highlightsAgentText: Bool = false`; `ChatPartActions.openHighlight: ((AgentTextHighlights.Span) -> Void)?`; `ChatPartActions.resolvesPath: ((String) -> Bool)?`.

- [ ] **Step 1: Failing scanner tests** (table-driven, `make chattext-test`):
  - `"Round 3 of #2188 is ready"` → one `.ref(2188)` on `#2188`.
  - `"see https://x.example.com/#123"` and `"# 12 heading"` → no ref.
  - `"(67a59755a)"` → `.hash`; `"deadbeef"` (no digit) and `"12345678"` (no letter) → none; a 41-char hex → none.
  - `"file CloudKitTransport+LinkDirect.swift is noise"` and `"internal/sessionhost/prompt_state.go"` → `.path`; `"e.g."`, `"v0.29.3"` → none.
  - `commandSpan(inCode: "make test-swift")` → `.command`; `"foo bar"` → nil; allow-list: `make go swift git gh xcodebuild npm` and `./scripts/`.
- [ ] **Step 2:** `TokenTests`: `SyntaxTint.opacity == 0.7` → FAIL first.
- [ ] **Step 3:** Implement scanner (regexes from spec §2) and token. Renderer: when `highlightsAgentText` and the message is the assistant's, foreground-colour the span ranges in plain-text runs (skip code blocks and link runs; inline code only via `commandSpan`); a `path` span is coloured only if `resolvesPath?(text) == true`; spans are clickable via `openHighlight`; underline on hover only. No background, no weight.
- [ ] **Step 4:** Desktop wiring in `WorkchatFeed.context()`: flag on; `.ref(n)` → `WorkbenchesViewModel.showTargetOnBoard(Int64(n), projectID:)`; `.hash` → pasteboard copy (existing copy closure + "Copied" toast); `.path` → `openFile(_:root:preview: true)`; `resolvesPath` checks the session folders' `CodeRoot` with a per-message cache. `SessionChatViewTests`: flag is set in the Workchat context; the AI chat's context leaves it `false`.
- [ ] **Step 5:** Also colour `#N` in the agent-finished title (C8) — expose `AgentTextHighlights.spans` for T4's title (no extra code here beyond the public API).
- [ ] **Step 6:** `make chattext-test`, `make kit-test FILTER=TokenTests`, `make test-swift FILTER='SessionChatViewTests|HighlightTests'` → PASS; shot vs mock 04 in light and dark.
- [ ] **Step 7: Commit** `feat(workchat): IDE-style highlighting in the agent's text (#2201)`.

### Task 3: Task notifications parsed into a `task` object (Go)

Depends on: none

**Files:**
- Modify: `internal/sessionfeed/entry.go` (`TaskRef`, `Entry.Task`), `internal/sessionfeed/parse.go` (`noticeEntry`), `internal/sessionfeed/feed.go` or the CLI join (handback fill)
- Modify: `cmd/workbench_session_feed.go` only if the handback join lives there
- Test: `internal/sessionfeed/parse_test.go`, `internal/sessionfeed/feed_test.go`, `cmd/workbench_session_feed_test.go` (`TestSessionFeedJSON_PinnedKeys`)
- Modify: `docs/inventory/session-feed.md` (FEED-03 text + change-log line "2026-11-24, ask #1757"), `docs/features/session-chat-feed.md` (entry kinds), `docs/features/README.md` summary

**Interfaces:**
- Produces JSON `entries[].task` (omitted when not a task notification): `{"task_id","tool_use_id","status","summary","result","output_file","tokens","tool_uses","duration_ms","kind","exit_code"}` — numbers as ints, `kind` `"agent"|"command"`, `exit_code` omitted when absent, `result` `""` for the boilerplate.
- Go: `type TaskRef struct { TaskID string; ToolUseID string; Status string; Summary string; Result string; OutputFile string; Tokens int; ToolUses int; DurationMS int; Kind string; ExitCode *int }` with the json tags above (`omitempty` on `exit_code`).

- [ ] **Step 1: Failing tests** in `parse_test.go`:
  - `TestNoticeTask_Fields`: a notification with `<task-id>aaea…</task-id><tool-use-id>toolu_01…</tool-use-id><output-file>/tmp/x.output</output-file><status>completed</status><summary>Agent "Claude verify review #2188" finished</summary><note>…</note><result>This agent's report was delivered to you as a message from "aaea…" …</result><usage><subagent_tokens>43545</subagent_tokens><tool_uses>9</tool_uses><duration_ms>88925</duration_ms></usage>` → `Task.Kind=="agent"`, `Tokens==43545`, `ToolUses==9`, `DurationMS==88925`, `Status=="completed"`, `Result==""`, `Title` and `Text` unchanged from today.
  - `TestNoticeTask_Command`: summary `Background command "Run full Go test suite" completed (exit code 0)` → `Kind=="command"`, `*ExitCode==0`.
  - `TestNoticeTask_NoUsage`: no `<usage>` → `Tokens==0`, entry still has `Task` with status and summary.
  - `TestNoticeTask_Truncated`: unclosed tags → `Task == nil`, entry as today.
- [ ] **Step 2:** `go test ./internal/sessionfeed -run TestNoticeTask` → FAIL.
- [ ] **Step 3:** Parse the children already matched by `taskChildRe`; parse `<usage>` with the same regex on its inner text; the boilerplate is a result starting with `This agent's report was delivered to you as a message` (curly or straight apostrophe).
- [ ] **Step 4: Handback fill.** `TestBuild_TaskResultFromHandback` (feed_test): a task entry with empty `Result` and a subagent whose `ToolUseID` matches and has `ParentReport` → `Result` = the report's first paragraph (up to the first blank line, ≤ 600 runes).
- [ ] **Step 5:** `TestSessionFeedJSON_PinnedKeys` asserts `task` appears on a task event with exactly the keys above, and is absent on other entries. `go test ./internal/sessionfeed ./cmd -run 'TestNoticeTask|TestBuild_TaskResult|TestSessionFeedJSON_PinnedKeys|TestSessionFeed_Codex'` → PASS.
- [ ] **Step 6:** Inventory/feature-note edits (additive wording, no guard relaxed).
- [ ] **Step 7: Commit** `feat(sessionfeed): structured task notifications (#2201)`.

### Task 4: Agent-finished row (Swift)

Depends on: Task 3 (JSON shape), Task 2 (`AgentTextHighlights.spans`, `SyntaxTint` for the title ref)

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionFeed.swift` (`SessionFeedTask`, `SessionFeedEntry.task`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/AgentFinishedPresentation.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/SessionChatRow.swift` (`eventLine` → `AgentFinishedRow` when `task != nil`)
- Test: `WatchtowerDesktop/Tests/Core/AgentFinishedPresentationTests.swift`, `WatchtowerDesktop/Tests/Core/SessionFeedDecodingTests.swift` (or the existing decode test file)

**Interfaces:**
- Consumes: T3's JSON.
- Produces: `package struct SessionFeedTask: Decodable, Equatable, Sendable` (camel-cased fields of T3, `exitCode: Int?`); `package struct AgentFinishedPresentation { let title: String; let meta: String; let tone: Tone; let glyph: String; let isCommand: Bool; let result: String?; let details: String; init(task: SessionFeedTask, fallbackTitle: String) }`.

- [ ] **Step 1: Failing tests:**
  - agent completed, 9 tools, 43545 tokens, 88925 ms → `title == "Claude verify review #2188"` (the summary's quoted name), `meta == "finished · 9 tools · 43.5k tokens · 1m 29s"`, glyph `checkmark`, tone success.
  - status `failed`, 2 tools, 1200 tokens, 12000 ms → `meta == "failed · 2 tools · 1.2k tokens · 12s"`, glyph `xmark`, tone failure.
  - command exit 0, 214000 ms → `title == "Background command · Run full Go test suite"`, `meta == "exit 0 · 3m 34s"`, `isCommand`.
  - no usage → `meta == "finished"`.
  - `result == ""` → `result == nil` (the row shows no Result block); `details == "task aaea… · toolu_01…"` (ids cut to 12 chars + "…").
  - decode: an entry without `task` decodes with `task == nil`.
- [ ] **Step 2:** `make test-swift FILTER='AgentFinishedPresentationTests|SessionFeed'` → FAIL.
- [ ] **Step 3:** Implement; row per mock 05: glyph tinted by `Tone`, title `.callout` `.secondary` (refs coloured via `SyntaxTint.ref`), meta `.caption2` `.tertiary`, chevron; expanded: leading rule, "RESULT" label, result text, text buttons Open output (code viewer read-only when under the session temp dir, else `NSWorkspace.activateFileViewerSelecting`) and Details (toggles the ids line). Command rows caption-size. Teammate events unchanged.
- [ ] **Step 4:** tests PASS; shot vs mock 05 light/dark.
- [ ] **Step 5: Commit** `feat(workchat): quiet agent-finished row (#2201)`.

### Task 5: Clipboard paste of screenshots and Finder files

Depends on: none

**Files:**
- Modify: `WatchtowerChat/Sources/ChatUI/Platform/macOS/PastingTextView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkchatComposer.swift` (paperclip menu item), the composer's attach menu in `WatchtowerChat/Sources/ChatUI/Composer/ChatComposerField.swift` if the menu lives there
- Test: `WatchtowerDesktop/Tests/PastingTextViewTests.swift`, `WatchtowerDesktop/Tests/WorkchatComposerTests.swift`
- Modify: spec §4 (record the Finder-file cause found in Step 1)

**Interfaces:**
- Produces: `PastingTextView.readablePasteboardTypes` override; `validateUserInterfaceItem(_:)` override for `#selector(NSText.paste(_:))`; `ComposerPasteMenu.title(for action: PasteAction?, fileCount: Int) -> String?` (`"Paste screenshot"`, `"Paste 1 file"`/`"Paste N files"`, `"Paste text"`, `nil` → disabled).

- [ ] **Step 1: Reproduce through the menu path.** New tests put content on a private named pasteboard, make the view first responder in an offscreen window, and call `validateUserInterfaceItem` with a paste menu item, then `NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)`:
  - `testScreenshotPasteIsEnabledAndAttaches` (PNG only) → validate `true`; `onInlinePaste` gets `.image`. Expected today: validate `false` (the confirmed cause).
  - `testFinderFilePasteAttaches` (a `public.file-url` + filename string, as Finder writes) → `onAttachFiles` gets the URL. Record the observed failure and its cause in spec §4.
  - `testNoPasteDataKeepsStockValidation`: without `onPasteData`, a PNG-only pasteboard validates `false`.
- [ ] **Step 2:** `make test-swift FILTER=PastingTextViewTests` → the first two FAIL.
- [ ] **Step 3:** Add image types (`public.png`, `public.tiff`, `public.jpeg`, `public.heic`), `public.file-url` and `com.adobe.pdf` to `readablePasteboardTypes` when `onPasteData != nil`; enable paste in `validateUserInterfaceItem` when the pasteboard holds one of them; fix the Finder-file cause found in Step 1. The private pasteboard property (`pasteboard`) is used in validation too.
- [ ] **Step 4:** Paperclip menu "Paste …" item from `ComposerPasteMenu.title`, computed when the menu opens (user action), disabled on `nil`; `WorkchatComposerTests` cover the four titles.
- [ ] **Step 5:** tests PASS; shot vs mock 06–07.
- [ ] **Step 6: Commit** `fix(chat): ⌘V takes screenshots and Finder files in the composer (#2201)`.

### Task 6: Draft length model in the host and its mirrors

Depends on: none

**Files:**
- Create: `internal/sessionhost/testdata/draft_cases.json`
- Modify: `internal/sessionhost/prompt.go` (`promptState`), `internal/sessionhost/session.go` (re-try held lines on change)
- Modify: `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (`ownerInput`, `promptDrafts` → `drafts: [Int64: DraftModel]`, `promptHoldsText`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/DraftModel.swift` (new, pure)
- Modify: `WatchtowerDesktop/Tests/FakeHostDelivery.swift` (boolean `draft` → `DraftModel`)
- Modify: `WatchtowerDesktop/Sources/Services/SessionLineDelivery.swift` (re-check held lines on draft change)
- Test: `internal/sessionhost/prompt_state_test.go`, `WatchtowerDesktop/Tests/Core/DraftModelFixtureTests.swift`, `WatchtowerDesktop/Tests/SessionLineDeliveryTests.swift`, the PROJ-23 guard file in `internal/sessionmsg/delivery`
- Modify: `docs/inventory/workbench.md` (PROJ-16/23 wording: the draft model; change-log line, ask #1757)

**Interfaces:**
- Produces Go: `type draftModel struct{ count int; exact bool }`, `func (d *draftModel) feed(b []byte, prof Profile, dialog bool)`, `func (d draftModel) holdsText() bool` (`count > 0 || !exact`), `func (d *draftModel) clearedByApp()` (`{0,true}`); `promptState` embeds it; `holdsText()` keeps its name and callers.
- Produces Swift: `package struct DraftModel: Equatable, Sendable { var count = 0; var exact = true; mutating func feed(_ bytes: [UInt8], profile: TerminalInputProfile, dialog: Bool); var holdsText: Bool; mutating func clearedByApp() }`; `TerminalCenter.draftChanged: AsyncStream<Int64>` (session id) or an `@Observable` counter the line delivery observes.
- Fixture rows: `{"name","profile","keys":[base64 or escaped bytes…],"dialog":false,"expect":{"count":N,"exact":B,"holds":B}}`.

- [ ] **Step 1: Write `draft_cases.json`** with at least: `type-abc` (3,exact,holds); `type-then-backspace-all` (0,exact,free); `backspace-on-empty` (0,exact,free); `ctrl-u-single-line` (0,exact,free); `ctrl-u-multi-line` (exact=false,holds); `left-then-backspace-all` (exact=false,holds); `option-backspace` (exact=false,holds); `esc` (exact=false,holds); `submit-return` (0,exact,free); `shift-tab` (unchanged); `bracketed-paste-5-runes` (5); `utf8-cyrillic-3-runes` (3); `ctrl-c-idle-nonempty` (0,exact,free); `dialog-y` with dialog=true (unchanged); `codex-profile-any-key` (exact=false).
- [ ] **Step 2:** Go `TestDraftFixture` and Swift `DraftModelFixtureTests` read the file (Swift path as in `TerminalPasteFixtureTests`) → FAIL.
- [ ] **Step 3:** Implement both from the table (spec §6.1). A delivery's own paste and `left_typed` set `exact = false` (as the old flag's set). Fake `FakeHostDelivery` uses `DraftModel`.
- [ ] **Step 4: Re-check on change.** Go: when `holdsText` flips to false, the host re-tries its held `hold_if_prompt_text` deliveries (phone lines, agent messages). Swift: `SessionLineDelivery` re-runs `lineCheck`/`workchatLineCheck` for lines held with `.promptHasText` on `draftChanged`. Tests: `TestPromptState_ReleaseRetriesHeld` (Go, fake deliverer), `SessionLineDeliveryTests.testHeldAnswerGoesWhenDraftErased`.
- [ ] **Step 5: Guards.** Run `go test ./internal/sessionhost ./internal/sessionmsg/... ./internal/sessionline` (PROJ-23 guards must stay green unchanged) and add `TestProj23_ErasedDraftReleases`. `make test-swift FILTER='SessionControlTests|SessionLineDeliveryTests|ComposerDeliverTests|OwnerAsksViewModelTests|DraftModelFixtureTests'` → PASS.
- [ ] **Step 6:** Inventory wording edit (no guard relaxed: unknown still holds).
- [ ] **Step 7: Commit** `fix(workbench): erased terminal draft no longer holds lines (#2201)`.

### Task 7: Hold captions and actions

Depends on: Task 6

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatOutgoing.swift` (`State.queued(reason:)` or a `holdReason` field; captions)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkchatModel.swift` (`clearAndSend(_:)`, `sendTogether(_:)`), `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (`sendClear(sessionID:) -> Bool`, Ctrl+C `0x03`, 3 s guard), `WatchtowerDesktop/Sources/Views/Workbench/WorkchatComposer.swift` (`WorkchatOutgoingBubble` actions)
- Test: `WatchtowerDesktop/Tests/Core/WorkchatOutgoingTests.swift`, `WatchtowerDesktop/Tests/WorkchatModelTests.swift`
- Modify: `docs/guide/features/workbench/sessions.md` (Workchat: held lines, Clear and send, paste), `docs/features/session-chat-feed.md`

**Interfaces:**
- Consumes: `SessionControl.LineHold`, `DraftModel.clearedByApp()` via `TerminalCenter`.
- Produces: `WorkchatOutgoing.holdReason: SessionControl.LineHold?`; `WorkchatOutgoing.caption(state:working:holdsUntilIdle:sentWhileBusy:holdReason:)`; `WorkchatModel.canClearAndSend(_ id: UUID) -> Bool`; `TerminalCenter.promptPreview(sessionID:) -> String?` (last prompt line from the terminal buffer, display only).

- [ ] **Step 1: Failing tests** (`WorkchatOutgoingTests`): `.needsApproval` → `"Waiting: answer the permission prompt in the terminal"`; `.agentBusy` → `"Queued · sends in a moment"`; `.promptHasText` → `"Waiting: the terminal prompt holds text"`.
- [ ] **Step 2: Failing tests** (`WorkchatModelTests`, fake control + fake clock):
  - `testClearAndSendIdle`: held `.promptHasText`, idle → exactly one `0x03` sent, draft `clearedByApp`, then the line delivered after the redraw signal.
  - `testClearAndSendRefusedWhenWorking`: status flips to Working before the click → no `0x03`, line stays held, `canClearAndSend == false`.
  - `testClearAndSendOncePerLine`: second call for the same line → no-op.
  - `testNoSecondCtrlCWithin3s`: two held lines, two clicks 1 s apart (fake clock) → one `0x03`; at 3.1 s → allowed.
  - `testClearAndSendGivesUpAfter1s`: no redraw within 1 s (fake clock) → line held, caption unchanged.
  - `testSendTogether`: uses the beside-text delivery (`sharedPrompts`), one Return.
  - `testHeldThenSessionGone`: → `.notSent`, text back in the field.
- [ ] **Step 3:** `make test-swift FILTER='WorkchatOutgoingTests|WorkchatModelTests'` → FAIL; implement; → PASS.
- [ ] **Step 4:** Bubble per mock 08/09: grey caption, prompt preview in monospace `.secondary`, text buttons (`KitQuietButtonStyle`); Clear hidden while working.
- [ ] **Step 5:** Guide page edit (follow `docs/guide/WRITING.md`); `go test ./docs/guide`.
- [ ] **Step 6: Commit** `feat(workchat): say why a line waits, Clear and send (#2201)`.

### Task 8: Snapshots against the mock, docs summary

Depends on: Tasks 1–7

**Files:**
- Modify: `WatchtowerDesktop/Tests/DesignShots/` (real-view shots for the 12 states beside the mock ones)
- Modify: `docs/features/README.md` (one-paragraph summary update), `CLAUDE.md` only if a new feature note was added (none planned)

- [ ] **Step 1:** Add real-view `DesignShot`s for states 01–12 (`workchat-polish-real-NN`), render light/dark, compare each to its mock PNG; list differences; fix the view or, where the mock was wrong, note it in the spec's Mockups section.
- [ ] **Step 2:** Update `docs/features/README.md` session-chat-feed summary with: steps collapsed, `SyntaxTint`/`AgentTextHighlights`, `task` object, paste types, `DraftModel`.
- [ ] **Step 3: Commit** `docs(workchat): polish shots and summary (#2201)`.
