# Question card in assistant chats — design

**Date:** 2026-10-02 · **Board:** #182 · **Status:** owner decisions recorded 2026-10-02; implementation started without a review round

When a request is genuinely ambiguous, the assistant can ask a structured question instead of plain text. The app renders it as a card the owner answers with a click, or with a free "Other" answer. The answer is sent as the owner's next message.

## Owner decisions

- **Mechanism:** a structured block in the model's reply, like `:::artifact`. It is not an MCP tool. It works on claude and codex because it is plain text in the reply.
- **Shape:**
  - 1–4 questions per card.
  - Each question has 2–4 options. Each option has a label and a description and may carry a "recommended" mark.
  - Each question is single-select or multi-select.
  - Every question always offers a free "Other" answer.
- **Fallback:** a block that is malformed or out of bounds is not a card. It stays in the reply as plain text.
- **Answering:** the answer goes out as the owner's next message.
- **Persistence:** an answered card shows the choice, and this survives restart and replay. Nothing new is stored: the card comes from the reply text, and its answers come from the owner message that follows it.
- **Coverage:** the card works in the main AI Chat and in every embedded chat, through the shared component (#170).
- **Teaching the model:**
  - The main chat learns the block from the Go-owned system prompt.
  - Embedded chats learn it from their own Swift-built prompts, using the same text.
  - The prompt says to use the card only for genuine ambiguity, not on every turn.

## Grammar

````
```watchtower-question
{"questions": [
  {"id": "scope", "question": "Which release should the summary cover?", "multi": false,
   "options": [
     {"label": "v0.11", "description": "The release being cut now", "recommended": true},
     {"label": "v0.10", "description": "The last shipped release"}
   ]}
]}
```
````

The fields:
- `questions`: 1–4 entries.
- `id`: optional. It defaults to the question's position.
- `question`: non-empty.
- `multi`: optional, default `false`.
- `options`: 2–4 entries, each with a non-empty `label` and an optional `description` and `recommended`.

Unknown keys are ignored. Only the last valid block of a reply becomes a card. The block is removed from the visible text.

While the reply streams, an open fence is hidden: there is no half-drawn JSON and no card until the reply completes.

## Answer message

The owner's answer is a plain owner message:

```
Answers:
- Which release should the summary cover? → v0.11
- Who is it for? → Other: the support team
```

Each question gets one line, `- <question> → <label>[, <label>…]`, or `Other: <text>`.

An answered card reads its selections back by parsing this text from the owner message that follows the reply. Matching is by question text, then by option label. If the owner typed something else instead, the card shows as answered with no selection highlighted. The owner's message itself is shown below the card, as with any message.

## Where it lives

| Piece | Where |
|---|---|
| Contract text (prompt) | `internal/chat/questions_contract.md`, embedded by Go `QuestionsContract()` and appended after the artifacts contract in `BuildSystemPrompt`. The Swift `ChatQuestionsContract.promptBlock` holds the same text, pinned by a Swift test that reads the `.md` file. |
| Parser + answer format | `WatchtowerCore/Services/Chat/ChatQuestionCard.swift`: `ChatQuestionParser.parse(_:final:)`, `ChatQuestionAnswer.format(_:)`, `ChatQuestionAnswer.selections(in:for:)`. |
| Card view | `Views/Chat/ChatQuestionCardView.swift`. It is rendered by `AssistantMessageBody`, so it appears in `ChatMessageRow` for both the main chat and every embedded chat. |
| Wiring | `ChatRowActions.answerQuestion: ((String) -> Void)?`. It is nil when answering is not possible: not the latest reply, or a turn is running. `ChatMessageRow.questionAnswer` holds the next owner message's text. The main chat sends through `ChatViewModel.send(text:)`, embedded chats through `EmbeddedChatEngine.send`. |
| Embedded prompts | Idea, meeting, track, target, onboarding and setup each append `ChatQuestionsContract.promptBlock` to their system prompt. |

## Limits

- No MCP tool: the turn ends after the card, and the owner's answer starts a new turn.
- The answer is only as structured as its text. If the owner retypes it by hand, the card cannot highlight the selection.
