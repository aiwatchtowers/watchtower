import Foundation

/// The setup's admin connect (`SlackAppSetupModel.connector`, plan B A4) over
/// the Desktop's connect flow: skip-confirm, awaited to its end. Slack sends
/// no callback for an install request (spike Q5), so `.approvalRequested`
/// never comes from here; an unfinished flow is `.notConnected`.
@MainActor
package final class SlackSetupConnector: SlackSetupConnectStarting {
    private let flow: SlackConnectFlowModel

    package init(flow: SlackConnectFlowModel) {
        self.flow = flow
    }

    package func connectForSetup(teamID: String, clientID: String) async -> SlackSetupConnectOutcome {
        await flow.run(SlackConnectTarget(teamID: teamID, clientID: clientID)) ? .connected : .notConnected
    }
}
