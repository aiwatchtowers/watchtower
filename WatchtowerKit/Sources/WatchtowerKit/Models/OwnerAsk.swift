import Foundation
import WatchtowerSync

/// The `owner_ask` slice (mobile POC spec §4.6), record name
/// `owner_ask-<owner_asks.id>`: something a workbench agent asked the owner
/// (a review of a document snapshot, a manual check or a question). Every
/// open ask is published, plus closed ones from the last 7 days.
public struct OwnerAsk: SliceMirror, Identifiable {
    public static let sliceKind = SliceKind.ownerAsk

    /// rawValues are wire format (`owner_asks.kind`).
    public struct Kind: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let review = Self(rawValue: "review")
        public static let check = Self(rawValue: "check")
        public static let question = Self(rawValue: "question")
        public static let knownValues: [Self] = [.review, .check, .question]
    }

    /// rawValues are wire format (`owner_asks.status`).
    public struct Status: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let open = Self(rawValue: "open")
        public static let answered = Self(rawValue: "answered")
        public static let delivered = Self(rawValue: "delivered")
        public static let withdrawn = Self(rawValue: "withdrawn")
        public static let knownValues: [Self] = [.open, .answered, .delivered, .withdrawn]
    }

    /// Why a withdrawn ask was withdrawn (`owner_asks.withdrawn_reason`);
    /// the key is absent on any other ask. rawValues are wire format.
    public struct WithdrawnReason: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let agent = Self(rawValue: "agent")
        /// A newer round of the same review replaced it (`previous_ask_id`).
        public static let superseded = Self(rawValue: "superseded")
        public static let knownValues: [Self] = [.agent, .superseded]
    }

    /// The one-tap answer the Mac computed: set only for a `question` ask
    /// with exactly one single-select question of 2–4 options, at least one
    /// recommended.
    public struct Quick: Codable, Hashable, Sendable {
        public struct Option: Codable, Hashable, Sendable {
            public let label: String
            public let recommended: Bool

            public init(label: String, recommended: Bool) {
                self.label = label
                self.recommended = recommended
            }
        }

        public let questionID: String
        public let options: [Option]

        public init(questionID: String, options: [Option]) {
            self.questionID = questionID
            self.options = options
        }

        enum CodingKeys: String, CodingKey {
            case questionID = "questionId"
            case options
        }
    }

    public let id: Int64
    public let workbenchID: Int64
    public let workbenchName: String
    /// The session that filed it; nil for an external terminal or a session
    /// deleted since.
    public let sessionID: Int64?
    public let targetID: Int64?
    public let kind: Kind
    public let status: Status
    /// nil unless withdrawn; a stored "" also reads as nil.
    public let withdrawnReason: WithdrawnReason?
    /// The ask this review round follows.
    public let previousAskID: Int64?
    public let createdAt: Date
    public let answeredAt: Date?
    public let deliveredAt: Date?
    /// Cap 200.
    public let title: String
    public let titleClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// Cap 4000.
    public let summary: String
    public let summaryClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// What changed since `previousAskID`. Cap 4000.
    public let changes: String
    public let changesClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// nil when it was over 64 KiB (`payloadClipped`): the phone then offers
    /// only "Open the ask on the Mac".
    public let payload: OwnerAskPayload?
    public let payloadClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The reviewed document's path, relative to the folder ("" unless a
    /// review). Cap 300.
    public let docPath: String
    public let docPathClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The reviewed document; open review asks only. At most 256 KiB, cut at
    /// the last newline before the cap (`docClipped`, full size `docBytes`).
    public let docSnapshot: String?
    public let docClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let docBytes: Int?
    /// The stored answer; closed asks only.
    public let answer: OwnerAskAnswer?
    public let quick: Quick?

    // convertFromSnakeCase maps "*_id" -> "*Id" (lowercase d).
    enum CodingKeys: String, CodingKey {
        case id
        case workbenchID = "workbenchId"
        case workbenchName
        case sessionID = "sessionId"
        case targetID = "targetId"
        case kind, status, withdrawnReason
        case previousAskID = "previousAskId"
        case createdAt, answeredAt, deliveredAt, title, titleClipped, summary, summaryClipped, changes, changesClipped
        case payload, payloadClipped, docPath, docPathClipped, docSnapshot, docClipped, docBytes, answer, quick
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        workbenchID = try c.decode(Int64.self, forKey: .workbenchID)
        workbenchName = try c.decode(String.self, forKey: .workbenchName)
        sessionID = try c.decodeIfPresent(Int64.self, forKey: .sessionID)
        targetID = try c.decodeIfPresent(Int64.self, forKey: .targetID)
        kind = try c.decode(Kind.self, forKey: .kind)
        status = try c.decode(Status.self, forKey: .status)
        // The DB's '' (not withdrawn) is no reason.
        withdrawnReason = try c.decodeIfPresent(WithdrawnReason.self, forKey: .withdrawnReason)
            .flatMap { $0.rawValue.isEmpty ? nil : $0 }
        previousAskID = try c.decodeIfPresent(Int64.self, forKey: .previousAskID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        answeredAt = try c.decodeIfPresent(Date.self, forKey: .answeredAt)
        deliveredAt = try c.decodeIfPresent(Date.self, forKey: .deliveredAt)
        title = try c.decode(String.self, forKey: .title)
        titleClipped = try c.decodeIfPresent(Bool.self, forKey: .titleClipped)
        summary = try c.decode(String.self, forKey: .summary)
        summaryClipped = try c.decodeIfPresent(Bool.self, forKey: .summaryClipped)
        changes = try c.decode(String.self, forKey: .changes)
        changesClipped = try c.decodeIfPresent(Bool.self, forKey: .changesClipped)
        payload = try c.decodeIfPresent(OwnerAskPayload.self, forKey: .payload)
        payloadClipped = try c.decodeIfPresent(Bool.self, forKey: .payloadClipped)
        docPath = try c.decode(String.self, forKey: .docPath)
        docPathClipped = try c.decodeIfPresent(Bool.self, forKey: .docPathClipped)
        docSnapshot = try c.decodeIfPresent(String.self, forKey: .docSnapshot)
        docClipped = try c.decodeIfPresent(Bool.self, forKey: .docClipped)
        docBytes = try c.decodeIfPresent(Int.self, forKey: .docBytes)
        answer = try c.decodeIfPresent(OwnerAskAnswer.self, forKey: .answer)
        quick = try c.decodeIfPresent(Quick.self, forKey: .quick)
    }
}

