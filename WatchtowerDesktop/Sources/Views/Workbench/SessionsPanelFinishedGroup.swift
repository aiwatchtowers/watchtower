import SwiftUI
import WatchtowerCore

/// The sessions panel's session row (main list, finished group or the
/// pinned row — they look alike, board #480): the row with its open asks,
/// report line and closed-asks button, the tab while on screen; the ✕
/// while hovered or under the panel cursor when its agent is not working.
struct SessionsPanelSessionRow: View {
    @Bindable var vm: WorkbenchesViewModel
    let projectID: Int64
    let row: SessionSwitcherPresentation.Row
    let actions: SessionRowActions
    let openAsks: Int
    let closedAsks: Int
    /// The row under the mouse, kept by the panel: its ✕ shows.
    @Binding var hoveredRow: Int64?
    /// The panel has the keyboard (`SessionsPanelKeyView`).
    let panelHasKeyboard: Bool

    var body: some View {
        TerminalSessionRow(
            row: row,
            actions: actions,
            openAsks: openAsks,
            reportLine: row.showsStateLabel ? reportLine : nil,
            reportProgress: row.showsStateLabel && !showsSpecReviewLine
                ? vm.reportProgress(sessionID: row.id, projectID: projectID) : nil,
            reportMergedProgress: vm.reportMergedProgress(sessionID: row.id, projectID: projectID),
            closedAsks: closedAsks > 0
                ? OwnerAskClosedButton(vm: vm, projectID: projectID, sessionID: row.id, count: closedAsks)
                : nil,
            quickDelete: quickDeleteAction,
            deleteButtonTakesKeyboard: vm.requestPanelKeyboard,
            showsDelete: hoveredRow == row.id || hasCursor,
            hasCursor: hasCursor,
            opensIn: row.session.kind.isAgent ? WorkspaceView(vm.layout(projectID: projectID).pane(forSession: row.id)) : nil
        )
        // Deleted, its background cleanup queued or running (board #1716):
        // no resume, no menu. A Clean Up… apply leaves it clickable.
        .disabled(!vm.canResume(row.id))
        .panelTab(isSelected: vm.panelSelection == .session(row.id))
        .onHover { inside in
            if inside {
                hoveredRow = row.id
            } else if hoveredRow == row.id {
                hoveredRow = nil
            }
        }
    }

    /// The report line, or "Cleaning up…" while a Clean Up… apply runs on
    /// this row (board #535), or the spec review
    /// author loop's round while one of its asks is in the loop (#1121).
    private var reportLine: String? {
        if showsCleaningUp { return "Cleaning up…" }
        if let line = vm.specReviewLine(sessionID: row.id) { return line }
        return vm.reportLine(sessionID: row.id, projectID: projectID)
    }

    private var showsCleaningUp: Bool {
        isCleaningUp || vm.sessionCleanup?.cleanupPhase(for: .session(row.id)) == .applying
    }

    private var showsSpecReviewLine: Bool {
        !showsCleaningUp && vm.specReviewLine(sessionID: row.id) != nil
    }

    private var isCleaningUp: Bool { vm.cleaningUpSessions.contains(row.id) }

    private var hasCursor: Bool {
        panelHasKeyboard && vm.panelCursor == row.id
    }

    /// The ✕ and VoiceOver's "Delete session": only on a row whose agent
    /// is not working (`SessionDeletePolicy.isQuick`), nil otherwise. A
    /// state that turned busy since the ✕ showed asks first. It leaves the
    /// keyboard where it is: only a click on the ✕ itself hands it to the
    /// panel (`deleteButtonTakesKeyboard`), so VoiceOver's action never
    /// pulls it out of the terminal or the editor.
    var quickDeleteAction: (() -> Void)? {
        guard !isCleaningUp, SessionDeletePolicy.isQuick(row.state, isWorkbenchSession: true) else { return nil }
        let (vm, actions, session) = (vm, actions, row.session)
        return {
            Task {
                if case let .confirm(busy) = await vm.deleteQuicklyOrConfirm(session) { actions.delete(busy) }
            }
        }
    }
}

