import CloudKit
import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// Who this hub is, and what it last read of the DataZone `heartbeat`
/// record (mobile POC spec §4.1, §8 I-1). Everything lives in the sidecar's
/// `hub_meta`: `hub_id` and `enabled_at` for good, the heartbeat cursor and
/// the last heartbeat seen until an account reset.
struct HubIdentity: Sendable {
    static let enabledAtKey = "enabled_at"
    static let heartbeatCursorKey = "heartbeat_cursor"
    static let heartbeatSeenKey = "heartbeat_seen"
    /// Wiped on an account reset: the new account's DataZone is another zone.
    static let heartbeatReadKeys = [heartbeatCursorKey, heartbeatSeenKey]
    /// A heartbeat under this age is a live hub (spec §3: 720 s).
    static let liveWindow = TimeInterval(RelayFeed.heartbeatStaleAfter.components.seconds)

    let sidecar: HubSyncState
    private let logger = Logger(subsystem: Constants.bundleID, category: "HubIdentity")

    init(sidecar: HubSyncState) {
        self.sidecar = sidecar
    }

    func hubID() throws -> String {
        try sidecar.ensureHubID()
    }

    /// When the hub was first turned on: set by the first enable and kept
    /// across relaunches, off/on and account resets, so the ask alerts
    /// never fire for asks older than the hub (spec §4.7 `ask_alert`).
    func ensureEnabledAt(_ now: Date) throws -> Date {
        let raw = try sidecar.ensureMetaValue(forKey: Self.enabledAtKey) { String(now.timeIntervalSince1970) }
        guard let seconds = TimeInterval(raw) else { throw HubIdentityError.corruptValue(Self.enabledAtKey) }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Reads DataZone changes since the stored cursor and returns the
    /// newest heartbeat this hub knows of, its own included (by
    /// `updated_at`: a heartbeat older than the one remembered never
    /// replaces it, so a late-arriving write loses to a later one). An
    /// undecodable heartbeat (a newer Mac's format) is logged and leaves
    /// the remembered one in place.
    func readHeartbeat(from transport: any CloudSyncTransport) async throws -> HeartbeatPayload? {
        let cursor = try sidecar.metaValue(forKey: Self.heartbeatCursorKey)
            .flatMap(Int.init)
            .map(CloudChangeToken.init(value:))
        let batch = try await transport.changes(in: .data, since: cursor)
        var latest = try storedHeartbeat()
        if let record = batch.changed.first(where: { $0.recordName == HeartbeatPayload.recordName }) {
            do {
                let heartbeat = try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: record.payload)
                if latest.map({ heartbeat.updatedAt > $0.updatedAt }) ?? true {
                    try remember(record.payload)
                    latest = heartbeat
                }
            } catch {
                logger.warning("undecodable heartbeat skipped: \(error.localizedDescription, privacy: .public)")
            }
        } else if batch.deletedRecordNames.contains(HeartbeatPayload.recordName) {
            try sidecar.setMetaValue("", forKey: Self.heartbeatSeenKey)
            latest = nil
        }
        try sidecar.setMetaValue(String(batch.newToken.value), forKey: Self.heartbeatCursorKey)
        return latest
    }

    /// Stores `payload` (RelayCoder JSON) as the newest heartbeat known.
    /// The hub calls it with each heartbeat it writes: CloudKit never
    /// fetches a device's own saves back into its buffer, so the read
    /// alone would keep the previous hub's heartbeat as the newest.
    func remember(_ payload: Data) throws {
        guard let raw = String(bytes: payload, encoding: .utf8) else {
            throw HubIdentityError.corruptValue(Self.heartbeatSeenKey)
        }
        try sidecar.setMetaValue(raw, forKey: Self.heartbeatSeenKey)
    }

    /// Whether a heartbeat read ever completed in this account (the cursor
    /// exists). Until then an empty buffer proves nothing.
    func hasReadHeartbeat() throws -> Bool {
        try sidecar.metaValue(forKey: Self.heartbeatCursorKey) != nil
    }

