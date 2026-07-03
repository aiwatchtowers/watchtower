import Foundation

enum TargetActionKind: String, Codable {
    case updateStatus = "update_status"
    case updateNotes = "update_notes"
    case updateProgress = "update_progress"
    case addSubItem = "add_sub_item"
    case createChildTarget = "create_child_target"
    case linkTarget = "link_target"
}

enum ProposedActionError: Error, Equatable {
    case invalid(String)
}

/// A task-mutating action the AI proposes. The AI never writes to the DB;
/// it emits one of these as JSON inside a ```watchtower-action``` block and
/// the desktop app applies it only after the user approves.
struct ProposedAction: Codable, Identifiable, Equatable {
    let id = UUID()
    let type: TargetActionKind
    let reason: String
    var status: String?
    var note: String?
    var progress: Int?
    var text: String?
    var intent: String?
    var priority: String?
    var targetId: Int?
    var relation: String?

    enum CodingKeys: String, CodingKey {
        case type, reason, status, note, progress, text, intent, priority
        case targetId = "target_id"
        case relation
    }

    init(
        type: TargetActionKind, reason: String, status: String? = nil, note: String? = nil,
        progress: Int? = nil, text: String? = nil, intent: String? = nil, priority: String? = nil,
        targetId: Int? = nil, relation: String? = nil
    ) {
        self.type = type
        self.reason = reason
        self.status = status
        self.note = note
        self.progress = progress
        self.text = text
        self.intent = intent
        self.priority = priority
        self.targetId = targetId
        self.relation = relation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(TargetActionKind.self, forKey: .type)
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        intent = try? c.decodeIfPresent(String.self, forKey: .intent)
        priority = try? c.decodeIfPresent(String.self, forKey: .priority)
        relation = try? c.decodeIfPresent(String.self, forKey: .relation)
        // LLMs frequently emit numeric fields as quoted strings — accept both.
        progress = Self.lenientInt(c, .progress)
        targetId = Self.lenientInt(c, .targetId)
    }

    /// Decodes an optional Int that the model may have emitted as a JSON number
    /// or as a quoted string ("50"). Returns nil when absent or unparseable.
    private static func lenientInt(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> Int? {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return Int(s.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static let allowedStatuses: Set<String> = [
        "todo", "in_progress", "blocked", "done", "dismissed", "snoozed"
    ]
    static let allowedPriorities: Set<String> = ["high", "medium", "low"]
    static let allowedRelations: Set<String> = [
        "contributes_to", "blocks", "related", "duplicates"
    ]

    func validate() throws {
        if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProposedActionError.invalid("reason is required")
        }
        switch type {
        case .updateStatus:
            guard let status, Self.allowedStatuses.contains(status) else {
                throw ProposedActionError.invalid("status must be one of \(Self.allowedStatuses.sorted())")
            }
        case .updateNotes:
            guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProposedActionError.invalid("note is required")
            }
        case .updateProgress:
            guard let progress, (0...100).contains(progress) else {
                throw ProposedActionError.invalid("progress must be 0...100")
            }
        case .addSubItem, .createChildTarget:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProposedActionError.invalid("text is required")
            }
            if type == .createChildTarget, let priority, !Self.allowedPriorities.contains(priority) {
                throw ProposedActionError.invalid("priority must be one of \(Self.allowedPriorities.sorted())")
            }
        case .linkTarget:
            guard let targetId, targetId > 0 else {
                throw ProposedActionError.invalid("target_id is required")
            }
            guard let relation, Self.allowedRelations.contains(relation) else {
                throw ProposedActionError.invalid("relation must be one of \(Self.allowedRelations.sorted())")
            }
        }
    }

    var cardDescription: String {
        switch type {
        case .updateStatus:
            return "Set status → \(status ?? "?")\n\(reason)"
        case .updateNotes:
            return "Add note: \(note ?? "")\n\(reason)"
        case .updateProgress:
            return "Set progress → \(progress ?? 0)%\n\(reason)"
        case .addSubItem:
            return "Add sub-item: \(text ?? "")\n\(reason)"
        case .createChildTarget:
            return "Create child target: \(text ?? "")\n\(reason)"
        case .linkTarget:
            return "Link → target #\(targetId ?? 0) as \"\(relation ?? "?")\"\n\(reason)"
        }
    }
}
