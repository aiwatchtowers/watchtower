import Foundation

enum TaskActionKind: String, Codable {
    case updateStatus = "update_status"
    case updateNotes = "update_notes"
    case updateProgress = "update_progress"
    case addSubItem = "add_sub_item"
    case createChildTarget = "create_child_target"
}

enum ProposedActionError: Error, Equatable {
    case invalid(String)
}

/// A task-mutating action the AI proposes. The AI never writes to the DB;
/// it emits one of these as JSON inside a ```watchtower-action``` block and
/// the desktop app applies it only after the user approves.
struct ProposedAction: Codable, Identifiable, Equatable {
    let id = UUID()
    let type: TaskActionKind
    let reason: String
    var status: String?
    var note: String?
    var progress: Int?
    var text: String?
    var intent: String?
    var priority: String?

    enum CodingKeys: String, CodingKey {
        case type, reason, status, note, progress, text, intent, priority
    }

    static let allowedStatuses: Set<String> = [
        "todo", "in_progress", "blocked", "done", "dismissed", "snoozed",
    ]
    static let allowedPriorities: Set<String> = ["high", "medium", "low"]

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
        case .addSubItem:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProposedActionError.invalid("text is required")
            }
        case .createChildTarget:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProposedActionError.invalid("text is required")
            }
            if let priority, !Self.allowedPriorities.contains(priority) {
                throw ProposedActionError.invalid("priority must be one of \(Self.allowedPriorities.sorted())")
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
        }
    }
}
