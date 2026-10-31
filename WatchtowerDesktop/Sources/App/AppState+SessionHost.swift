import Foundation
import WatchtowerCore

extension AppState {
    /// Connects the terminals to this build's session host (board #496), started when
    /// none serves the socket. Sessions run only there: when it cannot be reached, a
    /// session's launch tries once more and otherwise shows the reason in its pane.
    func startSessionHost() {
        let socket = SessionHostPaths.socketPath(bundleID: Constants.bundleID, tempDir: NSTemporaryDirectory())
        terminalCenter.startSessionHost { SessionHostClient(socketPath: socket) { Constants.findCLIPath() } }
    }
}
