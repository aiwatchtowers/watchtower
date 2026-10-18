import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// `session_chat_request` from the phone, entity: the session id, params
/// `{session_id?, subagent_id?, tool_use_id?}` (the subagent's two ids come
/// together or not at all; `session_id`, when sent, must be the entity).
/// Opens or extends the five-minute watch of the session's chat (or one
/// subagent's) in `SessionChatRunner`, counted from when the phone asked: a
/// request older than the watch plus the relay's clock skew is stale and
/// applies without a watch (the phone repeats it every minute while its Chat
/// screen is open). Idempotent: a re-run only extends the watch. The result is `{}`; the chat reaches the phone through the
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
    private let now: @Sendable () -> Date

    init(
        dbPool: DatabasePool,
        runner: SessionChatRunner,
        sessions: TerminalSessionSlice,
        timeout: Duration = SessionChatRequestHandler.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
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
            if let param = action.params["session_id"], param != .null {
                guard case let .integer(value) = param, value == sessionID else {
                    return .failed(.invalidParams, message: "session_id does not match the session")
                }
            }
            let agentID: String?
            let toolUseID: String?
            do {
                agentID = try Self.text(action.params["subagent_id"], "subagent_id")
                toolUseID = try Self.text(action.params["tool_use_id"], "tool_use_id")
            } catch let failure as ParamFailure {
                return .failed(.invalidParams, message: failure.message)
            }
            guard (agentID == nil) == (toolUseID == nil) else {
                return .failed(.invalidParams, message: "subagent_id and tool_use_id come together")
            }
            let sessions = self.sessions
            let known = try await self.dbPool.read { db in
                try sessions.publishedSessions(db).contains { $0.session.id == sessionID }
            }
            guard known else { return .failed(.notFound, message: Self.unknownSession) }
            // The watch counts from when the phone asked, not from when the
            // relay got to the record.
            let age = self.now().timeIntervalSince(action.createdAt)
            let watch = Double(self.runner.timing.watch.components.seconds)
            guard age <= watch + RelayProcessor.maxClockSkew else { return .applied() }
            let remaining = Duration.seconds(max(0, min(watch, watch - age)))
            self.runner.request(
                sessionID: sessionID, agentID: agentID, toolUseID: toolUseID,
                expires: self.runner.clock() + remaining
            )
            return .applied()
        }
    }

    private struct ParamFailure: Error {
        let message: String
    }

    private static func text(_ param: JSONValue?, _ name: String) throws -> String? {
        guard let param, param != .null else { return nil }
        guard case let .string(value) = param, !value.isEmpty else { throw ParamFailure(message: "\(name) must be a text") }
        return value
    }
}
