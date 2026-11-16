import Foundation
import WatchtowerChatText

/// Which reply's card can be answered, and what answered it — over the
/// rows of a thread (main chat or embedded), oldest first.
package enum ChatQuestionThread {
    /// The owner's words right after the reply at `index`, if any.
    package static func ownerReply(after index: Int, in messages: [ChatMessageRecord]) -> String? {
        guard messages.indices.contains(index), messages[index].isAssistant else { return nil }
        return messages[(index + 1)...].first { $0.isUser }?.text
    }

    /// A card is answerable on the latest reply that nothing has answered
    /// yet, while no turn runs (system notices after it do not count).
    package static func isAnswerable(at index: Int, in messages: [ChatMessageRecord], busy: Bool) -> Bool {
        guard !busy, messages.indices.contains(index), messages[index].isAssistant else { return false }
        return messages.lastIndex { $0.isAssistant } == index && ownerReply(after: index, in: messages) == nil
    }
}

/// `ChatQuestionThread` for every row of one render pass: the thread's rows
/// and their positions built once, so a row's look-ups are not a map and a
/// scan of the whole thread each (`EmbeddedChatRows`, `ChatThreadView`).
package struct ChatThreadIndex {
    private let rows: [ChatMessageRecord]
    private let positions: [Int64: Int]
    private let lastAssistant: Int?

    package init(_ rows: [ChatMessageRecord]) {
        self.rows = rows
        positions = Dictionary(rows.enumerated().map { ($1.id, $0) }) { first, _ in first }
        lastAssistant = rows.lastIndex { $0.isAssistant }
    }

    package var lastAssistantID: Int64? { lastAssistant.map { rows[$0].id } }

    package func isAnswerable(_ id: Int64, busy: Bool) -> Bool {
        guard let index = positions[id], index == lastAssistant else { return false }
        return ChatQuestionThread.isAnswerable(at: index, in: rows, busy: busy)
    }

    package func ownerReply(after id: Int64) -> String? {
        positions[id].flatMap { ChatQuestionThread.ownerReply(after: $0, in: rows) }
    }
}

// swiftlint:disable line_length
/// The prompt text that teaches the card — the same text as Go's
/// `internal/chat/questions_contract.md` (pinned by
/// `ChatQuestionsContractFixtureTests`), appended by the embedded chats'
/// Swift-built system prompts.
package enum ChatQuestionsContract {
    package static let promptBlock = #"""
=== QUESTIONS ===
When the owner's request is genuinely ambiguous — two or more reasonable readings that lead to different answers, and you cannot settle it from the data — you may ask ONE structured question card instead of guessing. The app shows it as a card the owner answers with a click; their choice comes back as their next message. Do not use it for small talk, for confirmations, or on every turn: when a sensible default exists, state it and go ahead.

Syntax: a fenced block on its own lines, holding JSON, at the END of your reply after a one-line lead-in:
```watchtower-question
{"questions": [
  {"id": "scope", "question": "Which release should the summary cover?", "multi": false,
   "options": [
     {"label": "v0.11", "description": "The release being cut now", "recommended": true},
     {"label": "v0.10", "description": "The last shipped release"}
   ]}
]}
```
- 1 to 4 questions; each with 2 to 4 options. Every option has a short "label" and a one-line "description"; mark at most one option per question "recommended": true.
- "multi": true lets the owner pick several options; the default is one.
- Do not add an "Other" option: the card always offers a free answer.
- Write the questions and options in the owner's language. Use only valid JSON (double quotes, no comments).
- After the card, stop and wait: the owner's answer arrives as "Answers:" followed by one line per question.
"""#
}
// swiftlint:enable line_length
