import Foundation
import os

/// One record surfaced by `ReplicaHydrator.onRecordsApplied`: the identity +
/// notification metadata of a data-zone record a hydration batch actually
/// persisted. Deliberately payload-free — the consumer that needs row content
/// (e.g. an alert snippet) reads it back from the store by recordName.
public struct AppliedSliceRecord: Equatable, Sendable {
    public let recordName: String
    public let kind: SliceKind
    /// Desktop-computed notification tag ("urgent"/"briefing"), nil for
    /// untagged records — see `SliceRecord.notifyLevel`.
    public let notifyLevel: String?
    public let modifiedAt: Date

    public init(recordName: String, kind: SliceKind, notifyLevel: String?, modifiedAt: Date) {
        self.recordName = recordName
        self.kind = kind
        self.notifyLevel = notifyLevel
        self.modifiedAt = modifiedAt
    }
}

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
    /// Fired once per cycle that indexed something, after persist, with the
    /// data-zone records of known kinds `ReplicaStore.indexPending` opened
    /// (F11): the plain record name, the kind and the frame's notify level
    /// (RelayFeed's `onActionApplied` precedent: fire-and-forget, never on
    /// the cycle's error path). Rows stored while the keys were locked are
    /// reported by the first cycle after unlock; a batch dropped by the
    /// store's monotonic guard adds nothing. Records of unknown kinds are
    /// stored but NOT surfaced: this build cannot render them, so it must not
    /// alert about them either. The closure is synchronous; consumers hop to
    /// their own actor/Task (AppEnvironment wires it to the
    /// NotificationCoordinator that way).
    private let onRecordsApplied: (@Sendable ([AppliedSliceRecord]) -> Void)?
    private var loopTask: Task<Void, Never>?
    /// The currently-running cycle, if any. Concurrent `hydrateOnce` callers
    /// await this instead of starting their own — see `hydrateOnce`.
    private var inFlight: Task<(applied: Int, deleted: Int), Error>?
    private let logger = Logger(subsystem: "WatchtowerKit", category: "ReplicaHydrator")

    public init(
        transport: any CloudSyncTransport,
        store: ReplicaStore,
        pull: (@Sendable () async throws -> Void)? = nil,
        onRecordsApplied: (@Sendable ([AppliedSliceRecord]) -> Void)? = nil
    ) {
        self.transport = transport
        self.store = store
        self.pull = pull
        self.onRecordsApplied = onRecordsApplied
    }

    // MARK: - One cycle

    /// One hydration cycle: optional engine pull, read data-zone changes
    /// since the store's persisted token, apply them in one transaction,
    /// then index every row that opens (`ReplicaStore.indexPending`).
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
        // A locked keychain before the first unlock (or no link yet) throws
        // here: nothing of the batch is stored and the token is kept (F15).
        let applied = try store.apply(batch)
        if applied {
            // Consumer-driven compaction of the CONSUMED data-zone buffer (see
            // CompactingTransport's retention note): safe here because the
            // replica is the ONLY data-zone consumer on this device and its
            // floor is its own just-persisted token — desktop hygiene's aged
            // -record scan only touches the hub's .relay buffer (the phone's
            // .relay buffer is RelayFeed's to compact).
            // Hygiene only; a failure must not fail an already-applied cycle.
            if let compacting = transport as? any CompactingTransport {
                do {
                    try await compacting.compact(in: .data, keepSince: batch.newToken)
                } catch {
                    logger.warning("data-zone compaction failed (will retry next cycle): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Every cycle, applied batch or not: rows stored while the keys were
        // locked open on the first cycle after unlock. Only what this pass
        // indexed is reported, so a dropped stale batch reports nothing new.
        let indexed = try store.indexPending()
        if let onRecordsApplied, !indexed.isEmpty {
            onRecordsApplied(indexed)
        }
        guard applied else {
            // Dropped by the monotonic guard — a stale/overlapping batch whose
            // events are already behind our stored token. Nothing applied.
            return (applied: 0, deleted: 0)
        }
        // apply ignores relay records and signals, so count only what reached it.
        let dataRecords = batch.changed.filter { $0.zone == .data && $0.kind != WireKind.signal }
        return (applied: dataRecords.count, deleted: batch.deletedRecordNames.count)
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
