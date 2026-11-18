import Foundation
import WatchtowerSync

// MARK: - Optimistic overlays (live link R5)

extension HubSession {
    /// This hub's overlay book and the two writers that fill it: board writes and ask answers show at tap time.
    /// The book's tap → applied echo timings go to the replica's `latency_confirm` on the route's transport (the
    /// outbox's rule: no route is the private CloudKit one).
    static func makeWriters(
        outbox: ActionOutbox, store: ReplicaStore, drafts: AskDraftStore, hubID: String, route: HubRoute?
    ) -> (OverlayBook, BoardWriter, AskAnswerer) {
        let transport = transportKind(of: route ?? .cloudKit(.private))
        let overlays = OverlayBook(hubID: hubID) { kind, ms, at in
            store.recordConfirm(kind: kind, ms: ms, transport: transport, at: at)
        }
        return (
            overlays,
            BoardWriter.sending(through: outbox, store: store, overlays: overlays),
            AskAnswerer.sending(through: outbox, store: store, drafts: drafts, overlays: overlays)
        )
    }
}
