# Shared embedded chat component — design

**Date:** 2026-10-01 · **Board:** #168 (spec/plan #169; PRs #170–#177) · **Status:** owner-approved (decisions recorded 2026-10-01, "та давай уже делать")

Every embedded assistant chat in the Desktop app (target, track, idea/decision, meeting, onboarding,
calendar/email setup) is rebuilt on one component that looks and behaves like the main AI chat: the
same message rows, live streaming row, follow-scroll feed, composer, error card and Stop. Backends do
not change: each turn is still one `watchtower ai query` process started through
`WatchtowerAIService.stream`.

All paths below are relative to `WatchtowerDesktop/` unless they start with `internal/`, `cmd/` or `docs/`.

## 1. Scope

In scope (owner choice "A", look and feel):

- One feed, message row, live row, composer, empty state, streaming indicator and follow-scroll for every embedded chat, built from the main chat's pieces.
- Row actions in embedded chats are **Copy**, plus **Retry** on the last failed reply. Nothing else.
- Streams survive navigation and collapsing (owner choice "1 — чиним"). Today the track, idea/decision and meeting chats cancel or drop the stream when you leave or collapse them (§2).
- Error card with the real error text and a hint for the kind of failure, as in the main chat.
- At most 3 embedded streams at once. A 4th send is queued and shown as queued.

Out of scope: the warm `ai session` v2 protocol and `ChatSessionPool`, attachments, artifacts, @-mentions,
skill picker, quoting, branching/variants, regenerate, message editing, the model pill. The main chat's
behaviour does not change.

## 2. Current state

| Surface | ViewModel / owner | Persistence | Stream lifetime today | Post-turn work |
|---|---|---|---|---|
| Target | `TargetChatViewModel` (`Sources/ViewModels/TargetChatViewModel.swift:85`), one per tab, owned by `TargetAssistantViewModel`, which lives in `TargetAssistantCenter` on `AppState` (`Sources/Services/TargetAssistantCenter.swift:15`, `Sources/App/AppState.swift:88`) | `chat_conversations` `context_type='target'`, many tabs per target | Survives navigation (the center is app-wide) | `surfaceActions` (`:494`): parse `watchtower-action` blocks → `TargetActionCard`s, auto-apply execute mode for the chat's own target, Applied/Failed and "held for approval" system notices, invalid-block warnings. `approve`/`approveAll`/`reject` (`:593/:641/:689`) send follow-up turns. Follow-ups that arrive mid-stream are queued (`queuedFollowUps`). Registry proposals go through `AgentActionFeed`. |
| Track | `TrackChatViewModel` (`Sources/Views/Tracks/TrackChatView.swift:9`), `@State` in `TrackDetailView` (`Sources/Views/Tracks/TrackDetailView.swift:9`, created `onAppear` `:65`) | `context_type='track'` | Dies with the view (`@State`) | none (reloads track + `TracksViewModel`) |
| Idea / decision | `IdeaChatViewModel` (`Sources/ViewModels/IdeaChatViewModel.swift:16`), `@State` in `IdeaDetailPane` (`:45`) and `DecisionDetailView` (`:29`) | `context_type='idea'` | `IdeaDiscussSection.toggleDiscuss` cancels on collapse (`Sources/Views/Ideas/IdeaDiscussSection.swift:67-72`); the VM dies with the pane | none |
| Meeting | `MeetingChatViewModel` (`Sources/ViewModels/MeetingChatViewModel.swift:13`), `@State` in `RecordingDetailView` (`:51`) | `context_type='meeting'` | `cancelStream()` on transcript switch and disappear (`RecordingDetailView.swift:363`, `:511`) | none |
| Onboarding | `OnboardingChatViewModel` (`Sources/ViewModels/OnboardingChatViewModel.swift:22`), owned by `OnboardingView` | memory only | Window lifetime | `[READY]` marker strip + `chatReady` (`:621`). Scripted role questionnaire with quick replies (`:118`). A hidden first prompt (`initiateChat`). Retry replays the last request (`:344`). Skip (`:331`). Continue → profile extraction. |
| Calendar / email setup | `CalendarSetupChatViewModel` (`:105`), `EmailSetupChatViewModel` (`:120`), `@State` in `AddCalendarAccountView` / `AddEmailAccountView` | memory only | Sheet lifetime | Settings block → `onApplySettings` form patch. The snapshot and patch types carry no password or feed URL (privacy boundary, `CalendarSetupChatViewModel.swift:1-40`). |

