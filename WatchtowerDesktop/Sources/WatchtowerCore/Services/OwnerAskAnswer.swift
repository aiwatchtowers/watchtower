import Foundation

/// `owner_asks.answer`: written by the Desktop, read by Go's `get_ask`
/// (`asks.Answer`). Every key is always written, so `encoded()` is the
/// canonical form `internal/asks/testdata/answers` pins byte for byte —
/// change both sides together.
package struct OwnerAskAnswer: Equatable, Sendable {
    package enum Verdict: String, Sendable {
        case approved, changes
    }

    package enum CheckState: String, Codable, Sendable {
        case ok, broken, skipped
    }

    /// The answer to one question: the picked labels and the free "Other".
    package struct QuestionAnswer: Codable, Equatable, Sendable {
        package var id: String
        package var labels: [String]
        package var other: String

        package init(id: String, labels: [String] = [], other: String = "") {
            self.id = id
            self.labels = labels
            self.other = other
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
            other = try c.decodeIfPresent(String.self, forKey: .other) ?? ""
        }
    }

    /// One check item's mark. An item the owner left unmarked is `skipped`.
    package struct CheckAnswer: Codable, Equatable, Sendable {
        package var id: String
        package var state: CheckState
        package var note: String

        package init(id: String, state: CheckState, note: String = "") {
            self.id = id
            self.state = state
            self.note = note
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            state = try c.decode(CheckState.self, forKey: .state)
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        }
    }

    /// A review comment, anchored on the ask's `doc_snapshot`.
    package struct Comment: Codable, Equatable, Sendable {
        package var quote: String
        package var prefix: String
        package var suffix: String
        package var heading: String
        package var body: String

        package init(anchor: CommentAnchor, body: String) {
            quote = anchor.quote
            prefix = anchor.prefix
            suffix = anchor.suffix
            heading = anchor.heading
            self.body = body
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
            prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
            suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
            heading = try c.decodeIfPresent(String.self, forKey: .heading) ?? ""
            body = try c.decode(String.self, forKey: .body)
        }
    }

    /// A review's verdict; nil on the other kinds (stored as "").
    package var verdict: Verdict?
    package var answers: [QuestionAnswer]
    package var checklist: [CheckAnswer]
    package var comments: [Comment]
    package var note: String

    package init(
        verdict: Verdict? = nil,
        answers: [QuestionAnswer] = [],
        checklist: [CheckAnswer] = [],
        comments: [Comment] = [],
        note: String = ""
    ) {
        self.verdict = verdict
        self.answers = answers
        self.checklist = checklist
        self.comments = comments
        self.note = note
    }

    /// The JSON stored in `owner_asks.answer`: sorted keys, no whitespace,
    /// slashes unescaped — what Go's `json.Marshal` of `asks.Answer` gives.
    package func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // JSONEncoder output is always UTF-8.
        return String(bytes: try encoder.encode(self), encoding: .utf8) ?? ""
    }

    /// A stored answer. Missing lists read as empty (Go's `ParseAnswer`).
    package static func decode(_ json: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}

extension OwnerAskAnswer: Codable {
    private enum CodingKeys: String, CodingKey {
        case verdict, answers, checklist, comments, note
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let verdictValue = try c.decodeIfPresent(String.self, forKey: .verdict) ?? ""
        if verdictValue.isEmpty {
            verdict = nil
        } else if let verdict = Verdict(rawValue: verdictValue) {
            self.verdict = verdict
        } else {
            throw DecodingError.dataCorruptedError(forKey: .verdict, in: c, debugDescription: "unknown verdict \(verdictValue)")
        }
        answers = try c.decodeIfPresent([QuestionAnswer].self, forKey: .answers) ?? []
        checklist = try c.decodeIfPresent([CheckAnswer].self, forKey: .checklist) ?? []
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(verdict?.rawValue ?? "", forKey: .verdict)
        try c.encode(answers, forKey: .answers)
        try c.encode(checklist, forKey: .checklist)
        try c.encode(comments, forKey: .comments)
        try c.encode(note, forKey: .note)
    }
}
