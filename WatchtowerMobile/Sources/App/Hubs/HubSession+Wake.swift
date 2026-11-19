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

    /// Runs `work` in a task of its own and waits for it, the wait (not the work) ending as soon as the caller is
    /// cancelled: a wake that does not stop on cancel never holds the app's leaving fetch.
    nonisolated static func untilCancelled(_ work: @escaping @Sendable () async -> Void) async {
        let (ended, end) = AsyncStream<Void>.makeStream()
        Task {
            await work()
            end.finish()
        }
        for await _ in ended {}
    }
}