Rendering today: target, track, idea and meeting each draw their own bubbles. Onboarding and the setup
panels use `MessageBubble` (`Sources/Views/Chat/MessageBubble.swift`). Every surface uses `ChatInput`
except track, which uses a single-line `TextField`. The main chat renders `ChatMessageRow` /
`LiveAssistantRow` (`Sources/Views/Chat/ChatMessageRow.swift`) inside `ChatThreadView`
(`Sources/Views/Chat/ChatThreadView.swift`). That view carries the follow-scroll machinery
(`ChatFollowTracker`, `Sources/WatchtowerCore/Services/Chat/ChatAutoScrollPolicy.swift:120`) and
reads the live text only through `LiveTurn` (`Sources/WatchtowerCore/Services/Chat/LiveTurn.swift`).

The same stream reducer (`.text` / `.turnComplete` / `.reset` / `.sessionID` / `.done` with a
`sawTurnComplete` flag) is copied 8 times. Persistence failures are mostly `print`ed or `try?`'d
(for example `TrackChatView.swift:223/234/277/295` and `IdeaChatViewModel.swift:227/237/250`). This
is backlog item `docs/backlog/2026-09-26-the-chat-streaming-reducer-is-copied-8-times-the-idea-and.md`.

Error text today: `ai query` reports provider failures as a v1 `{"type":"error"}` line and exits 0
(`cmd/ai.go:160-166`, `emitError` `:296`). `WatchtowerAIService.parseLine` turns that line into
`.text("[Error] …")` (`Sources/WatchtowerCore/Services/WatchtowerAIService.swift:231-235`), so the
error shows up as reply text. A non-zero exit throws `WatchtowerAIError.exitCode` carrying the
stderr text.

## 3. Architecture

```
Views (app target)                       WatchtowerCore (testable without UI)
──────────────────                       ────────────────────────────────────
EmbeddedChatView ─┬─ ChatFeedView  ◄──── (shared with ChatThreadView, main chat)
                  ├─ ChatMessageRow / LiveAssistantRow (shared, unchanged look)
                  └─ ChatComposerBar ◄── (shared with ChatComposerView, main chat)
        │ reads
        ▼
EmbeddedChatEngine (@Observable) ── ChatSurfaceSpec (value: prompts, tool access, postTurn)
        │  ├─ EmbeddedChatStore (database | memory)
        │  ├─ EmbeddedStreamReducer (one copy of the fold)
        │  ├─ LiveTurn (reused, render isolation, ~30 fps)
        │  └─ AIServiceProtocol.stream (unchanged backend)
        ▲ owned by
EmbeddedChatCenter (Core; instance on AppState) ── EmbeddedStreamGate (≤ 3 concurrent turns, FIFO queue)
```

### 3.1 `ChatSurfaceSpec` (Core, value type)

Describes one embedded chat. It holds no state; every closure is evaluated per turn.

- `key: EmbeddedChatKey`: `(contextType, contextID, conversationID?)`. This is the center's dictionary key. `conversationID` is nil for memory chats.
- `persistence`: `.database(conversationID:)` for target/track/idea/meeting, `.memory` for onboarding and the setup assistants.
- `toolAccess`: `.draftOnly` or `.actions(surface:)`. `.actions` makes the engine build `ChatToolMode(surface:conversationID:turnID:contextType:contextID:)` per turn, the same arguments `TargetChatViewModel.swift:301-307` passes today. Only the target spec uses `.actions("target")`, and only when `toolsAvailable` (provider ≠ ollama). Track, idea, meeting, onboarding and setup are `.draftOnly`, so `toolMode` stays `nil` (AGENT-04, review-rules "The assistant & chat contracts"). The capability choice is an explicit field, never inherited.
- `systemPrompt: () -> String`: built the way each chat builds it today (the existing static `buildSystemPrompt` functions stay where they are). Sent only when the conversation has no session id yet, as today.
- `turnPrompt: (ChatTurnInput) -> String`: the effective prompt. `ChatTurnInput` carries the text, `isResumed`, `previousOwnerMessageAt` and `turnID`. Each surface keeps its current behaviour:
  - Idea and meeting prepend their context block on resumed turns.
  - Target prepends the outcomes block always, and the context, tree, contract and tools blocks on resumed turns.
  - Setup prepends the form-state block on every turn.
  - Track sends the text as is.
