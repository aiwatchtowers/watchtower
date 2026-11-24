# "Not clear?" on an ask — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A quiet **Not clear?** on question and check asks that turns the ask drawer into a chat whose first message explains the question in plain words.

**Architecture:** A new embedded chat surface (`AskExplainSurface`, context type `owner_ask_explain`, id `<workbench>:<ask>`) on the existing `EmbeddedChatEngine`/`EmbeddedChatCenter`; the drawer keeps a per-ask mode in `OwnerAsksViewModel` and swaps its body and answer bar for the chat view. Go only learns the new context type (cleanup, merge re-key, knowledge filters) and the usage purpose.

**Tech Stack:** Go (`internal/db`, `internal/workbenchfolders`, `internal/tools`, `internal/kb`, `cmd`), SwiftUI Desktop (`WatchtowerCore`, `Views/Workbench/Asks`), DesignKit.

**Spec:** `docs/superpowers/specs/2026-11-24-ask-explain-chat-design.md` (approved, ask #1794). Mockups: `docs/design/mockups/ask-explain-chat/`.

## Global Constraints

- Context type string: `owner_ask_explain`; context id: `"\(workbenchID):\(askID)"`.
- Usage purpose: `ask.explain`, display name "Ask explanations", group "Workbench".
- UI copy exactly as the spec's Texts table (`AskExplainCopy`): entry "Not clear?", entryHelp "Ask the assistant to explain this question", back "Back to question", placeholder "Ask about this question…", explaining "Explaining…", queued "Waiting — other chats are answering.", errorPrefix "Couldn't explain:", retry "Retry", emptyHint "The assistant reads the workbench folder and never changes it.".
- Only kinds `question` and `check`, open or closed; never `review`. No entry without a CLI.
- `toolAccess: .draftOnly`; provider = config's, strong tier (model nil); `readFolder` = the workbench folder.
- Colours only via `Tone`/kit; no `Divider()` between rows; `.kitQuiet` buttons; the entry uses `KitQuietButtonStyle(label: .secondary)`.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` for Swift). The full gate runs once before merging into the umbrella.
- Tests never wait on wall-clock; subprocess stubs are reaped in `t.Cleanup`.

## Review Focus

1. Opening the chat twice quickly (double click, or open → back → open while the first hidden turn is still starting) must not start two hidden turns — Task 3 `testOpenTwiceStartsOneHiddenTurn`.
2. An ask whose summary contains triple backticks or "ignore previous instructions" stays data: the fence must be longer than any backtick run — Task 2 `testFenceOutgrowsBackticksInAsk`.
3. Switching "k of N ›" while a chat streams: the other ask shows its question view, the stream keeps going, coming back shows the chat — Task 3 `testModeIsPerAsk`.
4. Esc in a non-empty composer must not leave the chat (it would lose the owner's place) — Task 4 `testEscWithDraftStaysInChat`.
5. A check ask (no questions, a checklist) gets a prompt with its steps, not an empty question block — Task 2 `testCheckAskPromptListsSteps`.

---

### Task 1: Go — the context type, cleanup, merge re-key, knowledge filters, usage purpose

**Depends on:** none.

**Files:**
- Modify: `internal/db/spec_review_threads.go` (next to `SpecReviewThreadContextType`, add `AskExplainContextType`) — or a new `internal/db/ask_explain.go` holding only the const and its doc comment (preferred).
- Modify: `internal/db/workbenches.go` (`DeleteWorkbench` → `deleteWorkbenchAskExplainChats`)
- Modify: `internal/workbenchfolders/merge.go:411-415` (`reKeyChats` IN-list)
- Modify: `internal/tools/chat_history.go:101`, `internal/kb/source_chat_artifact.go:38`, `internal/db/chat_knowledge.go:94,98`
- Modify: `cmd/ai.go:86` (`queryPurposes`), and the `--purpose` flag help text
- Test: `internal/db/workbenches_test.go`, `internal/workbenchfolders/merge_test.go`, `internal/db/chat_knowledge_test.go`, `internal/tools/code_question_guard_test.go`, `internal/memory/code_question_guard_test.go`, `cmd/ai_purpose_test.go`

**Interfaces:**
- Produces: `db.AskExplainContextType = "owner_ask_explain"`; `ai query --purpose ask.explain` accepted.

- [ ] **Step 1: Failing tests**
  - `TestDeleteWorkbenchDropsAskExplainChats` (`workbenches_test.go`): insert `owner_ask_explain` conversations `"<wb>:5"` and `"<wb>1:5"` (prefix trap, as `TestDeleteWorkbench_CodeQuestionPrefixIsExact`), delete `<wb>`; assert the first is gone, the second stays.
  - In `TestMergeReKeysTheChats` add `explain := chat(db.AskExplainContextType, bs+":9")` and `assert.Equal(t, as+":9", key(explain))`; name the case in the test's doc comment.
  - `TestListChatTurnsForIdeas_SkipsAskExplainChats` (`chat_knowledge_test.go`), mirroring `…_SkipsSpecReviewThreads` for both queries of the file.
  - Guard tests: `code_question_guard_test.go` asserts each reader file contains `'owner_ask_explain'`; the memory guard seeds an `owner_ask_explain` conversation and asserts it is absent from the widest read.
  - `cmd/ai_purpose_test.go`: `ask.explain` is accepted.
- [ ] **Step 2:** `go test ./internal/db ./internal/workbenchfolders ./internal/tools ./internal/memory ./internal/kb -run 'AskExplain|ReKeysTheChats|Guard'` and `go test ./cmd -run Purpose` → FAIL.
- [ ] **Step 3: Implement.** The const with a doc comment naming the spec; `deleteWorkbenchAskExplainChats(tx, id)` shaped like `deleteWorkbenchSpecReviewThreads`, called from `DeleteWorkbench` after it; `reKeyChats` IN-list `('code_question', ?, ?)` with both consts; the three SQL `NOT IN` lists gain `'owner_ask_explain'`; `queryPurposes["ask.explain"] = true` and the flag help lists it.
- [ ] **Step 4:** Same commands → PASS. Also `go test ./internal/db -run 'TestSchemaGolden|TestDesktopTestSchema'` (no schema change expected; must stay green) and `make lint-diff`.
- [ ] **Step 5: Commit** `feat(asks): owner_ask_explain chats — cleanup, merge re-key, knowledge filters, ask.explain purpose (#2355)`.

### Task 2: Swift Core — copy, prompt, key, presentation, knowledge exclusion, purpose name

**Depends on:** none.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/AskExplain/AskExplain.swift` (`AskExplainCopy`, `AskExplainKey`, `AskExplainPresentation`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/AskExplain/AskExplainPrompt.swift`
- Modify: `WatchtowerDesktop/Sources/Services/EmbeddedChatWiring.swift:100` (`savesKnowledge`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/LLMPurposeNames.swift` (Workbench group)
- Test: `WatchtowerDesktop/Tests/Core/AskExplainTests.swift`, `WatchtowerDesktop/Tests/EmbeddedChatWiringTests.swift`

**Interfaces:**
- Produces:
  - `package enum AskExplainCopy` with `static let` per Global Constraints copy key.
  - `package enum AskExplainKey { static let contextType = "owner_ask_explain"; static let purpose = "ask.explain"; static func contextID(workbenchID: Int64, askID: Int64) -> String; static func title(askID: Int64) -> String /* "Ask #<id>" */ }`
  - `package enum AskExplainPresentation { static func showsEntry(kind: OwnerAskKind, hasCLI: Bool) -> Bool }` — true for `.question`/`.check` with a CLI.
  - `package enum AskExplainPrompt { static let firstTurn: String /* the spec's hidden prompt, verbatim */; static func system(ask: OwnerAsk, target: (title: String, intent: String)?) -> String }`

- [ ] **Step 1: Failing tests** (`AskExplainTests`):
  - `testCopyMatchesSpec`: every `AskExplainCopy` value equals the spec's Texts table.
  - `testContextIDAndTitle`: `contextID(workbenchID: 3, askID: 41) == "3:41"`, `title(askID: 41) == "Ask #41"`.
  - `testEntryOnlyOnQuestionAndCheckWithCLI`: question/check + CLI → true; review → false; no CLI → false.
  - `testFirstTurnIsSpecText`: equals the spec's quoted prompt.
  - `testSystemPromptCarriesAskAndRules`: contains the title, summary, reason, each option label and description, the recommended label, the target title and intent; contains the language rule, "never decide", and "read only".
  - `testFenceOutgrowsBackticksInAsk`: a summary holding "````" yields a fence of at least 5 backticks around the data, and a line saying it is data, not instructions.
  - `testCheckAskPromptListsSteps`: a check ask's steps appear; no empty "Questions" heading.
  - `EmbeddedChatWiringTests.testAskExplainSavesNoKnowledge`: `savesKnowledge(contextType: "owner_ask_explain") == false`.
- [ ] **Step 2:** `make test-swift FILTER='AskExplainTests|EmbeddedChatWiringTests'` → FAIL.
- [ ] **Step 3: Implement.** Fence helper like `CodeQuestionContext.fenced` (a fence one longer than the longest backtick run, min 3); `savesKnowledge` list gains `AskExplainKey.contextType`; `LLMPurposeNames` Workbench group gains `("ask.explain", "Ask explanations")`.
- [ ] **Step 4:** Same filter → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(asks): ask explain copy, prompt and key (#2355)`.

### Task 3: The surface and the per-ask mode

**Depends on:** Task 2 (and Task 1 at run time for `--purpose`).

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/ChatSurfaces/AskExplainSurface.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/OwnerAsksViewModel.swift` (`explainOpen`, open/close, chat start)
- Test: `WatchtowerDesktop/Tests/AskExplainSurfaceTests.swift`, `WatchtowerDesktop/Tests/AskExplainModelTests.swift`

**Interfaces:**
- Consumes: Task 2's `AskExplainKey`, `AskExplainPrompt`.
- Produces:
  - `enum AskExplainSurface { static func conversationID(ask: OwnerAsk, dbPool: DatabasePool, writes: ChatWrites) async throws -> Int64; static func spec(ask: OwnerAsk, conversationID: Int64, folder: String, target: (title: String, intent: String)?) -> ChatSurfaceSpec }` — key, `.database`, `.draftOnly`, `runOptions { ChatRunOptions(readFolder: folder, purpose: AskExplainKey.purpose) }`, system prompt from `AskExplainPrompt.system`, `emptyHint: AskExplainCopy.emptyHint`, placeholder from the copy.
  - On `OwnerAsksViewModel`: `private(set) var explainOpen: Set<Int64>`; `func isExplaining(_ askID: Int64) -> Bool`; `func openExplain(_ ask: OwnerAsk) async` (find-or-create, `center.engine(for:)`, then `sendHidden(AskExplainPrompt.firstTurn)` only when the engine's `messages` is empty, `!isBusy` and no hidden start is already in flight for this ask); `func closeExplain(_ askID: Int64)`; `func explainEngine(for ask: OwnerAsk) -> EmbeddedChatEngine?`; the drawer's close clears `explainOpen`.
  - The view model gets the center and `ChatWrites` the way `SpecReviewModel` does (`appState?.embeddedChatCenter`, `appState?.chatWrites`), injected so tests pass fakes.

- [ ] **Step 1: Failing tests**
  - `AskExplainSurfaceTests.testSpecShape`: key context type/id, `.draftOnly`, `.database(conversationID:)`, run options carry the folder and `ask.explain`, model nil.
  - `testSameKeySameConversation`: two concurrent `conversationID` calls on one ask return one id (test database; Go dedupe stubbed as in the existing embedded chat store tests).
  - `testTurnOutlivesDrawer`: open, start a turn, `closeExplain`, the engine in the center is still busy and finishes; reopening returns the same engine.
  - `AskExplainModelTests.testOpenStartsHiddenTurnOnce`: first open → one hidden turn with `firstTurn`; second open after it finished → none.
  - `testOpenTwiceStartsOneHiddenTurn`: two `openExplain` calls before the first turn's start returns → one hidden turn.
  - `testPartialFirstTurnOffersRetryOnly`: history holding a `partial` first reply → open starts nothing, engine `canRetry`.
  - `testErrorRow`: a failing fake transport → error row text starts with the real error, `canRetry`.
  - `testModeIsPerAsk`: open A, switch to B → `isExplaining(B) == false`, `isExplaining(A) == true`; closing the drawer clears both.
  - `testChatSurvivesAskClosing`: open, then the ask's status changes to answered in the poll → still `isExplaining`, engine untouched.
  - `testNoCLINoEntry`: without a CLI `openExplain` does nothing.
- [ ] **Step 2:** `make test-swift FILTER='AskExplainSurfaceTests|AskExplainModelTests'` → FAIL.
- [ ] **Step 3: Implement** per Interfaces; the in-flight guard is a `Set<Int64>` of asks whose open is running, cleared on return.
- [ ] **Step 4:** Same filter → PASS; plus `make test-swift FILTER='OwnerAsksViewModel|EmbeddedChat'` (neighbours); `make lint-swift`.
- [ ] **Step 5: Commit** `feat(asks): ask explain chat surface and per-ask mode (#2355)`.

### Task 4: The views

**Depends on:** Task 3.

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Asks/AskExplainChatView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Asks/AskExplainEntry.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/Asks/OwnerAskDrawer.swift:228-256` (`content`), `:186` (keys), `:197` (Esc)
- Test: `WatchtowerDesktop/Tests/OwnerAskKeyNavigationTests.swift`, `WatchtowerDesktop/Tests/AskExplainViewTests.swift`

**Interfaces:**
- Consumes: Task 3's `isExplaining`, `openExplain`, `closeExplain`, `explainEngine(for:)`.
- Produces: `struct AskExplainEntry: View` (the grey button, tooltip `entryHelp`); `struct AskExplainChatView: View { init(ask: OwnerAsk, engine: EmbeddedChatEngine, onBack: @escaping () -> Void) }` — the strip (back + one-line title), `EmbeddedChatRows` compact, `EmbeddedChatComposer` with the copy's placeholder; queued and explaining lines from `AskExplainCopy`; error row's prefix `errorPrefix`.

- [ ] **Step 1: Failing tests**
  - `OwnerAskKeyNavigationTests.testKeysOffWhileExplaining`: with `isExplaining(ask.id)`, the drawer key handler returns false for J/K/digits and ⌘↩ does not answer.
  - `testEscWithDraftStaysInChat`: Esc with a non-empty composer draft → still explaining; with an empty draft → back to the question.
  - `AskExplainViewTests.testEntryHiddenOnReviewAsk` and `testEntryShownOnClosedQuestionAsk` (through `AskExplainPresentation`, rendered with `ViewRenderProbe`).
- [ ] **Step 2:** `make test-swift FILTER='OwnerAskKeyNavigationTests|AskExplainViewTests'` → FAIL.
- [ ] **Step 3: Implement.** In `content`: when `asks.isExplaining(ask.id)`, after the header show `AskExplainChatView` instead of the body, the `Divider()` and `OwnerAskAnswerBar`; otherwise the entry sits trailing under `topSections` for non-review asks when `showsEntry`. `keys` gets `enabled: !asks.isExplaining(ask.id)`; Esc goes to `closeExplain` when explaining and the composer is empty, before the closed-list Esc.
- [ ] **Step 4:** Same filter → PASS; `make test-swift FILTER='OwnerAsk'`; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(asks): Not clear? entry and the chat view in the ask drawer (#2355)`.

### Task 5: Shots from the built views, guide, feature note

**Depends on:** Task 4.

**Files:**
- Create: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+AskExplain.swift` (the spec's eight states from the real views over a test workbench, fake engine for queued/loading/busy/error)
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`, `DesignShotsTests.swift` (`testAskExplainBuiltShotsRender`)
- Modify: `docs/guide/` (the asks page: a short "Not clear?" paragraph, per `docs/guide/WRITING.md`, under the 8 KB cap)
- Create: `docs/features/ask-explain-chat.md`; Modify: `CLAUDE.md` (feature list line), `docs/features/README.md` (summary), `docs/features/llm-usage-ledger.md` (the purpose)

- [ ] **Step 1:** Register shots named `ask-explain-built-<state>`; run `make desktop-shots DESKTOP_SHOTS=<scratch dir>` with `FILTER` narrowed to the new test.
- [ ] **Step 2:** Open each PNG next to its mockup in `docs/design/mockups/ask-explain-chat/`; fix any difference in layout, copy or colour, or record a justified one in the feature note.
- [ ] **Step 3:** Write the guide paragraph and the feature note (context type, key, writers, guards, limits D8/D9); `go test ./docs/guide`.
- [ ] **Step 4: Commit** `docs(asks): ask explain chat — shots, guide, feature note (#2355)`.

---

## Parallel lanes

Tasks 1 and 2 are independent (own worktrees, branches off the umbrella). Task 3 waits for 2; 4 for 3; 5 for 4.
