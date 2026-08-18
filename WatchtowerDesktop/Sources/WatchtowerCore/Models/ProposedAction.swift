import Foundation

package enum TargetActionKind: String, Codable {
    case updateStatus = "update_status"
    case updateNotes = "update_notes"
    case updateProgress = "update_progress"
    case addSubItem = "add_sub_item"
    case createChildTarget = "create_child_target"
    case linkTarget = "link_target"
    case updateTitle = "update_title"
    case updatePriority = "update_priority"
    case updateDue = "update_due"
    case updateIntent = "update_intent"
}

package enum ProposedActionError: Error, Equatable {
    case invalid(String)
}

/// A task-mutating action the AI proposes. The AI never writes to the DB;
/// it emits one of these as JSON inside a ```watchtower-action``` block and
/// the desktop app applies it only after the user approves.
package struct ProposedAction: Codable, Identifiable, Equatable {
    package let id = UUID()
    package let type: TargetActionKind
    package let reason: String
    package var status: String?
    package var note: String?
    package var progress: Int?
    package var text: String?
    package var intent: String?
    package var priority: String?
    package var targetId: Int?
    package var relation: String?
    /// "propose" | "execute". Absent or any other value ⇒ propose (backward
    /// compatible with old model output and persisted track_events rows).
    package var mode: String?

    /// True only for an explicit `"mode":"execute"` — everything else is a
    /// proposal awaiting the Approve gate.
    package var isExecute: Bool { mode == "execute" }

    package enum CodingKeys: String, CodingKey {
        case type, reason, status, note, progress, text, intent, priority
        case targetId = "target_id"
        case relation, mode
    }

    package init(
        type: TargetActionKind,
        reason: String,
        status: String? = nil,
        note: String? = nil,
        progress: Int? = nil,
        text: String? = nil,
        intent: String? = nil,
        priority: String? = nil,
        targetId: Int? = nil,
        relation: String? = nil,
        mode: String? = nil
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
        self.mode = mode
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(TargetActionKind.self, forKey: .type)
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        intent = try? c.decodeIfPresent(String.self, forKey: .intent)
        priority = try? c.decodeIfPresent(String.self, forKey: .priority)
        relation = try? c.decodeIfPresent(String.self, forKey: .relation)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
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

    package static let allowedStatuses: Set<String> = [
        "todo", "in_progress", "blocked", "done", "dismissed", "snoozed"
    ]
    package static let allowedPriorities: Set<String> = ["high", "medium", "low"]
    package static let allowedRelations: Set<String> = [
        "contributes_to", "blocks", "related", "duplicates"
    ]

    package func validate() throws {
        try Self.requireNonEmpty(reason, name: "reason")
        switch type {
        case .updateStatus:
            try Self.requireAllowed(status, in: Self.allowedStatuses, name: "status")
        case .updateNotes:
            try Self.requireNonEmpty(note, name: "note")
        case .updateProgress:
            guard let progress, (0...100).contains(progress) else {
                throw ProposedActionError.invalid("progress must be 0...100")
            }
        case .addSubItem, .updateTitle, .updateIntent:
            try Self.requireNonEmpty(text, name: "text")
        case .createChildTarget:
            try Self.requireNonEmpty(text, name: "text")
            if priority != nil {
                try Self.requireAllowed(priority, in: Self.allowedPriorities, name: "priority")
            }
        case .linkTarget:
            guard let targetId, targetId > 0 else {
                throw ProposedActionError.invalid("target_id is required")
            }
            try Self.requireAllowed(relation, in: Self.allowedRelations, name: "relation")
        case .updatePriority:
            try Self.requireAllowed(priority, in: Self.allowedPriorities, name: "priority")
        case .updateDue:
            guard let text, Self.isValidDueDate(text) else {
                throw ProposedActionError.invalid("text must be a valid YYYY-MM-DD date")
            }
        }
    }

    private static func requireNonEmpty(_ value: String?, name: String) throws {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProposedActionError.invalid("\(name) is required")
        }
    }

    private static func requireAllowed(_ value: String?, in allowed: Set<String>, name: String) throws {
        guard let value, allowed.contains(value) else {
            throw ProposedActionError.invalid("\(name) must be one of \(allowed.sorted())")
        }
    }

    /// Strict `YYYY-MM-DD` check: shape via regex, then a non-lenient calendar
    /// parse so an impossible date ("2026-02-30") is rejected too.
    package static func isValidDueDate(_ s: String) -> Bool {
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return false
        }
        return dueDateFormatter.date(from: s) != nil
    }

    private static let dueDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()

    package var cardDescription: String {
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
        case .updateTitle:
            return "Rename to \"\(text ?? "")\"\n\(reason)"
        case .updatePriority:
            return "Set priority to \(priority ?? "?")\n\(reason)"
        case .updateDue:
            return "Set due date to \(text ?? "?")\n\(reason)"
        case .updateIntent:
            return "Update context\n\(reason)"
        }
    }
}
