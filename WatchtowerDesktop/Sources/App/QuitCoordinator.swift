import AppKit

/// The one full-exit path (Cmd+Q and the tray's Quit item both land here via
/// applicationShouldTerminate). Injectable seams (`confirmQuit`, `stopDaemon`,
/// `reply`) follow the `openURL` convention so tests can drive every branch
/// without AppKit UI.
@MainActor
enum QuitCoordinator {
    static func shouldTerminate(
        isCapturing: Bool,
        confirmQuit: () -> Bool,
        stopDaemon: @escaping () async -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        if isCapturing && !confirmQuit() {
            return .terminateCancel
        }
        Task { @MainActor in
            await stopDaemon()
            // Always let termination proceed: a stuck daemon must never trap
            // the user in a quit — the next launch adopts or replaces it.
            reply(true)
        }
        return .terminateLater
    }
}
