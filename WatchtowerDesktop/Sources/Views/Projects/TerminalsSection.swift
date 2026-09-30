import AppKit
import SwiftUI
import WatchtowerCore

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
            // Shown on the terminal's own page when one is on screen.
            if vm.selectedStandalone == nil, let error = vm.standaloneSessionError {
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
    @State private var pending: (kind: TerminalSession.Kind, folder: URL)?
    @State private var sensitiveLocation: String?

    var body: some View {
        Menu {
            Button("Claude Code in Home") { start(.claude, folder: home) }
            Button("Claude Code in Folder…") { chooseFolder(for: .claude) }
            Divider()
            Button("Shell in Home") { start(.shell, folder: home) }
            Button("Shell in Folder…") { chooseFolder(for: .shell) }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New terminal")
        .accessibilityLabel("New terminal")
        .alert(
            "Folder in \(sensitiveLocation ?? "")",
            isPresented: Binding(get: { sensitiveLocation != nil }, set: { if !$0 { sensitiveLocation = nil } })
        ) {
            Button("Open anyway") {
                if let pending { start(pending.kind, folder: pending.folder) }
                pending = nil
            }
            Button("Choose another folder", role: .cancel) { pending = nil }
        } message: {
            Text(
                "The embedded terminal runs as part of Watchtower, so macOS may ask whether Watchtower can access "
                    + "\(sensitiveLocation ?? "this folder"). A folder outside Documents, Desktop, Downloads and "
                    + "cloud storage avoids that prompt."
            )
        }
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() }

    private func start(_ kind: TerminalSession.Kind, folder: URL) {
        Task { await vm.newStandalone(kind: kind, folder: folder) }
    }

    /// Warns before a folder macOS guards (the New project flow's rule).
    private func chooseFolder(for kind: TerminalSession.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal"
        guard panel.runModal() == .OK, let folder = panel.url?.resolvingSymlinksInPath() else { return }
        if let location = ProjectFolderPolicy.tccSensitiveLocation(path: folder.path, home: home.path) {
            pending = (kind, folder)
            sensitiveLocation = location
        } else {
            start(kind, folder: folder)
        }
    }
}
