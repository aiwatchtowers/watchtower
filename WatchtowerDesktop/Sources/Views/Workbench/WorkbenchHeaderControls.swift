import AppKit
import SwiftUI
import WatchtowerCore

/// The workbench row's controls in the window's title row (spec
/// 2026-10-20-workbench-header §1): the `Session | Board | Files` tabs, then
/// at the trailing edge the ⚡ automations menu, the Analytics icon, split
/// and ⋯. What belongs to one session — Terminal | Workchat, report,
/// Changes, the sessions menu — is that session pane's strip
/// (`WorkbenchSessionStrip`).
struct WorkbenchHeaderControls: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    /// The workbench's ⚡ automations menu, built by the page (nil: none —
    /// the Automations view model is not up yet).
    var automations: WorkbenchAutomationsMenu?
    /// The ⋯ menu's Delete…: the page reads the counts and confirms.
    let onDelete: () -> Void
    /// The ⋯ menu's Clean Up Old Worktrees…: the page shows the sweep sheet.
    let onCleanUpOldWorktrees: () -> Void
    /// The tab under the pointer.
    @State private var hoveredTab: String?
    @State private var showsWorktreeSetup = false
    @State private var showsAgentSettings = false
    @State private var showsBoardColumns = false

    var body: some View {
        HStack(spacing: Spacing.regular) {
            tabs
                // The tabs never truncate; the name before them does.
                .fixedSize()
                .layoutPriority(1)
            Spacer(minLength: Spacing.regular)
            if let automations { automations }
            analyticsToggle
            splitToggle
            moreMenu
        }
        .sheet(isPresented: $showsWorktreeSetup) {
            WorktreeSetupSheet(vm: vm, project: project)
        }
        .sheet(isPresented: $showsAgentSettings) {
            AgentSettingsSheet(vm: vm, project: project)
        }
        .sheet(isPresented: $showsBoardColumns) {
            BoardColumnsSheet(vm: vm, project: project)
        }
    }

    /// Session / Board / Files: on = on screen (call 7). On a single pane
    /// they pick — an unlit tab replaces the pane, the lit one does nothing
    /// (`hideView` / `hideSessionViews` keep a single pane); in a split they
    /// toggle: on shows the view beside the other pane, off closes its pane.
    /// Session stands for every view of a session (terminal, Workchat,
    /// report, Changes) and comes back in the mode it was last shown in.
    private var tabs: some View {
        let layout = vm.layout(projectID: project.id)
        return HStack(spacing: Spacing.tight) {
            tab("Session", systemImage: WorkspaceView.terminal.icon, isOn: layout.isShowingSessionView,
                help: "Show the session — its terminal or Workchat, as last shown; in a split, beside the other pane") { on in
                if on {
                    Task { await vm.showSessionTab(project: project) }
                } else {
                    vm.hideSessionViews(projectID: project.id)
                }
            }
            ForEach([WorkspaceView.board, .files], id: \.self) { view in
                tab(view.title, systemImage: view.icon, isOn: layout.isShowing(view), help: view.help) { on in
                    if on {
                        Task { await vm.showView(view, project: project) }
                    } else {
                        vm.hideView(view, projectID: project.id)
                    }
                }
            }
        }
        .segmentCapsule()
    }

    private func tab(
        _ title: String, systemImage: String, isOn: Bool, help: String, set: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            Label(title, systemImage: systemImage)
        }
        .toggleStyle(SegmentedToggleStyle(isHovered: hoveredTab == title) { inside in
            if inside { hoveredTab = title } else if hoveredTab == title { hoveredTab = nil }
        })
        .help(help)
    }

    /// Analytics as a quiet icon (spec §1): on while the
    /// Analytics view is on screen; the same show / hide as a tab.
    private var analyticsToggle: some View {
        let isOn = vm.layout(projectID: project.id).isShowing(.analytics)
        return Button {
            if isOn {
                vm.hideView(.analytics, projectID: project.id)
            } else {
                Task { await vm.showView(.analytics, project: project) }
            }
        } label: {
            Image(systemName: WorkspaceView.analytics.icon)
        }
        .buttonStyle(.kitIcon(isOn: isOn))
        .help(WorkspaceView.analytics.help)
        .accessibilityLabel("Analytics")
    }

    private var splitToggle: some View {
        let isSplit = vm.layout(projectID: project.id).isSplit
        return Button {
            vm.toggleSplit(projectID: project.id)
        } label: {
            // One symbol in both states: the accent highlight says "split on".
            Image(systemName: "rectangle.split.2x1")
        }
        .buttonStyle(.kitIcon(isOn: isSplit))
        .help(isSplit ? "Show one pane" : "Split: show two panes side by side")
        .accessibilityLabel(isSplit ? "Single Pane" : "Split")
    }

    /// Show in Finder (the folder path is the name's help, call 2), Repair
    /// install, Re-run Setup, the archive items, Agent Settings…, Clean Up
    /// Old Worktrees… and Delete…, out of the row. New Automation… is the
    /// ⚡ menu's.
    private var moreMenu: some View {
        let status = vm.installStatus[project.id]
        let installing = vm.isInstalling(projectID: project.id)
        return Menu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("\(project.folderPath)\nShow in Finder")
            Divider()
            Button {
                Task { await vm.repairInstall(projectID: project.id) }
            } label: {
                Label("Repair install", systemImage: "wrench.and.screwdriver")
            }
            .disabled(installing || status?.needsRepair != true)
            .help(status?.repairHelp ?? "Re-install what is missing in the folder")
            if status?.codexNeedsSetup == true {
                Button {
                    Task { await vm.setUpCodex(projectID: project.id) }
                } label: {
                    Label("Set up Codex", systemImage: "plus.circle")
                }
                .disabled(installing)
                .help("Set this folder up for Codex sessions: the skill for Codex and the trust of Watchtower's hooks")
            }
            Button {
                Task { await vm.resync(projectID: project.id) }
            } label: {
                Label("Re-run Setup", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(installing)
            .help("Re-index the folder for search and re-install what is missing. Never changes the board, comments or sources.")
            archiveMenu
            archiveNowItems
            Button {
                showsWorktreeSetup = true
            } label: {
                Label("Worktree Setup Command…", systemImage: "terminal")
            }
            .help("A command a new session's worktree runs before the agent starts")
            Button {
                showsAgentSettings = true
            } label: {
                Label("Agent Settings…", systemImage: "slider.horizontal.3")
            }
            .help("The methodology, the ask guard and the finish check this workbench's agents run under")
            Button {
                showsBoardColumns = true
            } label: {
                Label("Board Columns…", systemImage: "rectangle.split.3x1")
            }
            .help("Name the board's columns inside each status, and hide In Review or Blocked")
            Divider()
            Button {
                onCleanUpOldWorktrees()
            } label: {
                Label("Clean Up Old Worktrees…", systemImage: "sparkles")
            }
            .disabled(vm.sessionCleanup == nil)
            .help("Pick worktrees and branches older sessions left behind to remove; nothing in use or unsaved goes")
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete…", systemImage: "trash")
            }
            .disabled(vm.deletingWorkbenchID != nil)
        } label: {
            // Plain dots: the square is the button's outline, a circle
            // inside it would be a second one.
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.kitIcon(isOn: false))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Workbench actions")
        .accessibilityLabel("Workbench actions")
    }
}

