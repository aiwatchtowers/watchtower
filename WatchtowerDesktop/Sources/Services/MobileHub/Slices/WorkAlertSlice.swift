import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// The work alerts (spec 2026-10-25-mobile-workbench-remote §5.2), the `ask_alert` kind, record name
/// `ask_alert-<key>`: one alert per stop of work in a published workbench — a new open ask, a pending permission
/// request, a session that finished or waits for input, a failed session — chosen by `WorkAlertPolicy`, which keeps
/// one stop to one alert. Under E2E the record is sealed under `K_alert` (the only key the phone's notification
/// extension holds) and the subscription fires on its `sig-` signal record (`AskAlertSignal`), written when the alert
/// first reaches the zone. The payload is the Kit's `WorkAlertPayload`: titles only, never chat text.
///
/// Each pass, in order:
/// - the candidates that began at or after the hub's `enabled_at` (asks and requests by `created_at`, stops by
///   `state_at`), so a first enable never alerts on the work already waiting;
/// - session stops and permission requests also only from the work alerts' first pass (`work_alerts_started_at` in
///   `hub_meta`), so an upgraded hub never alerts on the stops already on its board (spec §4, no push storm);
/// - remembered in the sidecar's `work_alerts`: while the owner is at the Mac (`isAway` false) as seen only; while
///   away, every one not pushed yet is pushed now, in the same transaction (`noteWorkAlerts(pushing:)`). So an ask or
///   a request left open at the Mac pushes when the owner leaves, once; a stop left there does only when it began
///   within `WorkAlertPolicy.departureWindow` (30 min) before the departure — the first pass that reads the owner
///   away, stored as `work_alerts_away_since` until a pass reads them back. A pushed key never pushes again (a second
///   away period, a hub restart, a republish, a rotation);
/// - a record for each candidate pushed in the current sync generation within 7 days of its push; while the owner is
///   at the Mac only those already in the zone (a recorded hash): a push whose publish failed is held until the next
///   departure, so its first save and signal never buzz the phone while the owner is at the Mac. A resolved stop
///   (answered, decided, working again) leaves the candidates, so the publisher deletes its record and signal; an
///   account reset publishes nothing it pushed before into the new zone;
/// - a stop an open ask or a pending request stood for (`WorkAlertPolicy.coveredStopKeys`) is remembered as a seen-only
///   `cover-<stop key>` row, so when the ask or request resolves and the session still reads stopped at the same
///   `state_at` (an answered check of a finished session, a held answer) the stop never pushes on its own;
/// - the rows of resolved stops are forgotten 7 days after they were first seen; a current one is kept.
///
/// Text: the title is the workbench name (≤ 60), then " · " and the session's title (≤ 60) when the session is known;
/// the body (≤ 120) is the ask's title, "Needs approval: <tool>", "Finished", "Waiting for you" or "Failed". Cut with
/// `…`, no `_clipped` flags. `quick` is set on a question ask the phone can answer in one tap (`OwnerAskSlice.quick`).
///
/// The readers are the session and permission slices' own (`TerminalSessionSlice.publishedSessions`,
/// `PermissionRequestSlice.pending`), at this slice's clock and liveness.
struct WorkAlertSlice: SliceSource {
    let kind = SliceKind.askAlert

    static let lifetime: TimeInterval = 7 * 86_400
    static let maxWorkbenchName = 60
    static let maxSessionTitle = 60
    static let maxBody = 120
    /// `hub_meta`: the first pass of the work alerts (session stops and requests count from it, spec §4).
    static let startedAtKey = "work_alerts_started_at"
    /// `hub_meta`: when the owner left the Mac, as the first away pass saw it; absent while at the Mac.
    static let awaySinceKey = "work_alerts_away_since"