- `postTurn: @MainActor (ChatPostTurnInput) -> ChatPostTurnResult`: runs once, only when a turn **completes**. A stopped or failed turn is never parsed (the rule today, `TargetChatViewModel.swift:379-389`, `CalendarSetupChatViewModel.swift:230-233`). The result has:
  - `displayText`: replaces the stored reply. Use it to strip directives, `[READY]` or settings blocks, or to supply a placeholder such as "(proposed N action(s))".
  - `notices: [String]`: appended as `system` rows after the reply.
  - `failure: String?`: shown in that message's slot.

  Side effects (cards, form patch, `chatReady`) belong to the surface controller that built the spec. The default is identity.
- `emptyHint` and `starterPrompts: [ChatStarterPrompt]` for the empty state.

### 3.2 `EmbeddedChatStore` (Core protocol, two implementations)

`DatabaseEmbeddedChatStore(dbPool:)` writes the existing `chat_messages` / `chat_conversations`
columns. The storage format does not change and no migration is needed. Existing history opens in
the new view as is. `MemoryEmbeddedChatStore` holds rows in an array, with negative synthetic ids.

Operations:

- `loadMessages`
- `insertUser`
- `insertAssistantPlaceholder(turnID)`: status `partial`, empty text
- `saveProgress(id, text)`
- `finalize(id, text, status, errorCode, errorMessage)`
- `insertSystem`
- `saveSessionID`
- `touch`

Every write throws. None uses `try?`.

The new rows use statuses (`partial`, `error`) and `error_code`/`error_message` columns that already
exist (migration 00076 / 00091, `internal/db/schema.sql:1941-1956`). Today embedded chats write only
`complete` rows. The other readers of these rows are unaffected:

- Go memory ingest reads only `role='user'` (`internal/db/memory.go:840`).
- The persisted-count badges count rows, and an in-flight reply now counts one turn earlier.
- `latestTurnActivity` reads `MAX(created_at)`.

### 3.3 `EmbeddedChatEngine` (Core, `@MainActor @Observable`)

Owns the stream loop for one conversation. It is testable without UI.

Exposed state:

- `messages: [ChatThreadItem]`: finished rows. `steps` is empty and the sibling index/count is 1/1. `ChatMessageRecord` gains a package memberwise init for the memory store.
- `liveTurn: LiveTurn?`
- `isStreaming`
- `queued: QueuedTurn?`
- `draft: String`: survives navigation because the engine does.
- `bannerError: String?`: only for failures not tied to a row, such as a failed history load or a deleted context.
- `postTurnResults: [Int64: ChatPostTurnResult]`: kept for the view's slots.

Commands:

- `send(text)`: a visible owner turn.
- `sendFollowUp(prompt:notice:)`: no user row. An optional system notice is shown first. If a turn is streaming, the prompt queues behind it, as `TargetChatViewModel.queuedFollowUps` does today. The queue is flushed as one turn, or prepended to the next owner send.
- `sendHidden(prompt)`: onboarding's first prompt.
- `appendLocal(role:text:)`: scripted bubbles (onboarding questionnaire, setup greeting).
- `stop()`
- `retry()`
- `cancelQueued()`
- `shutdown()`: called by the center.

Both `LiveTurn` and `EmbeddedStreamReducer` come from the main chat. `LiveTurn` gains
`replaceText(_:)` for `.reset` / `.turnComplete`.

### 3.4 `EmbeddedChatCenter` and `EmbeddedStreamGate` (Core; the center instance lives on `AppState`)

