# Question card in assistant chats — plan

**Spec:** `docs/superpowers/specs/2026-10-02-chat-question-card-design.md`.
**Delivery:** one PR. **Gate:** CI. Local Swift builds are paused on the lane, so Swift is verified by CI. Go is tested locally.

## Task 1: contract text (Go and Swift)

- **Files:** `internal/chat/questions_contract.md`, `internal/chat/questions_contract.go`, `internal/chat/prompt.go`, `internal/chat/prompt_test.go`.
- **Interface:** `func QuestionsContract() string`. `BuildSystemPrompt` appends it after `ArtifactsContract()`.
- **Tests:**
  - `TestQuestionsContract`: the text names the fence, the limits (1–4 questions, 2–4 options), "Other", and the "only for genuine ambiguity" rule.
  - The main prompt contains the contract.

## Task 2: Swift parser and answer format (Core)

- **Files:** `WatchtowerCore/Services/Chat/ChatQuestionCard.swift`, `Tests/Core/ChatQuestionCardTests.swift`, `Tests/Core/ChatQuestionsContractFixtureTests.swift`.
- **Interfaces:**
  - `ChatQuestionCard { questions: [ChatQuestion] }`
  - `ChatQuestion { id, question, multi, options: [ChatQuestionOption] }`
  - `ChatQuestionParser.parse(_ text: String, final: Bool) -> (text: String, card: ChatQuestionCard?)`
  - `ChatQuestionAnswer.format(_ answers: [ChatQuestionAnswer.Entry]) -> String`
  - `ChatQuestionAnswer.selections(in owner: String, for card: ChatQuestionCard) -> [String: ChatQuestionAnswer.Entry]`
  - `ChatQuestionsContract.promptBlock`
- **Tests:**
  - A valid block parses and is stripped from the text.
  - Malformed JSON, 0 or 5 questions, 1 or 5 options, or an empty label leave the text unchanged.
  - When there are several blocks, the last valid one wins.
  - An open fence while streaming is hidden.
  - `format` → `selections` round-trips, including multi-select and Other.
  - A hand-typed reply gives no selections.
  - The fixture test parses the example in the `.md` file, and `promptBlock` equals the `.md` text.

## Task 3: card view and row wiring

- **Files:**
  - `Views/Chat/ChatQuestionCardView.swift`
  - `Views/Chat/ChatMessageRow.swift` (`AssistantMessageBody`, `ChatRowActions.answerQuestion`, `ChatMessageRow.questionAnswer`)
  - `Views/Chat/ChatThreadView.swift`
  - `Views/Chat/Embedded/EmbeddedChatView.swift`
  - `Tests/ChatQuestionCardViewTests.swift`
- **Behaviour:**
  - The card renders under the reply's markdown.
  - Options are radio buttons for single-select and checkboxes for multi-select, with descriptions and a "Recommended" badge.
  - Each question has an Other text field.
  - Send is enabled once every question has an answer.
  - An answered card is disabled and highlights the parsed selections.
  - Answering is offered only on the latest reply while nothing streams.
- **Tests (ViewInspector):**
  - The card shows the options and the Recommended badge.
  - Picking an option and pressing Send calls `onAnswer` with the formatted text.
  - An answered card has no Send button.

## Task 4: embedded prompts and docs

- **Files:** the idea, meeting and track surfaces, the `TargetChatViewModel` prompt, the onboarding prompt, the setup prompts, `docs/app-guide.md`, and `docs/features/embedded-chat.md`.
- **Tests:** the existing prompt tests stay green. One assertion per surface family checks that the system prompt contains the `watchtower-question` contract.
