import Foundation

// Moved from WatchtowerCore (unified chat T3): the one question parser, shared with the phone.
// Go twin: internal/chat/questions.go; one fixture, internal/chat/testdata/question_parse_cases.json.

/// One option of a question card.
public struct ChatQuestionOption: Equatable, Sendable {
    public let label: String
    public let description: String
    public let recommended: Bool

    public init(label: String, description: String = "", recommended: Bool = false) {
        self.label = label
        self.description = description
        self.recommended = recommended
    }
}

/// One question of a card: 2–4 options, single or multi select; the card
/// always adds a free "Other" answer of its own.
public struct ChatQuestion: Equatable, Sendable, Identifiable {
    public let id: String
    public let question: String
    public let multi: Bool
    public let options: [ChatQuestionOption]

    public init(id: String, question: String, multi: Bool = false, options: [ChatQuestionOption]) {
        self.id = id
        self.question = question
        self.multi = multi
        self.options = options
    }
}

/// A ```watchtower-question block from an assistant reply (spec
/// 2026-10-02): 1–4 questions the owner answers with a click.
public struct ChatQuestionCard: Equatable, Sendable {
    public let questions: [ChatQuestion]

    public init(questions: [ChatQuestion]) {
        self.questions = questions
    }
}

/// Finds the question card in a reply. Only a block that decodes and stays
/// within the bounds becomes a card; anything else stays in the text as is
/// (the owner then reads it as plain text). While a reply streams, an open
/// block is hidden so no half-written JSON shows.
public enum ChatQuestionParser {
    public static let fence = "```watchtower-question"

    /// `final`: the reply is complete. Until then no card is shown and an
    /// unclosed block is hidden; once final, an unclosed block stays visible.
    /// When several blocks are valid, the last one is the card and the
    /// earlier ones stay in the text.
    public static func parse(_ text: String, final: Bool) -> (text: String, card: ChatQuestionCard?) {
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
    public static func readableText(_ text: String) -> String {
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
    /// when it does not decode or breaks a bound — the dual path with Go's
    /// `asks.Validate`, pinned by `internal/asks/testdata/cards`.
    public static func decodeCard(_ json: Data) -> ChatQuestionCard? {
        decode(json, allowsNoOptions: false)
    }

    /// An owner ask's stored questions: a card's bounds, except that a
    /// question may have no options — one Watchtower raised from the agent's
    /// terminal question, answered by a free reply only (spec 2026-10-10
    /// Part 3.5; Go stores it only with origin `chat`). Never one option.
    public static func decodeOwnerAskQuestions(_ json: Data) -> ChatQuestionCard? {
        decode(json, allowsNoOptions: true)
    }

    private static func decode(_ json: Data, allowsNoOptions: Bool) -> ChatQuestionCard? {
        guard let raw = try? JSONDecoder().decode(RawCard.self, from: json),
              (1...4).contains(raw.questions.count) else { return nil }
        var questions: [ChatQuestion] = []
        for (index, rawQuestion) in raw.questions.enumerated() {
            let question = rawQuestion.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let options = rawQuestion.options.map {
                ChatQuestionOption(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                                   description: $0.description, recommended: $0.recommended)
            }
            let optionCountOK = (2...4).contains(options.count) || (allowsNoOptions && options.isEmpty)
            guard !question.isEmpty, optionCountOK,
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
