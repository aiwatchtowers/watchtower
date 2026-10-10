import Observation

/// One send per key at a time: until the outbox has saved an action and its
/// overlay row, a second send on the same key is a no-op. Shared by the
/// board writes (one per field or comment target) and the ask answers (one
/// per ask), so a double tap never sends twice.
@MainActor
@Observable
final class SendGuard {
    /// The keys whose send is still waiting for the outbox.
    private(set) var inFlight: Set<String> = []

    /// Runs `send` unless `key` is already in flight; returns whether it ran.
    func run(_ key: String, _ send: () async throws -> Void) async throws -> Bool {
        guard inFlight.insert(key).inserted else { return false }
        defer { inFlight.remove(key) }
        try await send()
        return true
    }
}
