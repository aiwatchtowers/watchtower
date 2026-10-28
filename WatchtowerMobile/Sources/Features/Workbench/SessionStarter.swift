import Foundation
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// What a phone start is on: a board target, or no target (#1189) — a new
/// session of the workbench, as New Session on the Mac, with the phone's
/// task description as its first message.
enum StartSubject: Hashable {
    case target(Int64)
    case untargeted(workbenchID: Int64)

    /// The action's entity: the target's record; none without a target.
    var entityRecordName: String? {
        switch self {
        case let .target(id): SessionStarter.targetRecordName(id)
        case .untargeted: nil
        }
    }

    /// Whether `action` is a start on this subject.
    func matches(_ action: ActionRequestPayload, entityRecordName entity: String?) -> Bool {
        guard action.kind == .sessionStart else { return false }
        switch self {
        case .target:
            return entity == entityRecordName
        case let .untargeted(workbenchID):
            return entity == nil && (try? SessionStartParams(wireParams: action.params).workbenchID) == workbenchID
        }
    }
}

/// One start the phone sent this run (`session_start`), as far as the Mac
/// got with it.
struct StartAttempt: Equatable {
    let actionID: String
    /// nil: a start with no target.
    let targetID: Int64?
    let params: SessionStartParams
    /// The Mac's `applied` echo arrived.
    var applied = false
    /// `result.session_id` of the applied echo.
    var sessionID: Int64?
    /// The target's session records as the phone held them when the start
    /// was sent (for an attempt rebuilt after a relaunch: when its applied
    /// echo came), by session id. A resume's record from before the start
    /// reads not live; only a newer Mac state than this ends the start.
    var baseline: [Int64: TerminalSessionState] = [:]
}

/// Starts and stops sessions from the phone (spec §5.2, §6.5) through the
/// outbox, and keeps each start's progress. Owned by `AppEnvironment`, so
/// leaving the start sheet, or reopening the target, shows the current
/// stage.
///
/// One start per target (and one start without a target per workbench)
/// and one stop per session are in flight at a time
/// (`SendGuard`). Nothing retries on its own: after a refusal only the
/// owner's Try again sends a new action.
@MainActor
@Observable
final class SessionStarter {
    typealias Enqueue = (ActionKind, String?, [String: JSONValue]) async throws -> String

    /// Target id → its start sent this run.
    private(set) var attempts: [Int64: StartAttempt] = [:]
    /// Workbench id → its start without a target sent this run.
    private(set) var untargetedAttempts: [Int64: StartAttempt] = [:]
    /// Keys (`BoardWriter.key`) of the sends still waiting for the outbox.
    var inFlight: Set<String> { sendGuard.inFlight }

    @ObservationIgnored private let sendGuard = SendGuard()
    @ObservationIgnored private let enqueue: Enqueue
    @ObservationIgnored private let remove: (String) throws -> Void
    /// The failed overlay rows of one kind on one entity (ids).
    @ObservationIgnored private let failedRows: (ActionKind, String) throws -> [String]
    /// The failed overlay rows of a workbench's starts without a target.
    @ObservationIgnored private let failedUntargeted: (Int64) throws -> [String]
    /// The replica's session records of a target: a start's baseline.
    @ObservationIgnored private let targetSessions: (Int64) -> [TerminalSessionState]
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SessionStarter")

    init(
        enqueue: @escaping Enqueue,
        remove: @escaping (String) throws -> Void,
        failedRows: @escaping (ActionKind, String) throws -> [String] = { _, _ in [] },
        failedUntargeted: @escaping (Int64) throws -> [String] = { _ in [] },
        targetSessions: @escaping (Int64) -> [TerminalSessionState] = { _ in [] }
    ) {
        self.enqueue = enqueue
        self.remove = remove
        self.failedRows = failedRows
        self.failedUntargeted = failedUntargeted
        self.targetSessions = targetSessions
    }

