import Foundation
import GRDB

package enum OwnerAskKind: String, Codable, CaseIterable, Sendable {
    case review, check, question
}

/// `open` → `answered` is the Desktop's only write; Go writes the rest
/// (spec 2026-10-03 Part 2, "Writers").
package enum OwnerAskStatus: String, Codable, CaseIterable, Sendable {
    case open, answered, delivered, withdrawn
}

/// One `focus` item: what the agent wants looked at, on a review optionally
/// tied to a heading or a quoted passage of the snapshot.
package struct OwnerAskFocus: Equatable, Sendable {
    package let text: String
    package let heading: String
    package let quote: String

    package init(text: String, heading: String = "", quote: String = "") {
        self.text = text
        self.heading = heading
        self.quote = quote
    }
}

/// One item of a `check` ask's checklist.
package struct OwnerAskCheckItem: Identifiable, Equatable, Sendable {
    package let id: String
    package let text: String
    package let hint: String

    package init(id: String, text: String, hint: String = "") {
        self.id = id
        self.text = text
        self.hint = hint
    }
}

/// `owner_asks.payload`, as Go's `asks.Payload` stores it. Go omits empty
/// optional fields; the questions decode through `ChatQuestionParser`, the
/// card the owner answers them with.
package struct OwnerAskPayload: Equatable, Sendable {
    package let focus: [OwnerAskFocus]
    package let questions: [ChatQuestion]
    package let checklist: [OwnerAskCheckItem]

    package init(focus: [OwnerAskFocus] = [], questions: [ChatQuestion] = [], checklist: [OwnerAskCheckItem] = []) {
        self.focus = focus
        self.questions = questions
        self.checklist = checklist
    }

    package static func decode(_ json: String) throws -> Self {
        let data = Data(json.utf8)
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        var questions: [ChatQuestion] = []
        if raw.questions > 0 {
            // Go validated them on `ask_owner`; a card Swift refuses is a
            // broken row, not an ask without questions.
            guard let card = ChatQuestionParser.decodeCard(data) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "payload questions are not a valid card"))
            }
            questions = card.questions
        }
        return Self(
            focus: raw.focus.map { OwnerAskFocus(text: $0.text, heading: $0.heading ?? "", quote: $0.quote ?? "") },
            questions: questions,
            checklist: raw.checklist.enumerated().map { index, item in
                OwnerAskCheckItem(id: item.id.flatMap { $0.isEmpty ? nil : $0 } ?? String(index + 1),
                                  text: item.text, hint: item.hint ?? "")
            }
        )
    }

    private struct Raw: Decodable {
        let focus: [RawFocus]
        let questions: Int
        let checklist: [RawCheckItem]

        enum CodingKeys: String, CodingKey { case focus, questions, checklist }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            focus = try c.decodeIfPresent([RawFocus].self, forKey: .focus) ?? []
            // Counted only: the questions themselves are the card decoder's.
            questions = try c.decodeIfPresent([Ignored].self, forKey: .questions)?.count ?? 0
            checklist = try c.decodeIfPresent([RawCheckItem].self, forKey: .checklist) ?? []
        }
    }

    private struct RawFocus: Decodable {
        let text: String
        let heading: String?
        let quote: String?
    }

    private struct RawCheckItem: Decodable {
        let id: String?
        let text: String
        let hint: String?
    }

    private struct Ignored: Decodable {}
}

/// An `owner_asks` row (migration 00097): something the workbench agent
/// asked the owner — a review of a document snapshot, a manual check or a
/// question. Go's `ask_owner` writes it; the Desktop only answers it.
package struct OwnerAsk: FetchableRecord, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let projectID: Int64
    /// The terminal session that filed it; nil for an external terminal or
    /// a session deleted since.
    package let sessionID: Int64?
    package let targetID: Int64?
    package let kind: OwnerAskKind
    package let title: String
    package let summary: String
    /// A review re-round: what changed since `previousAskID`.
    package let changes: String
    package let payload: OwnerAskPayload
    package let docPath: String
    package let docSnapshot: String
    package let previousAskID: Int64?
    package let status: OwnerAskStatus
    /// `agent` or `superseded` on a withdrawn ask, else empty.
    package let withdrawnReason: String
    /// Nil until answered.
    package let answer: OwnerAskAnswer?
    package let createdAt: String
    package let answeredAt: String
    package let deliveredAt: String

    /// Throws on a kind, status, payload or answer it cannot read: such a row
    /// is broken, and showing it as something else would answer the wrong ask.
    package init(row: Row) throws {
        id = row["id"]
        projectID = row["project_id"]
        sessionID = row["session_id"]
        targetID = row["target_id"]
        let kindValue: String = row["kind"] ?? ""
        guard let kind = OwnerAskKind(rawValue: kindValue) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown ask kind \(kindValue)"))
        }
        self.kind = kind
        let statusValue: String = row["status"] ?? ""
        guard let status = OwnerAskStatus(rawValue: statusValue) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown ask status \(statusValue)"))
        }
        self.status = status
        title = row["title"] ?? ""
        summary = row["summary"] ?? ""
        changes = row["changes"] ?? ""
        payload = try OwnerAskPayload.decode(row["payload"] ?? "{}")
        docPath = row["doc_path"] ?? ""
        docSnapshot = row["doc_snapshot"] ?? ""
        previousAskID = row["previous_ask_id"]
        withdrawnReason = row["withdrawn_reason"] ?? ""
        let answerJSON: String = row["answer"] ?? ""
        answer = answerJSON.isEmpty ? nil : try OwnerAskAnswer.decode(answerJSON)
        createdAt = row["created_at"] ?? ""
        answeredAt = row["answered_at"] ?? ""
        deliveredAt = row["delivered_at"] ?? ""
    }

    package var isOpen: Bool { status == .open }
}
