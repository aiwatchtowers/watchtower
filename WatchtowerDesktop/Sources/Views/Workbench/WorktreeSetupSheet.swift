import SwiftUI
import WatchtowerCore

/// The header menu's "Worktree Setup Command…" (board #229): one shell
/// command a new session's worktree runs before the agent starts. Empty =
/// none. Stays open with the error when the save fails.
struct WorktreeSetupSheet: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Worktree setup command").font(.headline)
            TextField("e.g. npm ci", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(width: 420)
                .onSubmit(save)
            Text(SessionStartPlacementPresentation.setupHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 420, alignment: .leading)
            if let error = vm.worktreeSetupErrors[project.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 420, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .onAppear { command = project.worktreeSetup }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            if await vm.setWorktreeSetup(command, projectID: project.id) { dismiss() }
            saving = false
        }
    }
}
