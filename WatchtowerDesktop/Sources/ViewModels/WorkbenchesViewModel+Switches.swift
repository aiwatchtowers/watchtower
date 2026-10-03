import Foundation

/// Ordering of the owner's session switches in a workbench (board #187).
extension WorkbenchesViewModel {
    /// Records that the owner just asked for something else on screen in
    /// `projectID` — a session switch, or a layout change of its own (a view
    /// button, a pane's picker, Split) — and returns its ticket. A switch
    /// takes it at its entry point, before its first await: switches finish
    /// out of order (a list load, the `touch` write behind another writer, a
    /// Start fresh waiting for its old process), and only the one asked for
    /// last may still focus its session, move the layout or report an error
    /// — else an earlier, slower click lands after a later one and puts its
    /// session back on screen (board #187). nil = standalone: its selection
    /// is set at once (`showStandalone`), nothing to order.
    @discardableResult
    func beginSwitch(projectID: Int64?) -> Int {
        switchSerial += 1
        if let projectID { latestSwitch[projectID] = switchSerial }
        return switchSerial
    }

    /// Whether no later switch was asked for in `projectID` since `ticket`.
    func isLatestSwitch(_ ticket: Int, projectID: Int64?) -> Bool {
        projectID.map { latestSwitch[$0] == ticket } ?? true
    }

    /// A new switch starts clean: the page's last error goes — unless a later
    /// switch is already under way, whose error it may be.
    func clearSwitchError(projectID: Int64?, ticket: Int) {
        if isLatestSwitch(ticket, projectID: projectID) { sessionActionErrors[projectID] = nil }
    }

    /// A switch's failure: on the page while it is the latest switch; a
    /// superseded one's is only logged, so it neither covers the latest
    /// switch's own error nor shows beside a session that is fine.
    func reportSwitchError(_ message: String, projectID: Int64?, ticket: Int) {
        guard isLatestSwitch(ticket, projectID: projectID) else {
            NSLog("WorkbenchesViewModel: superseded session switch failed: %@", message)
            return
        }
        sessionActionErrors[projectID] = message
    }
}
