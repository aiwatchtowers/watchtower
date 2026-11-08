import SwiftUI
import WatchtowerCore

/// The Inbox's first column: `InboxFolderMenu` fed by `InboxFolderMenuModel`.
/// The menu's own presses (selection, fields, folder writes, drag) go to the
/// model; the root ⋯'s Learned Rules and Assistant Profile open in the
/// reading pane; the rest (Needs approval's ⋯, + New Artifact…) goes to the
/// caller.
struct InboxFolderMenuColumn: View {
    let model: InboxFolderMenuModel
    /// Learned Rules / Assistant Profile in the reading pane.
    var onOpenAux: (InboxAuxPane) -> Void = { _ in }
    /// A ⋯ press the menu does not carry out itself.
    var onCommand: (Int64, InboxMenuCommand) -> Void = { _, _ in }
    var onNewArtifact: () -> Void = {}

    var body: some View {
        InboxFolderMenu(content: model.content, onAction: handle)
    }

    private func handle(_ action: InboxFolderMenuAction) {
        switch action {
        case let .select(id): model.select(id)
        case let .toggleExpanded(id): model.toggleExpanded(id)
        case .newFolder: model.beginCreate(parent: nil)
        case .newArtifact: onNewArtifact()
        case let .draftChanged(title): model.editDraft(title)
        case .commitDraft: Task { await model.commitDraft() }
        case .cancelDraft: model.cancelDraft()
        case let .confirmDelete(id): Task { await model.delete(id) }
        case .cancelDelete: model.cancelDelete()
        case let .menu(folderID, command): menu(command, folderID: folderID)
        case let .beginDrag(id): model.beginDrag(id)
        case let .dragOver(drop): model.dragOver(drop)
        case let .drop(drop):
            guard let dragged = model.draggedID else { return }
            Task { await model.drop(dragged, onto: drop) }
        }
    }

    private func menu(_ command: InboxMenuCommand, folderID: Int64) {
        switch command {
        case .learnedRules: onOpenAux(.learnedRules)
        case .assistantProfile: onOpenAux(.profile)
        default:
            Task {
                if await !model.perform(command, folderID: folderID) { onCommand(folderID, command) }
            }
        }
    }
}
