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
/// snapshotting `errorMessage` around the call rather than changing those
/// signatures and rippling into every existing caller.
enum TargetActionExecutor {
    @MainActor
    static func apply(_ action: ProposedAction, target: Target, viewModel: TargetsViewModel) throws -> String {
        switch action.type {
        case .updateStatus, .updateNotes, .updateProgress, .addSubItem, .createChildTarget, .linkTarget:
            return try applyCore(action, target: target, viewModel: viewModel)
        case .toggleSubItem, .editSubItem, .deleteSubItem, .setSubItemDue:
            return try applySubItem(action, target: target, viewModel: viewModel)
        case .updateDueDate, .updatePriority, .updateBallOn:
            return try applyTargetField(action, target: target, viewModel: viewModel)
        }
    }

    /// Throws when `viewModel.errorMessage` changed across the mutator call —
    /// the mutators swallow DB errors into that property (see the type comment).
    @MainActor
    private static func checkWrite(_ viewModel: TargetsViewModel, prior: String?) throws {
        if let err = viewModel.errorMessage, err != prior {
            throw TargetActionError.writeFailed(err)
        }
    }

    @MainActor
    private static func applyCore(
        _ action: ProposedAction, target: Target, viewModel: TargetsViewModel
    ) throws -> String {
        let priorError = viewModel.errorMessage
        switch action.type {
        case .updateStatus:
            guard let status = action.status else { throw TargetActionError.writeFailed("missing status") }
            viewModel.updateStatus(target, to: status)
            try checkWrite(viewModel, prior: priorError)
            return "set status to \(status)"
        case .updateNotes:
            guard let note = action.note else { throw TargetActionError.writeFailed("missing note") }
            viewModel.addNote(target, text: note)
            try checkWrite(viewModel, prior: priorError)
            return "added a note"
        case .updateProgress:
            guard let pct = action.progress else { throw TargetActionError.writeFailed("missing progress") }
            viewModel.updateProgress(target, to: Double(pct) / 100.0)
            try checkWrite(viewModel, prior: priorError)
            return "set progress to \(pct)%"
        case .addSubItem:
            guard let text = action.text else { throw TargetActionError.writeFailed("missing text") }
            viewModel.addSubItem(target, text: text)
            try checkWrite(viewModel, prior: priorError)
            return "added sub-item \"\(shorten(text))\""
        case .createChildTarget:
            guard let text = action.text else { throw TargetActionError.writeFailed("missing text") }
            guard let childID = viewModel.createChild(
                target, text: text,
                intent: action.intent ?? "",
                priority: action.priority ?? "medium"
            ) else {
                throw TargetActionError.writeFailed(viewModel.errorMessage ?? "could not create child target")
            }
            // The id lets the assistant address the new child (target_id) in
            // the same conversation without asking the user to open it.
            return "created child target #\(childID) \"\(shorten(text))\""
        case .linkTarget:
            return try applyLink(action, target: target, viewModel: viewModel, priorError: priorError)
        default:
            throw TargetActionError.writeFailed("internal: \(action.type.rawValue) is not a core action")
        }
    }

    @MainActor
    private static func applyLink(
        _ action: ProposedAction, target: Target, viewModel: TargetsViewModel, priorError: String?
    ) throws -> String {
        guard let targetID = action.targetId else { throw TargetActionError.writeFailed("missing target_id") }
        guard targetID != target.id else { throw TargetActionError.writeFailed("cannot link a task to itself") }
        guard let relation = action.relation else { throw TargetActionError.writeFailed("missing relation") }
        viewModel.createLink(from: target.id, to: targetID, relation: relation)
        try checkWrite(viewModel, prior: priorError)
        return "linked to target #\(targetID) (\(relation))"
    }

    @MainActor
    private static func applySubItem(
        _ action: ProposedAction, target: Target, viewModel: TargetsViewModel
    ) throws -> String {
        let priorError = viewModel.errorMessage
        let items = target.decodedSubItems
        let idx = try resolveSubItem(action, in: items)
        let current = shorten(items[idx].text)
        switch action.type {
        case .toggleSubItem:
            guard let done = action.done else { throw TargetActionError.writeFailed("missing done") }
            if items[idx].done == done {
                return "sub-item \"\(current)\" already \(done ? "done" : "not done")"
            }
            viewModel.toggleSubItem(target, index: idx)
            try checkWrite(viewModel, prior: priorError)
            return "\(done ? "checked" : "unchecked") sub-item \"\(current)\""
        case .editSubItem:
            guard let text = action.text else { throw TargetActionError.writeFailed("missing text") }
            viewModel.editSubItem(target, index: idx, newText: text)
            try checkWrite(viewModel, prior: priorError)
            // The new text alone: the old one is redundant (the address already
            // identified the item) and doubles the follow-up's size.
            return "edited sub-item → \"\(shorten(text))\""
        case .deleteSubItem:
            viewModel.removeSubItem(target, index: idx)
            try checkWrite(viewModel, prior: priorError)
            return "deleted sub-item \"\(current)\""
        case .setSubItemDue:
            guard let due = action.dueDate else { throw TargetActionError.writeFailed("missing due_date") }
            viewModel.updateSubItemDueDate(target, index: idx, dueDate: due.isEmpty ? nil : due)
            try checkWrite(viewModel, prior: priorError)
            return due.isEmpty
                ? "cleared due date on sub-item \"\(current)\""
                : "set sub-item \"\(current)\" due \(due)"
        default:
            throw TargetActionError.writeFailed("internal: \(action.type.rawValue) is not a sub-item action")
        }
    }

    @MainActor
    private static func applyTargetField(
        _ action: ProposedAction, target: Target, viewModel: TargetsViewModel
    ) throws -> String {
        let priorError = viewModel.errorMessage
        switch action.type {
        case .updateDueDate:
            guard let due = action.dueDate else { throw TargetActionError.writeFailed("missing due_date") }
            viewModel.updateDueDate(target, to: due)
            try checkWrite(viewModel, prior: priorError)
            return due.isEmpty ? "cleared due date" : "set due date to \(due)"
        case .updatePriority:
            guard let priority = action.priority else { throw TargetActionError.writeFailed("missing priority") }
            viewModel.updatePriority(target, to: priority)
            try checkWrite(viewModel, prior: priorError)
            return "set priority to \(priority)"
        case .updateBallOn:
            guard let ballOn = action.ballOn else { throw TargetActionError.writeFailed("missing ball_on") }
            viewModel.updateBallOn(target, to: ballOn)
            try checkWrite(viewModel, prior: priorError)
            return ballOn.isEmpty ? "cleared ball-on" : "set ball on \(ballOn)"
        default:
            throw TargetActionError.writeFailed("internal: \(action.type.rawValue) is not a field action")
        }
    }

    /// Caps quoted item texts in summaries — they are echoed into the chat
    /// transcript (and a batch follow-up joins dozens of them), so a summary
    /// identifies the item, never reproduces it.
    private static func shorten(_ text: String, limit: Int = 60) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Re-resolves the action's sub-item address against the live list,
    /// converting the model-layer error into the executor's error type so the
    /// failed card carries the specific mismatch message.
    private static func resolveSubItem(_ action: ProposedAction, in items: [TargetSubItem]) throws -> Int {
        do {
            return try action.resolveSubItemIndex(in: items)
        } catch let ProposedActionError.invalid(message) {
            throw TargetActionError.writeFailed(message)
        }
    }
}
