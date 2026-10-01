# Shared embedded chat component — implementation plan

> **For agentic workers:** execute task by task, TDD (failing test → implementation → green → commit). Inner loop only: `make test-swift FILTER=<Class>` (prefer `Tests/Core`), `make lint-diff`. Before any Swift build, check `pgrep -f swift-frontend`; never run two Swift builds at once.

**Goal:** every embedded assistant chat looks and behaves like the main AI chat. Streams survive navigation. One engine replaces 8 copies of the stream loop. Backends are unchanged (`watchtower ai query` per turn).

**Spec:** `docs/superpowers/specs/2026-10-01-shared-chat-component-design.md` (section numbers below refer to it).

**Architecture:** `ChatSurfaceSpec` (value) + `EmbeddedChatStore` (database/memory) + `EmbeddedChatEngine` (`@Observable`, Core) + `EmbeddedStreamGate` (≤ 3 turns) + `EmbeddedChatCenter` (on `AppState`). The views come from main-chat pieces: `ChatFeedView` and `ChatComposerBar` are extracted from `ChatThreadView` / `ChatComposerView`, and `ChatMessageRow` / `LiveAssistantRow` are reused with optional row actions.

**Review checklist for every task** (self-review before hand-back):
- `docs/review/review-rules.md`, Swift / Desktop conventions:
  - Async state lives in the center.
  - Each surface picks a capability contract explicitly.
  - No `try?` or `print` on persistence paths.
  - New `@Observable` types ship with a test suite.
- Guard tests are never weakened.
- Repo text is in English.
- No real ids, names or paths.

---

## PR 1 — #170: engine, center, extracted feed and composer, main chat on them

Branch `feature/shared-chat-component`. The spec and this plan ride in this PR.

### Task 1: `StreamEvent.error`

**Files:**
- `Sources/WatchtowerCore/Services/ClaudeService.swift`
- `Sources/WatchtowerCore/Services/WatchtowerAIService.swift` (`parseLine`)
- the 9 legacy switch sites:
  - `TargetChatViewModel`, `TrackChatView`, `IdeaChatViewModel`, `MeetingChatViewModel`
  - `OnboardingChatViewModel` ×3
  - `CalendarSetupChatViewModel`, `EmailSetupChatViewModel`
- `Tests/Core/WatchtowerAIServiceTests.swift`

**Interface:** `case error(String)`. `parseLine` returns `.error(msg)` for `{"type":"error"}`.

**Legacy sites:** fold `.error(msg)` exactly as they fold `.text("[Error] \(msg)")` today. Keep the behaviour byte-identical, including the `sawTurnComplete` handling.

**Tests:**
- `testParseLineErrorEmitsErrorEvent`: replaces the old `[Error]` text expectation.
- `testErrorDoesNotTouchAccumulatedText`: the error line leaves the turnComplete accumulator unchanged.

### Task 2: `EmbeddedStreamReducer` (Core)

**Files:**
- `Sources/WatchtowerCore/Services/Chat/EmbeddedStreamReducer.swift`
- `Tests/Core/EmbeddedStreamReducerTests.swift`

**Interface:**

```swift
package struct EmbeddedStreamReducer {
    package enum Effect: Equatable { case text(String), sessionID(String), failed(String), none }
    package private(set) var text: String
    package mutating func apply(_ event: StreamEvent) -> Effect   // .text = new full text
}
```

The fold semantics are the 8 copies' semantics:
- `.text` appends.
- `.turnComplete` replaces and arms "the next `.text` replaces".
- `.reset` clears.
- `.done` returns `.none`.

**Tests:**
- deltas accumulate
- turnComplete replaces
- text after turnComplete replaces
- reset clears mid-stream
- sessionID passthrough
- error → `.failed`

### Task 3: `LiveTurn.replaceText`

**Files:**
- `Sources/WatchtowerCore/Services/Chat/LiveTurn.swift`
- `Tests/Core/LiveTurnTests.swift` (new)

**Interface:** `package func replaceText(_ text: String, now: Date)` is throttled like `appendDelta`, and `fullText` is always authoritative.

**Tests:**
- replace after appends
- replace to empty
- 100 rapid deltas → `text` publishes are bounded and `fullText` is exact
- `finish` flushes

### Task 4: `EmbeddedChatErrorClassifier` (Core)

**Files:**
- `Sources/WatchtowerCore/Services/Chat/EmbeddedChatErrorClassifier.swift`
- `Tests/Core/EmbeddedChatErrorClassifierTests.swift`

