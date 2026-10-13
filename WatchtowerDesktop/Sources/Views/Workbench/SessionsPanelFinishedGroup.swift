import SwiftUI
import WatchtowerCore

/// The sessions panel's session row (main list, finished group or the
/// pinned row — they look alike, board #480): the row with its open asks,
/// report line and closed-asks button, the tab while on screen.
struct SessionsPanelSessionRow: View {
    @Bindable var vm: WorkbenchesViewModel
    let projectID: Int64
    let row: SessionSwitcherPresentation.Row
    let actions: SessionRowActions
    let openAsks: Int
    let closedAsks: Int

    var body: some View {
        TerminalSessionRow(
            row: row,
            actions: actions,
            openAsks: openAsks,
            reportLine: row.showsStateLabel ? vm.reportLine(sessionID: row.id, projectID: projectID) : nil,
            reportProgress: row.showsStateLabel ? vm.reportProgress(sessionID: row.id, projectID: projectID) : nil,
            closedAsks: closedAsks > 0
                ? OwnerAskClosedButton(vm: vm, projectID: projectID, sessionID: row.id, count: closedAsks)
                : nil
        )
        .panelTab(isSelected: vm.panelSelection == .session(row.id))
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
