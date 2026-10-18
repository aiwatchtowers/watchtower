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
/// The shared TargetsViewModel mutators await the writer (board #670) and
/// report a DB error in `errorMessage` (the house idiom for the list UI);
/// each returns whether it wrote, and a write that did not throws here with
/// that message.
enum TargetActionExecutor {
    @MainActor
    static func apply(_ action: ProposedAction, target: Target, viewModel: TargetsViewModel) async throws -> String {
        // `target` is the caller's snapshot: when the row is gone, the no-op
        // short-circuits below ("sub-item already done", "already has that
        // label") would answer from it and report a success that never
        // touched the database.
        guard try targetExists(target.id, viewModel: viewModel) else { throw TargetNotFoundError(id: target.id) }
        switch action.type {
        case .updateStatus, .updateNotes, .updateProgress, .addSubItem, .createChildTarget, .linkTarget:
            return try await applyCore(action, target: target, viewModel: viewModel)
        case .toggleSubItem, .editSubItem, .deleteSubItem, .setSubItemDue:
            return try await applySubItem(action, target: target, viewModel: viewModel)
        case .updateDueDate, .updatePriority, .updateBallOn, .updateTitle, .updateIntent,
             .addLabel, .removeLabel:
            return try await applyTargetField(action, target: target, viewModel: viewModel)
        }
    }

    /// Throws when a mutator did not write: its own failure, which it has
    /// just put in `viewModel.errorMessage` (see the type comment) — whether
    /// it wrote is the mutator's return, never a diff of that slot, so an
    /// identical repeat failure still throws.
    @MainActor
    private static func checkWrite(_ wrote: Bool, _ viewModel: TargetsViewModel) throws {
        guard wrote else { throw TargetActionError.writeFailed(viewModel.errorMessage ?? "the write failed") }
    }

