import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// Everything the Workbench and Now tabs draw, decoded from the replica in
/// one database snapshot: the hub's resolved Workbench slices plus the
/// heartbeat. An undecodable record is skipped (and logged once per read),
/// so a newer Mac's reshaped record never breaks a screen.
struct WorkbenchReplicaSnapshot: Equatable {
    var workbenches: [Workbench] = []
    var targets: [WorkbenchTarget] = []
    var sessions: [TerminalSessionState] = []
    var asks: [OwnerAsk] = []
    var comments: [WorkbenchComment] = []
    var heartbeat: HeartbeatPayload?

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "WorkbenchReplicaSnapshot")

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation tracking closure.
    static func read(from db: Database, store: ReplicaStore) throws -> Self {
        var snapshot = Self()
        snapshot.workbenches = try decodeAll(Workbench.self, store: store, from: db)
        snapshot.targets = try decodeAll(WorkbenchTarget.self, store: store, from: db)
        snapshot.sessions = try decodeAll(TerminalSessionState.self, store: store, from: db)
        snapshot.asks = try decodeAll(OwnerAsk.self, store: store, from: db)
        snapshot.comments = try decodeAll(WorkbenchComment.self, store: store, from: db)
        if let payload = try store.payload(forRecordName: HeartbeatPayload.recordName, from: db) {
            snapshot.heartbeat = try? RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: payload)
        }
        return snapshot
    }

    private static func decodeAll<T: SliceMirror>(_ type: T.Type, store: ReplicaStore, from db: Database) throws -> [T] {
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
            logger.warning("\(skipped) undecodable \(T.sliceKind.rawValue, privacy: .public) records skipped")
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
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "WorkbenchReplicaModel")

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        let observation = ValueObservation.tracking { db in
            try WorkbenchReplicaSnapshot.read(from: db, store: store)
        }
        cancellable = observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { Self.logger.error("workbench observation failed: \($0.localizedDescription, privacy: .public)") },
            onChange: { [weak self] value in
                MainActor.assumeIsolated { self?.snapshot = value }
            }
        )
    }
}
