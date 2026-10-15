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
    @State private var cleaningSession: TerminalSession?
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
            // With the panel hidden, the delete's Undo shows over the page.
            .overlay(alignment: .bottomLeading) {
                if !vm.panelVisible {
                    SessionDeleteToast(vm: vm).frame(maxWidth: 320)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.pendingDeleteToast)
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
        .sessionActionDialogs(vm: vm, renaming: $renamingSession, deleting: $deletingSession, cleaning: $cleaningSession)
        .onAppear {
            consumeRoute()
            Task { await vm.tabAppeared() }
        }
        .onChange(of: appState.pendingWorkbenchRoute) { _, _ in consumeRoute() }
        .alert(
            "Folder in \(sensitiveLocation ?? "")",
            isPresented: Binding(get: { sensitiveLocation != nil }, set: { if !$0 { sensitiveLocation = nil } })
        ) {
            Button("Open anyway") { startPending() }
            Button("Choose another folder", role: .cancel) { pendingFolder = nil }
        } message: {
            Text(
                "The embedded terminal runs as part of Watchtower, so macOS may ask whether "
                    + "Watchtower can access \(sensitiveLocation ?? "this folder"). A folder outside Documents, "
                    + "Desktop, Downloads and cloud storage avoids that prompt."
            )
        }
    }

    @ViewBuilder
    private var panel: some View {
        if let project = vm.drilledWorkbench {
            WorkbenchSessionsPanel(
                vm: vm, project: project, actions: sessionActions,
                switcherActions: switcherActions, paletteOpen: goToOpen
            )
        } else {
            workbenchList
        }
    }

    private var switcherActions: WorkbenchSwitcherActions {
        WorkbenchSwitcherActions(openFolder: chooseFolder, showAll: vm.showAllWorkbenches)
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
            delete: { deletingSession = $0 },
            cleanUp: { cleaningSession = $0 }
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
            // The Undo of a session delete (board #480) in its own bar, as
            // under the sessions list at level 2.
            SessionDeleteToast(vm: vm)
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
            Button(action: chooseFolder) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(vm.isCreating)
            .help("Open Folder…")
            .accessibilityLabel("Open Folder…")
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
            Text("Pick a folder to start a workbench. \(vm.defaultAgent.displayName) sets it up from there.")
                .foregroundStyle(.secondary)
        }
    }

    /// Open Folder… (board #778), the one way to a workbench: any folder —
    /// the panel's New Folder makes a new one — becomes the workbench, or
    /// opens the one already bound to it (`WorkbenchesViewModel.openFolder`),
    /// with no TCC warning: that one came when the workbench was created.
    private func chooseFolder() {
        guard let url = runFolderPanel(title: "Open Folder", prompt: "Open", canCreate: true) else { return }
        if vm.workbenchID(boundTo: url) != nil {
            Task { await vm.openFolder(url) }
        } else {
            confirmLocation(of: .project(url), path: url.path)
        }
    }

    /// New terminal → "… in Folder…": the same TCC warning as a project.
    private func chooseTerminalFolder(_ kind: TerminalSession.Kind) {
        guard let url = runFolderPanel(title: nil, prompt: "Open Terminal", canCreate: false) else { return }
        confirmLocation(of: .terminal(kind, url), path: url.path)
    }

    private func runFolderPanel(title: String?, prompt: String, canCreate: Bool) -> URL? {
        let panel = NSOpenPanel()
        if let title { panel.title = title }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.resolvingSymlinksInPath()
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
            Task { await vm.openFolder(folder) }
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
            // The panel hidden: the list is one click away here (board #743).
            if !vm.panelVisible {
                WorkbenchBackButton(action: switcherActions.showAll)
            }
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
        // A, with no field focused: "Waiting for you" takes the keyboard
        // (board #412); never under the open palette. Labelled: a trailing
        // closure would be `onKey`.
        // swiftlint:disable:next trailing_closure
        .background(OwnerAskKeyCatcher(onPress: { [vm, paletteOpen] press in
            Self.pressOnPage(press, vm: vm, paletteOpen: paletteOpen)
        }))
    }

    static let backShortcutID = "workbench.back-shortcut"

    /// A bare key the page's catcher offers (board #412): A opens the stack,
    /// never under the open palette; anything else stays the window's.
    static func pressOnPage(_ press: OwnerAskKeyMap.Press, vm: WorkbenchesViewModel, paletteOpen: Bool) -> Bool {
        !paletteOpen && OwnerAskKeyMap.mappedAction(for: press, at: .page) == .openStack && vm.openStackFromKeyboard()
    }

    /// ⌘T and ⌘1…⌘9 (the session switcher shows them) as hidden buttons;
    /// they need a workbench page. ⇧⌘O is Open Quickly's (ruling R26).
    /// ⌘[ goes back to the workbench list (board #743); like ⌘K, Monaco
    /// keeps it (Outdent) while the cursor is in the Files editor.
    private var shortcuts: some View {
        Group {
            Button("") { switcherActions.showAll() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!vm.canShowAllWorkbenches)
                .accessibilityIdentifier(Self.backShortcutID)
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
