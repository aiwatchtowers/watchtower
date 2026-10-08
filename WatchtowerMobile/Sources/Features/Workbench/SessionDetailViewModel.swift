import Foundation
import GRDB
import Observation
import os
import WatchtowerKit
import WatchtowerSync

/// Sends `session_report_request` (spec §5.2) when a session detail opens,
/// at most once per session per 60 s: the Mac runs the report at most that
/// often anyway (§4.8). Owned by `AppEnvironment`, so the throttle holds
/// across the detail view being re-created.
@MainActor
final class SessionReportRequester {
    static let interval: TimeInterval = 60

    private let now: () -> Date
    private let send: (Int64) async throws -> Void
    private var lastSent: [Int64: Date] = [:]
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SessionReportRequester")

    init(now: @escaping () -> Date, send: @escaping (Int64) async throws -> Void) {
        self.now = now
        self.send = send
    }

    /// The app's requester: one idempotent action through the outbox, the
    /// session's record as its entity.
    static func sending(through outbox: ActionOutbox, now: @escaping () -> Date = { Date() }) -> SessionReportRequester {
        SessionReportRequester(now: now) { sessionID in
            try await outbox.enqueue(
                kind: SessionReportRequestParams.actionKind,
                entityRecordName: SliceKind.terminalSession.recordName(id: String(sessionID)),
                params: try SessionReportRequestParams().wireParams()
            )
        }
    }

    /// Sends a request unless one went out for the session in the last 60 s.
    /// Returns whether one was sent. A failed send does not hold the
    /// throttle, so the next open tries again.
    @discardableResult
    func requestReport(sessionID: Int64) async -> Bool {
        let at = now()
        if let last = lastSent[sessionID], at.timeIntervalSince(last) < Self.interval {
            return false
        }
        // Taken before the await, so a second open meanwhile does not send too.
        lastSent[sessionID] = at
        do {
            try await send(sessionID)
            return true
        } catch {
            if lastSent[sessionID] == at {
                lastSent[sessionID] = nil
            }
            Self.logger.warning("session report request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// The session's report and timeline records, read in one snapshot. An
/// undecodable record reads as absent, so the screen falls back to the
/// header.
struct SessionDetailRecords: Equatable {
    var report: SessionReport?
    var timeline: SessionTimeline?

    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SessionDetailRecords")

    static func read(sessionID: Int64, from db: Database, store: ReplicaStore) throws -> Self {
        Self(
            report: try decode(SessionReport.self, sessionID: sessionID, from: db, store: store),
            timeline: try decode(SessionTimeline.self, sessionID: sessionID, from: db, store: store)
        )
    }

    private static func decode<T: SliceMirror>(_ type: T.Type, sessionID: Int64, from db: Database, store: ReplicaStore) throws -> T? {
        let recordName = T.sliceKind.recordName(id: String(sessionID))
        guard let payload = try store.payload(forRecordName: recordName, from: db) else { return nil }
        do {
            return try T.decode(payload: payload)
        } catch {
            logger.warning("undecodable \(recordName, privacy: .public) skipped")
            return nil
        }
    }
}

/// One open session detail: observes the session's report and timeline and
/// asks the Mac for a fresh report on open. The header, asks and state come
/// from the shared `WorkbenchReplicaModel`.
@MainActor
@Observable
final class SessionDetailViewModel {
    let sessionID: Int64
    private(set) var report: SessionReport?
    private(set) var timeline: SessionTimeline?
    /// true once the first read landed.
    private(set) var loaded = false

    @ObservationIgnored private let store: ReplicaStore
    @ObservationIgnored private let requester: SessionReportRequester
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SessionDetailViewModel")

    init(sessionID: Int64, store: ReplicaStore, requester: SessionReportRequester) {
        self.sessionID = sessionID
        self.store = store
        self.requester = requester
    }

    /// Starts the observation; a second call is a no-op.
    func start() {
        guard cancellable == nil else { return }
        let sessionID = sessionID
        let store = store
        let observation = ValueObservation.tracking { db in
            try SessionDetailRecords.read(sessionID: sessionID, from: db, store: store)
        }
        cancellable = observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { Self.logger.error("session detail observation failed: \($0.localizedDescription, privacy: .public)") },
            onChange: { [weak self] value in
                MainActor.assumeIsolated {
                    self?.report = value.report
                    self?.timeline = value.timeline
                    self?.loaded = true
                }
            }
        )
    }

    /// The detail appeared: observe, and ask the Mac for a fresh report
    /// (throttled per session).
    func opened() async {
        start()
        await requester.requestReport(sessionID: sessionID)
    }
}
