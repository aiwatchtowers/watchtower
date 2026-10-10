import Foundation
import GRDB
import Observation
import os
import WatchtowerSync

/// The Mac's status line in Settings → Your Mac. Online while the DataZone
/// heartbeat is under 720 s old (spec §3, `RelayFeed.heartbeatStaleAfter`);
/// a heartbeat stamped ahead of the phone's clock reads as online.
enum MacStatus: Equatable {
    case notConnected
    case online(macName: String)
    case offline(macName: String, lastSeen: Date)

    init(heartbeat: HeartbeatPayload?, now: Date) {
        guard let heartbeat else {
            self = .notConnected
            return
        }
        let age = Duration.seconds(now.timeIntervalSince(heartbeat.updatedAt))
        self = age < RelayFeed.heartbeatStaleAfter
            ? .online(macName: heartbeat.macName)
            : .offline(macName: heartbeat.macName, lastSeen: heartbeat.updatedAt)
    }

    var title: String {
        switch self {
        case .notConnected: "Your Mac has not connected yet"
        case .online: "Online"
        case .offline: "Offline"
        }
    }

    var macName: String? {
        switch self {
        case .notConnected: nil
        case let .online(name), let .offline(name, _): name
        }
    }
}

/// What Settings shows from the replica, read in one database snapshot.
struct SettingsSnapshot: Equatable {
    /// The hub's DataZone heartbeat; nil when none arrived or it does not
    /// decode.
    var heartbeat: HeartbeatPayload?
    /// The hub's grant for this phone; nil while unlinked or not answered.
    var grant: DeviceGrant?
    /// Outbox rows still waiting for the Mac (failed rows are not queued).
    var queuedCount = 0

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SettingsSnapshot")

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation tracking closure (a nested `DatabasePool.read`
    /// there would trap on reentrancy).
    static func read(from db: Database, store: ReplicaStore, deviceID: String?) throws -> Self {
        var snapshot = Self()
        snapshot.heartbeat = try decode(HeartbeatPayload.self, recordName: HeartbeatPayload.recordName, store: store, from: db)
        if let deviceID {
            snapshot.grant = try decode(
                DeviceGrant.self,
                recordName: SliceKind.deviceGrant.recordName(id: deviceID),
                store: store,
                from: db
            )
        }
        snapshot.queuedCount = try store.pendingActions(from: db).filter { $0.state == .pending }.count
        return snapshot
    }

    /// Both records are RelayCoder JSON in `slice_records`. An undecodable
    /// payload reads as absent (a newer Mac's reshaped record must never
    /// break Settings). The Workbench snapshot reads the heartbeat through it
    /// too.
    static func decode<T: Decodable>(
        _ type: T.Type,
        recordName: String,
        store: ReplicaStore,
        from db: Database
    ) throws -> T? {
        guard let payload = try store.payload(forRecordName: recordName, from: db) else { return nil }
        do {
            return try RelayCoder.makeDecoder().decode(T.self, from: payload)
        } catch {
            logger.warning("undecodable \(recordName, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Live Settings state: one observation over the heartbeat, this phone's
/// grant and the outbox overlay, re-read on every replica write.
@MainActor
@Observable
final class SettingsViewModel {
    private(set) var snapshot = SettingsSnapshot()
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var observedDeviceID: String?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SettingsViewModel")

    /// Starts (or, for another device id, restarts) the observation.
    func start(store: ReplicaStore, deviceID: String?) {
        if cancellable != nil, observedDeviceID == deviceID { return }
        observedDeviceID = deviceID
        let observation = ValueObservation.tracking { db in
            try SettingsSnapshot.read(from: db, store: store, deviceID: deviceID)
        }
        .removeDuplicates()
        cancellable = observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { Self.logger.error("settings observation failed: \($0.localizedDescription, privacy: .public)") },
            onChange: { [weak self] value in
                MainActor.assumeIsolated { self?.snapshot = value }
            }
        )
    }
}
