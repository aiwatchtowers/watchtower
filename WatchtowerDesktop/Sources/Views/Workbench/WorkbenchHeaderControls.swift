import SwiftUI
import WatchtowerCore

/// The workbench header's trailing controls: `Terminal ▾ | Session | Board |
/// Files | split | ⋯` (spec 2026-10-03-workbench-session-report Part 7, the
/// owner's pick on board #357).
struct WorkbenchHeaderControls: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    /// The ⋯ menu's Delete…: the page reads the counts and confirms.
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            viewButtons
            splitToggle
            moreMenu
        }
    }

    /// Terminal / Session / Board / Files: on = on screen. Turning one on
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
                .toggleStyle(.button)
                .help(view.help)
                if view == .terminal { sessionMenu(slot: layout.terminalSlot) }
            }
        }
        .controlSize(.small)
    }

    /// The Terminal button's dropdown: which session the terminal pane shows,
    /// or a new one — the split panes' picker actions, so a single pane can
    /// switch sessions with the side panel hidden. A chevron, no extra row.
    private func sessionMenu(slot: WorkspacePane) -> some View {
        Menu {
            ForEach(vm.orderedSessions(projectID: project.id)) { session in
                Button(session.title) {
                    Task { await vm.showInPane(slot, item: .session(session.id), projectID: project.id) }
                }
                .disabled(slot == .session(session.id))
            }
            Divider()
            Button("New session") {
                Task { await vm.newSession(inPane: slot, projectID: project.id) }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show another session in the terminal pane, or start a new one")
        .accessibilityLabel("Sessions")
    }

    private var splitToggle: some View {
        let isSplit = vm.layout(projectID: project.id).isSplit
        return Button {
            vm.toggleSplit(projectID: project.id)
        } label: {
            Image(systemName: isSplit ? "rectangle" : "rectangle.split.2x1")
        }
        .buttonStyle(.borderless)
        .help(isSplit ? "Show one pane" : "Split: show two panes side by side")
        .accessibilityLabel(isSplit ? "Single Pane" : "Split")
    }

    /// Repair install, Re-run Setup, the archive items and Delete…, out of the
    /// header row.
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
            Button {
                Task { await vm.resync(projectID: project.id) }
            } label: {
                Label("Re-run Setup", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(installing)
            .help("Re-index the folder for search and re-install what is missing. Never changes the board, comments or sources.")
            archiveMenu
            archiveNowItems
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete…", systemImage: "trash")
            }
            .disabled(vm.deletingWorkbenchID != nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
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
    /// Repair install's help.
    var repairHelp: String {
        "Skill \(skillDisplay) · hook \(hook ? "on" : "missing") · "
            + "drift hook \(stopHook ? "on" : "missing") · "
            + "state hooks \(stateHooks ? "on" : "missing") · "
            + "ask guard \(askGuard && askToolBlock ? "on" : "missing") · MCP \(mcp ? "on" : "missing")"
    }
}

private extension WorkspaceView {
    var help: String {
        switch self {
        case .terminal: "Show the terminal (in a split, beside the other pane)"
        case .report: "Show the session's report (in a split, beside its session's terminal)"
        case .board: "Show the Board (in a split, beside the terminal)"
        case .files: "Show the open files (in a split, beside the terminal)"
        }
    }
}