/// `owner_asks.payload`, as Go's `asks.Payload` stores it: what to look at,
/// the questions and the checklist. Go omits empty optional fields; a
/// missing question or check item id is its 1-based position, as Core's
/// `OwnerAskPayload` and Go read it.
public struct OwnerAskPayload: Decodable, Hashable, Sendable {
    /// What the agent wants looked at; on a review optionally tied to a
    /// heading or a quoted passage of the snapshot.
    public struct Focus: Hashable, Sendable {
        public let text: String
        public let heading: String
        public let quote: String

        public init(text: String, heading: String = "", quote: String = "") {
            self.text = text
            self.heading = heading
            self.quote = quote
        }
    }

    public struct Option: Hashable, Sendable {
        public let label: String
        public let description: String
        public let recommended: Bool

        public init(label: String, description: String = "", recommended: Bool = false) {
            self.label = label
            self.description = description
            self.recommended = recommended
        }
    }

    /// One question: 2–4 options, single or multi select; the owner may
    /// always answer with a free "Other" instead.
    public struct Question: Hashable, Sendable, Identifiable {
        public let id: String
        public let question: String
        public let multi: Bool
        public let options: [Option]

        public init(id: String, question: String, multi: Bool = false, options: [Option]) {
            self.id = id
            self.question = question
            self.multi = multi
            self.options = options
        }
    }

    public struct CheckItem: Hashable, Sendable, Identifiable {
        public let id: String
        public let text: String
        public let hint: String

        public init(id: String, text: String, hint: String = "") {
            self.id = id
            self.text = text
            self.hint = hint
        }
    }

    public let focus: [Focus]
    public let questions: [Question]
    public let checklist: [CheckItem]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focus = try (c.decodeIfPresent([RawFocus].self, forKey: .focus) ?? []).map {
            Focus(text: $0.text, heading: $0.heading ?? "", quote: $0.quote ?? "")
        }
        let rawQuestions = try c.decodeIfPresent([RawQuestion].self, forKey: .questions) ?? []
        questions = rawQuestions.enumerated().map { index, raw in
            Question(
                id: Self.resolvedID(raw.id, index: index),
                question: raw.question,
                multi: raw.multi ?? false,
                options: raw.options.map {
                    Option(label: $0.label, description: $0.description ?? "", recommended: $0.recommended ?? false)
                }
            )
        }
        let rawChecklist = try c.decodeIfPresent([RawCheckItem].self, forKey: .checklist) ?? []
        checklist = rawChecklist.enumerated().map { index, raw in
            CheckItem(id: Self.resolvedID(raw.id, index: index), text: raw.text, hint: raw.hint ?? "")
        }
    }

    private static func resolvedID(_ id: String?, index: Int) -> String {
        id.flatMap { $0.isEmpty ? nil : $0 } ?? String(index + 1)
    }

    private enum CodingKeys: String, CodingKey { case focus, questions, checklist }

    private struct RawFocus: Decodable {
        let text: String
        let heading: String?
        let quote: String?
    }

    private struct RawOption: Decodable {
        let label: String
        let description: String?
        let recommended: Bool? // swiftlint:disable:this discouraged_optional_boolean
    }

    private struct RawQuestion: Decodable {
        let id: String?
        let question: String
        let multi: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let options: [RawOption]
    }

    private struct RawCheckItem: Decodable {
        let id: String?
        let text: String
        let hint: String?
    }
}

