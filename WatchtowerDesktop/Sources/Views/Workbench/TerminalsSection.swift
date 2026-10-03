import SwiftUI
import WatchtowerCore

/// Level 1's "Terminals" section: standalone sessions (outside any project)
/// and the "New terminal" menu.
struct TerminalsSection: View {
    @Bindable var vm: WorkbenchesViewModel
    let actions: SessionRowActions
    /// Picks a folder for a new terminal (the page warns about guarded ones).
    let chooseFolder: (TerminalSession.Kind) -> Void

    var body: some View {
        let sessions = vm.orderedSessions(projectID: nil)
        Section {
            ForEach(vm.sessionRows(sessions)) { row in
                TerminalSessionRow(row: row, actions: actions)
                    .tag(WorkbenchesPanelItem.terminal(row.id))
            }
            .onMove { vm.moveSessions(sessions, projectID: nil, from: $0, to: $1) }
            // Shown on the terminal's own page when one is on screen.
            if vm.selectedStandalone == nil, let error = vm.standaloneSessionError {
                Text(error).font(.caption).foregroundStyle(.red).listRowSeparator(.hidden)
            }
        } header: {
            HStack {
                Text("Terminals")
                Spacer()
                NewTerminalMenu(vm: vm, chooseFolder: chooseFolder)
            }
        }
    }
}

private struct NewTerminalMenu: View {
    let vm: WorkbenchesViewModel
    let chooseFolder: (TerminalSession.Kind) -> Void

    var body: some View {
        Menu {
            Button("Claude Code in Home") { start(.claude) }
            Button("Claude Code in Folder…") { chooseFolder(.claude) }
            Divider()
            Button("Shell in Home") { start(.shell) }
            Button("Shell in Folder…") { chooseFolder(.shell) }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New terminal")
        .accessibilityLabel("New terminal")
    }

    private func start(_ kind: TerminalSession.Kind) {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        Task { await vm.newStandalone(kind: kind, folder: home) }
    }
}
