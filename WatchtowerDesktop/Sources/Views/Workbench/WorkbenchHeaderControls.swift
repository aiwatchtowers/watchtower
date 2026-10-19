import SwiftUI
import WatchtowerCore

/// The workbench header's trailing controls: the automation buttons, then `Terminal | Workchat ▾ |
/// Session | Board | Files | Analytics | Changes | split | ⋯` (spec 2026-10-03-workbench-session-report
/// Part 7, the owner's pick on board #357; the twin switch is #711's variant A).
struct WorkbenchHeaderControls: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    /// The workbench's automation buttons, built by the page (nil: none —
    /// the Automations view model is not up yet).
    var automationButtons: WorkbenchAutomationButtons?
    /// The ⋯ menu's Delete…: the page reads the counts and confirms.
    let onDelete: () -> Void
    /// The ⋯ menu's Clean Up Old Worktrees…: the page shows the sweep sheet.
    let onCleanUpOldWorktrees: () -> Void
    /// The view button under the pointer, and whether the sessions chevron
    /// is: Workchat and the chevron after it light up together.
    @State private var hoveredView: WorkspaceView?
    @State private var chevronHovered = false
    @State private var showsWorktreeSetup = false
    @State private var showsAgentSettings = false
    @State private var showsBoardColumns = false

    var body: some View {
        HStack(spacing: 8) {
            if let automationButtons { automationButtons }
            viewButtons
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

    /// Terminal | Workchat / Session / Board / Files / Analytics / Changes: on = on
    /// screen. Turning one on shows it (beside the terminal in a split — the
    /// Session view beside its own session's terminal); turning it off
    /// closes that pane of a split. Split then puts two side by side.
    /// Terminal and Workchat are one twin segment sharing the sessions menu:
    /// on a single pane either half swaps the session's pane in place; in a
    /// split both can be lit (#711).
    private var viewButtons: some View {
        let layout = vm.layout(projectID: project.id)
        return HStack(spacing: 2) {
            // Workchat is drawn inside Terminal's twin, not as a button of its own.
            ForEach(WorkspaceView.allCases.filter { $0 != .chat }, id: \.self) { view in
                viewButton(view, layout: layout)
                if view == .terminal {
                    viewButton(.chat, layout: layout)
                        // Cancel the capsule's segment gap: Workchat continues Terminal.
                        .padding(.leading, -2)
                    sessionMenu(
                        slot: layout.terminalSlot,
                        isOn: layout.isShowing(.chat),
                        isLit: layout.isShowing(.terminal) || layout.isShowing(.chat)
                    )
                }
            }
        }
        .segmentCapsule()
    }

    private func viewButton(_ view: WorkspaceView, layout: WorkspaceLayout) -> some View {
        Toggle(isOn: Binding(
            get: { layout.isShowing(view) },
            set: { on in
                if on {
                    Task { await vm.showView(view, project: project) }
                } else {
                    vm.hideView(view, projectID: project.id)
                }
            }
        )) {
            Label(view.title, systemImage: view.icon)
        }
        .toggleStyle(SegmentedToggleStyle(
            joinsRight: view == .terminal,
            joinsLeft: view == .chat,
            joinsChevron: view == .chat,
            isHovered: hoveredView == view || (view == .chat && chevronHovered)
        ) { inside in
            if inside { hoveredView = view } else if hoveredView == view { hoveredView = nil }
        })
        .help(view.help)
        // No session to review: say so rather than a click that does nothing.
        .disabled((view == .changes || view == .chat) && !layout.isShowing(view) && vm.sessionViewTarget(projectID: project.id) == nil)
    }

    /// The twin's dropdown, shared by Terminal and Workchat: which session
    /// the session pane shows — in the mode it was last shown in — or a new
    /// one; the split panes' picker actions, so a single pane can switch
    /// sessions with the side panel hidden. A chevron, no extra row.
    /// `isOn`: Workchat, which it continues, is on; `isLit`: either half is.
    private func sessionMenu(slot: WorkspacePane, isOn: Bool, isLit: Bool) -> some View {
        Menu {
            ForEach(vm.orderedSessions(projectID: project.id)) { session in
                Button(session.title) {
                    Task { await vm.showInPane(slot, item: .session(session.id), projectID: project.id) }
                }
                .disabled(WorkspaceLayout.sessionID(of: slot) == session.id)
            }
            Divider()
            NewSessionMenuItems(vm: vm, projectID: project.id) { agent, worktree in
                Task { await vm.newSession(inPane: slot, projectID: project.id, agent: agent, worktree: worktree) }
            }
        } label: {
            // The twin's right end: a hairline, then the chevron, coloured
            // like the segment.
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isLit ? Color.accentColor : Color.secondary)
            }
            .padding(.trailing, 8)
            .frame(height: 22)
            .background(
                SegmentedToggleStyle.fill(isOn: isOn, isHovered: hoveredView == .chat || chevronHovered),
                in: UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { chevronHovered = $0 }
            .animation(SegmentedToggleStyle.animation, value: isOn)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // Cancel the capsule's segment gap: the chevron continues Workchat.
        .padding(.leading, -2)
        .help("Show another session in the session pane, or start a new one")
        .accessibilityLabel("Sessions")
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

    /// Repair install, Re-run Setup, the archive items, Agent Settings…,
    /// Clean Up Old Worktrees… and Delete…, out of the header row.
    private var moreMenu: some View {
        let status = vm.installStatus[project.id]
        let installing = vm.isInstalling(projectID: project.id)
        return Menu {
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
