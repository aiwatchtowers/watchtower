import Foundation
import WatchtowerSync

/// What a handler (or the hub itself) answers one phone action with; the
/// relay processor writes it into the action's echo (mobile POC spec §5.2)
/// and keeps it in the exactly-once ledger (Codable for that, never wire).
struct ActionOutcome: Equatable, Codable {
    let status: ActionStatus
    let reason: ActionReason?
    let result: [String: JSONValue]?
    let errorMessage: String?

    static func applied(_ result: [String: JSONValue] = [:]) -> Self {
        Self(status: .applied, reason: nil, result: result, errorMessage: nil)
    }

    static func failed(_ reason: ActionReason, message: String? = nil) -> Self {
        Self(status: .failed, reason: reason, result: nil, errorMessage: message)
    }

    static let expired = Self(status: .expired, reason: .expired, result: nil, errorMessage: nil)
}

/// The main-actor side of the relay (spec §6.1): `TerminalCenter`,
/// `OwnerAsksViewModel` and `WorkbenchesViewModel` are main-actor objects,
/// so every workbench handler lives here, while `RelayProcessor` stays a
/// background type for decoding, exactly-once and echoes and hops here for
/// the work. The table is empty in A; B registers its handlers in
/// `AppState.initMobileHub`. A handler that throws is echoed `failed` /
/// `write_failed` with the error's description.
@MainActor
final class MobileHubCommandDispatcher {
    typealias Handler = @MainActor (ActionRequestPayload) async throws -> ActionOutcome

    private var handlers: [ActionKind: Handler] = [:]

    /// Registers (or replaces) the handler of `kind`.
    func register(_ kind: ActionKind, handler: @escaping Handler) {
        handlers[kind] = handler
    }

    func handles(_ kind: ActionKind) -> Bool {
        handlers[kind] != nil
    }

    /// nil when no handler is registered for the action's kind.
    func dispatch(_ action: ActionRequestPayload) async throws -> ActionOutcome? {
        guard let handler = handlers[action.kind] else { return nil }
        return try await handler(action)
    }
}
