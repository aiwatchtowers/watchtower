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
            reportProgress: row.showsStateLabel ? vm.reportProgress(sessionID: row.id, projectID: projectID) : nil,
            closedAsks: closedAsks > 0
                ? OwnerAskClosedButton(vm: vm, projectID: projectID, sessionID: row.id, count: closedAsks)
                : nil,
            quickDelete: quickDeleteAction,
            deleteButtonTakesKeyboard: vm.requestPanelKeyboard,
            showsDelete: hoveredRow == row.id || hasCursor,
            hasCursor: hasCursor
        )
        // Its terminal closed by Delete and Clean Up (board #535): no
        // resume, no menu. A Clean Up… apply leaves it clickable.
        .disabled(vm.closedForCleanup.contains(row.id))
        .panelTab(isSelected: vm.panelSelection == .session(row.id))
        .onHover { inside in
            if inside {
                hoveredRow = row.id
            } else if hoveredRow == row.id {
                hoveredRow = nil
            }
        }
    }

    /// The report line, or "Cleaning up…" while Delete and Clean Up or a
    /// Clean Up… apply runs on this row (board #535).
    private var reportLine: String? {
        if isCleaningUp || vm.sessionCleanup?.cleanupPhase(for: .session(row.id)) == .applying { return "Cleaning up…" }
        return vm.reportLine(sessionID: row.id, projectID: projectID)
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

/// The "▸ N finished" / "▾ N finished" header at the bottom of SESSIONS
/// (board #480, spec 2026-10-12-sessions-panel-design §4.5): a click opens
/// or folds the group, remembered per workbench.
struct SessionsPanelFinishedHeader: View {
    let count: Int
    let expanded: Bool
    let onFold: () -> Void

    var body: some View {
        Button(action: onFold) {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 10)
                Text("\(count) finished")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .help(expanded ? "Hide finished sessions" : "Show finished sessions")
        .accessibilityLabel("\(count) finished session\(count == 1 ? "" : "s"), \(expanded ? "expanded" : "collapsed")")
        .accessibilityAddTraits(.isHeader)
    }
}
