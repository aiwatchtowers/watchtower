import Foundation
import GRDB
import os

/// Applies mobile-originated relay actions to the local DB through the
/// existing Queries, then writes an applied/failed status record back to
/// the relay zone so mobile sees the outcome.
///
/// Idempotency: the sidecar's `relay_processed` set absorbs duplicate
/// deliveries, and the relay change token is persisted only after a fully
/// processed batch — a crash mid-batch re-reads the whole batch, and the
/// processed set makes the replay safe.
final class RelayProcessor: Sendable {
    private let dbPool: DatabasePool
    private let transport: any CloudSyncTransport & Sendable
    private let sidecar: HubSyncState
    /// Unused until Task 7 wires chat handling; stored so the init is stable.
    private let aiService: any AIServiceProtocol
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: Constants.bundleID, category: "RelayProcessor")

    static let relayTokenKey = "relay_change_token"

    init(
        dbPool: DatabasePool,
        transport: any CloudSyncTransport & Sendable,
        sidecar: HubSyncState,
        aiService: any AIServiceProtocol,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dbPool = dbPool
        self.transport = transport
        self.sidecar = sidecar
        self.aiService = aiService
        self.now = now
    }

    // MARK: - Processing

    /// One poll cycle over the relay zone. Returns the number of actions applied.
    /// One bad action (missing entity, unknown id, unparseable date, …) becomes
    /// a `.failed` status record and never stops the rest of the batch.
    func processOnce() async throws -> Int {
        let token = try storedToken()
        let batch = try await transport.changes(in: .relay, since: token)
        var applied = 0

        for record in batch.changed where record.kind == RelayRecordKind.action.rawValue {
            let action: ActionRequestPayload
            do {
                action = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
            } catch {
                // No decodable id → no status record to write back; log and move on.
                logger.warning("""
                    undecodable action record \(record.recordName, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
                continue
            }
            // Echo of our own status write-back (same recordName, applied/failed).
            guard action.status == .pending else { continue }
            // Duplicate delivery of an already-applied action (spec Section 4).
            guard try !sidecar.isRelayProcessed(record.recordName) else { continue }

            var result = action
            do {
                try await dbPool.write { [self] db in try apply(action, db: db) }
                result.status = .applied
                applied += 1
            } catch {
                result.status = .failed
                result.errorMessage = error.localizedDescription
                logger.warning("""
                    action \(record.recordName, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
            try await transport.save([CloudRecordFactory.record(for: result, modifiedAt: now())])
            try sidecar.markRelayProcessed(record.recordName, at: now())
        }

        try persistToken(batch.newToken)
        return applied
    }

    // MARK: - Action → Query mapping

    private func apply(_ action: ActionRequestPayload, db: Database) throws {
        switch action.kind {
        case .targetDone:
            let id = try entityInt(action)
            try requireRow(db, table: "targets", id: id)
            try TargetQueries.updateStatus(db, id: id, status: "done")
        case .targetSnooze:
            let id = try entityInt(action)
            try requireRow(db, table: "targets", id: id)
            try TargetQueries.snooze(db, id: id, until: try dateParam(action, "snooze_until"))
        case .inboxResolve:
            let id = try entityInt(action)
            try requireRow(db, table: "inbox_items", id: id)
            try InboxQueries.resolve(db, id: id, reason: "Resolved from mobile")
        case .inboxDismiss:
            let id = try entityInt(action)
            try requireRow(db, table: "inbox_items", id: id)
            try InboxQueries.dismiss(db, id: id)
        case .inboxSnooze:
            let id = try entityInt(action)
            try requireRow(db, table: "inbox_items", id: id)
            // Inbox snooze stores the raw string; target snooze wants a Date.
            try InboxQueries.snooze(db, id: id, until: try stringParam(action, "snooze_until"))
        case .taskCreate:
            let text = try stringParam(action, "text")
            let today = Self.dayFormatter.string(from: now())
            try TargetQueries.create(db, text: text, periodStart: today, periodEnd: today)
        case .trackRead:
            let id = try entityInt(action)
            try requireRow(db, table: "tracks", id: id)
            try TrackQueries.markRead(db, id: id)
        }
    }

    // MARK: - Payload helpers

    private func entityInt(_ action: ActionRequestPayload) throws -> Int {
        guard let raw = action.entityID, !raw.isEmpty else {
            throw RelayActionError.missingEntityID(action.kind)
        }
        guard let id = Int(raw) else {
            throw RelayActionError.invalidEntityID(raw)
        }
        return id
    }

    private func stringParam(_ action: ActionRequestPayload, _ key: String) throws -> String {
        guard case .string(let value)? = action.params[key], !value.isEmpty else {
            throw RelayActionError.missingParam(key)
        }
        return value
    }

    private func dateParam(_ action: ActionRequestPayload, _ key: String) throws -> Date {
        let raw = try stringParam(action, key)
        guard let date = ISO8601DateFormatter().date(from: raw) else {
            throw RelayActionError.unparseableDate(raw)
        }
        return date
    }

    /// The mutation Queries are plain UPDATEs that succeed on 0 rows, so an
    /// unknown id must be detected up front to surface as `.failed`.
    private func requireRow(_ db: Database, table: String, id: Int) throws {
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)",
            arguments: [id]
        ) ?? false
        guard exists else {
            throw RelayActionError.entityNotFound(table: table, id: id)
        }
    }

    // MARK: - Token persistence

    private func storedToken() throws -> CloudChangeToken? {
        guard let raw = try sidecar.metaValue(forKey: Self.relayTokenKey) else { return nil }
        guard let token = try? JSONDecoder().decode(CloudChangeToken.self, from: Data(raw.utf8)) else {
            // Corrupted token → full re-read; the processed set keeps the replay safe.
            logger.warning("unreadable relay change token, re-reading the zone from scratch")
            return nil
        }
        return token
    }

    private func persistToken(_ token: CloudChangeToken) throws {
        let data = try JSONEncoder().encode(token)
        // JSONEncoder always emits valid UTF-8, so the guard is unreachable;
        // skipping persistence just re-reads the zone next cycle (safe).
        guard let raw = String(bytes: data, encoding: .utf8) else { return }
        try sidecar.setMetaValue(raw, forKey: Self.relayTokenKey)
    }

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()
}

/// Why an action could not be applied. `errorDescription` becomes the
/// `errorMessage` echoed back to mobile in the failed status record.
enum RelayActionError: Error, LocalizedError, Equatable {
    case missingEntityID(ActionKind)
    case invalidEntityID(String)
    case missingParam(String)
    case unparseableDate(String)
    case entityNotFound(table: String, id: Int)

    var errorDescription: String? {
        switch self {
        case .missingEntityID(let kind):
            return "\(kind.rawValue) requires an entity_id"
        case .invalidEntityID(let raw):
            return "entity_id is not an integer: \(raw)"
        case .missingParam(let key):
            return "missing required param: \(key)"
        case .unparseableDate(let raw):
            return "unparseable ISO8601 date: \(raw)"
        case let .entityNotFound(table, id):
            return "no row in \(table) with id \(id)"
        }
    }
}
