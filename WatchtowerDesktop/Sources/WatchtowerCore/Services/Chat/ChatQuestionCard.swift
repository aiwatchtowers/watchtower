import Foundation

/// One option of a question card.
package struct ChatQuestionOption: Equatable, Sendable {
    package let label: String
    package let description: String
    package let recommended: Bool

    package init(label: String, description: String = "", recommended: Bool = false) {
        self.label = label
        self.description = description
        self.recommended = recommended
    }
}

/// One question of a card: 2–4 options, single or multi select; the card
/// always adds a free "Other" answer of its own.
package struct ChatQuestion: Equatable, Sendable, Identifiable {
    package let id: String
    package let question: String
    package let multi: Bool
    package let options: [ChatQuestionOption]

    package init(id: String, question: String, multi: Bool = false, options: [ChatQuestionOption]) {
        self.id = id
        self.question = question
        self.multi = multi
        self.options = options
    }
}

/// A ```watchtower-question block from an assistant reply (spec
/// 2026-10-02): 1–4 questions the owner answers with a click.
package struct ChatQuestionCard: Equatable, Sendable {
    package let questions: [ChatQuestion]

    package init(questions: [ChatQuestion]) {
        self.questions = questions
    }
}

/// Finds the question card in a reply. Only a block that decodes and stays
/// within the bounds becomes a card; anything else stays in the text as is
/// (the owner then reads it as plain text). While a reply streams, an open
/// block is hidden so no half-written JSON shows.
package enum ChatQuestionParser {
    package static let fence = "```watchtower-question"

    /// `final`: the reply is complete. Until then no card is shown and an
    /// unclosed block is hidden; once final, an unclosed block stays visible.
    /// When several blocks are valid, the last one is the card and the
    /// earlier ones stay in the text.
    package static func parse(_ text: String, final: Bool) -> (text: String, card: ChatQuestionCard?) {
        guard text.contains(fence) else { return (text, nil) }
        var removals: [Range<String.Index>] = []
        var card: ChatQuestionCard?
        var cardRange: Range<String.Index>?
        var cursor = text.startIndex
        while let open = text.range(of: fence, range: cursor..<text.endIndex) {
            cursor = open.upperBound
            guard open.lowerBound == text.startIndex || text[text.index(before: open.lowerBound)] == "\n" else {
                continue
            }
            guard let lineEnd = text[open.upperBound...].firstIndex(of: "\n"),
                  let close = closingFence(in: text, from: lineEnd) else {
                if !final { removals.append(open.lowerBound..<text.endIndex) }
                break
            }
            let body = close.lowerBound > lineEnd ? String(text[text.index(after: lineEnd)..<close.lowerBound]) : ""
            cursor = close.upperBound
            if let decoded = decodeCard(Data(body.utf8)) {
                card = decoded
                cardRange = open.lowerBound..<close.upperBound
            }
        }
        if let cardRange { removals.append(cardRange) }
        removals.sort { $0.lowerBound < $1.lowerBound }
        if !final { card = nil }
        guard !removals.isEmpty else { return (text, card) }
        // Rebuilt from slices of the original, so every range stays valid.
        var visible = ""
        var kept = text.startIndex
        for range in removals {
            visible += text[kept..<range.lowerBound]
            kept = range.upperBound
        }
        visible += text[kept...]
        return (visible.trimmingCharacters(in: .whitespacesAndNewlines), card)
    }

    /// A finished reply as a person reads it — what Copy and Quote take: the
    /// prose, then the card's questions and options as plain lines instead
    /// of the raw JSON block.
    package static func readableText(_ text: String) -> String {
        let parsed = parse(text, final: true)
        guard let card = parsed.card else { return parsed.text }
        let questions = card.questions.map { question in
            ([question.question] + question.options.map { "- \($0.label)\($0.recommended ? " (recommended)" : "")" })
                .joined(separator: "\n")
        }
        return ([parsed.text].filter { !$0.isEmpty } + questions).joined(separator: "\n\n")
    }

    /// The line that is exactly ``` after `start` (a newline); its range
    /// covers the leading newline and the fence.
    private static func closingFence(in text: String, from start: String.Index) -> Range<String.Index>? {
        var cursor = start
        while let found = text.range(of: "\n```", range: cursor..<text.endIndex) {
            if found.upperBound == text.endIndex || text[found.upperBound] == "\n" { return found }
            cursor = found.upperBound
        }
        return nil
    }

    private struct RawCard: Decodable {
        let questions: [RawQuestion]
    }

    private struct RawQuestion: Decodable {
        let id: String?
        let question: String
        let multi: Bool
        let options: [RawOption]

        enum CodingKeys: String, CodingKey { case id, question, multi, options }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            question = try c.decode(String.self, forKey: .question)
            multi = try c.decodeIfPresent(Bool.self, forKey: .multi) ?? false
            options = try c.decode([RawOption].self, forKey: .options)
        }
    }

    private struct RawOption: Decodable {
        let label: String
        let description: String
        let recommended: Bool

        enum CodingKeys: String, CodingKey { case label, description, recommended }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        }
    }

    /// A card body (`{"questions": [...]}`, unknown keys ignored), or nil
    /// when it does not decode or breaks a bound. Also the decoder of an
    /// owner ask's stored questions — the dual path with Go's
    /// `asks.Validate`, pinned by `internal/asks/testdata/cards`.
    package static func decodeCard(_ json: Data) -> ChatQuestionCard? {
        guard let raw = try? JSONDecoder().decode(RawCard.self, from: json),
              (1...4).contains(raw.questions.count) else { return nil }
        var questions: [ChatQuestion] = []
        for (index, rawQuestion) in raw.questions.enumerated() {
            let question = rawQuestion.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let options = rawQuestion.options.map {
                ChatQuestionOption(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                                   description: $0.description, recommended: $0.recommended)
            }
            guard !question.isEmpty, (2...4).contains(options.count),
                  options.allSatisfy({ !$0.label.isEmpty }) else { return nil }
            let id = rawQuestion.id.flatMap { $0.isEmpty ? nil : $0 } ?? String(index + 1)
            // Ids and labels key the card's state: duplicates make it no card.
            guard Set(options.map(\.label)).count == options.count,
                  !questions.contains(where: { $0.id == id }) else { return nil }
            questions.append(ChatQuestion(id: id, question: question, multi: rawQuestion.multi, options: options))
        }
        return ChatQuestionCard(questions: questions)
    }
}

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

