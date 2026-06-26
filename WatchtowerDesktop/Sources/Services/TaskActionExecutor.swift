import Foundation

/// Applies an approved ProposedAction to a target via TargetsViewModel.
/// The AI proposes; this executor (driven by an explicit user Approve) is the
/// only thing that mutates the DB. Returns a short summary for the follow-up
/// message sent back into the conversation.
enum TaskActionExecutor {
    @MainActor
    static func apply(_ action: ProposedAction, target: Target, viewModel: TargetsViewModel) -> String {
        switch action.type {
        case .updateStatus:
            let status = action.status ?? "todo"
            viewModel.updateStatus(target, to: status)
            return "set status to \(status)"
        case .updateNotes:
            let note = action.note ?? ""
            viewModel.addNote(target, text: note)
            return "added a note"
        case .updateProgress:
            let pct = action.progress ?? 0
            viewModel.updateProgress(target, to: Double(pct) / 100.0)
            return "set progress to \(pct)%"
        case .addSubItem:
            let text = action.text ?? ""
            viewModel.addSubItem(target, text: text)
            return "added sub-item \"\(text)\""
        case .createChildTarget:
            let text = action.text ?? ""
            viewModel.createChild(
                target, text: text,
                intent: action.intent ?? "",
                priority: action.priority ?? "medium"
            )
            return "created child target \"\(text)\""
        }
    }
}
