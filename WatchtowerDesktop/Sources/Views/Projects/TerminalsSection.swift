import AppKit
import SwiftUI
import WatchtowerCore

/// A level-1 row of the Projects panel: a project, or a standalone terminal.
enum ProjectsPanelItem: Hashable {
    case project(Int64)
    case terminal(Int64)
}

/// Level 1's "Terminals" section: standalone sessions (outside any project)
/// and the "New terminal" menu.
struct TerminalsSection: View {
    @Bindable var vm: ProjectsViewModel
    let actions: SessionRowActions

    var body: some View {
        Section {
            ForEach(vm.standaloneSessions) { session in
                TerminalSessionRow(session: session, isLive: vm.isLive(session), actions: actions)
                    .tag(ProjectsPanelItem.terminal(session.id))
            }
            // Shown on the terminal's own page when one is selected.
            if vm.selectedStandaloneID == nil, let error = vm.standaloneSessionError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Terminals")
                Spacer()
                NewTerminalMenu(vm: vm)
            }
        }
    }
}

private struct NewTerminalMenu: View {
    let vm: ProjectsViewModel

    var body: some View {
        Menu {
            Button("Claude Code in Home") { start(.claude, folder: home) }
            Button("Claude Code in Folder…") { if let folder = chooseFolder() { start(.claude, folder: folder) } }
            Divider()
            Button("Shell in Home") { start(.shell, folder: home) }
            Button("Shell in Folder…") { if let folder = chooseFolder() { start(.shell, folder: folder) } }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New terminal")
        .accessibilityLabel("New terminal")
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private func start(_ kind: TerminalSession.Kind, folder: URL) {
        Task { await vm.newStandalone(kind: kind, folder: folder) }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal"
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.resolvingSymlinksInPath()
    }
}
