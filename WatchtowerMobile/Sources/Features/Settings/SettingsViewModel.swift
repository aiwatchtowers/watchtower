import Foundation
import GRDB
import Observation
import os
import WatchtowerSync

/// The Mac's status line in Settings → Your Mac. Online while the DataZone
/// heartbeat is under 2100 s old (spec §3, `RelayFeed.heartbeatStaleAfter`);
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

    /// The slice kinds this snapshot decodes.
    static let kinds: [SliceKind] = [.heartbeat, .deviceGrant]

    /// Reads from an ALREADY-OPEN database, so it runs inside a
    /// ValueObservation fetch (a nested `DatabasePool.read` there would
    /// trap on reentrancy). A record whose kind's change stamp is unchanged
    /// comes from `cache` undecoded; the default fresh cache decodes both.
    static func read(
        from db: Database,
        store: ReplicaStore,
        deviceID: String?,
        cache: ReplicaDecodeCache = ReplicaDecodeCache()
    ) throws -> Self {
        let versions = try store.kindVersions(kinds, from: db)
        var snapshot = Self()
        snapshot.heartbeat = try cache.value(HeartbeatPayload.recordName, version: versions[.heartbeat] ?? 0) {
            try decode(HeartbeatPayload.self, recordName: HeartbeatPayload.recordName, store: store, from: db)
        }
        if let deviceID {
            let recordName = SliceKind.deviceGrant.recordName(id: deviceID)
            snapshot.grant = try cache.value(recordName, version: versions[.deviceGrant] ?? 0) {
                try decode(DeviceGrant.self, recordName: recordName, store: store, from: db)
            }
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
/// grant and the outbox overlay, re-read when their change stamps or the
/// overlay change; and the Battery section, re-read by `refreshBattery()`.
@MainActor
@Observable
final class SettingsViewModel {
    private(set) var snapshot = SettingsSnapshot()
    /// Settings → Battery; nil until the first `refreshBattery()`.
    private(set) var battery: BatteryReport?
    /// The decoded records between reads (and the tests' decode counter).
    @ObservationIgnored let decodeCache = ReplicaDecodeCache()
    @ObservationIgnored private var cancellable: ResilientObservation?
    @ObservationIgnored private var observedDeviceID: String?
    @ObservationIgnored private let health: ObservationHealth
    @ObservationIgnored private let batteryDiagnostics: BatteryDiagnostics

    init(health: ObservationHealth = .shared, batteryDiagnostics: BatteryDiagnostics = .shared) {
        self.health = health
        self.batteryDiagnostics = batteryDiagnostics
    }

    /// Re-reads the counters and the newest MetricKit report (neither is
    /// observable: the view calls this on appear and periodically).
    func refreshBattery() {
        battery = BatteryReport(diagnostics: batteryDiagnostics)
    }

    /// One row per replica observation that failed since launch, in name
    /// order; empty while none did. Reads `health`, so a view updates on a
    /// new failure. `locale` formats the relative times (tests pin it).
    func diagnostics(now: Date, locale: Locale = .current) -> [ObservationDiagnostic] {
        health.failures.sorted { $0.key < $1.key }.map { name, failure in
            ObservationDiagnostic(name: name, text: Self.text(name: name, failure: failure, now: now, locale: locale))
        }
    }

    private static func text(name: String, failure: ObservationHealth.Failure, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: failure.lastAt, relativeTo: now)
        let text = "\(name) updates: failed \(failure.count)×, last \(when): \(failure.lastMessage)"
        return failure.recovered ? text + " (recovered)" : text
    }

    /// Starts (or, for another device id, restarts) the observation.
    func start(store: ReplicaStore, deviceID: String?, gate: ReplicaObservationGate? = nil) {
        if cancellable != nil, observedDeviceID == deviceID { return }
        observedDeviceID = deviceID
        cancellable?.cancel()
        let cache = decodeCache
        cancellable = ResilientObservation(
            name: "settings",
            reader: store.reader,
            gate: gate,
            observation: {
                ValueObservation.tracking(regions: [ReplicaStore.kindVersionsRegion, ReplicaStore.pendingActionsRegion]) { db in
                    try SettingsSnapshot.read(from: db, store: store, deviceID: deviceID, cache: cache)
                }
                .removeDuplicates()
            },
            onChange: { [weak self] value in self?.snapshot = value }
        )
    }
}