/// `owner_asks.answer` (Core `OwnerAskAnswer`, Go `asks.Answer`): what the
/// phone sends in `ask_answer` and what a closed ask carries. Every key is
/// always written, so `encoded()` is the canonical form
/// `internal/asks/testdata/answers` pins byte for byte.
public struct OwnerAskAnswer: Codable, Hashable, Sendable {
    /// A review's verdict. rawValues are wire format.
    public struct Verdict: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let approved = Self(rawValue: "approved")
        public static let changes = Self(rawValue: "changes")
        public static let knownValues: [Self] = [.approved, .changes]
    }

    /// One check item's mark. rawValues are wire format.
    public struct CheckState: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let ok = Self(rawValue: "ok")
        public static let broken = Self(rawValue: "broken")
        public static let skipped = Self(rawValue: "skipped")
        public static let knownValues: [Self] = [.ok, .broken, .skipped]
    }

    /// The answer to one question: the picked labels and the free "Other".
    public struct QuestionAnswer: Codable, Hashable, Sendable {
        public var id: String
        public var labels: [String]
        public var other: String

        public init(id: String, labels: [String] = [], other: String = "") {
            self.id = id
            self.labels = labels
            self.other = other
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
            other = try c.decodeIfPresent(String.self, forKey: .other) ?? ""
        }
    }

    /// One check item's mark and note.
    public struct CheckAnswer: Codable, Hashable, Sendable {
        public var id: String
        public var state: CheckState
        public var note: String

        public init(id: String, state: CheckState, note: String = "") {
            self.id = id
            self.state = state
            self.note = note
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            state = try c.decode(CheckState.self, forKey: .state)
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        }
    }

    /// A review comment, anchored on the ask's `doc_snapshot`.
    public struct Comment: Codable, Hashable, Sendable {
        public var quote: String
        public var prefix: String
        public var suffix: String
        public var heading: String
        public var body: String

        public init(quote: String, prefix: String, suffix: String, heading: String, body: String) {
            self.quote = quote
            self.prefix = prefix
            self.suffix = suffix
            self.heading = heading
            self.body = body
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
            prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
            suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
            heading = try c.decodeIfPresent(String.self, forKey: .heading) ?? ""
            body = try c.decode(String.self, forKey: .body)
        }
    }

    /// A review's verdict; nil on the other kinds (written as "").
    public var verdict: Verdict?
    public var answers: [QuestionAnswer]
    public var checklist: [CheckAnswer]
    public var comments: [Comment]
    public var note: String

    public init(
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

    /// The canonical JSON: sorted keys, no whitespace, slashes unescaped —
    /// what Go's `json.Marshal` of `asks.Answer` gives.
    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // JSONEncoder output is always UTF-8.
        return String(bytes: try encoder.encode(self), encoding: .utf8) ?? ""
    }

    /// A stored answer. Missing lists read as empty (Go's `ParseAnswer`).
    public static func decode(_ json: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    private enum CodingKeys: String, CodingKey {
        case verdict, answers, checklist, comments, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let verdictValue = try c.decodeIfPresent(String.self, forKey: .verdict) ?? ""
        verdict = verdictValue.isEmpty ? nil : Verdict(rawValue: verdictValue)
        answers = try c.decodeIfPresent([QuestionAnswer].self, forKey: .answers) ?? []
        checklist = try c.decodeIfPresent([CheckAnswer].self, forKey: .checklist) ?? []
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(verdict?.rawValue ?? "", forKey: .verdict)
        try c.encode(answers, forKey: .answers)
        try c.encode(checklist, forKey: .checklist)
        try c.encode(comments, forKey: .comments)
        try c.encode(note, forKey: .note)
    }
}