    @MainActor
    private static func applyCore(
        _ action: ProposedAction, target: Target, viewModel: TargetsViewModel
    ) async throws -> String {
        switch action.type {
        case .updateStatus:
            guard let status = action.status else { throw TargetActionError.writeFailed("missing status") }
            try checkWrite(await viewModel.updateStatus(target, to: status), viewModel)
            return "set status to \(status)"
        case .updateNotes:
            guard let note = action.note else { throw TargetActionError.writeFailed("missing note") }
            try checkWrite(await viewModel.addNote(target, text: note), viewModel)
            return "added a note"
        case .updateProgress:
            guard let pct = action.progress else { throw TargetActionError.writeFailed("missing progress") }
            try checkWrite(await viewModel.updateProgress(target, to: Double(pct) / 100.0), viewModel)
            return "set progress to \(pct)%"
        case .addSubItem:
            guard let text = action.text else { throw TargetActionError.writeFailed("missing text") }
            try checkWrite(await viewModel.addSubItem(target, text: text), viewModel)
            return "added sub-item \"\(shorten(text))\""
        case .createChildTarget:
            guard let text = action.text else { throw TargetActionError.writeFailed("missing text") }
            guard let childID = await viewModel.createChild(
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
            return try await applyLink(action, target: target, viewModel: viewModel)
        default:
            throw TargetActionError.writeFailed("internal: \(action.type.rawValue) is not a core action")
        }
    }

    @MainActor
    private static func applyLink(
        _ action: ProposedAction, target: Target, viewModel: TargetsViewModel
    ) async throws -> String {
        guard let targetID = action.targetId else { throw TargetActionError.writeFailed("missing target_id") }
        guard targetID != target.id else { throw TargetActionError.writeFailed("cannot link a task to itself") }
        // Checked here although `createLink` checks both endpoints too: the AI
        // may invent the id, and "does not exist" is the honest message for it.
        guard try targetExists(targetID, viewModel: viewModel) else {
            throw TargetActionError.writeFailed("target #\(targetID) does not exist")
        }
        guard let relation = action.relation else { throw TargetActionError.writeFailed("missing relation") }
        try checkWrite(await viewModel.createLink(from: target.id, to: targetID, relation: relation), viewModel)
        return "linked to target #\(targetID) (\(relation))"
    }

    /// Whether a target row exists — the acted-on target (a stale snapshot of
    /// a deleted row) or a link's other end (the AI may hallucinate its id).
    /// A failed READ throws as such — not conflated with "does not exist".
    @MainActor
    private static func targetExists(_ id: Int, viewModel: TargetsViewModel) throws -> Bool {
        do {
            return try viewModel.fetchByID(id) != nil
        } catch {
            throw TargetActionError.writeFailed(
                "could not verify target #\(id): \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private static func applySubItem(
        _ action: ProposedAction, target: Target, viewModel: TargetsViewModel
    ) async throws -> String {
        let items = target.decodedSubItems
        let idx = try resolveSubItem(action, in: items)
        let current = shorten(items[idx].text)
        switch action.type {
        case .toggleSubItem:
            guard let done = action.done else { throw TargetActionError.writeFailed("missing done") }
            if items[idx].done == done {
                return "sub-item \"\(current)\" already \(done ? "done" : "not done")"
            }
            try checkWrite(await viewModel.toggleSubItem(target, index: idx), viewModel)
            return "\(done ? "checked" : "unchecked") sub-item \"\(current)\""
        case .editSubItem:
            guard let text = action.text else { throw TargetActionError.writeFailed("missing text") }
            try checkWrite(await viewModel.editSubItem(target, index: idx, newText: text), viewModel)
            // The new text alone: the old one is redundant (the address already
            // identified the item) and doubles the follow-up's size.
            return "edited sub-item → \"\(shorten(text))\""
        case .deleteSubItem:
            try checkWrite(await viewModel.removeSubItem(target, index: idx), viewModel)
            return "deleted sub-item \"\(current)\""
        case .setSubItemDue:
            guard let due = action.dueDate else { throw TargetActionError.writeFailed("missing due_date") }
            let wrote = await viewModel.updateSubItemDueDate(target, index: idx, dueDate: due.isEmpty ? nil : due)
            try checkWrite(wrote, viewModel)
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
    ) async throws -> String {
        switch action.type {
        case .updateDueDate:
            guard let due = action.dueDate else { throw TargetActionError.writeFailed("missing due_date") }
            try checkWrite(await viewModel.updateDueDate(target, to: due), viewModel)
            return due.isEmpty ? "cleared due date" : "set due date to \(due)"
        case .updatePriority:
            guard let priority = action.priority else { throw TargetActionError.writeFailed("missing priority") }
            try checkWrite(await viewModel.updatePriority(target, to: priority), viewModel)
            return "set priority to \(priority)"
        case .updateBallOn:
            guard let ballOn = action.ballOn else { throw TargetActionError.writeFailed("missing ball_on") }
            try checkWrite(await viewModel.updateBallOn(target, to: ballOn), viewModel)
            return ballOn.isEmpty ? "cleared ball-on" : "set ball on \(ballOn)"
        case .updateTitle:
            // updateText silently no-ops on a whitespace-only title, which would
            // read as a false "renamed" success — reject it here instead.
            let text = try requireTrimmedText(action)
            try checkWrite(await viewModel.updateText(target, to: text), viewModel)
            return "renamed to \"\(text)\""
        case .updateIntent:
            guard let text = action.text else { throw TargetActionError.writeFailed("missing text") }
            try checkWrite(await viewModel.updateIntent(target, to: text), viewModel)
            return "updated context"
        case .addLabel:
            let label = try requireTrimmedText(action)
            let changed = await viewModel.addTag(target, tag: label)
            try checkWrite(changed != nil, viewModel)
            // The no-op summary must not claim a write (the toggleSubItem
            // precedent); `changed` is the in-transaction truth, not a snapshot.
            return changed == .changed ? "added label \"\(label)\"" : "task already has label \"\(label)\""
        case .removeLabel:
            let label = try requireTrimmedText(action)
            let changed = await viewModel.removeTag(target, tag: label)
            try checkWrite(changed != nil, viewModel)
            return changed == .changed ? "removed label \"\(label)\"" : "label \"\(label)\" was not on the task"
        default:
            throw TargetActionError.writeFailed("internal: \(action.type.rawValue) is not a field action")
        }
    }

    /// Decode-time validation guarantees non-empty text on the parser path,
    /// but track-watcher actions reach apply without validate() — and the
    /// stored value must be trimmed to match what the manual editors write.
    private static func requireTrimmedText(_ action: ProposedAction) throws -> String {
        guard let raw = action.text else { throw TargetActionError.writeFailed("missing text") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TargetActionError.writeFailed("missing text") }
        return text
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
