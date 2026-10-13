import CloudKit
import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// Who this hub is (multi-hub spec §3.2): `hub_id` and `enabled_at` in the
/// sidecar's `hub_meta`, kept for good. Since phase F each Mac publishes into
/// its own zones; no other hub's heartbeat is read.
struct HubIdentity: Sendable {
    static let enabledAtKey = "enabled_at"
    /// Set once the sidecar forgot the single-hub zones' publish state
    /// (multi-hub spec §3.6, first start on the per-hub build).
    static let perHubZonesKey = "per_hub_zones"
    /// The legacy zone check's outcome (`LegacyZoneCleanup.rawValue`); set
    /// once the check completed, so it runs at one start only.
    static let legacyZonesCheckedKey = "legacy_zones_checked"
    /// Set while turning the hub off has not settled its zone delete (it
    /// timed out, or the sync state wipe after it failed): the next start
    /// deletes again before the engine runs (multi-hub spec §3.3).
    static let zonesDeletePendingKey = "hub_zones_delete_pending"
    /// The E2E hard cut (mobile E2E spec §2.8, D13): `1` once this hub deleted its pre-E2E zones, forgot its phones
    /// and started on fresh keys; `pending` while that cut is under way (it rides `zonesDeletePendingKey`, so a
    /// failure, a timeout or a crash leaves the next start to finish it).
    static let e2eMigrationKey = "e2e_v1"
    static let e2eCutDone = "1"
    static let e2eCutPending = "pending"

    let sidecar: HubSyncState

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

    /// The single-hub build's zones go only when they hold this hub's
    /// heartbeat or none (multi-hub spec §3.6). Another Mac's — or one this
    /// build cannot read, so possibly a newer Mac's — is left alone.
    static func legacyZonesAreOurs(heartbeat payload: Data?, hubID: String) -> Bool {
        guard let payload else { return true }
        do {
            return try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: payload).hubID == hubID
        } catch {
            return false
        }
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

    /// This app's flavor, from its `WTBuildFlavor`.
    static func bundleFlavor() -> HubFlavor {
        flavor(buildFlavor: (Bundle.main.object(forInfoDictionaryKey: "WTBuildFlavor") as? String) ?? "")
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
    /// Label and status rows, never a token (spec §4.1). Throws when the
    /// read fails, so a failure is never mistaken for "no accounts". Async:
    /// the live read runs on the pool, off the main actor (the hub checks
    /// it every minute).
    let accounts: @Sendable () async throws -> [HeartbeatAccount]
    /// The Mac's `userRecordID().recordName`; nil while unknown. Bounded by
    /// the caller's timeout.
    let ownerUser: @Sendable () async -> String?

    init(
        macName: String,
        appVersion: String,
        flavor: HubFlavor,
        accounts: @escaping @Sendable () async throws -> [HeartbeatAccount],
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
        Self(
            macName: Host.current().localizedName ?? "Mac",
            appVersion: Constants.appVersion,
            flavor: HubIdentity.bundleFlavor(),
            accounts: { try await dbPool.read(HubAccountRows.fetch) },
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
