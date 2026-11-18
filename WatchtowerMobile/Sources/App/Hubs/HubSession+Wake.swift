import Foundation
import WatchtowerSync

/// Live link R7: the phone's wake timing.
extension HubSession {
    /// The return's fetch read every zone: one `wake_ms` sample (became active → all zones read) in the replica's
    /// latency rows and the log (live link R7). Once per activation.
    func recordWake() {
        guard let activatedAt else { return }
        self.activatedAt = nil
        let readAt = now()
        let ms = Int((readAt.timeIntervalSince(activatedAt) * 1000).rounded())
        let transport = route.map(Self.transportKind(of:)) ?? .cloudKit
        store.recordWake(ms: ms, transport: transport, at: readAt)
        Self.logger.info("wake: all zones read in \(ms, privacy: .public) ms (\(transport.rawValue, privacy: .public))")
    }
}
