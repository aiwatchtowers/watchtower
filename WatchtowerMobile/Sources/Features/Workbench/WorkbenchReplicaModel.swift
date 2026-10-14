import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// Everything the Workbench and Now tabs draw, decoded from the replica in
/// one database snapshot: the hub's resolved Workbench slices plus the
/// heartbeat. An undecodable record is skipped and counted in
/// `skippedRecords`, so a newer Mac's reshaped record never breaks a screen.
struct WorkbenchReplicaSnapshot: Equatable {
    var workbenches: [Workbench] = []
    var targets: [WorkbenchTarget] = []
    var sessions: [TerminalSessionState] = []
    var asks: [OwnerAsk] = []
    var comments: [WorkbenchComment] = []
    var heartbeat: HeartbeatPayload?
    /// The hub's `device_grant` records (spec §4.13); `grant(for:)` picks
    /// this phone's. An undecodable one is left out.
    var grants: [DeviceGrant] = []
    /// The outbox overlay: the phone's actions the Mac has not yet applied
    /// (pending) or refused (failed), oldest first.
    var pending: [PendingAction] = []
    /// Undecodable records per kind in this read; kinds without any are
    /// absent.
    var skippedRecords: [SliceKind: Int] = [:]

    /// The slice kinds this snapshot decodes.
    static let kinds: [SliceKind] = [
        Workbench.sliceKind, WorkbenchTarget.sliceKind, TerminalSessionState.sliceKind,
        OwnerAsk.sliceKind, WorkbenchComment.sliceKind, .heartbeat, .deviceGrant
    ]

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation fetch. A kind whose change stamp is unchanged comes
    /// from `cache` undecoded; the default fresh cache decodes everything.
    static func read(from db: Database, store: ReplicaStore, cache: ReplicaDecodeCache = ReplicaDecodeCache()) throws -> Self {
        let versions = try store.kindVersions(kinds, from: db)
        var snapshot = Self()
        snapshot.workbenches = try snapshot.decodeAll(Workbench.self, store: store, from: db, cache: cache, versions: versions)
        snapshot.targets = try snapshot.decodeAll(WorkbenchTarget.self, store: store, from: db, cache: cache, versions: versions)
        snapshot.sessions = try snapshot.decodeAll(TerminalSessionState.self, store: store, from: db, cache: cache, versions: versions)
        snapshot.asks = try snapshot.decodeAll(OwnerAsk.self, store: store, from: db, cache: cache, versions: versions)
        snapshot.comments = try snapshot.decodeAll(WorkbenchComment.self, store: store, from: db, cache: cache, versions: versions)
        snapshot.heartbeat = try cache.value(HeartbeatPayload.recordName, version: versions[.heartbeat] ?? 0) {
            try SettingsSnapshot.decode(HeartbeatPayload.self, recordName: HeartbeatPayload.recordName, store: store, from: db)
        }
        snapshot.grants = try cache.value(SliceKind.deviceGrant.rawValue, version: versions[.deviceGrant] ?? 0) {
            let decoder = RelayCoder.makeDecoder()
            return try store.payloads(of: .deviceGrant, from: db).compactMap { try? decoder.decode(DeviceGrant.self, from: $0) }
        }
        snapshot.pending = try store.pendingActions(from: db)
        return snapshot
    }

    /// One kind's decoded records and how many did not decode.
    private struct Decoded<T> {
        let records: [T]
        let skipped: Int
    }

    private mutating func decodeAll<T: SliceMirror>(
        _ type: T.Type,
        store: ReplicaStore,
        from db: Database,
        cache: ReplicaDecodeCache,
        versions: [SliceKind: Int64]
    ) throws -> [T] {
        let decoded = try cache.value(T.sliceKind.rawValue, version: versions[T.sliceKind] ?? 0) {
            var skipped = 0
            let records = try store.payloads(of: T.sliceKind, from: db).compactMap { payload -> T? in
                do {
                    return try T.decode(payload: payload)
                } catch {
                    skipped += 1
                    return nil
                }
            }
            return Decoded(records: records, skipped: skipped)
        }
        if decoded.skipped > 0 {
            skippedRecords[T.sliceKind] = decoded.skipped
        }
        return decoded.records
    }

    /// The Workbench list's order: latest session activity first (none
    /// last), then by name.
    var orderedWorkbenches: [Workbench] {
        workbenches.sorted { lhs, rhs in
            switch (lhs.lastSessionActivity, rhs.lastSessionActivity) {
            case let (left?, right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    func workbench(_ id: Int64) -> Workbench? {
        workbenches.first { $0.id == id }
    }

    /// This phone's grant; nil while unlinked or before the hub wrote one.
    func grant(for deviceID: String?) -> DeviceGrant? {
        deviceID.flatMap { id in grants.first { $0.deviceID == id } }
    }

    func session(_ id: Int64) -> TerminalSessionState? {
        sessions.first { $0.id == id }
    }

    /// Open asks, newest first; all workbenches when `workbenchID` is nil.
    func openAsks(in workbenchID: Int64? = nil) -> [OwnerAsk] {
        asks
            .filter { $0.status == .open && (workbenchID == nil || $0.workbenchID == workbenchID) }
            .sorted(by: Self.newestFirst)
    }

    static func newestFirst(_ lhs: OwnerAsk, _ rhs: OwnerAsk) -> Bool {
        lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id > rhs.id
    }
}

/// Live replica state for one tab root: one observation over the change
/// stamps of its kinds and the outbox overlay.
@MainActor
@Observable
final class WorkbenchReplicaModel {
    private(set) var snapshot = WorkbenchReplicaSnapshot()
    /// The open asks across all workbenches: the Workbench tab's badge.
    /// Its own property, so the tab bar re-renders only when it changes.
    private(set) var openAskCount = 0
    /// The decoded kinds between reads (and the tests' decode counter).
    @ObservationIgnored let decodeCache = ReplicaDecodeCache()
    @ObservationIgnored private var cancellable: ResilientObservation?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "WorkbenchReplicaModel")

    /// Re-read when a stamp changes (any kind's write) or the overlay does;
    /// only this snapshot's changed kinds decode again, and a read that
    /// leaves it equal publishes nothing.
    nonisolated static func observation(
        store: ReplicaStore,
        cache: ReplicaDecodeCache = ReplicaDecodeCache()
    ) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<WorkbenchReplicaSnapshot>>> {
        ValueObservation.tracking(regions: [ReplicaStore.kindVersionsRegion, ReplicaStore.pendingActionsRegion]) { db in
            try WorkbenchReplicaSnapshot.read(from: db, store: store, cache: cache)
        }
        .removeDuplicates()
    }

    func start(store: ReplicaStore, gate: ReplicaObservationGate? = nil) {
        guard cancellable == nil else { return }
        let cache = decodeCache
        cancellable = ResilientObservation(
            name: "workbench",
            reader: store.reader,
            gate: gate,
            observation: { Self.observation(store: store, cache: cache) },
            onChange: { [weak self] value in self?.receive(value) }
        )
    }

    /// Logs the skipped records only when their count changes, not on
    /// every replica write.
    private func receive(_ value: WorkbenchReplicaSnapshot) {
        if value.skippedRecords != snapshot.skippedRecords {
            for (kind, count) in value.skippedRecords.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                Self.logger.warning("\(count) undecodable \(kind.rawValue, privacy: .public) records skipped")
            }
        }
        snapshot = value
        let openAsks = value.openAsks().count
        if openAsks != openAskCount {
            openAskCount = openAsks
        }
    }
}