/// The owner's answer to a card, as their next message — and back: an
/// answered card reads its selections from that message (nothing else is
/// stored, so it survives restart and replay).
package enum ChatQuestionAnswer {
    package static let header = "Answers:"
    private static let arrow = " → "
    private static let otherPrefix = "Other: "

    package struct Entry: Equatable, Sendable {
        package var labels: [String]
        package var other: String?

        package init(labels: [String] = [], other: String? = nil) {
            self.labels = labels
            self.other = other
        }

        package var isEmpty: Bool {
            labels.isEmpty && (other?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    /// "Answers:" then one line per question: `- <question> → <labels>` with
    /// `Other: <text>` last (its line breaks as spaces).
    package static func format(_ card: ChatQuestionCard, answers: [String: Entry]) -> String {
        let lines = card.questions.map { question -> String in
            let entry = answers[question.id] ?? Entry()
            var parts = entry.labels
            if let other = entry.other?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
                // A multi-line answer stays on its question's line: the
                // read-back finds each answer by its line.
                parts.append(otherPrefix + other.split(whereSeparator: \.isNewline).joined(separator: " "))
            }
            return "- \(question.question)\(arrow)\(parts.joined(separator: ", "))"
        }
        return ([header] + lines).joined(separator: "\n")
    }

    /// The selections an owner message carries for `card`; empty when the
    /// message is not an answer in this format.
    package static func selections(in owner: String, for card: ChatQuestionCard) -> [String: Entry] {
        let lines = owner.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == header else { return [:] }
        var result: [String: Entry] = [:]
        for question in card.questions {
            let prefix = "- \(question.question)\(arrow)"
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { continue }
            let value = String(line.dropFirst(prefix.count))
            var choices = value
            var other: String?
            if let range = value.range(of: otherPrefix) {
                other = String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                choices = String(value[..<range.lowerBound])
            }
            // Matched against the known labels, not split: a label may hold ", ".
            let padded = ", " + choices.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",")) + ", "
            let labels = question.options.map(\.label).filter { padded.contains(", \($0), ") }
            result[question.id] = Entry(labels: labels, other: other)
        }
        return result
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
