import Foundation

/// Which of the owner's two texts a value, a save or a suggestion belongs to.
package enum InstructionField: String, Decodable, CaseIterable, Sendable {
    case session
    case procedure
}

/// A refusal from `watchtower instructions …` — Go's message (it names the
/// field when the text is over the limit), shown inline next to the field.
package struct OwnerInstructionsError: LocalizedError, Equatable {
    package let message: String
    package var errorDescription: String? { message }

    package init(message: String) { self.message = message }
}

/// One "You keep saying this" row: a direction the owner repeated across
/// sessions. `workbenchID` is set when every repeat came from one workbench.
package struct InstructionSuggestion: Decodable, Equatable, Identifiable, Sendable {
    package let id: Int64
    package let text: String
    package let field: InstructionField
    package let workbenchID: Int64?
    package let sessionCount: Int
    package let workbenchCount: Int
    package let firstSeenAt: Date
    package let lastSeenAt: Date

    enum CodingKeys: String, CodingKey {
        case id, text, field
        case workbenchID = "workbench_id"
        case sessionCount = "session_count"
        case workbenchCount = "workbench_count"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
    }
}

/// `watchtower instructions show --json` (Go `buildInstructionsJSON`).
package struct OwnerInstructionsState: Decodable, Equatable, Sendable {
    package struct Texts: Decodable, Equatable, Sendable {
        package let session: String
        package let procedure: String

        package func text(_ field: InstructionField) -> String {
            field == .session ? session : procedure
        }
    }

    package struct WorkbenchTexts: Decodable, Equatable, Sendable {
        package let id: Int64
        package let session: String
        package let procedure: String

        package func text(_ field: InstructionField) -> String {
            field == .session ? session : procedure
        }
    }

    package let limit: Int
    package let global: Texts
    package let workbench: WorkbenchTexts?
    package let suggestions: [InstructionSuggestion]

    /// Decodes a CLI reply; an `{"ok":false,"error":…}` body becomes a thrown
    /// `OwnerInstructionsError` carrying that message.
    package static func decode(_ data: Data) throws -> Self {
        try OwnerInstructionsJSON.decode(Self.self, from: data)
    }

    /// Open suggestions for one field at one scope: global (`nil`) or a
    /// workbench's own.
    package func suggestions(for field: InstructionField, workbenchID: Int64? = nil) -> [InstructionSuggestion] {
        suggestions.filter { $0.field == field && $0.workbenchID == workbenchID }
    }

    /// The length the limit applies to: Go counts runes (Unicode scalars),
    /// not bytes and not grapheme clusters.
    package static func runeCount(_ text: String) -> Int { text.unicodeScalars.count }
}

/// `watchtower instructions preview --json`: the exact brief slot and
/// procedure text the agent receives.
package struct OwnerInstructionsPreview: Decodable, Equatable, Sendable {
    package let briefSlot: String
    package let procedure: String

    enum CodingKeys: String, CodingKey {
        case briefSlot = "brief_slot"
        case procedure
    }

    package static func decode(_ data: Data) throws -> Self {
        try OwnerInstructionsJSON.decode(Self.self, from: data)
    }
}

enum OwnerInstructionsJSON {
    private struct Failure: Decodable {
        let ok: Bool
        let error: String?
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let f = try? JSONDecoder().decode(Failure.self, from: data), !f.ok {
            throw OwnerInstructionsError(message: f.error ?? "The instructions command failed.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = plain.date(from: s) ?? fractional.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date \(s)"))
        }
        return try decoder.decode(type, from: data)
    }
}
