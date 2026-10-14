import SwiftUI
import WatchtowerCore

/// What the Delete dialog says about cleanup in each phase (board #535,
/// spec 2026-10-12-session-cleanup §12).
enum SessionDeleteCleanupOffer {
    static let checkingText = "Checking what this session left…"
    static let undoNote = "Undo brings the session back, not the removed worktrees and branches."

    /// The dialog's cleanup line; nil when there is nothing to say (no
    /// cleanup for this session, or nothing removable — the dialog is then
    /// as before cleanup).
    static func message(_ phase: SessionCleanupPhase) -> String? {
        switch phase {
        case .idle, .done: nil
        case .planning: checkingText
        case .applying: "Cleaning up…"
        case let .ready(plan): SessionCleanupPresentation.offerLine(plan).map { "\($0) \(undoNote)" }
        case let .failed(message): "Could not check what this session left: \(message)"
        }
    }

    /// Whether the dialog offers Delete and Clean Up: a ready plan with
    /// something to remove.
    static func offersCleanup(_ phase: SessionCleanupPhase) -> Bool {
        if case let .ready(plan) = phase { return !plan.removableKeys.isEmpty }
        return false
    }
}

/// The Delete confirmation. On open it plans the session's cleanup; with
/// something to remove it offers **Delete and Clean Up** (the default, ask
/// #193), **Delete Only** and Cancel, else Delete Session and Cancel as
/// before. Delete and Clean Up passes on exactly the keys shown. The quick
/// ✕ / ⌘⌫ delete never comes here and never cleans up.
struct SessionDeleteConfirmSheet: View {
    let vm: WorkbenchesViewModel
    let session: TerminalSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let phase = vm.deleteCleanupPhase(session)
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(session.title)”?").font(.headline)
            Text(AgentChoicePresentation.deleteSessionMessage(session.kind))
                .fixedSize(horizontal: false, vertical: true)
            if let line = SessionDeleteCleanupOffer.message(phase) {
                Text(line)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(cleanupDropped: true) }
                    .keyboardShortcut(.cancelAction)
                deleteButtons(offersCleanup: SessionDeleteCleanupOffer.offersCleanup(phase), checking: phase == .planning)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: session.id) { await vm.planCleanupBeforeDelete(session) }
    }

    @ViewBuilder
    private func deleteButtons(offersCleanup: Bool, checking: Bool) -> some View {
        if offersCleanup {
            Button("Delete Only", role: .destructive) { deleteOnly() }
            Button("Delete and Clean Up", role: .destructive) {
                let (vm, session, keys) = (vm, session, vm.plannedDeleteRemovals(session))
                finish(cleanupDropped: false)
                Task { await vm.deleteAndCleanUp(session, items: keys) }
            }
            .keyboardShortcut(.defaultAction)
        } else {
            // While the plan is checked, Return deletes nothing: the
            // default may yet become Delete and Clean Up.
            Button("Delete Session", role: .destructive) { deleteOnly() }
                .keyboardShortcut(checking ? nil : .defaultAction)
        }
    }

    private func deleteOnly() {
        let (vm, session) = (vm, session)
        finish(cleanupDropped: true)
        Task { await vm.delete(session) }
    }

    private func finish(cleanupDropped: Bool) {
        if cleanupDropped { vm.dismissDeleteCleanup(session) }
        dismiss()
    }
}