/// A deleted session whose background cleanup could not remove everything
/// (board #1716, spec 2026-11-10-auto-cleanup-on-session-delete §3, §7), in
/// the finished group: its title and the warning line in place of the
/// summary, on the kit row's warning-tone plate. **Clean Up Again**,
/// **Delete Anyway** and **Show in Clean Up** are plain row buttons that
/// show on hover; their space is always laid out, so the row never changes
/// height. While Clean Up Again runs the line reads "Cleaning up…" and they
/// are off. In a narrow panel the line keeps to one line and the actions
/// move into a ⋯ menu. A click opens the session's report (with its
/// Cleanup section), never the session. No ⌘1…⌘9 number: it is not in the
/// panel's order.
struct NotFullyCleanedSessionRow: View {
    @Bindable var vm: WorkbenchesViewModel
    let projectID: Int64
    let session: TerminalSession
    /// The row under the mouse, kept by the panel: its actions show.
    @Binding var hoveredRow: Int64?

    private typealias Copy = SessionAutoCleanupPresentation

    /// Below this width the actions move into the ⋯ menu.
    static let narrowWidth: CGFloat = 230

    private var cleaning: Bool { vm.cleaningAgain.contains(session.id) }
    private var actionsOff: Bool { cleaning || vm.autoCleanupBusy.contains(session.id) }
    private var showsActions: Bool { cleaning || hoveredRow == session.id }

    var body: some View {
        // Picked by width, before the first frame: no wide-then-narrow flicker.
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                opener(lineLimit: 2)
                inlineActions
            }
            .frame(minWidth: Self.narrowWidth, idealWidth: Self.narrowWidth, maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                opener(lineLimit: 1)
                menu
            }
        }
        .kitRow(isSelected: false, tint: Tone.warning)
        .onHover { inside in
            if inside {
                hoveredRow = session.id
            } else if hoveredRow == session.id {
                hoveredRow = nil
            }
        }
        .contextMenu { actions }
        .listRowSeparator(.hidden)
    }

    private func opener(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(session.title)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(Copy.rowLine(mark: vm.notFullyCleaned[session.id], cleaning: cleaning))
                .font(.caption)
                .foregroundStyle(Tone.warning)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: lineLimit > 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { vm.openNotFullyCleaned(session.id, projectID: projectID) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { vm.openNotFullyCleaned(session.id, projectID: projectID) }
        .help(Copy.openHelp)
    }

    /// The buttons under the line: laid out always, shown on hover or while
    /// Clean Up Again runs. One line when they fit, else two.
    private var inlineActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.compact) { actions }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.compact) {
                    button(.cleanUpAgain)
                    button(.deleteAnyway)
                }
                button(.showInCleanUp)
            }
        }
        .buttonStyle(.kitQuiet)
        .controlSize(.small)
        .opacity(showsActions ? 1 : 0)
        .allowsHitTesting(showsActions)
        .accessibilityHidden(!showsActions)
    }

    private enum RowAction: CaseIterable { case cleanUpAgain, deleteAnyway, showInCleanUp }

    /// The three actions in order: the inline buttons, the ⋯ menu and the
    /// context menu are all built from `button(_:)`.
    private var actions: some View {
        ForEach(RowAction.allCases, id: \.self) { button($0) }
    }

    private func button(_ action: RowAction) -> some View {
        let (vm, id) = (vm, session.id)
        let (title, help, run): (String, String, () -> Void) = switch action {
        case .cleanUpAgain: (Copy.cleanUpAgain, Copy.cleanUpAgainHelp, { vm.cleanUpAgain(id) })
        case .deleteAnyway: (Copy.deleteAnyway, Copy.deleteAnywayHelp, { Task { await vm.deleteAnyway(id) } })
        case .showInCleanUp: (Copy.showInCleanUp, Copy.showInCleanUpHelp, { vm.showInCleanUp(id) })
        }
        return Button(title, action: run)
            .help(help)
            .disabled(actionsOff)
    }

    private var menu: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help(Copy.moreActions)
        .accessibilityLabel(Copy.moreActions)
    }
}

/// The sessions panel's SESSIONS label, with "Cleaning up 2 sessions…" on
/// its right while the workbench's background cleanups run (board #1716,
/// spec §3). No spinner: the owner already deleted those rows.
struct SessionsPanelSectionLabel: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Text("SESSIONS")
                .sidebarSectionLabel()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.small)
            if let line = SessionAutoCleanupPresentation.cleaningHeader(count: vm.autoCleanupCount(projectID: projectID)) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