**Interface:** `static func classify(_ error: Error) -> (code: ChatErrorCode?, message: String)` and `static func classify(eventMessage: String) -> (code: ChatErrorCode?, message: String)`.

**Tests:**
- `cliNotFound` → `.providerUnavailable`
- exitCode with "not logged in" → `.auth`
- "429" → `.rateLimit`
- unknown → nil code with the real text
- an empty detail falls back to the error's description

### Task 5: `ChatSurfaceSpec` and its values (Core)

**Files:**
- `Sources/WatchtowerCore/Services/Chat/ChatSurfaceSpec.swift`
- `Tests/Core/ChatSurfaceSpecTests.swift`

**Interfaces:**
- `EmbeddedChatKey: Hashable` (contextType, contextID, conversationID?)
- `ChatSurfaceSpec.Persistence { case database(conversationID: Int64), memory }`
- `ChatSurfaceSpec.ToolAccess { case draftOnly, actions(surface: String) }` with `func toolMode(key:turnID:) -> ChatToolMode?`
- `ChatTurnInput { text, isResumed, previousOwnerMessageAt, turnID }`
- `ChatPostTurnInput { reply, turnID, messageID }`
- `ChatPostTurnResult { displayText, notices, failure }` with `.identity(reply)`
- `ChatSurfaceSpec { key, persistence, toolAccess, systemPrompt, turnPrompt, postTurn, emptyHint, starterPrompts }`

**Tests:**
- draftOnly → nil toolMode
- actions → `ChatToolMode` with the conversation, turn, context type and context id
- identity postTurn

### Task 6: `EmbeddedChatStore`, database and memory

**Files:**
- `Sources/WatchtowerCore/Services/Chat/EmbeddedChatStore.swift`
- `Sources/WatchtowerCore/Database/Queries/ChatMessageQueries.swift` (new queries)
- `Sources/WatchtowerCore/Models/ChatModels.swift` (package memberwise init on `ChatMessageRecord`)
- `Tests/Core/EmbeddedChatStoreTests.swift`

**Interface:**

```swift
@MainActor package protocol EmbeddedChatStore: AnyObject {
    func loadMessages() throws -> [ChatMessageRecord]
    func loadSessionID() throws -> String?
    func beginTurn(ownerText: String?, turnID: String) throws -> (ownerID: Int64?, assistantID: Int64)  // one transaction
    func beginAssistant(turnID: String) throws -> Int64
    func saveProgress(messageID: Int64, text: String) throws
    func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) throws
    func appendSystem(_ text: String) throws -> Int64
    func appendLocal(role: String, text: String) throws -> Int64
    func saveSessionID(_ id: String) throws
}
```

`DatabaseEmbeddedChatStore(dbPool:conversationID:)` throws `ChatContextGoneError` when the conversation row is gone. `MemoryEmbeddedChatStore` uses negative synthetic ids.

**Tests (both stores, shared cases):**
- beginTurn writes the owner and placeholder in order
- finalize sets status, error_code and error_message
- saveProgress updates the text
- session id round-trip
- a deleted conversation throws `ChatContextGoneError`
- the database store leaves every other column at its default (storage format unchanged)

### Task 7: `EmbeddedStreamGate` (Core)

**Files:**
- `Sources/WatchtowerCore/Services/Chat/EmbeddedStreamGate.swift`
- `Tests/Core/EmbeddedStreamGateTests.swift`

**Interface:** `@MainActor @Observable package final class EmbeddedStreamGate`:
- `init(limit: Int = 3)`
- `func tryAcquire(_ id: UUID) -> Bool`
- `func enqueue(_ id: UUID, onGranted: @escaping () -> Void)`
- `func cancel(_ id: UUID)`
- `func release(_ id: UUID)`: grants the head of the queue
- `var active: Int`
- `var waiting: Int`

**Tests:**
- 3 grants and the 4th waits
- a release grants FIFO
- cancel removes a waiter without granting
- a double release is a no-op

### Task 8: `EmbeddedChatEngine` (Core)

**Files:**
- `Sources/WatchtowerCore/Services/Chat/EmbeddedChatEngine.swift`
- `Tests/Core/EmbeddedChatEngineTests.swift`
- `Tests/Core/Support/ScriptedAIService.swift` (or reuse `Tests/Support/MockClaudeService`)

**Interface:** `@MainActor @Observable package final class EmbeddedChatEngine`

