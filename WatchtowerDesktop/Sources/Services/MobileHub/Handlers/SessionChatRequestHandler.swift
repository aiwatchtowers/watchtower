import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// `session_chat_request` from the phone, entity: the session id, params
/// `{subagent_id?}`. Opens or extends the five-minute watch of the session's
/// chat (or one subagent's) in `SessionChatRunner`; the phone repeats it every
/// minute while its Chat screen is open. Idempotent: a re-run only extends
/// the watch. The result is `{}`; the chat reaches the phone through the
/// `session_chat` slice. Needs no grant: reading is what the phone's link
/// already allows, like the session report.
///
/// A session that is not an agent session of a published workbench
/// (`TerminalSessionSlice.publishedSessions`) fails `not_found` with the
/// message `unknown_session`. Owns its timeout (one DB read) and never calls
/// back into the relay processor.
@MainActor
final class SessionChatRequestHandler {
    nonisolated static let defaultTimeout: Duration = .seconds(10)
    static let timeoutMessage = "The Mac did not answer in time — check the chat on the Mac"
    static let unknownSession = "unknown_session"

    private let dbPool: DatabasePool
    private let runner: SessionChatRunner
    private let sessions: TerminalSessionSlice
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(
        dbPool: DatabasePool,
        runner: SessionChatRunner,
        sessions: TerminalSessionSlice,
        timeout: Duration = SessionChatRequestHandler.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.dbPool = dbPool
        self.runner = runner
        self.sessions = sessions
        self.timeout = timeout
        self.sleep = sleep
    }

    func register(on dispatcher: MobileHubCommandDispatcher) {
        dispatcher.register(.sessionChatRequest) { try await self.handle($0) }
    }

    func handle(_ action: ActionRequestPayload) async throws -> ActionOutcome {
        try await withHandlerTimeout(timeout, sleep: sleep, message: Self.timeoutMessage) {
            guard let sessionID = action.entityID.flatMap(Int64.init) else {
                return .failed(.invalidParams, message: "session_chat_request needs a session id")
            }
            var agentID: String?
            if let param = action.params["subagent_id"], param != .null {
                guard case let .string(value) = param, !value.isEmpty else {
                    return .failed(.invalidParams, message: "subagent_id must be a text")
                }
                agentID = value
            }
            let sessions = self.sessions
            let known = try await self.dbPool.read { db in
                try sessions.publishedSessions(db).contains { $0.session.id == sessionID }
            }
            guard known else { return .failed(.notFound, message: Self.unknownSession) }
            self.runner.request(sessionID: sessionID, agentID: agentID)
            return .applied()
        }
    }
}