    /// The app's starter: actions through the outbox, Dismiss on the overlay.
    static func sending(through outbox: ActionOutbox, store: ReplicaStore) -> SessionStarter {
        SessionStarter(
            enqueue: { kind, entity, params in
                try await outbox.enqueue(kind: kind, entityRecordName: entity, params: params)
            },
            remove: { try store.removePendingAction(id: $0) },
            failedRows: { kind, entity in
                try store.pendingActions(forEntity: entity)
                    .filter { $0.state == .failed && $0.action.kind == kind }
                    .map(\.id)
            },
            failedUntargeted: { workbenchID in
                let subject = StartSubject.untargeted(workbenchID: workbenchID)
                return try store.pendingActions()
                    .filter { $0.state == .failed && subject.matches($0.action, entityRecordName: $0.entityRecordName) }
                    .map(\.id)
            },
            targetSessions: { targetID in
                do {
                    let payloads = try store.reader.read { db in try store.payloads(of: .terminalSession, from: db) }
                    // An undecodable record is skipped, as the Workbench
                    // snapshot skips (and counts) it.
                    return payloads
                        .compactMap { try? TerminalSessionState.decode(payload: $0) }
                        .filter { $0.targetID == targetID }
                } catch {
                    // Read as no records: the next not-live record ends the start.
                    logger.warning("session records not read: \(error.localizedDescription, privacy: .public)")
                    return []
                }
            }
        )
    }

    private static func byID(_ sessions: [TerminalSessionState]) -> [Int64: TerminalSessionState] {
        Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
    }

    nonisolated static func targetRecordName(_ targetID: Int64) -> String {
        SliceKind.workbenchTarget.recordName(id: String(targetID))
    }

    nonisolated static func sessionRecordName(_ sessionID: Int64) -> String {
        SliceKind.terminalSession.recordName(id: String(sessionID))
    }

    nonisolated static func startKey(_ targetID: Int64) -> String {
        BoardWriter.key(.sessionStart, targetRecordName(targetID))
    }

    nonisolated static func startKey(_ subject: StartSubject) -> String {
        switch subject {
        case let .target(id): startKey(id)
        case let .untargeted(workbenchID): BoardWriter.key(.sessionStart, "untargeted:\(workbenchID)")
        }
    }

    /// This run's start on `subject`.
    func attempt(_ subject: StartSubject) -> StartAttempt? {
        switch subject {
        case let .target(id): attempts[id]
        case let .untargeted(workbenchID): untargetedAttempts[workbenchID]
        }
    }

    nonisolated static func stopKey(_ sessionID: Int64) -> String {
        BoardWriter.key(.sessionStop, sessionRecordName(sessionID))
    }

    /// Asks the Mac to start (or, with `open_existing`, resume) a session
    /// on the target; nothing (false) while a start for it is on its way.
    /// Once it is queued, the target's older refused starts go, so the
    /// sheet follows the new one.
    @discardableResult
    func start(targetID: Int64, params: SessionStartParams) async throws -> Bool {
        let entity = Self.targetRecordName(targetID)
        let wire = try params.wireParams()
        let stale = try failedRows(.sessionStart, entity)
        // Read before the send: whatever lands after it may already be the
        // Mac's work on this start.
        let baseline = Self.byID(targetSessions(targetID))
        var actionID: String?
        let sent = try await sendGuard.run(Self.startKey(targetID)) {
            actionID = try await enqueue(.sessionStart, entity, wire)
        }
        guard sent, let actionID else { return false }
        attempts[targetID] = StartAttempt(actionID: actionID, targetID: targetID, params: params, baseline: baseline)
        for id in stale {
            try remove(id)
        }
        return true
    }

