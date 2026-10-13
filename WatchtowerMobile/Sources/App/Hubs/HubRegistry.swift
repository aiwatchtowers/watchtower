import Foundation
import GRDB
import os

/// One linked Mac as the phone's registry holds it (multi-hub spec §5.2).
struct HubRow: Equatable, Sendable {
    enum State: String, Sendable {
        case linked
        case unlinkedByMac = "unlinked_by_mac"
    }

    var link: LinkRecord
    /// The Mac's flavor, as its last heartbeat reported it.
    var flavor: String?
    var sortOrder: Int
    var state: State
    /// When a fetch first found this hub without the phone's grant (the
    /// phone's clock); nil while the grant is there.
    var grantMissingSince: Date?
    var lastHeartbeatAt: Date?
    var linkedOn: Date

    var hubID: String { link.hubID }
}

enum HubRegistryError: Error {
    /// The registry already holds `HubRegistry.limit` hubs.
    case full
}

/// The phone's linked Macs, up to `limit`, in a small SQLite file outside
/// the app group (`HubPaths.registryPath`). Not an actor: callers are
/// `@MainActor`. Every write is one transaction.
final class HubRegistry {
    static let limit = 4

    private let queue: DatabaseQueue
    private static let activeKey = "active_hub_id"
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "HubRegistry")

    init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        try Self.migrate(queue)
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrate(queue)
    }

    static func inMemory() throws -> HubRegistry {
        try HubRegistry(queue: DatabaseQueue())
    }

    private static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE hubs (
                  hub_id TEXT PRIMARY KEY,
                  link_json BLOB NOT NULL,
                  flavor TEXT,
                  sort_order INTEGER NOT NULL,
                  state TEXT NOT NULL CHECK (state IN ('linked','unlinked_by_mac')),
                  grant_missing_since REAL,
                  last_heartbeat_at REAL,
                  linked_on REAL NOT NULL
                );
                CREATE TABLE registry_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
        }
        try migrator.migrate(queue)
    }

    // MARK: Reads

    /// The readable rows in order. A row that does not decode (a newer
    /// build's link, a damaged value) is logged and skipped: one bad row
    /// never hides the others (multi-hub spec §6.3). It still counts
    /// towards `limit`, and its hub id stays in `hubIDs()`.
    func rows() throws -> [HubRow] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM hubs ORDER BY sort_order").compactMap { row in
                do {
                    return try Self.hubRow(row)
                } catch {
                    Self.logger.error("unreadable hub row skipped: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
        }
    }

    /// Every row's hub id in order, readable or not: what the files on disk
    /// are checked against (`HubBoot`), so an unreadable row's files are
    /// never taken for an orphan's.
    func hubIDs() throws -> [String] {
        try queue.read { db in
            try Self.orderedIDs(db)
        }
    }

    func row(_ hubID: String) throws -> HubRow? {
        try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM hubs WHERE hub_id = ?", arguments: [hubID]).map(Self.hubRow)
        }
    }

    /// True when `hubID` would be a new hub and the registry is at `limit`.
    func isFull(adding hubID: String) throws -> Bool {
        try queue.read { db in
            try Self.isFull(db, adding: hubID)
        }
    }

    var activeHubID: String? {
        get throws {
            try queue.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM registry_meta WHERE key = ?", arguments: [Self.activeKey])
            }
        }
    }

    // MARK: Writes

    /// A new hub goes last and is `linked`; an existing one keeps its place,
    /// takes the new link and turns `linked` with no missing-grant mark.
    /// Throws `.full` for a new hub when `limit` hubs are linked.
    func upsert(_ link: LinkRecord, now: Date) throws {
        let json = try JSONEncoder().encode(link)
        try queue.write { db in
            if try Self.exists(db, link.hubID) {
                try db.execute(
                    sql: "UPDATE hubs SET link_json = ?, state = 'linked', grant_missing_since = NULL WHERE hub_id = ?",
                    arguments: [json, link.hubID]
                )
            } else {
                if try Self.isFull(db, adding: link.hubID) { throw HubRegistryError.full }
                let next = (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM hubs") ?? -1) + 1
                try db.execute(
                    sql: """
                        INSERT INTO hubs (hub_id, link_json, sort_order, state, linked_on)
                        VALUES (?, ?, ?, 'linked', ?)
                        """,
                    arguments: [link.hubID, json, next, now.timeIntervalSince1970]
                )
            }
        }
    }

    /// Deletes the row, closes the gap in the order and clears the active
    /// hub when it was this one.
    func remove(_ hubID: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM hubs WHERE hub_id = ?", arguments: [hubID])
            try Self.renumber(db, ids: try Self.orderedIDs(db))
            try db.execute(sql: "DELETE FROM registry_meta WHERE key = ? AND value = ?", arguments: [Self.activeKey, hubID])
        }
    }

    /// Moves the hub to `index` (clamped) and renumbers 0…n−1.
    func move(_ hubID: String, to index: Int) throws {
        try queue.write { db in
            var ids = try Self.orderedIDs(db)
            guard let from = ids.firstIndex(of: hubID) else { return }
            ids.remove(at: from)
            ids.insert(hubID, at: min(max(index, 0), ids.count))
            try Self.renumber(db, ids: ids)
        }
    }

    func setState(_ state: HubRow.State, for hubID: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE hubs SET state = ? WHERE hub_id = ?", arguments: [state.rawValue, hubID])
        }
    }

    func setGrantMissingSince(_ date: Date?, for hubID: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE hubs SET grant_missing_since = ? WHERE hub_id = ?",
                arguments: [date?.timeIntervalSince1970, hubID]
            )
        }
    }

    func noteHeartbeat(flavor: String, at date: Date, for hubID: String) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE hubs SET flavor = ?, last_heartbeat_at = ? WHERE hub_id = ?",
                arguments: [flavor, date.timeIntervalSince1970, hubID]
            )
        }
    }

    func setActive(_ hubID: String?) throws {
        try queue.write { db in
            if let hubID {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO registry_meta (key, value) VALUES (?, ?)",
                    arguments: [Self.activeKey, hubID]
                )
            } else {
                try db.execute(sql: "DELETE FROM registry_meta WHERE key = ?", arguments: [Self.activeKey])
            }
        }
    }

    func removeAll() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM hubs")
            try db.execute(sql: "DELETE FROM registry_meta")
        }
    }

    // MARK: Helpers

    private static func exists(_ db: Database, _ hubID: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM hubs WHERE hub_id = ?", arguments: [hubID]) != nil
    }

    private static func isFull(_ db: Database, adding hubID: String) throws -> Bool {
        if try exists(db, hubID) { return false }
        return (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hubs") ?? 0) >= limit
    }

    private static func orderedIDs(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT hub_id FROM hubs ORDER BY sort_order")
    }

    private static func renumber(_ db: Database, ids: [String]) throws {
        for (order, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE hubs SET sort_order = ? WHERE hub_id = ?", arguments: [order, id])
        }
    }

    private static func hubRow(_ row: Row) throws -> HubRow {
        let json: Data = row["link_json"]
        let state: String = row["state"]
        guard let parsed = HubRow.State(rawValue: state) else {
            throw DatabaseError(message: "unknown hub state \(state)")
        }
        let missing: Double? = row["grant_missing_since"]
        let heartbeat: Double? = row["last_heartbeat_at"]
        let linkedOn: Double = row["linked_on"]
        return HubRow(
            link: try JSONDecoder().decode(LinkRecord.self, from: json),
            flavor: row["flavor"],
            sortOrder: row["sort_order"],
            state: parsed,
            grantMissingSince: missing.map(Date.init(timeIntervalSince1970:)),
            lastHeartbeatAt: heartbeat.map(Date.init(timeIntervalSince1970:)),
            linkedOn: Date(timeIntervalSince1970: linkedOn)
        )
    }
}
