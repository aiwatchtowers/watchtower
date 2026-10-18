import Foundation
import WatchtowerCore

extension AppState {
    /// Connects the terminals to this build's session host (board #496), started when
    /// none serves the socket. Until it answers, or when it cannot, sessions run locally.
    func startSessionHost() {
        let socket = SessionHostPaths.socketPath(bundleID: Constants.bundleID, tempDir: NSTemporaryDirectory())
        terminalCenter.startSessionHost { SessionHostClient(socketPath: socket) { Constants.findCLIPath() } }
    }
}