private extension WorkbenchHeaderControls {
    /// "Archive Closed Targets After ▸ Never / 3 / … / 90 days" (board #301):
    /// a closed target leaves the board after that long; the board's
    /// "Archive" toggle shows it again. Applies at once, both ways.
    var archiveMenu: some View {
        Menu {
            ForEach(Workbench.archiveAfterDaysChoices, id: \.self) { days in
                Toggle(Workbench.archiveAfterDaysLabel(days), isOn: Binding(
                    get: { project.archiveAfterDays == days },
                    set: { on in
                        guard on else { return }
                        Task { await vm.setArchiveAfterDays(days, projectID: project.id) }
                    }
                ))
            }
        } label: {
            Label("Archive Closed Targets After", systemImage: "archivebox")
        }
        .help("How long a done or dismissed target stays on the board before it is archived")
    }

    /// "Archive Closed Targets Now" and, while its moment is remembered,
    /// "Undo Archive Now" (board #415): every target closed by the click
    /// leaves the board at once, whatever the setting above. Undo forgets
    /// the moment, so it also brings back what earlier presses archived
    /// (except what the setting archives anyway). No confirmation — nothing
    /// is deleted.
    @ViewBuilder var archiveNowItems: some View {
        Button {
            Task { await vm.archiveClosedTargetsNow(projectID: project.id) }
        } label: {
            Label("Archive Closed Targets Now", systemImage: "archivebox.fill")
        }
        .help("Archive every done or dismissed target now; one with an open sub-target stays, and so does work closed later")
        if project.archivedThrough != nil {
            Button {
                Task { await vm.undoArchiveNow(projectID: project.id) }
            } label: {
                Label("Undo Archive Now", systemImage: "arrow.uturn.backward")
            }
            .help("Bring back what Archive Now archived, except targets the setting above archives anyway")
        }
    }
}