    /// Asks the Mac for a new session of the workbench with no target
    /// (#1189); `params.brief` is the task. Nothing (false) while one is on
    /// its way. As `start(targetID:)`, older refused ones then go.
    @discardableResult
    func startUntargeted(params: SessionStartParams) async throws -> Bool {
        let workbenchID = params.workbenchID
        let wire = try params.wireParams()
        let stale = try failedUntargeted(workbenchID)
        var actionID: String?
        let sent = try await sendGuard.run(Self.startKey(.untargeted(workbenchID: workbenchID))) {
            actionID = try await enqueue(.sessionStart, nil, wire)
        }
        guard sent, let actionID else { return false }
        untargetedAttempts[workbenchID] = StartAttempt(actionID: actionID, targetID: nil, params: params)
        for id in stale {
            try remove(id)
        }
        return true
    }

    /// Try again after a refusal: a new action with the refused one's
    /// params.
    @discardableResult
    func retry(_ row: PendingAction) async throws -> Bool {
        guard row.action.kind == .sessionStart else { return false }
        let params = try SessionStartParams(wireParams: row.action.params)
        guard let entity = row.action.entityID else { return try await startUntargeted(params: params) }
        guard let targetID = Int64(entity) else { return false }
        return try await start(targetID: targetID, params: params)
    }

    /// An `applied` echo of a start: keeps its session id. One this run did
    /// not send (sent before a relaunch) is followed too. Other kinds are
    /// not ours.
    func receiveApplied(_ action: ActionRequestPayload) {
        guard action.kind == .sessionStart else { return }
        guard let entity = action.entityID else { return receiveUntargetedApplied(action) }
        guard let targetID = Int64(entity) else { return }
        var attempt = attempts[targetID]
        if attempt?.actionID != action.id {
            guard let params = try? SessionStartParams(wireParams: action.params) else { return }
            attempt = StartAttempt(
                actionID: action.id, targetID: targetID, params: params, baseline: Self.byID(targetSessions(targetID))
            )
        }
        guard var attempt else { return }
        attempt.applied = true
        if case let .integer(sessionID)? = action.result?["session_id"] {
            attempt.sessionID = sessionID
        }
        attempts[targetID] = attempt
    }

    private func receiveUntargetedApplied(_ action: ActionRequestPayload) {
        guard let params = try? SessionStartParams(wireParams: action.params) else { return }
        var attempt = untargetedAttempts[params.workbenchID]
        if attempt?.actionID != action.id {
            attempt = StartAttempt(actionID: action.id, targetID: nil, params: params)
        }
        guard var attempt else { return }
        attempt.applied = true
        if case let .integer(sessionID)? = action.result?["session_id"] {
            attempt.sessionID = sessionID
        }
        untargetedAttempts[params.workbenchID] = attempt
    }

    /// The owner is done with a start (opened its session, tapped Done, or
    /// dismissed a refusal or an ended session): its failed rows go and the
    /// target's sheet starts fresh.
    func clear(targetID: Int64) throws {
        try clear(.target(targetID))
    }

    func clear(_ subject: StartSubject) throws {
        let failed: [String]
        switch subject {
        case let .target(id):
            attempts[id] = nil
            failed = try failedRows(.sessionStart, Self.targetRecordName(id))
        case let .untargeted(workbenchID):
            untargetedAttempts[workbenchID] = nil
            failed = try failedUntargeted(workbenchID)
        }
        for id in failed {
            try remove(id)
        }
    }

    /// Asks the Mac to stop the session; nothing (false) while a stop for it
    /// is on its way.
    @discardableResult
    func stop(sessionID: Int64) async throws -> Bool {
        let entity = Self.sessionRecordName(sessionID)
        let wire = try SessionStopParams().wireParams()
        let stale = try failedRows(.sessionStop, entity)
        guard try await sendGuard.run(Self.stopKey(sessionID), { _ = try await enqueue(.sessionStop, entity, wire) }) else {
            return false
        }
        for id in stale {
            try remove(id)
        }
        return true
    }

    /// Dismiss on a failed stop.
    func dismiss(_ row: PendingAction) throws {
        try remove(row.id)
    }
}