- `engine(for spec:) -> EmbeddedChatEngine`: creates the engine on first use and returns the same instance afterwards. Views fetch the engine from the center and never hold it in `@State` (review-rules "Lifecycle & state").
- `markShown(key)` / `markHidden(key)`: the view calls these from `onAppear` / `onDisappear`.
- `sweep(now:)`: runs from a 60-second timer and releases an engine that is idle and has been hidden for ≥ 5 minutes. An engine that is streaming or queued is never released.
- `dropContext(type:id:)`: called from the delete paths for target, track and idea. It cancels the engine. The resulting "not found" write error is swallowed quietly, because no view is left to show it.
- `release(key)`: onboarding and the setup sheets call this when the window or sheet closes (as today).
- `finishAllAsPartial()`: called on app termination. Every running turn is finalized as `partial` and its streamed text is kept.

`EmbeddedStreamGate(limit: 3)` hands out turn slots in FIFO order. The limit counts embedded turns
across the whole app. The main chat's pool is separate. A turn that cannot get a slot sets the
engine's `queued` state. Its text is not written yet: the owner row is written when the slot is
acquired and before the process starts (the CHAT-01 order). The queue lives in memory.

- **Stop on a queued turn** removes it and puts the text back into the draft.
- **Restart**: queued text is also mirrored to a per-key draft in `UserDefaults`. After a restart it comes back as an unsent draft in the composer. The mirror is cleared when the turn starts or is cancelled.

### 3.5 Views

- **`ChatFeedView` (new, VM-free).** Extracted from `ChatThreadView`: the `LazyVStack` scroll, content-frame preference, `ChatFollowTracker` box, jump-to-latest button and thread-change handling. The rows are supplied by a `@ViewBuilder`. `ChatThreadView` becomes this view plus its main-chat rows, action cards and quote sheet, with no behaviour change. Its parameters:
  - `ChatAutoScrollPolicy.ThreadState`
  - `lastRowID`
  - `onScrollTargetConsumed`
  - `density`