extension WorkbenchInstallStatus {
    /// What is installed and what is missing, for the install icons' and
    /// Repair install's help. A folder set up before the Workbench rename
    /// gets a line of its own: its old hooks and registration read as on.
    /// The Codex line shows only once codex is found (D5: without it Codex
    /// is skipped quietly) or when the CLI could not tell which codex to use
    /// (a trust error).
    var repairHelp: String {
        "Skill \(skill) · hook \(hook ? "on" : "missing") · "
            + "drift hook \(stopHook ? "on" : "missing") · "
            + "state hooks \(stateHooks ? "on" : "missing") · "
            + "ask guard \(askGuard && askToolBlock ? "on" : "missing") · "
            + "permission wait \(permissionWait ? "on" : "missing") · "
            + "cleanup permission \(cleanupPermission ? "on" : "missing") · MCP \(mcp ? "on" : "missing")"
            + (legacy ? "\nSet up under the old Projects name — it no longer runs; Repair install migrates it" : "")
            + (codex.flatMap { $0.found || $0.trustError != nil ? "\n" + $0.summary : nil } ?? "")
            + (groupRulesNote.map { "\n" + $0 } ?? "")
    }

    /// Board #476: a skill without the group rules gets a group's Work on It
    /// as a single target's; nil when every set-up skill has them.
    var groupRulesNote: String? {
        let claudeLacks = (skill != "missing" || (legacy && !legacySkill.isEmpty)) && !groupPrompt
        let codexLacks = codex.map { $0.skill && !$0.groupPrompt } ?? false
        let lacking = [claudeLacks ? "Claude Code" : nil, codexLacks ? "Codex" : nil].compactMap { $0 }
        guard !lacking.isEmpty else { return nil }
        return "The \(lacking.joined(separator: " and ")) skill here has no group rules, "
            + "so Work on It starts a group as a single target"
    }
}

private extension WorkspaceView {
    var help: String {
        switch self {
        case .terminal: "Show the session's terminal, in place of its Workchat (⌃`); in a split, beside the other pane"
        case .report: "Show the session's report (in a split, beside its session's terminal)"
        case .board: "Show the Board (in a split, beside the terminal)"
        case .files: "Show the open files (in a split, beside the terminal)"
        case .analytics: "Agent time, cost and hints for this workbench"
        case .changes: "Review the session's changes"
        case .chat: "Show the session's Workchat, in place of its terminal (⌃`); in a split, beside its terminal"
        }
    }
}
