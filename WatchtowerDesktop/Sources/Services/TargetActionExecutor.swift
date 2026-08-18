import Foundation
import WatchtowerCore

enum TargetActionError: LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message): return message
        }
    }
}

/// Applies an approved ProposedAction to a target via TargetsViewModel.
/// The AI proposes; this executor (driven by an explicit user Approve) is the
/// only thing that mutates the DB. Returns a short summary for the follow-up
/// message sent back into the conversation, or throws if the write failed so
/// the caller can surface a failed card instead of reporting a false success.
///
/// The shared TargetsViewModel mutators swallow DB errors into `errorMessage`
/// (the established house idiom for the list UI), so we detect failure by
/// clearing `errorMessage` before the call and checking it after, rather than
/// changing those signatures and rippling into every existing caller. Clearing
/// first (instead of snapshotting the prior value) means a write that fails
/// with the same message as a previous action's failure is still detected —
/// a stale identical error can never mask a new one as a false success.
enum TargetActionExecutor {
    @MainActor
    static func apply(_ action: ProposedAction, target: Target, viewModel: TargetsViewModel) throws -> String {
        viewModel.errorMessage = nil
        func checkWrite() throws {
            if let err = viewModel.errorMessage {
                throw TargetActionError.writeFailed(err)
            }
        }

        switch action.type {
        case .updateStatus:
            let status = try require(action.status, "status")
            viewModel.updateStatus(target, to: status)
            try checkWrite()
            return "set status to \(status)"
        case .updateNotes:
            let note = try require(action.note, "note")
            viewModel.addNote(target, text: note)
            try checkWrite()
            return "added a note"
        case .updateProgress:
            let pct = try require(action.progress, "progress")
            viewModel.updateProgress(target, to: Double(pct) / 100.0)
            try checkWrite()
            return "set progress to \(pct)%"
        case .addSubItem:
            let text = try require(action.text, "text")
            viewModel.addSubItem(target, text: text)
            try checkWrite()
            return "added sub-item \"\(text)\""
        case .createChildTarget:
            let text = try require(action.text, "text")
            guard viewModel.createChild(
                target, text: text,
                intent: action.intent ?? "",
                priority: action.priority ?? "medium"
            ) != nil else {
                throw TargetActionError.writeFailed(viewModel.errorMessage ?? "could not create child target")
            }
            return "created child target \"\(text)\""
        case .linkTarget:
            let targetID = try require(action.targetId, "target_id")
            guard targetID != target.id else { throw TargetActionError.writeFailed("cannot link a task to itself") }
            // The AI may hallucinate an id; verify the linked target exists
            // before writing so a bad link fails loudly instead of dangling.
            guard viewModel.itemByID(targetID) != nil else {
                throw TargetActionError.writeFailed("target #\(targetID) does not exist")
            }
            let relation = try require(action.relation, "relation")
            viewModel.createLink(from: target.id, to: targetID, relation: relation)
            try checkWrite()
            return "linked to target #\(targetID) (\(relation))"
        case .updateTitle:
            // updateText silently no-ops on a whitespace-only title, which would
            // read as a false "renamed" success — reject it here instead.
            let text = try require(action.text, "text")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TargetActionError.writeFailed("missing text")
            }
            viewModel.updateText(target, to: text)
            try checkWrite()
            return "renamed to \"\(text.trimmingCharacters(in: .whitespacesAndNewlines))\""
        case .updatePriority:
            let priority = try require(action.priority, "priority")
            viewModel.updatePriority(target, to: priority)
            try checkWrite()
            return "set priority to \(priority)"
        case .updateDue:
            let due = try require(action.text, "text")
            viewModel.updateDueDate(target, to: due)
            try checkWrite()
            return "set due date to \(due)"
        case .updateIntent:
            let text = try require(action.text, "text")
            viewModel.updateIntent(target, to: text)
            try checkWrite()
            return "updated context"
        }
    }

    /// Unwraps an action field that validate() should have guaranteed, throwing
    /// the same "missing <field>" error the guards used to produce.
    private static func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw TargetActionError.writeFailed("missing \(name)") }
        return value
    }
}