    let sidecar: HubSyncState
    let isAway: @Sendable () -> Bool
    let liveness: @Sendable () -> SessionLiveness
    /// The sessions deleted on the Mac whose DELETE waits for Undo (PROJ-17): they never alert.
    let hiddenIDs: @Sendable () -> Set<Int64>
    let now: @Sendable () -> Date

    init(
        sidecar: HubSyncState,
        isAway: @escaping @Sendable () -> Bool,
        liveness: @escaping @Sendable () -> SessionLiveness,
        hiddenIDs: @escaping @Sendable () -> Set<Int64> = { [] },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sidecar = sidecar
        self.isAway = isAway
        self.liveness = liveness
        self.hiddenIDs = hiddenIDs
        self.now = now
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let stamp = now()
        // The hub's first enable; the heartbeat sets the same value.
        let enabledAt = try HubIdentity(sidecar: sidecar).ensureEnabledAt(stamp)
        let names = Dictionary(uniqueKeysWithValues: try WorkbenchSlice.publishedWorkbenchRefs(db).map { ($0.id, $0.name) })
        let hidden = hiddenIDs()
        let asks = try openAsks(db, published: names).filter { $0.input.sessionID.map(hidden.contains) != true }
        let requests = try PermissionRequestSlice(liveness: liveness, now: now).pending(db).filter { !hidden.contains($0.sessionID) }
        let waiting = Set(requests.map(\.sessionID))
        // Labelled: the hidden ids are not the reader's main closure.
        let reader = TerminalSessionSlice(
            liveness: liveness, reportSummary: { _, _ in nil }, now: now, hiddenIDs: { hidden } // swiftlint:disable:this trailing_closure
        )
        let sessions = try reader.publishedSessions(db)
            .map { item in
                WorkAlertPolicy.SessionInput(
                    id: item.session.id, workbenchID: item.workbenchID, title: item.session.title, kind: item.state.kind,
                    stateAt: TerminalSessionSlice.stateAt(item), openAsks: item.state.openAsks,
                    hasPendingRequest: waiting.contains(item.session.id)
                )
            }
        let all = WorkAlertPolicy.candidates(
            asks: asks.map(\.input),
            requests: requests.map {
                .init(id: $0.id, sessionID: $0.sessionID, workbenchID: $0.workbenchID, toolName: $0.toolName, createdAt: $0.createdAt)
            },
            sessions: sessions,
            now: stamp
        )
        // A stop an ask or a request stood for stays theirs once they resolve (seen-only `cover-` rows, never pushed).
        let covers = WorkAlertPolicy.coveredStopKeys(sessions: sessions).map(Self.cover)
        let covered = try sidecar.noteWorkAlerts(covers, at: stamp).marks
        let startedAt = try metaDate(Self.startedAtKey, ensuring: stamp)
        let candidates = all.filter {
            WorkAlertPolicy.counts($0, enabledAt: enabledAt, workAlertsStartedAt: startedAt) && covered[Self.cover($0.key)] == nil
        }
        let keys = candidates.map(\.key)
        let since = try awaySince(stamp)
        let pushing = since.map { since in
            Set(candidates.filter { WorkAlertPolicy.pushesWhileAway($0, awaySince: since) }.map(\.key))
        } ?? []
        // At the Mac only what already reached the zone stays: a push whose publish failed waits for the next
        // departure, so its first save (and its signal) never lands while the owner sits at the Mac.
        let inZone: Set<String>? = since == nil ? Set(try sidecar.hashes(forKind: kind).keys) : nil
        let (generation, marks) = try sidecar.noteWorkAlerts(keys, pushing: pushing, at: stamp)
        let current = all.map(\.key)
        try sidecar.pruneWorkAlerts(
            olderThan: stamp.addingTimeInterval(-Self.lifetime), keeping: Set(current + current.map(Self.cover) + covers)
        )
        let quick = Set(asks.filter(\.quick).map(\.input.id))
        let encoder = RelayCoder.makeEncoder()
        return try candidates.compactMap { candidate in
            guard let mark = marks[candidate.key], let pushedAt = mark.pushedAt, mark.generation == generation,
                  stamp.timeIntervalSince(pushedAt) <= Self.lifetime,
                  inZone?.contains(kind.recordName(id: candidate.key)) ?? true else { return nil }
            let payload = Self.payload(
                candidate, workbenchName: names[candidate.workbenchID] ?? "",
                quick: candidate.askID.map(quick.contains) ?? false
            )
            return SliceRecord(kind: kind, id: candidate.key, modifiedAt: stamp, payload: try encoder.encode(payload))
        }
    }

