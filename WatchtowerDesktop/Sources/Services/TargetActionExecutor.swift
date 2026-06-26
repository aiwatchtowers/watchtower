import Foundation

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
/// snapshotting `errorMessage` around the call rather than changing those
/// signatures and rippling into every existing caller.
enum TargetActionExecutor {
    @MainActor
    static func apply(_ action: ProposedAction, target: Target, viewModel: TargetsViewModel) throws -> String {
        let priorError = viewModel.errorMessage
        func checkWrite() throws {
            if let err = viewModel.errorMessage, err != priorError {
                throw TargetActionError.writeFailed(err)
            }
        }

        switch action.type {
        case .updateStatus:
            guard let status = action.status else { throw TargetActionError.writeFailed("missing status") }
            viewModel.updateStatus(target, to: status)
            try checkWrite()
            return "set status to \(status)"
        case .updateNotes:
            guard let note = action.note else { throw TargetActionError.writeFailed("missing note") }
            viewModel.addNote(target, text: note)
            try checkWrite()
            return "added a note"
        case .updateProgress:
            guard let pct = action.progress else { throw TargetActionError.writeFailed("missing progress") }
            viewModel.updateProgress(target, to: Double(pct) / 100.0)
            try checkWrite()
            return "set progress to \(pct)%"
        case .addSubItem:
            guard let text = action.text else { throw TargetActionError.writeFailed("missing text") }
            viewModel.addSubItem(target, text: text)
            try checkWrite()
            return "added sub-item \"\(text)\""
        case .createChildTarget:
            guard let text = action.text else { throw TargetActionError.writeFailed("missing text") }
            guard viewModel.createChild(
                target, text: text,
                intent: action.intent ?? "",
                priority: action.priority ?? "medium"
            ) != nil else {
                throw TargetActionError.writeFailed(viewModel.errorMessage ?? "could not create child target")
            }
            return "created child target \"\(text)\""
        case .linkTarget:
            guard let targetID = action.targetId else { throw TargetActionError.writeFailed("missing target_id") }
            guard targetID != target.id else { throw TargetActionError.writeFailed("cannot link a task to itself") }
            guard let relation = action.relation else { throw TargetActionError.writeFailed("missing relation") }
            viewModel.createLink(from: target.id, to: targetID, relation: relation)
            try checkWrite()
            return "linked to target #\(targetID) (\(relation))"
        }
    }
}
