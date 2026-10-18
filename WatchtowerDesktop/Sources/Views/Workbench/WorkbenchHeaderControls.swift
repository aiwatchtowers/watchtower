import SwiftUI
import WatchtowerCore

/// The workbench header's trailing controls: the automation buttons, then `Terminal ▾ | Session | Board |
/// Files | Changes | split | ⋯` (spec 2026-10-03-workbench-session-report Part 7, the
/// owner's pick on board #357).
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
    /// is: Terminal and its chevron light up together, as one segment.
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

    /// Terminal / Session / Board / Files / Changes: on = on screen. Turning one on
    /// shows it (beside the terminal in a split — the Session view beside
    /// its own session's terminal); turning it off closes that pane of a
    /// split. Split then puts two side by side.
    private var viewButtons: some View {
        let layout = vm.layout(projectID: project.id)
        return HStack(spacing: 2) {
            ForEach(WorkspaceView.allCases, id: \.self) { view in
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
                .toggleStyle(HeaderSegmentStyle(
                    joinsChevron: view == .terminal,
                    isHovered: hoveredView == view || (view == .terminal && chevronHovered)
                ) { inside in
                    if inside { hoveredView = view } else if hoveredView == view { hoveredView = nil }
                })
                .help(view.help)
                // No session to review: say so rather than a click that does nothing.
                .disabled((view == .changes || view == .chat) && !layout.isShowing(view) && vm.sessionViewTarget(projectID: project.id) == nil)
                if view == .terminal {
                    sessionMenu(slot: layout.terminalSlot, isOn: layout.isShowing(.terminal))
                }
            }
        }
        .padding(2)
        .frame(height: 26)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    /// The Terminal button's dropdown: which session the terminal pane shows,
    /// or a new one — the split panes' picker actions, so a single pane can
    /// switch sessions with the side panel hidden. A chevron, no extra row.
    private func sessionMenu(slot: WorkspacePane, isOn: Bool) -> some View {
        Menu {
            ForEach(vm.orderedSessions(projectID: project.id)) { session in
                Button(session.title) {
                    Task { await vm.showInPane(slot, item: .session(session.id), projectID: project.id) }
                }
                .disabled(slot == .session(session.id))
            }
            Divider()
            NewSessionMenuItems(vm: vm, projectID: project.id) { agent, worktree in
                Task { await vm.newSession(inPane: slot, projectID: project.id, agent: agent, worktree: worktree) }
            }
        } label: {
            // The Terminal segment's right end: a hairline, then the chevron,
            // coloured like the segment.
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
            .padding(.trailing, 8)
            .frame(height: 22)
            .background(
                HeaderSegmentStyle.fill(isOn: isOn, isHovered: hoveredView == .terminal || chevronHovered),
                in: UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { chevronHovered = $0 }
            .animation(HeaderSegmentStyle.animation, value: isOn)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // Cancel the capsule's segment gap: the chevron continues Terminal.
        .padding(.leading, -2)
        .help("Show another session in the terminal pane, or start a new one")
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
        .buttonStyle(HeaderIconButtonStyle(isOn: isSplit))
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
        .buttonStyle(HeaderIconButtonStyle(isOn: false))
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

/// A view button inside the header capsule: on = accent tint behind an
/// accent icon, off = secondary with a light highlight under the pointer.
/// Hover comes from the controls so Terminal and its chevron share it.
private struct HeaderSegmentStyle: ToggleStyle {
    static let animation: Animation = .snappy(duration: 0.15)

    /// Terminal's: the sessions chevron continues the segment on the right.
    var joinsChevron = false
    var isHovered: Bool
    var onHover: (Bool) -> Void

    static func fill(isOn: Bool, isHovered: Bool) -> Color {
        if isOn { return Color.accentColor.opacity(0.20) }
        return isHovered ? Color.primary.opacity(0.07) : .clear
    }

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        let corner: CGFloat = 6
        let trailing = joinsChevron ? 0 : corner
        return Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                configuration.label
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    // VoiceOver reads the title once, from the copy below.
                    .accessibilityHidden(true)
                configuration.label
                    .labelStyle(.titleOnly)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn || isHovered ? Color.primary : Color.secondary)
            }
            .padding(.leading, 10)
            .padding(.trailing, joinsChevron ? 6 : 10)
            .frame(height: 22)
            .background(
                Self.fill(isOn: isOn, isHovered: isHovered),
                in: UnevenRoundedRectangle(topLeadingRadius: corner, bottomLeadingRadius: corner,
                                           bottomTrailingRadius: trailing, topTrailingRadius: trailing,
                                           style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .animation(Self.animation, value: isOn)
        .animation(Self.animation, value: isHovered)
        // The role `.toggleStyle(.button)` gave the view buttons.
        .accessibilityAddTraits(isOn ? [.isToggle, .isSelected] : .isToggle)
    }
}

/// Split and ⋯ beside the capsule: a 26pt icon square, highlighted under
/// the pointer; `isOn` (split) tints it like an on segment.
private struct HeaderIconButtonStyle: ButtonStyle {
    var isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        IconSquare(configuration: configuration, isOn: isOn)
    }

    private struct IconSquare: View {
        let configuration: Configuration
        let isOn: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 14))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    HeaderSegmentStyle.fill(isOn: isOn, isHovered: isHovered || configuration.isPressed),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .animation(HeaderSegmentStyle.animation, value: isOn)
                .animation(HeaderSegmentStyle.animation, value: isHovered)
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
        case .terminal: "Show the terminal (in a split, beside the other pane)"
        case .report: "Show the session's report (in a split, beside its session's terminal)"
        case .board: "Show the Board (in a split, beside the terminal)"
        case .files: "Show the open files (in a split, beside the terminal)"
        case .analytics: "Agent time, cost and hints for this workbench"
        case .changes: "Review the session's changes"
        case .chat: "Show the session's dialog as a chat (in a split, beside its session's terminal)"
        }
    }
}
