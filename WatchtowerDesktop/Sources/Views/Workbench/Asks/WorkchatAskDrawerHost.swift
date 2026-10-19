import SwiftUI
import WatchtowerCore

/// A session's Workchat with its ask drawer (#711): the drawer opens beside
/// whichever mode of the session is on screen, as `WorkbenchSessionView`
/// hosts it beside the terminal. With the session's terminal on screen too
/// (a split), the terminal keeps the drawer and this pane neither shows it
/// nor reports room for one, so an ask never opens twice.
struct WorkchatAskDrawerHost<Content: View>: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let sessionID: Int64
    @ViewBuilder let content: () -> Content

    var body: some View {
        let terminalShown = vm.layout(projectID: projectID).visiblePanes.contains(.session(sessionID))
        let drawerAsk = terminalShown ? nil
            : vm.asks.drawerAsk(projectID: projectID).flatMap { $0.sessionID == sessionID ? $0 : nil }
        // Always hosted, so the Workchat keeps its identity when the drawer comes and goes.
        OwnerAskDrawerHost(vm: vm, ask: drawerAsk, workspace: content)
            .onGeometryChange(for: Bool.self, of: {
                OwnerAskDrawerLayout.fitsBeside(total: $0.size.width)
            }, action: { fits in
                guard !vm.layout(projectID: projectID).visiblePanes.contains(.session(sessionID)) else { return }
                vm.sessionPaneMeasured(sessionID, projectID: projectID, fits: fits)
            })
            .onDisappear {
                guard !vm.layout(projectID: projectID).visiblePanes.contains(.session(sessionID)) else { return }
                vm.asks.setRoomBeside(false, sessionID: sessionID)
            }
    }
}