- **`ChatComposerBar` (new, VM-free).** The input row (`ChatInput`'s rendering) plus an optional status line above it (queued, banner error) and an optional bottom accessory. `ChatComposerView` puts its model pill in that accessory slot. The pickers, quotes and attachment wiring stay in `ChatComposerView`.
- **`ChatMessageRow`.** Becomes capability-driven: every `ChatRowActions` closure except `copy` turns optional, and nil hides the button. The main chat passes all of them, so its row is unchanged. Embedded chats pass `copy`, and `retry` only for the last failed reply while nothing streams. A `partial` row then reads "Stopped" without Continue, and an `error` row shows the main chat's error card (`ChatErrorPresentation`).
- **`EmbeddedChatView(engine:density:placeholder:dictationTargetID:)`.** Built from `ChatFeedView` with `ChatMessageRow`/`LiveAssistantRow` and `ChatComposerBar`. It has three slots:
  - `accessory(for: ChatThreadItem)`: the target's action cards.
  - `footer`: Approve all, onboarding quick replies and Continue/Skip.
  - `emptyState`: `EmbeddedChatEmptyState(hint:prompts:)`.

  `density`: `.regular` is the tab-sized layout (main chat spacing, column ≤ 760 pt). `.compact` covers the track bottom dock, the 420 pt setup panel and the idea section: tighter spacing and padding, a full-width column, and a smaller composer max height.
- **Inline split.** The idea/decision Discuss section sits inside its pane's `ScrollView`, and `ChatInput`'s `NSScrollView` collapses inside a SwiftUI `ScrollView` (the comment at `IdeaDiscussSection.swift:9-14`). So the view also comes in two halves: `EmbeddedChatRows(engine:)` with no scroll of its own, and `EmbeddedChatComposer(engine:)`, which the pane docks below its scroll as today.

## 4. Data flow

1. **`send(text)`.**
   - Trim the text. An empty text or a context that is gone is a no-op, and the draft is kept.
   - Acquire a gate slot. If none is free, the turn is queued (§3.4).
   - Write the owner row, then the assistant placeholder, in one write transaction.
   - If that write fails, nothing is sent, the text goes back to the draft and the failure shows in the banner. This is the embedded analogue of CHAT-01.
   - Create a `LiveTurn` for the placeholder id.
2. **Stream.**
   - Call `aiService.stream` with:
     - `prompt: spec.turnPrompt(...)`
     - `systemPrompt: sessionID == nil ? spec.systemPrompt() : nil`
     - `sessionID`: the conversation's
     - `dbPath`: the pool path for database chats, nil for memory chats, as today
     - `model: nil, provider: nil`
     - `toolMode`: from `toolAccess`
   - Deltas go only to `LiveTurn`, so only the live row re-renders. `messages` is untouched.
   - `.sessionID` is persisted immediately.
   - The text is flushed with `saveProgress` at most once per second (`ChatTurnDriver.flushInterval`), so a crash keeps the partial text.
3. **Turn end.**
   - **`.done`.** If the text is non-empty, run `postTurn`, then finalize with status `complete` and `displayText`, append `notices` as system rows, `touch` the conversation, and store the result. An empty completed reply is finalized as `error` ("The assistant returned no text.", retryable). An action-only target reply is not empty: its `postTurn` supplies the placeholder text.
   - **Thrown error or `.error(message)` event.** Finalize as `error` with the partial text kept, `error_code` from `EmbeddedChatErrorClassifier`, and `error_message` holding the real text.
   - **Stop.** Finalize as `partial`.
   - In every case, release the slot, start the next queued turn, and fire `onTurnFinished`, which surfaces use to reload their entity.
4. **`.error` event.** `StreamEvent` gains `.error(String)`. `parseLine` emits it for the v1 `error` line instead of `.text("[Error] …")`. The legacy view models that are not migrated yet map it back to the `[Error]` text they show today, so their behaviour is byte-identical until they move.

## 5. Errors and cancellation

| Case | Behaviour |
|---|---|
| Stop | Cancel the stream task. `AsyncThrowingStream.onTermination` → `WatchtowerProcessHandle.terminate()` sends SIGTERM to `watchtower ai query`. Its `notifyShutdownContext` (`cmd/shutdown.go:46`) cancels the context, which sends SIGINT to the provider child and SIGKILL after 5 s (`internal/ai/client.go:439-442`), so no orphans. The partial text is persisted as `partial` ("Stopped"). The next send resumes the same session id. |
| Turn error (CLI missing, non-zero exit, error event, auth, timeout) | Error card under the reply, from the main chat's `ChatErrorPresentation`. The text is the classified hint plus `detail(error_message)`. `EmbeddedChatErrorClassifier` maps:<br>• `cliNotFound` → `provider_unavailable`<br>• auth phrases ("not logged in", "login", "401", "invalid api key", "authentication") → `auth`, with the per-provider sign-in hint from `Constants.aiProviderID()`<br>• "rate limit"/"429" → `rate_limit`<br>• everything else → generic.<br>Partial text is kept. |
| Retry | Shown only on the last failed reply while nothing streams. It reruns the last request (the owner text, a follow-up prompt or a hidden prompt) under a new placeholder. It never inserts the owner row again. The failed row stays as history and its Retry disappears, because it is no longer last. |
| `postTurn` failure | `ChatPostTurnResult.failure` renders in that message's slot, for example "Couldn't read the proposed action: …". The reply stays and nothing is applied silently. Target malformed blocks keep today's "⚠️ Invalid action proposal" notice. |
| DB write failure | Any store write that throws during a turn marks the turn `error` (code `internal`, message = the DB error) and shows the card. The turn is not counted as successful. Writes outside a turn (history load) set `bannerError`. |
| Context deleted mid-stream | `EmbeddedChatCenter.dropContext` cancels the engine. Its "not found" write errors are dropped, because no view can show them. |
| Queue | Stop on a queued turn removes it and returns its text to the draft. On restart, the queued text comes back as a draft (§3.4). |

## 6. Per-surface mapping

- **Track (#172).** Spec `context_type='track'`, `.draftOnly`. `systemPrompt` = `TrackChatViewModel.buildSystemPrompt` (moves to a `TrackChatPrompt` enum, unchanged text). `onTurnFinished` reloads the track and `TracksViewModel`. `TrackDetailView` docks `EmbeddedChatView(.compact)` in the `VSplitView`. The conversation is resolved or created as today: `fetchByContext`, else `create` with the title "Track: …".
- **Idea / decision (#173).** Spec `context_type='idea'`, `.draftOnly`, with the resumed-turn context block as today. Both `IdeaDetailPane` and `DecisionDetailView` use `EmbeddedChatRows` inside their scroll and dock `EmbeddedChatComposer`. Collapsing Discuss only hides the rows and no longer stops anything. The collapsed header badge keeps reading `persistedMessageCount`.
- **Meeting (#174).** Spec `context_type='meeting'`, `.draftOnly`. The system prompt is built from the transcript excerpt + recap + memory exactly as today. The resumed-turn block is kept. `RecordingChatTab` becomes `EmbeddedChatView(.regular)`. Switching transcripts or leaving the screen no longer cancels.
- **Target (#171).**
  - `TargetChatViewModel` becomes the target *surface controller*. It keeps `actionCards`, `approve`/`approveAll`/`reject`, `resolveActionTarget`, `reloadTarget`, `targetGone` and `AgentActionFeed`. It builds the spec:
    - `.actions("target")` when `toolsAvailable`, else `.draftOnly`.
    - `turnPrompt` = today's outcomes + resumed blocks.
    - `postTurn` = today's `surfaceActions`: parse, cards keyed by the assistant row id, execute-mode auto-apply only for `autoApplies(inChatFor:)`, Applied/Failed and held notices, invalid-block warnings.
  - Its follow-ups go through `engine.sendFollowUp`.
  - `TargetAssistantViewModel` keeps the tabs and auto-titling. The engines come from `EmbeddedChatCenter`, keyed per conversation. `TargetAssistantCenter` eviction keeps checking "busy" via the engines.
  - Slots: `accessory` = the collapsed batch and its Approve all (batch threshold `compactBatchThreshold`), the per-card views, and `AgentActionFeed` cards with their per-turn Approve all and unattached proposals. `footer` = "Approve all" across the chat.
  - TGT-BRIEF-01..03 are untouched.
- **Onboarding (#175).**
  - `.memory`, `.draftOnly`. The spec's system prompt is `onboardingSystemPrompt(language:)`, sent on every turn as today (onboarding passes it even on resumed turns).
  - Questionnaire bubbles use `appendLocal`. `initiateChat` uses `sendHidden`.
  - `postTurn` strips `[READY]` and sets `chatReady`, with today's question-mark heuristic and fallback count.
  - Footer slot: quick replies, Continue, and "Skip interview" (always reachable).
  - The error card's Retry replaces "Try again" and replays the last request.
  - Profile extraction reads the engine's rows, skipping `error` rows.
  - The two non-chat streams (context extraction, profile parse) move onto a shared `AIStreamText.collect(_:)` helper on the same reducer.
- **Calendar / email setup (#176).**
  - `.memory`, `.draftOnly`.
  - `turnPrompt` prepends `formStateBlock(snapshot)`. The snapshot comes from a `makeSnapshot` closure the panel sets, and its types stay credential-free.
  - `postTurn` parses the settings block, returns the stripped text or "(filled in the settings on the left)", and calls `onApplySettings`.
  - The greeting uses `appendLocal`.
  - `sendConnectionError` is a visible owner turn as today.
  - The panels render `EmbeddedChatView(.compact)` and release the engine on sheet close.
- **Cleanup (#177).**
  - `MessageBubble` is deleted.
  - `ChatInput` folds into `ChatComposerBar`, which reads the dictation environment itself and renders `ChatInputContent`.
  - `TargetDetailView`'s "Ask the assistant" field (`:943-958`) is not a chat. It becomes a bare `ChatComposerBar` (no slots) with the same placeholder, dictation id and submit, so it keeps the composer's look.
  - `docs/app-guide.md` is updated, and the backlog item is marked done.

## 7. Behaviour that must survive (checked per PR)

- **Target.**
  - Propose renders pending cards. Execute auto-applies only on the chat's own target, with one Applied/Failed notice.
  - Approve all works both in the collapsed batch and on the `AgentActionFeed` per-turn cards.
  - Reject sends a follow-up. A decision taken mid-stream is queued and never dropped.
  - A deleted target sends no new turn.
  - Guards: `TargetChatViewModelTests` and its TGT-BRIEF scenarios, `TargetAssistantViewModelTests`, `TargetAssistantCenterTests`, and `TargetBriefCenterTests` (survives navigation).
- **Onboarding.** Skip interview is reachable during the questionnaire and while streaming. Continue appears after `[READY]`. Quick replies work. Retry after an error replays the request. Guards: `OnboardingChatViewModelOwnerTests`, `OnboardingCompletionTests`.
- **Setup.** The form patch is applied. A password or feed URL never reaches the prompt or the patch. Guards: `CalendarSetupChatViewModelTests`, `EmailSetupChatViewModelTests`.
- **Idea and decision.** Discuss works in both `IdeaDetailPane` and `DecisionDetailView`.
- **Meeting.** The prompt is built from transcript + recap (`MeetingChatViewModelTests`, `MeetingChatMemoryPromptTests`, `MeetingChatSkillsPromptTests`).
- **Main chat.** Unchanged. `ChatViewModelTests`, `ChatMessageRowTests` and `ChatAutoScrollPolicyTests` stay green without edits, except where a test names an action closure that became optional.

No guard test is weakened. Existing view-model tests move onto engine + spec and keep their scenario
names and assertions. Where an assertion read an in-memory `[ChatMessage]`, it reads
`engine.messages` instead.

## 8. Contracts touched

- **AGENT-04 / persona capability contracts.** Explicit `toolAccess` per spec. Draft-only surfaces never get a `toolMode`.
- **TGT-BRIEF-01..03.** Moved verbatim into the target controller's `postTurn` and approve paths. Guard tests unchanged.
- **CHAT-01 (main chat).** Not touched. Embedded chats adopt its ordering (owner row first) without being covered by the guard.
- **CHAT-04.** Applies to the main chat's `ai session` only. Embedded chats keep `ai query` with the prompt on argv, as today, so this is not a regression and stays out of scope.
- **Setup privacy boundary.** The snapshot and patch types are unchanged.

## 9. Testing

All new tests live in `Tests/Core` and use a scripted fake `AIServiceProtocol` (the existing
`MockClaudeService` lives in `Tests/Support`).

- **Engine.**
  - Full turn: deltas, done, DB rows.
  - Throttle: 100 deltas → bounded `LiveTurn.text` publishes, `messages` unchanged until the end.
  - Stop: partial row and status.
  - Retry without a duplicate owner row.
  - Error event and thrown error, with the text and code.
  - "Start stream → view hidden → shown → answer complete".
  - Queue at limit 3, plus cancel from the queue.
  - Context deleted mid-stream.
  - A DB write failure turns the turn into an error.
  - A memory store gives the same results without a DB.
- **Center.** Same instance per key, sweep releases only idle hidden engines, `dropContext`, `finishAllAsPartial`.
- **Reducer.** The `.text` / `.turnComplete` / `.reset` sequences that the 8 copies handle today.
- **Classifier.** Each mapping.
- **`postTurn` per surface.** Pure functions, with valid and malformed input.
- **Surface view-model tests.** Ported onto engine + spec in the PR that migrates the surface.

## 10. Delivery

| PR | Targets | Content |
|---|---|---|
| 1 | #170 | Spec + plan. Core: spec type, store, reducer, classifier, gate, engine, `.error` event, `LiveTurn.replaceText`. App target: center on `AppState`, `ChatFeedView` / `ChatComposerBar` extraction, optional row actions, `EmbeddedChatView` and its halves. The main chat moves onto the extracted pieces. No surface migrates yet. |
| 2 | #172, #173, #174 | Track, idea/decision and meeting move onto the component. They stop cutting streams on navigation. |
| 3 | #171 | Target moves onto the component (directives, Approve all, propose/execute, follow-up queue). |
| 4 | #175, #176, #177 | Onboarding and setup move. `MessageBubble` and `ChatInput` are deleted. App guide updated, backlog item closed. |

## 11. Known limits

- Action cards (`TargetActionCard`) stay in memory as today. A reloaded target chat shows the persisted notices, not the cards.
- The queue limit is shared by `TargetBriefCenter` runs, because they go through the target chat. A fourth concurrent brief waits.
- The warm session, attachments and the other main-chat features stay main-only (§1).
