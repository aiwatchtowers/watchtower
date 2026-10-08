import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// `session_report_request` from the phone (mobile POC spec §5.2, §4.8),
/// entity: the session id, params `{}`. Asks `SessionReportRunner` for a
/// run with the network (gh refreshes the PR states) at its next pass; the
/// runner takes at most one per 60 s per session, so a second request
/// inside that is `applied` with nothing more run. Idempotent: a re-run of
/// the same action only asks again. The result is `{}`; the new report
/// reaches the phone through the `session_report` slice.
///
/// A session outside the report window (`SessionReportSlice.window`: not a
/// `claude` session of a published workbench, or neither live nor active
/// in the last 7 days) fails `not_found`: no report would ever reach the
/// phone. Owns its timeout (one DB read) and never calls back into the
/// relay processor.
@MainActor
final class SessionReportRequestHandler {
    nonisolated static let defaultTimeout: Duration = .seconds(10)
    static let timeoutMessage = "The Mac did not answer in time — check the session report on the Mac"

    private let dbPool: DatabasePool
    private let runner: SessionReportRunner
    private let sessions: TerminalSessionSlice
    private let now: @Sendable () -> Date
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(
        dbPool: DatabasePool,
        runner: SessionReportRunner,
        sessions: TerminalSessionSlice,
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: Duration = SessionReportRequestHandler.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.dbPool = dbPool
        self.runner = runner
        self.sessions = sessions
        self.now = now
        self.timeout = timeout
        self.sleep = sleep
    }

    func register(on dispatcher: MobileHubCommandDispatcher) {
        dispatcher.register(.sessionReportRequest) { try await self.handle($0) }
    }

    func handle(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        try await withHandlerTimeout(timeout, sleep: sleep, message: Self.timeoutMessage) {
            guard let sessionID = action.entityID.flatMap(Int64.init) else {
                return .failed(.invalidParams, message: "session_report_request needs a session id")
            }
            let (sessions, stamp) = (self.sessions, self.now())
            let inWindow = try await self.dbPool.read { db -> Bool in
                try SessionReportSlice.window(db, sessions: sessions, now: stamp).contains { $0.sessionID == sessionID }
            }
            guard inWindow else { return .failed(.notFound, message: "This session has no report on the Mac") }
            self.runner.requestReport(sessionID: sessionID)
            return .applied()
        }
    }
}