    private func storedHeartbeat() throws -> HeartbeatPayload? {
        guard let raw = try sidecar.metaValue(forKey: Self.heartbeatSeenKey), !raw.isEmpty else { return nil }
        return try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: Data(raw.utf8))
    }

    /// Another hub's heartbeat, under 720 s old: that Mac is the hub.
    static func isLiveForeign(_ heartbeat: HeartbeatPayload, hubID: String, now: Date) -> Bool {
        heartbeat.hubID != hubID && now.timeIntervalSince(heartbeat.updatedAt) < liveWindow
    }

    /// At most 60 characters, cut at a grapheme-cluster boundary (a
    /// Swift `Character` is one cluster, so an emoji ZWJ sequence stays whole).
    static func clipMacName(_ name: String) -> String {
        String(name.prefix(HeartbeatPayload.maxMacNameLength))
    }

    /// `WTBuildFlavor` (stamped by build-app.sh): absent or `dev` is the
    /// default build; any other flavor is a corporate build.
    static func flavor(buildFlavor: String) -> HubFlavor {
        buildFlavor.isEmpty || buildFlavor == "dev" ? .default : .corp
    }
}

enum HubIdentityError: Error, LocalizedError {
    case corruptValue(String)

    var errorDescription: String? {
        switch self {
        case .corruptValue(let key): return "hub_meta value \(key) is not readable"
        }
    }
}

/// The Mac-side facts the heartbeat carries besides the hub's own state.
/// Injected so tests run without a host lookup, a main DB or CloudKit.
struct HubHostInfo: Sendable {
    /// Already clipped to 60 characters.
    let macName: String
    let appVersion: String
    let flavor: HubFlavor
    /// Label and status rows, never a token (spec §4.1).
    let accounts: @Sendable () -> [HeartbeatAccount]
    /// The Mac's `userRecordID().recordName`; nil while unknown. Bounded by
    /// the caller's timeout.
    let ownerUser: @Sendable () async -> String?

    init(
        macName: String,
        appVersion: String,
        flavor: HubFlavor,
        accounts: @escaping @Sendable () -> [HeartbeatAccount],
        ownerUser: @escaping @Sendable () async -> String?
    ) {
        self.macName = HubIdentity.clipMacName(macName)
        self.appVersion = appVersion
        self.flavor = flavor
        self.accounts = accounts
        self.ownerUser = ownerUser
    }

    /// The real Mac: its localized name, the app version and build flavor,
    /// and account rows from the main DB. `ownerUser` comes with the hub
    /// storage (`MobileHubStorage.ownerUser`).
    static func live(dbPool: DatabasePool, ownerUser: @escaping @Sendable () async -> String?) -> Self {
        let logger = Logger(subsystem: Constants.bundleID, category: "HubIdentity")
        return Self(
            macName: Host.current().localizedName ?? "Mac",
            appVersion: Constants.appVersion,
            flavor: HubIdentity.flavor(
                buildFlavor: (Bundle.main.object(forInfoDictionaryKey: "WTBuildFlavor") as? String) ?? ""
            ),
            accounts: {
                do {
                    return try dbPool.read(HubAccountRows.fetch)
                } catch {
                    logger.error("heartbeat accounts read failed: \(error.localizedDescription, privacy: .public)")
                    return []
                }
            },
            ownerUser: ownerUser
        )
    }

    /// `CKContainer.userRecordID().recordName` (spec §2.3). The hub asks
    /// only after it saw iCloud available, so the entitlement is present.
    @Sendable
    static func iCloudUserRecordName() async -> String? {
        do {
            return try await CKContainer(identifier: WatchtowerCloud.containerID).userRecordID().recordName
        } catch {
            Logger(subsystem: Constants.bundleID, category: "HubIdentity")
                .warning("iCloud user record lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// The heartbeat's `accounts[]` (spec §4.1): kind, label and status of
/// each connected Slack, Google and Jira account, at most 20. Only those
/// three columns are read, so no token or secret can reach the payload.
enum HubAccountRows {
    static func fetch(_ db: Database) throws -> [HeartbeatAccount] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT kind, label, status FROM (
                SELECT 0 AS ord, id, 'slack' AS kind, COALESCE(NULLIF(label, ''), team_name) AS label, status
                FROM slack_accounts WHERE status != 'removed'
                UNION ALL
                SELECT 1, id, 'google', COALESCE(NULLIF(label, ''), email), status FROM google_accounts
                UNION ALL
                SELECT 2, id, 'jira', COALESCE(NULLIF(label, ''), site_name), status
                FROM jira_accounts WHERE status != 'removed'
            )
            ORDER BY ord, id
            LIMIT ?
            """, arguments: [HeartbeatPayload.maxAccounts])
        return rows.map { row in
            HeartbeatAccount(
                kind: HeartbeatAccount.Kind(rawValue: row["kind"]),
                label: String((row["label"] as String).prefix(HeartbeatAccount.maxLabelLength)),
                status: row["status"]
            )
        }
    }
}
