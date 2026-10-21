# Workchat polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Terminal/Workchat toggle, asks that open in the session's current mode, a live action line while the agent works, Workchat lines that go while the agent works, and ⌘V of images and files in the Workchat composer.

**Architecture:** Go `internal/sessionfeed` gains (a) owner entries from Claude Code's `queued_command` attachments (lines taken mid-turn) and (b) an `Activity` read from the transcript tail, emitted as a new top-level `activity` key by `workbench session-feed --json`. The Desktop decodes it into `SessionFeedStore.activity`, and a pure Core presenter turns it into the live line. The Workchat composer gets a busy-tolerant gate (`SessionControl.workchatLineCheck`), reuses `ChatComposerField`'s existing paste/attachment routing, and keeps pasted images in `<workspace>/workchat-attachments/<session id>/`.

**Tech Stack:** Go 1.26 (testify), SwiftUI + XCTest (`WatchtowerCore`, `WatchtowerDesktop`).

**Spec:** `docs/superpowers/specs/2026-10-21-workchat-polish-design.md` (approved in ask #482; decisions in ask #481).

## Global Constraints

- FEED-01 (no transcript text stored), FEED-02 (dialog only: the live line is never an entry), FEED-05 (the phone's `session_chat` payload ignores `activity`) hold. FEED-03 gains exactly one additive top-level key, `activity` (object or `null`).
- The cursor format (`<agent session id>:<offset>`) does not change.
- PROJ-16 is the phone's gate and stays unchanged: `SessionControl.lineCheck` keeps its `.agentBusy` hold. Only the Mac Workchat uses the new gate.
- The Workchat gate keeps the `needsApproval`, `promptHasText`, `sessionGone` holds and the `justSubmitted` settle.
- English UI copy, design-kit components, `docs/review/review-rules.md` Swift conventions, swiftlint clean (`make lint-swift`; `make lint-diff` is Go-only).
- Pasted files: `<workspace>/workchat-attachments/<session id>/<yyyyMMdd-HHmmss>-<n>.<ext>`, where `<workspace>` is the directory of the open `watchtower.db` (as `DBLockMetrics` resolves it). At launch, delete files older than 7 days, except in the folders of sessions that are live.
- Inner loop only per task (`go test ./internal/sessionfeed`, `go test ./cmd -run TestSessionFeed`, `make test-swift FILTER=…`). The full gate runs once before the PR.

## Review Focus

1. **An empty tail poll while a tool runs.** `--after C` with no new bytes must still return the open tool's `activity`, or the line blinks off every 3 s. Pinned in Task 2 (`TestActivity_EmptyTailKeepsOpenTool`).
2. **Ask answers delivered mid-turn.** "Ask #N answered…" typed while the agent works now arrives as a `queued_command`. It must become an `ask_answer` entry, not an owner bubble. Pinned in Task 1 (`TestParse_QueuedAskAnswerIsAskAnswer`).
3. **Two lines sent quickly while busy.** Each line must go exactly once, in order, and never share one prompt. Pinned in Task 5 (`testTwoLinesWhileBusyGoInOrder`).
4. **A pasted screenshot echoed as `[Image #1]`.** The bubble must still find its echo. Pinned in Task 7 (`testMatchesIgnoresImageMarkersAndPaths`).
5. **Esc or a stop while a tool is open.** The transcript still shows the tool open, but the line must hide because the session is not working. Pinned in Task 6 (`testHiddenWhenNotWorkingEvenWithOpenTool`).

---

### Task 1: Owner lines taken mid-turn (`queued_command`)

**Depends on:** none

**Files:**
- Modify: `internal/sessionfeed/parse.go` (`handle`, the `"attachment"` case)
- Test: `internal/sessionfeed/parse_test.go`

Real record shape (from live transcripts; no other record is written for such a line):
`{"type":"attachment","uuid":"…","timestamp":"…","attachment":{"type":"queued_command","commandMode":"prompt","origin":{"kind":"human"},"humanTurn":true,"prompt":"<string or content blocks>","imagePasteIds":[2]}}`
Lines from other origins (`task-notification`, `peer`, `coordinator`) and any `isMeta: true` attachment are not owner lines.

- [ ] **Step 1: Write the failing tests** in `parse_test.go`:
  - `TestParse_QueuedHumanPromptIsOwner`: a `queued_command` with `commandMode:"prompt"`, `origin.kind:"human"`, `prompt:"run the tests"` → one entry `{ID: rec.uuid, Kind: KindOwner, Text: "run the tests"}`, `At` = record timestamp.
  - `TestParse_QueuedPromptWithoutOriginIsOwner`: same with no `origin` key → owner (older Claude Code).
  - `TestParse_QueuedPromptBlocksWithImage`: `prompt:[{"type":"text","text":"look"},{"type":"image",…}]` → text `"look\n[image]"` (whatever `userText` already renders for the same content in a `user` record).
  - `TestParse_QueuedAskAnswerIsAskAnswer`: prompt `"Ask #9 answered (Q: A) — read it with get_ask 9 using the skill."` → `KindAskAnswer`, `AskID 9`.
  - `TestParse_QueuedNonHumanIgnored`: `commandMode:"task-notification"`; `origin.kind:"peer"` with `isMeta:true`; `origin.kind:"coordinator"` → no entries, nothing in `Unknown`.
  - `TestParse_QueuedSidechainIgnoredInMain`: `isSidechain:true` in a main read → no entry.

- [ ] **Step 2:** `go test ./internal/sessionfeed -run TestParse_Queued`. Expected: FAIL.

- [ ] **Step 3: Implement** in the `"attachment"` case. Before `briefText`, call a new `queuedOwnerEntry(rec record) (Entry, bool)`. It decodes `attachment.{type, commandMode, origin.kind, isMeta, prompt}`, requires type `queued_command`, mode `prompt`, origin absent or `"human"`, `!isMeta`, `rec.IsSidechain == st.sidechain`. It then runs `prompt` through the same `userText` → `classifyUserText(rec.UUID, text)` path a `user` record takes. Append with `At`/`Conversation` set as `handleUser` does.

- [ ] **Step 4:** `go test ./internal/sessionfeed`. Expected: PASS (existing tests too).

- [ ] **Step 5: Commit** `feat(sessionfeed): owner lines Claude Code took mid-turn (queued_command)`.

### Task 2: The `activity` value (Go)

**Depends on:** none (parallel with Task 1; both touch `internal/sessionfeed`, so one lane)

**Files:**
- Create: `internal/sessionfeed/activity.go`, `internal/sessionfeed/activity_test.go`
- Modify: `cmd/workbench_session_feed.go` (`sessionFeedJSON`, `buildSessionFeedOutput`), `cmd/workbench_session_feed_test.go`
- Modify: `docs/inventory/session-feed.md` (FEED-03 lists `activity`; changelog line "2026-10-21 (board #846, owner approval ask #482): FEED-03 gains `activity`")

**Interfaces:**
- Produces:
  ```go
  type Activity struct {
      Tool      string    `json:"tool"`       // as recorded, e.g. "Bash", "mcp__watchtower-workbench__ask_owner"
      Summary   string    `json:"summary"`    // ≤ 120 runes
      StartedAt time.Time `json:"started_at"` // the tool_use record's timestamp
      More      int       `json:"more"`       // other open calls besides this one
  }
  // ActivityOf reads at most activityWindow (256 KiB) before EOF of path and
  // returns the newest open call of the main (non-sidechain unless sidechain) conversation, or nil.
  func ActivityOf(path string, codex, sidechain bool) (*Activity, error)
  ```
  JSON: top-level `"activity": {"tool","summary","started_at","more"}` or `"activity": null`.

Rules: an open call is a `tool_use` block of an `assistant` record whose id has no `tool_result` (in any later `user` record) inside the window. Of the open calls, the newest is the one shown. `More` = open calls − 1. Exception: when every open call is `Read`, Summary = `"N files"` (N ≥ 2) and More = 0. Summary table (spec §3): Bash → `input.description` else the first line of `input.command`. Edit/Write/MultiEdit/NotebookEdit/Read → basename of `file_path`/`notebook_path`. Grep/Glob → `pattern`. Agent/Task → `description`. WebFetch → URL host. WebSearch → `query`. `mcp__<server>__<tool>` → `<tool> · <server>`. Anything else → the tool name. Text is trimmed and cut to 120 runes with `…`. The window skips a first partial line. Codex: open `function_call` (payload `type:"function_call"`, `name`, `arguments`, `call_id`) without a `function_call_output` for its `call_id` → Tool = name, Summary = the first line of `arguments.command` joined when it is an array, else name. Should Codex records not match this shape in a fixture made from a live Codex transcript, return nil for Codex and note it in Task 8.

- [ ] **Step 1: Write the failing tests** in `activity_test.go` (helpers write a temp JSONL):
  - `TestActivity_OpenBash`: tool_use Bash `{command:"go test ./internal/db\n-v", description:""}` with no result → `{Tool:"Bash", Summary:"go test ./internal/db", More:0}`, StartedAt = record ts.
  - `TestActivity_BashDescriptionWins`: description "Run db tests" → Summary "Run db tests".
  - `TestActivity_ClosedIsNil`: the tool_use followed by a user record with its tool_result → nil.
  - `TestActivity_ThreeReads`: three open Reads in one message → Summary "3 files", More 0.
  - `TestActivity_NewestOfMixed`: open Bash then open Edit `/a/b/WorkchatModel.swift` → Tool "Edit", Summary "WorkchatModel.swift", More 1.
  - `TestActivity_AgentAndMCP`: Agent description "look around" → "look around"; `mcp__watchtower-workbench__ask_owner` → "ask_owner · watchtower-workbench".
  - `TestActivity_SidechainIgnored`: an open call in an `isSidechain:true` record → nil for a main read.
  - `TestActivity_Clipped`: 300-rune command → 120 runes ending in "…".
  - `TestActivity_WindowSkipsPartialLine`: file larger than the window → no error, the open call near EOF found.
  - `TestActivity_CodexOpenCall` (fixture under `testdata/`).
- [ ] **Step 2: Add CLI tests** in `cmd/workbench_session_feed_test.go`:
  - Extend `TestSessionFeedJSON_PinnedKeys`: the expected top-level keys become `{"activity","cursor","entries","session_id","skipped","subagents","unknown_records"}`, and `got["activity"]` is nil for that closed transcript.
  - `TestSessionFeed_ActivityOpenTool`: a transcript ending in an open Bash → `activity` keys `{"more","started_at","summary","tool"}`.
  - `TestActivity_EmptyTailKeepsOpenTool`: first call gets the cursor. A second call with `--after <cursor>` and no new bytes → `entries` empty, `activity` still the open Bash.
  - `TestSessionFeed_SubagentActivity`: `--subagent T` whose subagent file ends in an open Read → `activity.tool == "Read"`.
- [ ] **Step 3:** `go test ./internal/sessionfeed -run TestActivity && go test ./cmd -run 'TestSessionFeed|TestActivity'`. Expected: FAIL.
- [ ] **Step 4: Implement** `activity.go`. In `buildSessionFeedOutput`, set `Activity *sessionfeed.Activity `json:"activity"`` (no omitempty). For the tab: `ActivityOf(last conversation's Path, Codex, false)`. Use the last `convs` entry, whatever the cursor. For `--subagent`: the subagent file (`findSubagent` already resolves `agent-<id>.jsonl`; return its path alongside) with `sidechain=true`. A read error leaves `activity` nil (logged to stderr, never fails the command).
- [ ] **Step 5:** run Step 3's commands. Expected: PASS.
- [ ] **Step 6:** update `docs/inventory/session-feed.md` FEED-03, then commit `feat(sessionfeed): activity — the agent's open tool call, read at request time`.

### Task 3: One Terminal/Workchat toggle

**Depends on:** none

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionStrip.swift` (replace the two `modeToggle` calls and the function)
- Test: `WatchtowerDesktop/Tests/WorkbenchSessionStripTests.swift`

**Interfaces:**
- Produces (static, testable): `WorkbenchSessionStrip.modeButton(pane: WorkspacePane, sessionID: Int64, layout: WorkspaceLayout) -> (label: String, target: WorkspacePane)`
  - pane `.session(id)` → `("Workchat", .sessionChat(id))`
  - pane `.sessionChat(id)` → `("Terminal", .session(id))`
  - any other pane (report, changes) → the session's remembered mode: `layout.pane(forSession: id)`, labelled "Terminal" or "Workchat" accordingly.

- [ ] **Step 1: Write the failing tests** `testModeButtonOnTerminalNamesWorkchat`, `testModeButtonOnWorkchatNamesTerminal`, `testModeButtonOverReportUsesRememberedMode` (layout with `workchatSessions = [id]` → "Workchat", `.sessionChat(id)`).
- [ ] **Step 2:** `make test-swift FILTER=WorkbenchSessionStripTests`. Expected: FAIL.
- [ ] **Step 3: Implement** one plain strip button (`Button` + `Label(label, systemImage: target.isWorkchat ? WorkspaceView.chat.icon : WorkspaceView.terminal.icon)`, styled like Report: `segmentStyle` / `.segmentCapsule()`). Its action is today's `set` branch: `toggleMode` when this pane is the session's, else `showSession(…, workchat: target.isWorkchat, inPane: pane, …)`. Help: "Show this session's \(label == "Workchat" ? "Workchat" : "terminal") in this pane (⌃`)". It is disabled when `target` is already visible in the other pane (today's `shownElsewhere`).
- [ ] **Step 4:** run the filter. PASS. `make lint-swift`.
- [ ] **Step 5: Commit** `feat(workbench): one Terminal/Workchat toggle on the session strip`.

### Task 4: Asks open the session in its current mode

**Depends on:** none

**Files:**
- Modify: the path the failing test exposes. Suspects: `WorkbenchesViewModel+Sessions.swift` `activate`/`placing(_:_:in:)` for `.show` (a live session's `open(subject, placement: .show)` from `revealTerminal(projectID:sessionID:ticket:)`), and `WorkbenchesViewModel+Panel.swift` `revealTerminal(_:keeping:in:)`'s `setMode(false…)`.
- Test: `WatchtowerDesktop/Tests/WorkbenchesViewModelSessionsTests.swift` (or the file holding the existing `showAsk` tests: `grep -l showAsk Tests`)

- [ ] **Step 1: Write the failing tests:**
  - `testShowAskOfLiveWorkchatSessionShowsWorkchat`: session id live in `terminalCenter.liveIDs`, layout `workchatSessions = [id]`, another session on screen → `await vm.showAsk(askID, projectID:)` → `layout.visiblePanes.contains(.sessionChat(id))`, not `.session(id)`, and `asks.drawerAskIDs[projectID] == askID`.
  - `testShowAskOfStoppedWorkchatSessionShowsWorkchat`: the same with the session not live.
  - `testShowAskOfTerminalSessionShowsTerminal`: mode terminal → `.session(id)`.
  - `testRouteForAskKeepsWorkchat`: `vm.reveal(.forAsk(projectID:, sessionID: id, askID:))` (notification and Home path) → `.sessionChat(id)`.
- [ ] **Step 2:** run them. Expected: at least the live case FAILS. Note which.
- [ ] **Step 3: Fix** the failing path so that placing a session for `.show` uses `layout.pane(forSession: id)`. Only a fresh session (`fresh == true`, already handled) and the explicit Terminal actions force the terminal. Do not change `revealTerminal(_:keeping:in:)` for the Terminal toolbar action; it is an explicit Terminal.
- [ ] **Step 4:** run them + `make test-swift FILTER='WorkbenchesViewModelSessionsTests|WorkbenchesViewModelPlacementTests|OwnerAsksViewModelTests'`. PASS.
- [ ] **Step 5: Commit** `fix(workbench): an ask opens its session in the mode it was last shown in`.

### Task 5: Workchat lines go while the agent works

**Depends on:** Task 1 (the echo of a mid-turn line comes from it; tests here use fake entries, so it can run in parallel; merge after Task 1)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/SessionControl.swift`, `WatchtowerDesktop/Sources/ViewModels/WorkchatModel.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatOutgoing.swift`, `WatchtowerDesktop/Sources/Views/Workbench/WorkchatComposer.swift` (bubble caption), `WatchtowerDesktop/Sources/Views/Chat/ChatComposerField.swift` only if Return is blocked while `isStreaming` (check `onSend` gating)
- Test: `WatchtowerDesktop/Tests/SessionControlTests.swift`, `WatchtowerDesktop/Tests/WorkchatModelTests.swift`, `WatchtowerDesktop/Tests/Core/WorkchatOutgoingTests.swift`

**Interfaces:**
- Produces:
  - `SessionControl.workchatLineCheck(_ sessionID: Int64) -> LineCheck`: as `lineCheck`, minus the `isIdle` part of the busy hold. Keeps `needsApproval`, `justSubmitted` → `.hold(.agentBusy)`, `promptHoldsText` → `.hold(.promptHasText)`, missing status → `.sessionGone`. Codex sessions (`status.kind`/agent is Codex): only if the Codex verification (Step 0) shows Codex queues a Return during a turn; else Codex falls back to `lineCheck`.
  - `WorkchatControl` gains `func workchatLineCheck(_:) -> SessionControl.LineCheck` and `func isWorking(_ sessionID: Int64) -> Bool`.
  - `WorkchatOutgoing.sentWhileBusy: Bool` (default false), set in `settle` for `.submitted` when `control.isWorking(sessionID)`.
  - Echo rule: a `sentWhileBusy` line's echo may be dated any time from `deliveredAt - echoLead` on (no 90 s cap). Other lines are unchanged.

- [ ] **Step 0 (verification, no code):** in a scratch Codex session, type a line and press Return while Codex works, and see whether it is queued and later taken. Record the result in the commit message and in Task 8's note.
- [ ] **Step 1: Write the failing tests:**
  - SessionControlTests: `testWorkchatLineCheckGoesWhileWorking` (state `.working`, no prompt text → `.go`), `testWorkchatLineCheckHoldsOnApproval`, `testWorkchatLineCheckHoldsOnPromptText`, `testWorkchatLineCheckHoldsJustSubmitted`, `testPhoneLineCheckStillHoldsWhileWorking` (`lineCheck` → `.hold(.agentBusy)`; this is the PROJ-16 guard, unchanged).
  - WorkchatModelTests: `testSendWhileWorkingSubmitsAtOnce` (fake control `workchatLineCheck` → `.go`, `isWorking` true → bubble `.sent`, `sentWhileBusy == true`), `testTwoLinesWhileBusyGoInOrder` (two `send()` back to back → the fake delivery sees line 1 then line 2, each once, never concatenated), `testBusyLineEchoAfterTwoMinutesStillMatches` (owner entry dated `deliveredAt + 150 s` removes it), `testIdleLineEchoWindowUnchanged` (not busy, entry at +150 s → stays).
- [ ] **Step 2:** `make test-swift FILTER='SessionControlTests|WorkchatModelTests|WorkchatOutgoingTests'`. FAIL.
- [ ] **Step 3: Implement.** `WorkchatModel.send` uses `control?.workchatLineCheck($0)` in its gate. The composer's Return sends while working, and the round button stays Stop while working (Return = send, button = Stop). Bubble caption for `.sent && sentWhileBusy` while `working`: "Queued · the agent reads it at its next step". There is no Cancel on it. Cancel stays on `.queued` (held by our queue).
- [ ] **Step 4:** re-run the filter. PASS. `make lint-swift`.
- [ ] **Step 5: Commit** `feat(workchat): a line goes while the agent works, as in the terminal`.

### Task 6: The live action line (Swift)

**Depends on:** Task 2 (JSON shape)

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionFeed.swift` (`SessionFeedPayload.activity`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionFeedStore.swift` (`@Published activity`, set from every successful `refresh`, including an empty one; the subagent read returns it too)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionFeedActivity.swift` (decodable model), `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatActivityPresenter.swift` (pure), `WatchtowerDesktop/Sources/Views/Workbench/WorkchatActivityLine.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/SessionChatView.swift` (line between the feed and the composer; the subagent screen also shows its own)
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/SessionChatPayload.swift` only to confirm that `activity` is not carried (a test, no code, if it already builds from entries only)
- Test: `WatchtowerDesktop/Tests/Core/SessionFeedStoreTests.swift`, `WatchtowerDesktop/Tests/Core/WorkchatActivityPresenterTests.swift`, `WatchtowerDesktop/Tests/MobileHub/SessionChatPayloadTests.swift`

**Interfaces:**
- Consumes: Task 2 JSON `activity {tool, summary, started_at, more}` | null.
- Produces:
  ```swift
  package struct SessionFeedActivity: Decodable, Equatable, Sendable { tool, summary: String; startedAt: Date?; more: Int }
  package enum WorkchatActivityPresenter {
      package struct Line: Equatable { let symbol: String; let text: String; let since: Date? }
      /// nil = no line. `working`: SessionControl.isWorking; `background`: state kind .background;
      /// `stateAt`: the status stamp (Thinking… counts from it); `lastAgentAt`: newest agent entry's `at`.
      package static func line(activity: SessionFeedActivity?, working: Bool, background: Bool,
                               runningSubagents: Int, stateAt: Date?, lastAgentAt: Date?) -> Line?
  }
  ```
  Rules: `!working` → nil. activity present and (`lastAgentAt` nil or `< startedAt`) → `Line(symbol(tool), summary + (more > 0 ? " · \(more) more" : ""), startedAt)`. Else background → `Line("person.2", runningSubagents > 0 ? "Agents working · \(runningSubagents)" : "Agents working", stateAt)`. Else → `Line("ellipsis", "Thinking…", stateAt)`. Symbols: Bash "terminal", Edit/Write/MultiEdit/NotebookEdit "pencil", Read "doc.text", Grep/Glob "magnifyingglass", Agent/Task "person.2", WebFetch/WebSearch "globe", `mcp__*` "powerplug", else "gearshape".

- [ ] **Step 1: Write the failing tests:** presenter: `testBashLine`, `testMoreSuffix`, `testThinkingWhenNoActivity`, `testBackgroundAgentsCount`, `testHiddenWhenNotWorkingEvenWithOpenTool`, `testHiddenAfterNewerAgentText` (`lastAgentAt > startedAt` and working → Thinking…, not the tool). Store: `testRefreshSetsActivity`, `testEmptyRefreshKeepsServerActivity` (payload with no entries but activity → `store.activity` set), `testNullActivityClears`. Payload: `testActivityNotPublished` (a `SessionChatPayload` built from a store with activity has no activity field in its encoded JSON).
- [ ] **Step 2:** `make test-swift FILTER='WorkchatActivityPresenterTests|SessionFeedStoreTests|SessionChatPayloadTests'`. FAIL.
- [ ] **Step 3: Implement.** `WorkchatActivityLine` is a fixed-height row (caption font, secondary colour). The symbol uses a design-kit pulse/shimmer if one exists (`make design-gallery`), else `.symbolEffect(.pulse)`. Text is truncated in the middle, and the elapsed time is `TimelineView(.periodic(from: .now, by: 1))` formatted `m:ss`. Text changes crossfade (`.contentTransition(.opacity)`, `.animation(.default, value: line)`). It is hidden while the permission card shows.
- [ ] **Step 4:** re-run. PASS. Look at it: `make desktop-shots DESKTOP_SHOTS=<scratch dir>` if a Workchat shot exists, else the manual check in Task 8. `make lint-swift`.
- [ ] **Step 5: Commit** `feat(workchat): a live line with the agent's current step, never in the history`.

### Task 7: Paste images and files into the Workchat

**Depends on:** Task 5 (`WorkchatModel.send` and `WorkchatOutgoing` edits; same files)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatAttachmentStore.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkchatModel.swift` (attachments + compose), `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatOutgoing.swift` (`typedText`, `attachmentPaths`, matching), `WatchtowerDesktop/Sources/Views/Workbench/WorkchatComposer.swift` (wire `attachments`, `onAttachFiles`, `onPasteData`, `onRemoveAttachment` of `ChatComposerField`; drag and drop comes with `onAttachFiles`), the app's launch path for the cleanup (where other launch-time sweeps run, e.g. beside `ChatHistoryAttachmentCleanup`)
- Test: `WatchtowerDesktop/Tests/Core/WorkchatAttachmentStoreTests.swift`, `WatchtowerDesktop/Tests/WorkchatModelTests.swift`, `WatchtowerDesktop/Tests/Core/WorkchatOutgoingTests.swift`

**Interfaces:**
- Produces:
  ```swift
  package struct WorkchatAttachmentStore {
      package init(root: URL, now: @escaping () -> Date = Date.init, fileManager: FileManager = .default) // root = <workspace>/workchat-attachments
      package func save(_ data: Data, name: String, sessionID: Int64) throws -> URL   // keeps name's extension
      package func sweep(olderThan: TimeInterval = 7 * 86_400, keepingSessions live: Set<Int64>) // best effort, logs failures
  }
  ```
  `WorkchatModel`: `private(set) var attachments: [ChatAttachment]` (in memory, ids from a negative counter, `path` = absolute path, `mime` from the extension), `func attach(files: [URL])`, `func attach(data: Data, name: String) async -> Bool`, `func removeAttachment(_ id: Int64)`. `send()` composes `text + "\n" + paths.joined("\n")`, with each path in double quotes when it holds a space. An empty text with attachments still sends. Attachments clear on send and come back on `.notSent`.
  `WorkchatOutgoing`: `typedText: String`, `attachmentPaths: [String]` (text stays the composed line). `matches` compares the collapsed `entry.text`, with `[Image #N]` / `[image]` markers and any of `attachmentPaths` (quoted or not) removed, against the collapsed `typedText`.

- [ ] **Step 1: Write the failing tests:** store: `testSaveWritesUnderSessionFolder` (path `<root>/42/20261021-101500-1.png`, bytes equal), `testSweepRemovesOldKeepsLive`. Model: `testPasteImageAddsChip`, `testAttachFilesUsesPathsAsIs`, `testSendComposesTextAndQuotedPaths` (`"look\n\"/tmp/a b.png\""`), `testAttachmentsOnlySends`, `testNotSentRestoresAttachments`. Outgoing: `testMatchesIgnoresImageMarkersAndPaths` (typed "look", path `/x/1.png`, entry "look [Image #1]" → match; entry "look /x/1.png" → match).
- [ ] **Step 2:** `make test-swift FILTER='WorkchatAttachmentStoreTests|WorkchatModelTests|WorkchatOutgoingTests'`. FAIL.
- [ ] **Step 3: Implement.** The attachment chips come from `ChatComposerField` as they are. The image size limit is the one `PastedContent.imageAttachment` already applies. Run the sweep once at launch after the DB opens, with the live session ids from `TerminalCenter.liveIDs` (or skip folders of sessions `TerminalSessionQueries` lists as not ended). Failures are logged with `NSLog` and never block launch.
- [ ] **Step 4:** re-run. PASS. `make lint-swift`.
- [ ] **Step 5: Commit** `feat(workchat): paste or drop images and files into the composer`.

### Task 8: Docs and the gate

**Depends on:** Tasks 1–7

**Files:**
- Modify: `docs/features/session-chat-feed.md` (one toggle; asks in the current mode; `queued_command` owner lines; `activity` and the live line; send while busy + echo rule; paste + attachments folder + 7-day sweep; v1 limits: Codex activity/queueing per Task 2/5 findings, no activity on the phone)
- Modify: `docs/guide/features/workbench/workchat.md`, `docs/guide/features/workbench/sessions.md` (toggle wording), `docs/guide/reference/keyboard-shortcuts.md` only if wording changed (per `docs/guide/WRITING.md`)
- Modify: `CLAUDE.md` feature line for the session chat feed only if its summary names the two-button switch (append "polish 2026-10-21, #846")

- [ ] **Step 1:** write the docs. `go test ./docs/guide` PASS (8 KB page cap).
- [ ] **Step 2: Gate:** `make test`, `make test-swift`, `make lint-all`, each to a log with `; echo "exit=$?"`. All exit 0.
- [ ] **Step 3: Commit** `docs: Workchat polish — toggle, live line, send while busy, paste`.
- [ ] **Step 4:** owner check (ask, kind check) from the spec's manual list: a long session in Workchat, the live line through several steps, two lines sent while working, a pasted screenshot and a Finder file, an ask opened from the stack while in Workchat, and the toggle flipped both ways.
