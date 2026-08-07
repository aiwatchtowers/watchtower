import AppKit

/// The one full-exit path (Cmd+Q and the tray's Quit item both land here via
/// applicationShouldTerminate). Injectable seams (`confirmQuit`, `stopDaemon`,
/// `reply`) follow the `openURL` convention so tests can drive every branch
/// without AppKit UI.
@MainActor
enum QuitCoordinator {
    /// `hasBlockingWork` covers everything a quit would destroy that the user
    /// cannot get back by relaunching — a live capture AND any queued or
    /// running post-processing job (`MeetingRecorderCenter.isBusy`), not just
    /// the capture: killing a transcription mid-flight loses the run.
    static func shouldTerminate(
        hasBlockingWork: Bool,
        confirmQuit: () -> Bool,
        stopDaemon: @escaping () async -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        if hasBlockingWork && !confirmQuit() {
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
