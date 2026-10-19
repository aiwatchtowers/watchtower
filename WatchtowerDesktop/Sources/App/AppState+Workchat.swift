import GRDB

extension AppState {
    /// The Workchat's control of a session (#711): it writes through the
    /// session's line delivery and reads the session's state from the
    /// agent-state center.
    func makeSessionControl(
        dbPool: DatabasePool, agentStates: SessionAgentStateCenter, lineDelivery: SessionLineDelivery
    ) -> SessionControl {
        SessionControl(
            dbPool: dbPool, terminalCenter: terminalCenter, lineDelivery: lineDelivery
        ) { [weak agentStates] in agentStates?.statuses[$0] }
    }
}