State:
- `spec`
- `messages: [ChatThreadItem]`
- `liveTurn: LiveTurn?`
- `isStreaming`
- `queuedText: String?`
- `draft`
- `bannerError`
- `postTurnResults: [Int64: ChatPostTurnResult]`
- `var isBusy: Bool { isStreaming || queued }`

Commands:
- `send(_ text:)`
- `sendFollowUp(prompt:notice:)`
- `sendHidden(_ prompt:)`
- `appendLocal(role:text:)`
- `stop()`
- `retry()`
- `cancelQueued()`
- `shutdown(quietly:)`
- `finishAsPartial()`

Hooks: `onTurnFinished: ((TurnOutcome) -> Void)?`.

Init: `init(spec:store:aiService:gate:dbPath:clock:draftMirror:)`.

Behaviour follows spec §4/§5. Follow-ups queue while streaming and flush as one turn, or prepend to the next owner send. `retry` reruns the last request kind.

**Tests:**
- full turn (deltas → complete row)
- throttle (100 deltas → bounded publishes, `messages` unchanged until the end)
- system prompt only without a session id
- session id persisted on the event
- Stop → `partial` with its text
- Retry → a new placeholder and no second owner row
- error event → `error` row with the code and text, partial text kept
- thrown exitCode → error row
- an empty completed reply → error
- postTurn: displayText replaces the reply, notices are appended after it, a failure is stored in `postTurnResults`
- postTurn is not run on stop or error
- a store failure in `beginTurn` → nothing is sent, the draft is restored, the banner is set
- a store failure mid-turn → error row
- queue: 3 engines streaming, the 4th send is queued (`queuedText` set, no rows), a release starts it with the owner row written at start
- cancel from the queue → the draft is restored and the mirror cleared
- follow-up while streaming is flushed after the turn
- context gone mid-stream with quiet shutdown → no banner
- memory store parity

### Task 9: `EmbeddedChatCenter`

**Files:**
- `Sources/WatchtowerCore/Services/Chat/EmbeddedChatCenter.swift`
- `Tests/Core/EmbeddedChatCenterTests.swift`

**Interface:** `@MainActor @Observable package final class EmbeddedChatCenter`
- `init(gate:makeEngine:clock:idleTTL: 300)`
- `func engine(for spec: ChatSurfaceSpec) -> EmbeddedChatEngine`
- `func loaded(_ key:) -> EmbeddedChatEngine?`
- `markShown(_ key)` / `markHidden(_ key)`
- `sweep(now:)`
- `dropContext(type:id:)`
- `release(_ key)`
- `finishAllAsPartial()`

The draft mirror is `EmbeddedDraftMirror`, a protocol with a `UserDefaults` implementation in the app target and an in-memory one for tests.

**Tests:**
- the same instance per key
- "start stream → markHidden → sweep → markShown → answer complete" (the review-rules navigation test)
- sweep releases an idle engine hidden past the TTL, keeps a busy one and keeps a shown one
- `dropContext` cancels quietly and removes every key of that context
- `finishAllAsPartial` persists partials

### Task 10: optional row actions

**Files:**
- `Sources/Views/Chat/ChatMessageRow.swift`
- `Sources/Views/Chat/ChatThreadView.swift`
- `Tests/ChatMessageRowTests.swift`

**Interface:** in `ChatRowActions`, every closure except `copy` becomes optional, and nil hides its button. In the `partial` status card, a nil `continueStopped` leaves only "Stopped". In the `error` card, a nil `retry` hides Retry.

**Tests:**
- existing tests stay green, with only mechanical edits where the main thread passes closures
- a new test: actions with only `copy` → no edit, quote, regenerate or variant buttons
- error row without `retry` → no Retry

### Task 11: extract `ChatFeedView`

**Files:**
- `Sources/Views/Chat/ChatFeedView.swift` (new)
- `Sources/Views/Chat/ChatThreadView.swift`

**Interface:** `struct ChatFeedView<Content: View>: View`, initialized with `init(state: ChatAutoScrollPolicy.ThreadState, lastRowID: Int64?, density: ChatDensity, onScrollTargetConsumed: @escaping () -> Void, @ViewBuilder content: () -> Content)`.

The follow tracker, content-frame preference, jump-to-latest and thread-change handling move here verbatim. `ChatDensity { regular, compact }` carries spacing, padding, max column width and the composer max-height factor. `ChatThreadView` renders `ChatFeedView(…, density: .regular)` with its rows, action cards and errors. It keeps the quote sheet.

