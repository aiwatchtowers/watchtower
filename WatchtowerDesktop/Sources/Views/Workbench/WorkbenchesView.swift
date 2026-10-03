import AppKit
import SwiftUI
import WatchtowerCore

/// A level-1 row of the Workbench panel: a project, or a standalone terminal.
enum WorkbenchesPanelItem: Hashable {
    case project(Int64)
    case terminal(Int64)
}

/// A folder the owner picked, held while the TCC warning is on screen.
private enum PendingFolder {
    case project(URL)
    /// New Project…: not on disk yet (or empty) until the warning is passed.
    case newWorkbench(URL)
    case terminal(TerminalSession.Kind, URL)
}

/// Workbench tab: the collapsible, resizable two-level panel on the left
/// (projects and standalone terminals, or one project's sessions) and the
/// selected project's page — or standalone terminal — on the right
/// (spec 2026-09-30-project-workspace-sessions §3).
struct WorkbenchesView: View {
    @Bindable var vm: WorkbenchesViewModel
    @Environment(AppState.self) private var appState
    // The `projects.` keys predate the Workbench rename; persisted, so kept
    // (spec 2026-10-02 A1). The panel's visibility is the VM's (`panelVisible`).
    @AppStorage("projects.panelWidth") private var panelWidth = PanelResizeHandle.defaultWidth
    @State private var dragPanelWidth: Double?
    @State private var pendingFolder: PendingFolder?
    @State private var sensitiveLocation: String?
    @State private var renamingSession: TerminalSession?
    @State private var deletingSession: TerminalSession?
    /// The ⌘K palette (board #252). View state: it closes with the tab.
    @State private var goToOpen = false

