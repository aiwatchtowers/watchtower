import AppKit

/// What the quit does once it goes ahead (board #496): hosted workbench
/// sessions are either left running in the session host for the next launch
/// to reattach (`quitKeepingSessions`) or stopped as before
/// (`quitStoppingSessions`).
enum QuitChoice: Equatable {
    case cancel
    case quitKeepingSessions
    case quitStoppingSessions
}

/// The one full-exit path (Cmd+Q, the tray's Quit item and an update's
/// relaunch all land here via applicationShouldTerminate). Injectable seams
/// (`confirmQuit`, `stopDaemon`, `reply`) follow the `openURL` convention so
/// tests can drive every branch without AppKit UI.
@MainActor
enum QuitCoordinator {
    /// `hasBlockingWork` covers everything a quit would destroy or leave
    /// behind that the user should decide on — a live capture AND any queued
    /// or running post-processing job (`MeetingRecorderCenter.isBusy`),
    /// unsent ask answers, live hosted sessions. Without it the quit goes
    /// ahead unasked: keeping the hosted sessions when `keepsSessions` (an
    /// update, a logout, a restart or a shutdown), else stopping them.
    static func shouldTerminate(
        hasBlockingWork: Bool,
        confirmQuit: () -> QuitChoice,
        keepsSessions: Bool = false,
        closeChatSessions: @escaping () async -> Void = {},
        closeTerminals: @escaping () async -> Void = {},
        detachTerminals: @escaping () async -> Void = {},
        stopDaemon: @escaping () async -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        let choice = hasBlockingWork
            ? confirmQuit()
            : (keepsSessions ? .quitKeepingSessions : .quitStoppingSessions)
        if choice == .cancel {
            return .terminateCancel
        }
        Task { @MainActor in
            // CHAT-03: every chat session gets `close`, then SIGTERM after
            // its grace — bounded, and each keeps its partial text (CHAT-01).
            await closeChatSessions()
            if choice == .quitKeepingSessions {
                // PROJ-20: hosted sessions keep running in the session host
                // (no signal); local fallback ones stop as below.
                await detachTerminals()
            } else {
                // Workbench terminals: SIGHUP to each process group, SIGKILL
                // after 3 s — no `claude` outlives the app.
                await closeTerminals()
            }
            await stopDaemon()
            // Always let termination proceed: a stuck daemon must never trap
            // the user in a quit — the next launch adopts or replaces it.
            reply(true)
        }
        return .terminateLater
    }
}
