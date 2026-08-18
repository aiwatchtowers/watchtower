import Foundation

package enum TargetActionKind: String, Codable {
    case updateStatus = "update_status"
    case updateNotes = "update_notes"
    case updateProgress = "update_progress"
    case addSubItem = "add_sub_item"
    case createChildTarget = "create_child_target"
    case linkTarget = "link_target"
    case toggleSubItem = "toggle_sub_item"
    case editSubItem = "edit_sub_item"
    case deleteSubItem = "delete_sub_item"
    case setSubItemDue = "set_sub_item_due"
    case updateDueDate = "update_due_date"
    case updatePriority = "update_priority"
    case updateBallOn = "update_ball_on"
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
    package var index: Int?
    package var match: String?
    // Tri-state by design: nil = the model omitted the field (validation error),
    // not a default — so an optional Bool is the honest type here.
    package var done: Bool? // swiftlint:disable:this discouraged_optional_boolean
    package var dueDate: String?
    package var ballOn: String?

    package enum CodingKeys: String, CodingKey {
        case type, reason, status, note, progress, text, intent, priority
        case targetId = "target_id"
        case relation
        case index, match, done
        case dueDate = "due_date"
        case ballOn = "ball_on"
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
        index: Int? = nil,
        match: String? = nil,
        done: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        dueDate: String? = nil,
        ballOn: String? = nil
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
        self.index = index
        self.match = match
        self.done = done
        self.dueDate = dueDate
        self.ballOn = ballOn
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
        match = try? c.decodeIfPresent(String.self, forKey: .match)
        dueDate = try? c.decodeIfPresent(String.self, forKey: .dueDate)
        ballOn = try? c.decodeIfPresent(String.self, forKey: .ballOn)
        // LLMs frequently emit numeric fields as quoted strings — accept both.
        progress = Self.lenientInt(c, .progress)
        targetId = Self.lenientInt(c, .targetId)
        index = Self.lenientInt(c, .index)
        done = Self.lenientBool(c, .done)
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

    /// Decodes an optional Bool that the model may have emitted as a JSON bool
    /// or as a quoted string ("true"/"false"). Returns nil when absent or unparseable.
    private static func lenientBool(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> Bool? { // swiftlint:disable:this discouraged_optional_boolean
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
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
        if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProposedActionError.invalid("reason is required")
        }
        switch type {
        case .updateStatus:
            try validateStatus()
        case .updateNotes:
            try validateNote()
        case .updateProgress:
            try validateProgress()
        case .addSubItem:
            try validateText()
        case .createChildTarget:
            try validateText()
            try validateOptionalPriority()
        case .linkTarget:
            try validateLink()
        case .toggleSubItem:
            try validateSubItemAddress()
            try validateDone()
        case .editSubItem:
            try validateSubItemAddress()
            try validateText()
        case .deleteSubItem:
            try validateSubItemAddress()
        case .setSubItemDue:
            try validateSubItemAddress()
            try validateDueDateField()
        case .updateDueDate:
            try validateDueDateField()
        case .updatePriority:
            try validatePriority()
        case .updateBallOn:
            try validateBallOn()
        }
    }

    private func validateStatus() throws {
        guard let status, Self.allowedStatuses.contains(status) else {
            throw ProposedActionError.invalid("status must be one of \(Self.allowedStatuses.sorted())")
        }
    }

    private func validateNote() throws {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProposedActionError.invalid("note is required")
        }
    }

    private func validateProgress() throws {
        guard let progress, (0...100).contains(progress) else {
            throw ProposedActionError.invalid("progress must be 0...100")
        }
    }

    private func validateText() throws {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProposedActionError.invalid("text is required")
        }
    }

    /// A priority is optional on create_child_target but must be valid when given.
    private func validateOptionalPriority() throws {
        if let priority, !Self.allowedPriorities.contains(priority) {
            throw ProposedActionError.invalid("priority must be one of \(Self.allowedPriorities.sorted())")
        }
    }

    private func validatePriority() throws {
        guard let priority, Self.allowedPriorities.contains(priority) else {
            throw ProposedActionError.invalid("priority must be one of \(Self.allowedPriorities.sorted())")
        }
    }

    private func validateLink() throws {
        guard let targetId, targetId > 0 else {
            throw ProposedActionError.invalid("target_id is required")
        }
        guard let relation, Self.allowedRelations.contains(relation) else {
            throw ProposedActionError.invalid("relation must be one of \(Self.allowedRelations.sorted())")
        }
    }

    private func validateDone() throws {
        guard done != nil else {
            throw ProposedActionError.invalid("done (true|false) is required")
        }
    }

    private func validateBallOn() throws {
        guard ballOn != nil else {
            throw ProposedActionError.invalid("ball_on is required (\"\" to clear)")
        }
    }

    /// Sub-item-addressing actions must carry both the index the AI saw and the
    /// item's current text; the pair is re-resolved against the live list at
    /// apply time (see resolveSubItemIndex).
    private func validateSubItemAddress() throws {
        guard let index, index >= 0 else {
            throw ProposedActionError.invalid("index is required (from the sub-items list)")
        }
        guard let match, !match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProposedActionError.invalid("match (the sub-item's current text) is required")
        }
    }

    private func validateDueDateField() throws {
        guard let dueDate else {
            throw ProposedActionError.invalid("due_date is required (\"\" to clear)")
        }
        guard Self.isValidDueDate(dueDate) else {
            throw ProposedActionError.invalid("due_date must be YYYY-MM-DD, YYYY-MM-DDTHH:MM, or \"\" to clear")
        }
    }

    /// Accepts the two stored due-date shapes ("YYYY-MM-DD" and
    /// "YYYY-MM-DDTHH:MM") plus "" meaning "clear".
    package static func isValidDueDate(_ s: String) -> Bool {
        if s.isEmpty { return true }
        return s.range(of: #"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$"#, options: .regularExpression) != nil
    }

    /// Resolves this action's sub-item address against the live sub-items list.
    /// The prompt snapshot the AI saw may be stale by apply time, so the index
    /// counts only when the text at that index still matches; otherwise a
    /// unique text match wins; otherwise the action fails (never guess).
    package func resolveSubItemIndex(in items: [TargetSubItem]) throws -> Int {
        guard let index, let match else {
            throw ProposedActionError.invalid("index and match are required")
        }
        let wanted = match.trimmingCharacters(in: .whitespacesAndNewlines)
        func text(_ i: Int) -> String {
            items[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if items.indices.contains(index), text(index) == wanted { return index }
        let hits = items.indices.filter { text($0) == wanted }
        guard hits.count == 1 else {
            throw ProposedActionError.invalid(
                hits.isEmpty
                    ? "no sub-item matches \"\(wanted)\" — the list may have changed"
                    : "\"\(wanted)\" matches several sub-items — cannot pick one safely"
            )
        }
        return hits[0]
    }

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
        case .toggleSubItem:
            return "\(done == true ? "Check" : "Uncheck") sub-item: \(match ?? "")\n\(reason)"
        case .editSubItem:
            return "Edit sub-item: \(match ?? "") → \(text ?? "")\n\(reason)"
        case .deleteSubItem:
            return "Delete sub-item: \(match ?? "")\n\(reason)"
        case .setSubItemDue:
            let due = dueDate ?? ""
            return due.isEmpty
                ? "Clear due date on sub-item: \(match ?? "")\n\(reason)"
                : "Set sub-item due → \(due): \(match ?? "")\n\(reason)"
        case .updateDueDate:
            let due = dueDate ?? ""
            return due.isEmpty ? "Clear due date\n\(reason)" : "Set due date → \(due)\n\(reason)"
        case .updatePriority:
            return "Set priority → \(priority ?? "?")\n\(reason)"
        case .updateBallOn:
            let ball = ballOn ?? ""
            return ball.isEmpty ? "Clear ball-on\n\(reason)" : "Set ball on → \(ball)\n\(reason)"
        }
    }
}
