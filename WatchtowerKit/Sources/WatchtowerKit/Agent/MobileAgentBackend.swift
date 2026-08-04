import Foundation

/// The phone's turn-sender seam (Plan 5): the chat view model routes `send()`
/// through one of two backends, chosen per session by the user's explicit
/// opt-in (`direct_mode`) — never a silent switch.
public protocol MobileAgentBackend: Sendable {
    /// Ships one user turn and returns the ids the UI tracks (`messageID` is
    /// the assistant reply's id — see `ChatAssembler.send`). Whether the
    /// answer comes from the Mac over the relay or from the on-device agent
    /// is the conforming backend's business; either way it streams into the
    /// same chat replica rows.
    ///
    /// `context` marks an entity-bound thread (a situation's Discuss chat).
    /// Not every backend can answer one — the on-device agent has neither the
    /// owner's style profile nor the raw messages a situation draft is built
    /// from — so a backend that cannot MUST throw rather than answer without
    /// the context.
    func sendTurn(
        text: String,
        sessionID: String?,
        context: ChatContext?
    ) async throws -> (sessionID: String, messageID: String)
}

extension MobileAgentBackend {
    /// The generic secretary chat's call shape.
    public func sendTurn(text: String, sessionID: String?) async throws -> (sessionID: String, messageID: String) {
        try await sendTurn(text: text, sessionID: sessionID, context: nil)
    }
}

/// Today's default path: the turn ships into the relay zone and the DESKTOP
/// answers with chunk records. A deliberately thin wrapper — all behavior
/// (transport-first ordering, empty-text guard, row creation) lives in
/// `ChatAssembler.send`.
public struct RelayAgentBackend: MobileAgentBackend {
    private let assembler: ChatAssembler

    public init(assembler: ChatAssembler) {
        self.assembler = assembler
    }

    public func sendTurn(
        text: String,
        sessionID: String?,
        context: ChatContext?
    ) async throws -> (sessionID: String, messageID: String) {
        try await assembler.send(text: text, sessionID: sessionID, route: .relay, context: context)
    }
}
