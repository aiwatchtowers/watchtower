import Foundation
import WatchtowerCore

extension AppState {
    /// Serves the workspace's owner-confirm socket (AGENT-07, board #568): an
    /// owner-only CLI gesture run outside the Desktop waits for the owner's
    /// click in `OwnerConfirmWindow`. Without it the CLI falls back to a code
    /// typed on a terminal, so a failure here is logged, not shown.
    func startOwnerConfirm(databasePath: String) {
        guard ownerConfirmServer == nil else { return }
        let server = OwnerConfirmServer(path: OwnerConfirmServer.socketPath(databasePath: databasePath)) {
            OwnerConfirmWindow.present($0)
        }
        do {
            try server.start()
            ownerConfirmServer = server
        } catch {
            print("[OwnerConfirm] not serving the confirmation socket: \(error)")
        }
    }
}
