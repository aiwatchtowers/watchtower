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
}
