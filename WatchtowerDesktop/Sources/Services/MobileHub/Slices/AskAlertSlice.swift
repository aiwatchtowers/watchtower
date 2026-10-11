import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// The `ask_alert` slice (mobile POC spec §4.7, §7), record name
/// `ask_alert-<owner_asks.id>`: the push trigger for a new owner ask. The
/// phone's query subscription fires on the record's creation, so each ask
/// gets its record once:
/// - only for an ask opened at or after the hub's `enabled_at`, so a first
///   enable never alerts on the asks already waiting;
/// - remembered in the sidecar's `alerted_asks` with the sync generation
///   that wrote it. A rebuilt hub or a full republish finds it there; an
///   account reset (a new generation, a new zone) publishes no record for
///   an alert confirmed published before, and stamps an unconfirmed one
///   again in the new generation;
/// - deleted when the ask leaves `open`, or 7 days after it was written.
///
/// Open asks of published workbenches only (`WorkbenchSlice`), the same
/// window as `owner_ask`. Go caps them at 30 per workbench.
struct AskAlertSlice: SliceSource {
    let kind = SliceKind.askAlert

    static let lifetime: TimeInterval = 7 * 86_400
    static let maxWorkbenchName = 60
    static let maxTitle = 120

    let sidecar: HubSyncState
    let now: @Sendable () -> Date

    init(sidecar: HubSyncState, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sidecar = sidecar
        self.now = now
    }

    struct Payload: Encodable, Equatable {
        let askID: Int64
        let workbenchID: Int64
        let workbenchName: String
        let sessionID: Int64?
        let kind: String
        let title: String
        /// The notification offers the one-tap answer (`ASK_QUICK`).
        let quick: Bool

        enum CodingKeys: String, CodingKey {
            case askID = "ask_id"
            case workbenchID = "workbench_id"
            case workbenchName
            case sessionID = "session_id"
            case kind, title, quick
        }
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let stamp = now()
        // The hub's first enable; the heartbeat sets the same value.
        let enabledAt = try HubIdentity(sidecar: sidecar).ensureEnabledAt(stamp)
        let workbenches = try WorkbenchSlice.publishedWorkbenches(db)
        let names = Dictionary(uniqueKeysWithValues: workbenches.map { ($0.id, $0.project.name) })
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, project_id, session_id, kind, title, payload, created_at
            FROM owner_asks WHERE status = 'open' ORDER BY id
            """)
        let open = rows.filter { names[$0["project_id"]] != nil }
        let fresh = open.compactMap { row -> Int64? in
            guard let created = SliceDate.parse(row["created_at"] ?? ""), created >= enabledAt else { return nil }
            return row["id"]
        }
        let (generation, alerted) = try sidecar.markAlerted(fresh, at: stamp)
        // Every open ask stays remembered, published or not.
        try sidecar.pruneAlertedAsks(
            olderThan: stamp.addingTimeInterval(-Self.lifetime), keeping: Set(rows.map { $0["id"] as Int64 })
        )
        let encoder = RelayCoder.makeEncoder()
        return try open.compactMap { row in
            let id: Int64 = row["id"]
            guard let alert = alerted[id], alert.generation == generation,
                  stamp.timeIntervalSince(alert.at) <= Self.lifetime else { return nil }
            let payload = makePayload(row, workbenchName: names[row["project_id"]] ?? "")
            return SliceRecord(kind: kind, id: String(id), modifiedAt: stamp, payload: try encoder.encode(payload))
        }
    }

    private func makePayload(_ row: Row, workbenchName: String) -> Payload {
        let id: Int64 = row["id"]
        let askKind: String = row["kind"] ?? ""
        let stored = OwnerAskSlice.json(row["payload"] ?? "", record: kind.recordName(id: String(id)), field: "payload")
        return Payload(
            askID: id,
            workbenchID: row["project_id"],
            workbenchName: SliceClip.text(workbenchName, limit: Self.maxWorkbenchName).text,
            sessionID: row["session_id"],
            kind: askKind,
            title: SliceClip.text(row["title"] ?? "", limit: Self.maxTitle).text,
            quick: askKind == "question" && stored.value.flatMap(OwnerAskSlice.quick) != nil
        )
    }
}