**Tests:** `ChatAutoScrollPolicyTests` unchanged. Manual by-eye check in the main chat: follow while streaming, jump to latest, ⌘K hit jump.

### Task 12: extract `ChatComposerBar`

**Files:**
- `Sources/Views/Chat/ChatComposerBar.swift` (new)
- `Sources/Views/Chat/ChatComposerView.swift`

**Interface:** `struct ChatComposerBar<Accessory: View>: View`:
- `text: Binding<String>`
- `isStreaming`
- `onSend`
- `onStop`
- `placeholder`
- `dictationTargetID`
- `maxHeight`
- `status: ChatComposerStatus?` (`.queued(onCancel)`, `.error(String)`)
- the remaining `ChatInput` passthroughs (escape, arrow-up, attachments, picker) as optionals
- `@ViewBuilder accessory`

`ChatComposerView` renders its pickers, quotes and chips, then `ChatComposerBar { modelPill }`.

**Tests:** `ChatInputViewTests` and `ChatInputAttachmentTests` unchanged. A new `ChatComposerBarTests` (ViewInspector) checks that the queued status shows Cancel and an error status shows its text.

### Task 13: `EmbeddedChatView` and its halves

**Files:**
- `Sources/Views/Chat/Embedded/EmbeddedChatView.swift`
- `EmbeddedChatRows.swift`, `EmbeddedChatComposer.swift`, `EmbeddedChatEmptyState.swift`
- `Tests/EmbeddedChatViewTests.swift`

**Interfaces:**
- `EmbeddedChatView<Accessory, Footer>(engine:density:placeholder:dictationTargetID:accessory:footer:)`
- `EmbeddedChatRows(engine:accessory:)`: no scroll of its own
- `EmbeddedChatComposer(engine:placeholder:dictationTargetID:density:)`

Rows:
- `ChatMessageRow` with `copy`, and `retry` only on the last error row while idle
- `LiveAssistantRow` for the live turn
- a queued owner bubble with Cancel
- a postTurn failure caption under its message

Banner errors render through `ChatComposerBar` status.

**Tests (ViewInspector, Tests/):**
- an empty engine shows the hint and the starter prompts
- a starter prompt with `sendsImmediately` calls send
- the last error row has Retry and an earlier one does not
- a queued turn shows Cancel

### Task 14: `AppState` wiring

**Files:**
- `Sources/App/AppState.swift`
- `Sources/Services/UserDefaultsDraftMirror.swift`

**Content:** `let embeddedChatCenter`, a sweep timer started with the app, and `finishAllAsPartial()` from the existing termination hook (the same place the main chat finishes its turns). No surface uses the center yet.

**Tests:** covered by Task 9. Only the wiring is checked here, by build.

### Task 15: feature note

**Files:**
- `docs/features/embedded-chat.md`
- `CLAUDE.md` (one line in Feature Notes)

**Content:** architecture, contracts (§8), surface table, limits.

**PR 1 gate:**
- CI green
- main chat by eye: stream, stop, retry, follow-scroll, jump to latest, model pill

---

## PR 2 — #172 track, #173 idea/decision, #174 meeting

Each surface is migrated in its own commit. Branch `feature/embedded-chat-draft-surfaces`, from fresh origin/main.

### Task 16: track (#172)

**Files:**
- `Sources/Views/Tracks/TrackChatView.swift`: `TrackChatViewModel` and `TrackChatSection` are deleted, and the prompt builders move to `enum TrackChatPrompt` with the same text
- `Sources/Views/Tracks/TrackDetailView.swift`
- `Sources/ViewModels/TargetChatViewModel.swift`: reference update for `trackMemorySubjects`
- `Tests/TrackChat*PromptTests.swift`: rename the reference only
- `Tests/Core/TrackChatSpecTests.swift`

**Interfaces:**
- `enum TrackChatSurface { static func spec(track:conversationID:dbPool:) -> ChatSurfaceSpec; static func conversation(for track:, dbPool:) throws -> Int64 }` (fetch or create)
- The view fetches `appState.embeddedChatCenter.engine(for:)` in `.task(id: track.id)` and calls `markShown`/`markHidden`.
- `onTurnFinished` → `viewModel.load()`.

**Tests:**
- the spec is `.draftOnly`
- the system prompt equals `TrackChatPrompt.buildSystemPrompt`
- resolving an existing conversation reuses it, otherwise one is created with the title "Track: …"
- the engine survives a hide/show (center test with the track spec)