    var body: some View {
        HStack(spacing: 0) {
            if vm.panelVisible {
                panel
                    .frame(width: dragPanelWidth ?? PanelResizeHandle.clamp(panelWidth))
                    .panelSurface()
                PanelResizeHandle(width: $panelWidth, liveWidth: $dragPanelWidth)
            }
            VStack(spacing: 0) {
                WorkbenchTitleRow(vm: vm, switcherActions: switcherActions, paletteOpen: goToOpen) { goToOpen = true }
                Divider()
                Group {
                    if let standalone = vm.selectedStandalone {
                        StandaloneTerminalView(session: standalone, actions: sessionActions)
                            .id(standalone.id)
                    } else if let project = vm.selectedWorkbench {
                        WorkbenchPageView(vm: vm, project: project)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        // ⌥⌘S, the title row's toggle, "All Workbenches" and the switchers' "Show
        // Sessions Panel" all slide the panel the same way.
        .animation(.easeInOut(duration: 0.2), value: vm.panelVisible)
        // The workspace — title row, page header, the terminal (transparent
        // under dark), Board and Files — on the detail backdrop, as AI
        // Chat's conversation is; the panel paints its own lighter surface.
        .detailBackground()
        .overlay {
            if goToOpen {
                GoToPaletteOverlay(vm: vm) { goToOpen = false }
            }
        }
        .sessionActionDialogs(vm: vm, renaming: $renamingSession, deleting: $deletingSession)
        .onAppear {
            consumeRoute()
            Task { await vm.reload() }
        }
        .onChange(of: appState.pendingWorkbenchRoute) { _, _ in consumeRoute() }
        .alert(
            "Folder in \(sensitiveLocation ?? "")",
            isPresented: Binding(get: { sensitiveLocation != nil }, set: { if !$0 { sensitiveLocation = nil } })
        ) {
            Button(isTerminalPending ? "Open anyway" : "Create anyway") { startPending() }
            Button("Choose another folder", role: .cancel) { pendingFolder = nil }
        } message: {
            Text(
                "The embedded terminal runs as part of Watchtower, so macOS may ask whether "
                    + "Watchtower can access \(sensitiveLocation ?? "this folder"). A folder outside Documents, "
                    + "Desktop, Downloads and cloud storage avoids that prompt."
            )
        }
    }

    private var isTerminalPending: Bool {
        if case .terminal? = pendingFolder { return true }
        return false
    }

    @ViewBuilder
    private var panel: some View {
        if let project = vm.drilledWorkbench {
            WorkbenchSessionsPanel(
                vm: vm, project: project, actions: sessionActions,
                switcherActions: switcherActions
            )
        } else {
            workbenchList
        }
    }

    private var switcherActions: WorkbenchSwitcherActions {
        WorkbenchSwitcherActions(newWorkbench: chooseNewWorkbenchFolder, showAll: vm.showAllWorkbenches)
    }

    private var sessionActions: SessionRowActions {
        SessionRowActions(
            open: { session in
                Task {
                    if session.projectID == nil {
                        await vm.selectStandalone(session)
                    } else {
                        await vm.showSession(id: session.id)
                    }
                }
            },
            rename: { renamingSession = $0 },
            delete: { deletingSession = $0 }
        )
    }

    private var workbenchList: some View {
        VStack(spacing: 0) {
            workbenchListHeader
            List(selection: listSelection) {
                Section {
                    ForEach(vm.summaries) { summary in
                        row(summary)
                            .tag(WorkbenchesPanelItem.project(summary.id))
                            .listRowSeparator(.hidden)
                            // A click on the already-selected project (after
                            // Back) changes no selection: drill in anyway.
                            .simultaneousGesture(TapGesture().onEnded { vm.drill(into: summary.id) })
                    }
                }
                TerminalsSection(vm: vm, actions: sessionActions, chooseFolder: chooseTerminalFolder)
            }
            .clearPlainList()
            if let error = vm.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
    }

    /// The chat history's header shape ("Chats" + New Chat).
    private var workbenchListHeader: some View {
        HStack(spacing: 6) {
            Text("Workbenches").font(.headline)
            Spacer(minLength: 4)
            if vm.isCreating { ProgressView().controlSize(.small) }
            Menu {
                Button("New Workbench…") { chooseNewWorkbenchFolder() }
                Button("Add Existing Folder…") { chooseExistingFolder() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(vm.isCreating)
            .help("New workbench…")
            .accessibilityLabel("New workbench…")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var listSelection: Binding<WorkbenchesPanelItem?> {
        Binding(
            get: {
                if let id = vm.selectedStandaloneID { return .terminal(id) }
                return vm.selectedWorkbenchID.map(WorkbenchesPanelItem.project)
            },
            set: { item in
                // A terminal row opens on its own click (`SessionRowActions.open`);
                // arrow keys only move the highlight (VoiceOver has the row's action).
                if case let .project(id)? = item { vm.drill(into: id) }
            }
        )
    }

    private func row(_ summary: WorkbenchSummary) -> some View {
        let badge = vm.badgeCount(for: summary)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.project.name).font(.body)
                Text(summary.project.folderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(summary.openTargets) open · \(summary.inProgressTargets) in progress")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if badge > 0 {
                WorkbenchCapsuleBadge(text: "\(badge)")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape").font(.largeTitle).foregroundStyle(.secondary)
            Text("Pick a folder to start a workbench. Claude Code sets it up from there.")
                .foregroundStyle(.secondary)
        }
    }

    /// New Project… → name a folder that is created for it. Only checked
    /// here; it is created once the TCC warning (if any) is passed, so
    /// "Choose another folder" leaves no empty folder behind.
    private func chooseNewWorkbenchFolder() {
        guard let url = runNewWorkbenchPanel() else { return }
        do {
            _ = try NewWorkbenchFolder.check(url)
        } catch {
            showCreateOutcome(error: error)
            return
        }
        confirmLocation(of: .newWorkbench(url), path: url.path)
    }

    /// New Workbench… may come from the switcher (level 2, or the panel
    /// hidden), where the list that carries the create's progress and
    /// errors is not on screen: it goes there once the create fails or
    /// starts, not on "Choose another folder".
    private func showCreateOutcome(error: Error?) {
        vm.showAllWorkbenches()
        if let error { vm.errorMessage = error.localizedDescription }
    }

    /// Add Existing Folder… → a folder already on disk becomes the project.
    private func chooseExistingFolder() {
        guard let url = runFolderPanel(prompt: "Add Folder", canCreate: true) else { return }
        confirmLocation(of: .project(url), path: url.path)
    }

    /// New terminal → "… in Folder…": the same TCC warning as a project.
    private func chooseTerminalFolder(_ kind: TerminalSession.Kind) {
        guard let url = runFolderPanel(prompt: "Open Terminal", canCreate: false) else { return }
        confirmLocation(of: .terminal(kind, url), path: url.path)
    }

    private func runFolderPanel(prompt: String, canCreate: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.resolvingSymlinksInPath()
    }

    /// The entered name is the folder's and the project's. Whatever the panel
    /// says about an existing name, nothing is ever replaced: an empty folder
    /// is reused and anything else is refused by `NewWorkbenchFolder`.
    private func runNewWorkbenchPanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "New Workbench"
        panel.nameFieldLabel = "Workbench name:"
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.directoryURL = NewWorkbenchFolder.defaultParent(home: FileManager.default.homeDirectoryForCurrentUser)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return NewWorkbenchFolder.resolved(url)
    }

    private func confirmLocation(of pending: PendingFolder, path: String) {
        pendingFolder = pending
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        if let location = WorkbenchFolderPolicy.tccSensitiveLocation(path: path, home: home) {
            sensitiveLocation = location
        } else {
            startPending()
        }
    }

    private func startPending() {
        guard let pending = pendingFolder else { return }
        pendingFolder = nil
        sensitiveLocation = nil
        switch pending {
        case let .project(folder):
            Task { await vm.createWorkbench(folder: folder, name: nil) }
        case let .newWorkbench(folder):
            do {
                try NewWorkbenchFolder.prepare(folder)
            } catch {
                showCreateOutcome(error: error)
                return
            }
            showCreateOutcome(error: nil)
            Task { await vm.createWorkbench(folder: folder, name: folder.lastPathComponent) }
        case let .terminal(kind, folder):
            Task { await vm.newStandalone(kind: kind, folder: folder) }
        }
    }

    private func consumeRoute() {
        guard let route = appState.pendingWorkbenchRoute else { return }
        appState.pendingWorkbenchRoute = nil
        vm.reveal(route)
    }
}

/// The chat's inline title row (`ChatSplitView.toolbar`) instead of a
/// window toolbar, which would add a tall title-bar strip above the tab.
/// It stays visible with the panel hidden: its toggle is the way back, and
/// then on a workbench page it carries `▦ <workbench> ▾ › ● <session> ▾`
/// (board #251, variant H) instead of the plain title. At its right, Go
/// to… opens the go-to palette (⌘K, board #252). It also holds the tab's
/// shortcuts, so they exist on the Workbench tab only, and not under the
/// open palette (they would change the page behind it).
struct WorkbenchTitleRow: View {
    @Bindable var vm: WorkbenchesViewModel
    let switcherActions: WorkbenchSwitcherActions
    var paletteOpen = false
    let openGoTo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { vm.panelVisible.toggle() } label: {
                Image(systemName: "sidebar.leading")
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(paletteOpen)
            .help(vm.panelVisible ? "Hide Sessions Panel (⌥⌘S)" : "Show Sessions Panel (⌥⌘S)")
            .accessibilityLabel(vm.panelVisible ? "Hide Sessions Panel" : "Show Sessions Panel")
            if let project = vm.headerSwitcherWorkbench {
                WorkbenchSwitcher(vm: vm, project: project, actions: switcherActions, fillsWidth: false)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                SessionSwitcher(vm: vm, project: project)
            } else {
                Text(vm.selectedStandalone?.title ?? vm.selectedWorkbench?.name ?? "Workbench")
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: openGoTo) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text("Go to…")
                    Text("⌘K").foregroundStyle(.secondary)
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Go to… (⌘K)")
            .accessibilityLabel("Go to…")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { shortcuts }
    }

    /// ⌘T and ⌘1…⌘9 (the session switcher shows them) as hidden buttons;
    /// they need a workbench page. ⇧⌘O is Open Quickly's (ruling R26).
    private var shortcuts: some View {
        Group {
            Group {
                Button("") { Task { await vm.newSessionOnPage() } }
                    .keyboardShortcut("t", modifiers: .command)
                ForEach(1...SessionSwitcherPresentation.maxShortcut, id: \.self) { n in
                    Button("") { Task { await vm.openSession(atShortcut: n) } }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                }
            }
            .disabled(!vm.hasWorkbenchPage)
        }
        .disabled(paletteOpen)
        .hidden()
    }
}
