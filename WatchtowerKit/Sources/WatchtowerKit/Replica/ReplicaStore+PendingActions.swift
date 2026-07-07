import Foundation
import GRDB

// MARK: - Pending actions (optimistic overlay)

extension ReplicaStore {
    /// All overlay rows, oldest first (stable: created_at, then action_id).
    /// Failed rows stay visible until the user retries or dismisses them.
    public func pendingActions() throws -> [PendingAction] {
        try writer.read { db in try pendingActions(from: db) }
    }

    /// `pendingActions()` against an ALREADY-OPEN database — for the app's
    /// ValueObservation tracking closures, where a nested `writer.read` would
    /// trap on DatabasePool reentrancy (same rule as `fetchAll(_:kind:from:)`).
    public func pendingActions(from db: Database) throws -> [PendingAction] {
        decodePendingActions(try Row.fetchAll(
            db,
            sql: "SELECT * FROM pending_actions ORDER BY created_at, action_id"
        ))
    }

    /// Overlay rows targeting one slice record (`target-42`), oldest first.
    public func pendingActions(forEntity recordName: String) throws -> [PendingAction] {
        try writer.read { db in
            decodePendingActions(try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM pending_actions WHERE entity_record_name = ?
                    ORDER BY created_at, action_id
                    """,
                arguments: [recordName]
            ))
        }
    }

    /// Deletes one overlay row. Public for the app's "Dismiss" affordance on
    /// failed actions; unknown ids are a no-op (DELETE matches nothing).
    public func removePendingAction(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM pending_actions WHERE action_id = ?", arguments: [id])
        }
    }

    /// ActionOutbox's write path (internal: the app enqueues via the outbox,
    /// never by inserting rows directly). Stores the wire-encoded payload so
    /// the overlay can re-surface the full request (retry re-enqueues it).
    func insertPendingAction(_ action: ActionRequestPayload, entityRecordName: String?) throws {
        let payload = try RelayCoder.makeEncoder().encode(action)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pending_actions
                        (action_id, kind, entity_record_name, payload, created_at, state)
                    VALUES (?, ?, ?, ?, ?, 'pending')
                    """,
                arguments: [
                    action.id, action.kind.rawValue, entityRecordName,
                    payload, action.createdAt.timeIntervalSince1970
                ]
            )
        }
    }

    /// Flips one overlay row to `failed` (desktop echo). Unknown ids are a
    /// no-op: the echo may be a redelivery for a row the sweep already
    /// removed, or an action whose pending insert never happened.
    func markPendingActionFailed(id: String, errorMessage: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE pending_actions SET state = 'failed', error_message = ? WHERE action_id = ?",
                arguments: [errorMessage, id]
            )
        }
    }

    /// Fails every still-pending row created strictly before `cutoff` in one
    /// transaction; returns the affected ids (oldest first). Already-failed
    /// rows keep their (more informative) desktop error message.
    func sweepPendingActions(before cutoff: Date, errorMessage: String) throws -> [String] {
        try writer.write { db in
            let predicate = "state = 'pending' AND created_at < ?"
            let ids = try String.fetchAll(
                db,
                sql: "SELECT action_id FROM pending_actions WHERE \(predicate) ORDER BY created_at, action_id",
                arguments: [cutoff.timeIntervalSince1970]
            )
            guard !ids.isEmpty else { return [] }
            try db.execute(
                sql: "UPDATE pending_actions SET state = 'failed', error_message = ? WHERE \(predicate)",
                arguments: [errorMessage, cutoff.timeIntervalSince1970]
            )
            return ids
        }
    }

    /// Maps rows to PendingAction, skipping (and logging once, keyed by
    /// action_id) any whose payload no longer decodes. These blobs are written
    /// by this module from a just-encoded payload, so a failure here is a
    /// programmer error — but one bad row must never take down the overlay.
    private func decodePendingActions(_ rows: [Row]) -> [PendingAction] {
        let decoder = RelayCoder.makeDecoder()
        var decoded: [PendingAction] = []
        var badIDs: [String] = []
        for row in rows {
            let id: String = row["action_id"]
            guard let action = try? decoder.decode(ActionRequestPayload.self, from: row["payload"] as Data),
                  let state = PendingAction.State(rawValue: row["state"]) else {
                badIDs.append(id)
                continue
            }
            decoded.append(PendingAction(
                id: id,
                action: action,
                entityRecordName: row["entity_record_name"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                state: state,
                errorMessage: row["error_message"]
            ))
        }
        let firstSeen = corruptPending.withLock { seen -> [String] in
            badIDs.filter { seen.insert($0).inserted }
        }
        for id in firstSeen {
            logger.warning("undecodable pending_actions row skipped: \(id, privacy: .public)")
        }
        return decoded
    }
}

/// One optimistic-overlay row: an action the phone enqueued into the relay
/// that the desktop has not yet resolved. View models join these over the
/// slice models by `entityRecordName` (strike-through/pending chip, error
/// banner on `failed`).
///
/// `state` is the authoritative overlay state — the embedded `action` keeps
/// its as-enqueued `.pending` status even after a failed echo flips the row.
public struct PendingAction: Equatable, Identifiable {
    public enum State: String {
        case pending
        case failed
    }

    /// The `ActionRequestPayload.id` (also the row's primary key).
    public let id: String
    /// The request exactly as written to the relay zone.
    public let action: ActionRequestPayload
    /// Full recordName of the slice row this action targets (`target-42`);
    /// nil for entity-less kinds (`task_create`).
    public let entityRecordName: String?
    public let createdAt: Date
    public let state: State
    /// The desktop echo's message, or the silent-pending sweep text; nil
    /// while `state == .pending`.
    public let errorMessage: String?
}
