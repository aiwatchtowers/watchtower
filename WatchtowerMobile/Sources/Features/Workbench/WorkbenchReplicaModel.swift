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

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation tracking closure.
    static func read(from db: Database, store: ReplicaStore) throws -> Self {
        var snapshot = Self()
        snapshot.workbenches = try snapshot.decodeAll(Workbench.self, store: store, from: db)
        snapshot.targets = try snapshot.decodeAll(WorkbenchTarget.self, store: store, from: db)
        snapshot.sessions = try snapshot.decodeAll(TerminalSessionState.self, store: store, from: db)
        snapshot.asks = try snapshot.decodeAll(OwnerAsk.self, store: store, from: db)
        snapshot.comments = try snapshot.decodeAll(WorkbenchComment.self, store: store, from: db)
        snapshot.heartbeat = try SettingsSnapshot.decode(
            HeartbeatPayload.self,
            recordName: HeartbeatPayload.recordName,
            store: store,
            from: db
        )
        let decoder = RelayCoder.makeDecoder()
        snapshot.grants = try store.payloads(of: .deviceGrant, from: db).compactMap { try? decoder.decode(DeviceGrant.self, from: $0) }
        snapshot.pending = try store.pendingActions(from: db)
        return snapshot
    }

    private mutating func decodeAll<T: SliceMirror>(_ type: T.Type, store: ReplicaStore, from db: Database) throws -> [T] {
        var skipped = 0
        let decoded = try store.payloads(of: T.sliceKind, from: db).compactMap { payload -> T? in
            do {
                return try T.decode(payload: payload)
            } catch {
                skipped += 1
                return nil
            }
        }
        if skipped > 0 {
            skippedRecords[T.sliceKind] = skipped
        }
        return decoded
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

/// Live replica state for one tab root: one observation over the slice
/// records, re-read on every replica write.
@MainActor
@Observable
final class WorkbenchReplicaModel {
    private(set) var snapshot = WorkbenchReplicaSnapshot()
    /// The open asks across all workbenches: the Workbench tab's badge.
    /// Its own property, so the tab bar re-renders only when it changes.
    private(set) var openAskCount = 0
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "WorkbenchReplicaModel")

    /// The slices re-read on every replica write; a write that leaves them
    /// equal (another kind's record, a sync token) publishes nothing.
    nonisolated static func observation(
        store: ReplicaStore
    ) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<WorkbenchReplicaSnapshot>>> {
        ValueObservation.tracking { db in
            try WorkbenchReplicaSnapshot.read(from: db, store: store)
        }
        .removeDuplicates()
    }

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        cancellable = Self.observation(store: store).start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { Self.logger.error("workbench observation failed: \($0.localizedDescription, privacy: .public)") },
            onChange: { [weak self] value in
                MainActor.assumeIsolated { self?.receive(value) }
            }
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
