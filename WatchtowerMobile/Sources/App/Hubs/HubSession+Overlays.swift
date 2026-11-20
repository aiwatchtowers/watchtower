import Foundation
import os
import WatchtowerSync

// MARK: - Optimistic overlays (live link R5)

extension HubSession {
    /// This hub's overlay book and the two writers that fill it: board writes and ask answers show at tap time.
    /// The book's tap → applied echo timings go to the replica's `latency_confirm` on the route's transport (the
    /// outbox's rule: no route is the private CloudKit one) and to the log, as `wake_ms` does (live link R7): the
    /// line carries the action's kind (a fixed vocabulary), the transport and the time, nothing of its content.
    static func makeWriters(
        outbox: ActionOutbox, store: ReplicaStore, drafts: AskDraftStore, hubID: String, route: HubRoute?
    ) -> (OverlayBook, BoardWriter, AskAnswerer) {
        let transport = transportKind(of: route ?? .cloudKit(.private))
        let overlays = OverlayBook(hubID: hubID) { kind, ms, at in
            store.recordConfirm(kind: kind, ms: ms, transport: transport, at: at)
            guard ms >= 0 else { return }  // a clock moved: no row either
            let what = "\(kind.rawValue), \(transport.rawValue)"
            logger.info("confirm: applied echo in \(ms, privacy: .public) ms (\(what, privacy: .public))")
        }
        return (
            overlays,
            BoardWriter.sending(through: outbox, store: store, overlays: overlays),
            AskAnswerer.sending(through: outbox, store: store, drafts: drafts, overlays: overlays)
        )
    }

    /// The outbox's one applied observer, shared by the app and the tests:
    /// every applied echo goes to every consumer on the main actor, and
    /// each keeps only its own kind. `overlays` takes it as it arrives: its
    /// `confirm_ms` is tap → this echo.
    nonisolated static func appliedObserver(
        askAnswerer: AskAnswerer,
        sessionStarts: SessionStarter,
        sessionInputs: SessionInputSender? = nil,
        boardWriter: BoardWriter? = nil,
        chats: ChatsCenter? = nil,
        inbox: InboxCenter? = nil,
        overlays: OverlayBook? = nil
    ) -> @Sendable (ActionRequestPayload) -> Void {
        { [weak askAnswerer, weak sessionStarts, weak sessionInputs, weak boardWriter, weak chats, weak inbox, weak overlays] action in
            let arrived = Date()
            Task { @MainActor in
                askAnswerer?.receiveApplied(action)
                sessionStarts?.receiveApplied(action)
                sessionInputs?.receiveApplied(action)
                boardWriter?.receiveApplied(action)
                chats?.receiveApplied(action)
                inbox?.receiveApplied(action)
                overlays?.receiveEcho(action, now: arrived)
            }
        }
    }
}