    /// When the owner left the Mac, or nil while they are at it: the first pass that reads them away stores its
    /// stamp (`awaySinceKey`), the first pass that reads them back removes it.
    private func awaySince(_ stamp: Date) throws -> Date? {
        guard isAway() else {
            if try sidecar.metaValue(forKey: Self.awaySinceKey) != nil { try sidecar.removeMetaValue(forKey: Self.awaySinceKey) }
            return nil
        }
        return try metaDate(Self.awaySinceKey, ensuring: stamp)
    }

    /// The date stored under `key`, `stamp` stored there when the key is new.
    private func metaDate(_ key: String, ensuring stamp: Date) throws -> Date {
        let raw = try sidecar.ensureMetaValue(forKey: key) { String(stamp.timeIntervalSince1970) }
        guard let seconds = TimeInterval(raw) else { throw HubIdentityError.corruptValue(key) }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The ledger key remembering that `key`'s stop was an ask's or a request's.
    static func cover(_ key: String) -> String { "cover-\(key)" }

    /// The Kit payload of one candidate (the one encoder of record for the extension's `AlertOpener`).
    static func payload(_ candidate: WorkAlertPolicy.Candidate, workbenchName: String, quick: Bool) -> WorkAlertPayload {
        let workbench = SliceClip.text(workbenchName, limit: maxWorkbenchName).text
        let session = SliceClip.text(candidate.title, limit: maxSessionTitle).text
        return WorkAlertPayload(
            event: event(candidate.event),
            key: candidate.key,
            workbenchID: candidate.workbenchID,
            workbenchName: workbench,
            sessionID: candidate.sessionID,
            askID: candidate.askID,
            requestID: candidate.requestID,
            title: session.isEmpty ? workbench : "\(workbench) · \(session)",
            body: SliceClip.text(candidate.body, limit: maxBody).text,
            quick: quick
        )
    }

    private static func event(_ event: WorkAlertPolicy.Event) -> WorkAlertPayload.Event {
        switch event {
        case .ask: .ask
        case .permission: .permission
        case .sessionStopped: .sessionStopped
        case .sessionFailed: .sessionFailed
        }
    }

    private struct OpenAsk {
        let input: WorkAlertPolicy.AskInput
        let quick: Bool
    }

    /// The open asks of the published workbenches with a readable `created_at` (Go caps them at 30 per workbench).
    private func openAsks(_ db: Database, published names: [Int64: String]) throws -> [OpenAsk] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, project_id, session_id, kind, title, payload, created_at
            FROM owner_asks WHERE status = 'open' ORDER BY id
            """)
        return rows.compactMap { row in
            let id: Int64 = row["id"]
            let project: Int64 = row["project_id"]
            guard names[project] != nil, let created = SliceDate.parse(row["created_at"] ?? "") else { return nil }
            let askKind: String = row["kind"] ?? ""
            let stored = OwnerAskSlice.json(row["payload"] ?? "", record: kind.recordName(id: WorkAlertKey.ask(id)), field: "payload")
            let quick = askKind == "question" && stored.value.flatMap(OwnerAskSlice.quick) != nil
            return OpenAsk(
                input: .init(
                    id: id, workbenchID: project, sessionID: row["session_id"], title: row["title"] ?? "", kind: askKind,
                    createdAt: created
                ),
                quick: quick
            )
        }
    }
}
