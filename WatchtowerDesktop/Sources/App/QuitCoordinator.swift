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
        shutdownChat: @escaping () async -> Void = {},
        closeTerminals: @escaping () async -> Void = {},
        detachTerminals: @escaping () async -> Void = {},
        stopDaemon: @escaping () async -> Void,
        finishPendingDeletes: @escaping () async -> Void = {},
        stopBackgroundCleanups: @escaping () async -> Void = {},
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        let choice = hasBlockingWork
            ? confirmQuit()
            : (keepsSessions ? .quitKeepingSessions : .quitStoppingSessions)
        if choice == .cancel {
            return .terminateCancel
        }
        Task { @MainActor in
            // PROJ-17: the sessions waiting in the Undo batch are deleted
            // from the start, alongside the steps below, so the two bounds
            // overlap rather than add up (board #588) — on every quit,
            // sessions kept or stopped. Bounded inside; awaited before the
            // reply.
            let deletes = Task { @MainActor in await finishPendingDeletes() }
            // Board #1716: a deleted session's background cleanup still
            // running gets SIGTERM to its process group, SIGKILL after 5 s —
            // no cleanup outlives the app to race the next launch's, which
            // queues the row again (it keeps `delete_requested_at`).
            let cleanups = Task { @MainActor in await stopBackgroundCleanups() }
            // CHAT-03: the engine ends every chat turn (partial kept,
            // CHAT-01) and reaps every session — `close`, then SIGTERM after
            // its grace — bounded; the CLI does it when the engine cannot.
            await shutdownChat()
            if choice == .quitKeepingSessions {
                // PROJ-20: hosted sessions keep running in the session host
                // (no signal).
                await detachTerminals()
            } else {
                // Workbench terminals: SIGHUP to each process group, SIGKILL
                // after 3 s — no `claude` outlives the app.
                await closeTerminals()
            }
            await stopDaemon()
            await deletes.value
            await cleanups.value
            // Always let termination proceed: a stuck daemon must never trap
            // the user in a quit — the next launch adopts or replaces it.
            reply(true)
        }
        return .terminateLater
    }

    /// Spec §7: a stop that must end the chat asks the engine first
    /// (`chat_shutdown` on `chat.sock`, `SocketChatClient.shutdown()`); when
    /// it could not (unreachable, refused, past its bound) `watchtower chat
    /// shutdown` ends the turns and reaps the sessions over their own
    /// sockets and group files. Quit, the data wipe and Slack disconnect.
    static func shutdownChat(engine: () async -> Bool, cli: () async -> Void) async {
        if await engine() { return }
        await cli()
    }
}
