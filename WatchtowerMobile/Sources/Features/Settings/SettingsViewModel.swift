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

/// One failed observation as Settings → Your Mac lists it.
struct ObservationDiagnostic: Identifiable, Equatable {
    let name: String
    let text: String
    var id: String { name }
}

/// Live Settings state: one observation over the heartbeat, this phone's
/// grant and the outbox overlay, re-read on every replica write.
@MainActor
@Observable
final class SettingsViewModel {
    static let newerFormatNotice = "Update Watchtower on this iPhone: your Mac uses a newer format."
    static let waitingForKeysNotice = "Unlock this iPhone to see the latest from your Mac."

    private(set) var snapshot = SettingsSnapshot()
    /// `newerFormatNotice` once the replica kept a record of a newer envelope
    /// format unread (`ReplicaStore.newerFormatCount`); nil otherwise.
    private(set) var formatNotice: String?
    /// The last read was refused for the keys (locked, or an epoch's keys
    /// not here yet): the snapshot shown is the last one read.
    private(set) var waitingForKeys = false
    @ObservationIgnored private var cancellable: ResilientObservation?
    @ObservationIgnored private var observedDeviceID: String?
    @ObservationIgnored private var store: ReplicaStore?
    @ObservationIgnored private let health: ObservationHealth

    init(health: ObservationHealth = .shared) {
        self.health = health
    }

    /// One row per replica observation that failed since launch, in name
    /// order; empty while none did. Reads `health`, so a view updates on a
    /// new failure.
    func diagnostics(now: Date) -> [ObservationDiagnostic] {
        health.failures.sorted { $0.key < $1.key }.map { name, failure in
            ObservationDiagnostic(name: name, text: Self.text(name: name, failure: failure, now: now))
        }
    }

    private static func text(name: String, failure: ObservationHealth.Failure, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: failure.lastAt, relativeTo: now)
        let text = "\(name) updates: failed \(failure.count)×, last \(when): \(failure.lastMessage)"
        return failure.recovered ? text + " (recovered)" : text
    }

    /// Re-reads the newer-format count: it grows while rows are indexed,
    /// which writes nothing when a row stays unread, so Settings checks
    /// again after every fetch (`AppEnvironment.lastSyncAt`).
    func refreshFormatNotice() {
        guard let store else { return }
        let notice = store.newerFormatCount() > 0 ? Self.newerFormatNotice : nil
        if notice != formatNotice { formatNotice = notice }
    }

    /// Starts (or, for another device id, restarts) the observation.
    func start(store: ReplicaStore, deviceID: String?) {
        if cancellable != nil, observedDeviceID == deviceID { return }
        observedDeviceID = deviceID
        self.store = store
        refreshFormatNotice()
        cancellable?.cancel()
        cancellable = ResilientObservation(
            name: "settings",
            reader: store.reader,
            observation: {
                ValueObservation.tracking { db in
                    try SettingsSnapshot.read(from: db, store: store, deviceID: deviceID)
                }
                .removeDuplicates()
            },
            onWaitingForKeys: { [weak self] in self?.waitingForKeys = true },
            onChange: { [weak self] value in
                guard let self else { return }
                snapshot = value
                if waitingForKeys { waitingForKeys = false }
                refreshFormatNotice()
            }
        )
    }
}
