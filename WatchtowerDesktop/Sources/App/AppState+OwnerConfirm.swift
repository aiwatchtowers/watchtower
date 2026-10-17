import AppKit
import WatchtowerCore

extension AppState {
    /// Serves the workspace's owner-confirm socket (AGENT-07, board #568): an
    /// owner-only CLI gesture run outside the Desktop waits for the owner's
    /// click in `OwnerConfirmWindow`. Without it such a gesture is refused,
    /// so a socket another process already serves is shown to the owner.
    func startOwnerConfirm(databasePath: String) {
        guard ownerConfirmServer == nil else { return }
        let path = OwnerConfirmServer.socketPath(databasePath: databasePath)
        let server = OwnerConfirmServer(path: path) { OwnerConfirmWindow.present($0) }
        do {
            try server.start()
            ownerConfirmServer = server
            // The socket file goes with the app; once per process (the guard above).
            _ = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { server.stop() }
            }
        } catch OwnerConfirmServer.ServerError.anotherServer {
            OwnerConfirmWindow.notice(
                title: "Another program serves Watchtower's confirmation socket",
                message: "Something other than this app is listening on \(path). Commands such as "
                    + "`watchtower actions approve` run from a terminal will be refused until it stops "
                    + "and Watchtower is reopened. If you did not start another copy of Watchtower, "
                    + "quit the program holding the socket."
            )
        } catch {
            print("[OwnerConfirm] not serving the confirmation socket: \(error)")
        }
    }
}
