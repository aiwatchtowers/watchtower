import Foundation
import os

/// Pulls DataZone changes from the transport into the local ReplicaStore —
/// the mobile counterpart of the desktop's SlicePublisher, with the same
/// Task-loop shape (start/stop, per-cycle error logging, sleep between
/// cycles).
public actor ReplicaHydrator {
    private let transport: any CloudSyncTransport
    private let store: ReplicaStore
    /// Wraps CloudKitTransport.pull() at composition time; nil in tests
    /// (InMemoryCloudTransport has no engine to nudge).
    private let pull: (@Sendable () async throws -> Void)?
    private var loopTask: Task<Void, Never>?
    /// The currently-running cycle, if any. Concurrent `hydrateOnce` callers
    /// await this instead of starting their own — see `hydrateOnce`.
    private var inFlight: Task<(applied: Int, deleted: Int), Error>?
    private let logger = Logger(subsystem: "WatchtowerKit", category: "ReplicaHydrator")

    public init(
        transport: any CloudSyncTransport,
        store: ReplicaStore,
        pull: (@Sendable () async throws -> Void)? = nil
    ) {
        self.transport = transport
        self.store = store
        self.pull = pull
    }

    // MARK: - One cycle

    /// One hydration cycle: optional engine pull, read data-zone changes
    /// since the store's persisted token, apply them in one transaction.
    ///
    /// Cycles are coalesced: actors are reentrant, so a caller arriving while
    /// a cycle is suspended (at `pull`/`changes`) would otherwise start a
    /// second overlapping cycle whose older batch could regress the token and
    /// overwrite fresher payloads. Concurrent callers instead await the
    /// running cycle's own result. (The store's monotonic `apply` guard is
    /// the belt to this suspenders.)
    @discardableResult
    public func hydrateOnce() async throws -> (applied: Int, deleted: Int) {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await self.performHydration() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performHydration() async throws -> (applied: Int, deleted: Int) {
        try await pull?()
        let batch = try await transport.changes(in: .data, since: store.storedToken())
        guard try store.apply(batch) else {
            // Dropped by the monotonic guard — a stale/overlapping batch whose
            // events are already behind our stored token. Nothing applied,
            // nothing to compact.
            return (applied: 0, deleted: 0)
        }

        // Consumer-driven compaction of the CONSUMED data-zone buffer (see
        // CompactingTransport's retention note): safe here because the
        // replica is the ONLY data-zone consumer on this device and its
        // floor is its own just-persisted token — desktop hygiene's aged
        // -record scan only touches .relay, which we never compact.
        // Hygiene only; a failure must not fail an already-applied cycle.
        if let compacting = transport as? any CompactingTransport {
            do {
                try await compacting.compact(in: .data, keepSince: batch.newToken)
            } catch {
                logger.warning("data-zone compaction failed (will retry next cycle): \(error.localizedDescription, privacy: .public)")
            }
        }

        // apply ignores relay records, so count only what actually landed.
        let applied = batch.changed.filter { $0.zone == .data }.count
        return (applied: applied, deleted: batch.deletedRecordNames.count)
    }

    // MARK: - Poll loop

    public func start(interval: Duration = .seconds(30)) {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    _ = try await self.hydrateOnce()
                } catch {
                    self.logger.error("hydration cycle failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }
}