### Task 17: idea / decision (#173)

**Files:**
- `Sources/ViewModels/IdeaChatViewModel.swift`: becomes `enum IdeaChatSurface` (prompt builders, `persistedMessageCount`, spec)
- `Sources/Views/Ideas/IdeaDiscussSection.swift`
- `Sources/Views/Ideas/IdeaDetailPane.swift`
- `Sources/Views/Digests/DecisionDetailView.swift`
- `Tests/IdeaChatViewModelTests.swift` → `IdeaChatSurfaceTests` (same scenarios on engine + spec)
- `Tests/IdeaChatSkillsPromptTests.swift`

**Interface:** `IdeaDiscussSection(idea:mentions:dbManager:isExpanded:)` reads the engine from the center. Collapse only hides the rows. The docked composer is `EmbeddedChatComposer`.

**Tests:**
- every existing `IdeaChatViewModelTests` scenario is ported: resumed turn carries the context block, first turn has the system prompt, session id persisted, partial on stop
- collapse does not stop a stream (center + engine)

### Task 18: meeting (#174)

**Files:**
- `Sources/ViewModels/MeetingChatViewModel.swift` → `enum MeetingChatSurface`
- `Sources/Views/Calendar/RecordingDetailTabs.swift` (`RecordingChatTab`)
- `Sources/Views/Calendar/RecordingDetailView.swift`: remove the `cancelStream` calls at `:363` / `:511`
- the matching tests

**Tests:**
- ported `MeetingChatViewModelTests` scenarios
- `MeetingChatMemoryPromptTests` and `MeetingChatSkillsPromptTests` keep their assertions
- switching transcript does not cancel the stream of the previous one

### Task 19: context deletion

**Files:** the delete paths for track and idea (`TracksViewModel`, `IdeasViewModel` or their queries' callers), which call `embeddedChatCenter.dropContext`.

**Tests:** deleting a track or idea mid-stream ends quietly. This is a view-model test with the center injected.

**PR 2 gate:**
- CI green
- by eye: track, idea and decision, and meeting each stream, navigate away and back with the answer complete, collapse Discuss mid-answer

---

## PR 3 — #171 target

Branch `feature/embedded-chat-target`.

### Task 20: target surface controller

**Files:**
- `Sources/ViewModels/TargetChatViewModel.swift`
- `Tests/TargetChatViewModelTests.swift` (ported, guards unchanged)

**Interface:** `TargetChatViewModel` keeps:
- `actionCards`, `pendingActionCount`, `approve(_:as:)`, `approveAll(messageID:)`, `reject(_:)`
- `actionFeed`, `toolsAvailable`, `targetGone`
- `onTargetActivity`, `onUserMessage`

It gains `let engine: EmbeddedChatEngine` and builds the spec:
- `turnPrompt` = outcomes + resumed blocks verbatim
- `postTurn` = `surfaceActions`

`TargetActionCard.messageID` becomes `Int64` (the assistant row id). `send()` goes to `engine.send` after `reloadTarget()` and the `targetGone` guard. Follow-ups go to `engine.sendFollowUp`. `isStreaming` = `engine.isBusy`, because `TargetBriefCenter` treats "started" as busy. `onTurnFinished` → `actionFeed.refresh()`, `reloadTarget()`, `viewModel.load()`, `onTargetActivity`.

**Tests:** every existing scenario, assertions unchanged except the message type. TGT-BRIEF guards:
- contract prompt
- no follow-up turn after auto-apply
- out-of-line action fails its card
- propose-mode unchanged
- malformed execute block not applied

New tests:
- a decision mid-stream is queued and flushed
- stop never parses actions
- a postTurn failure shows in the slot

### Task 21: target view

**Files:**
- `Sources/Views/Targets/TargetChatView.swift`
- `Tests/TargetChatViewTests.swift`

**Content:** `TargetChatPane` renders `EmbeddedChatView(.regular)`:
- `accessory(for:)` = collapsed batch / per-card `TargetActionCardView` plus `AgentActionFeed` cards and the per-turn Approve all
- `footer` = unattached proposals and the feed's `lastError`

The tab strip is unchanged.

**Tests:**
- Approve all is visible for ≥ 2 pending cards in a batch and for ≥ 2 pending feed cards
- the collapsed batch above `compactBatchThreshold`

### Task 22: container, center and brief center

**Files:**
- `TargetAssistantViewModel.swift`, `TargetAssistantCenter.swift`, `TargetBriefCenter.swift`
- their tests

**Content:** engines come from `embeddedChatCenter`. `stop()` releases the keys. `isAnyWorking` reads `engine.isBusy`. `drop(targetID:)` also calls `dropContext("target", id)`.

**Tests:**
- `TargetAssistantCenterTests` (busy container never evicted)
- `TargetBriefCenterTests` (run survives navigation; failure leaves the row)
- both unchanged in intent

**PR 3 gate:**
- CI green
- by eye: propose → card → Approve, Approve all (batch and feed), execute directive auto-applies, reject, navigate away mid-turn

---

## PR 4 — #175 onboarding, #176 setup, #177 cleanup

Branch `feature/embedded-chat-onboarding-setup`.

### Task 23: onboarding (#175)

**Files:**
- `Sources/ViewModels/OnboardingChatViewModel.swift`
- `Sources/Views/Onboarding/OnboardingChatView.swift`
- `Tests/OnboardingChatViewModelOwnerTests.swift`, `Tests/OnboardingCompletionTests.swift`
- `Tests/Core/OnboardingPostTurnTests.swift`

**Content:**
- The VM keeps the questionnaire, `chatReady`, profile extraction and the team form. It owns a `.memory` engine from the center and releases it on finish or skip.
- The questionnaire uses `appendLocal`. `initiateChat` uses `sendHidden`.
- `retryAfterError` → `engine.retry()`.
- `skipChat` → `engine.stop()` plus clearing `errorMessage` and `quickReplies`.
- `postTurn` = `[READY]` strip plus the question-mark heuristic, as a pure static function.

The view is `EmbeddedChatView(.regular)`, with the footer slot holding quick replies, Continue and "Skip interview" (always shown).

**Tests:**
- `[READY]` strip, both cases insensitive
- the heuristic after 6 answers
- the fallback count
- Skip while streaming stops and clears the error
- Retry replays a hidden prompt without a user row
- the extraction transcript skips error rows

### Task 24: onboarding non-chat streams

**Files:**
- `Sources/WatchtowerCore/Services/Chat/AIStreamText.swift`
- `OnboardingChatViewModel` (`extractContextFromConversation`, `collectStreamText`)

**Interface:** `enum AIStreamText { static func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> String }` on `EmbeddedStreamReducer`. A `.error` event throws.

**Tests:** collect with deltas, reset and turnComplete; an error event throws.

### Task 25: calendar setup (#176)

**Files:**
- `CalendarSetupChatViewModel.swift`, `CalendarSetupAssistantPanel.swift`, `AddCalendarAccountView.swift`
- `Tests/CalendarSetupChatViewModelTests.swift`

**Content:**
- The VM keeps the parser and the snapshot/patch types (unchanged, credential-free), `onApplySettings` and `makeSnapshot`.
- The engine is `.memory` and is released on sheet close.
- `turnPrompt` prepends `formStateBlock(makeSnapshot())`.
- `postTurn` parses → patch, display text.
- The greeting uses `appendLocal`. `sendConnectionError` is a visible owner turn.

**Tests:**
- every existing scenario
- the privacy guard: a prompt never contains the password or feed URL, and a patch with a password key is dropped

### Task 26: email setup (#176)

The same as Task 25 for `EmailSetupChatViewModel` / `EmailSetupAssistantPanel` / `AddEmailAccountView`, with the IMAP password excluded.

### Task 27: delete `MessageBubble` and `ChatInput` (#177)

**Files:**
- delete `Sources/Views/Chat/MessageBubble.swift` and `Tests/MessageBubbleViewTests.swift`
- `ChatInput` folds into `ChatComposerBar` (the dictation environment read moves there, and `ChatInputContent` stays as the rendering)
- `TargetDetailView.assistantInlineInput` → `ChatComposerBar` without slots (same placeholder, dictation id and submit)
- `ChatInputViewTests` re-targeted to `ChatComposerBar` with the same assertions

**Check:** `grep -rn "MessageBubble\|ChatInput(" Sources` returns nothing.

### Task 28: docs

**Files:**
- `docs/app-guide.md`: embedded chats section (same look as the main chat, Copy/Retry, stop, queued, streams survive navigation)
- the backlog item → `status: done`
- `docs/features/embedded-chat.md`: final state

**PR 4 gate:**
- CI green
- by eye: onboarding (quick replies, Continue after `[READY]`, Skip mid-stream, error card Retry), calendar and email setup (form fills, password stays empty in the prompt), TargetDetailView "Ask the assistant" field
