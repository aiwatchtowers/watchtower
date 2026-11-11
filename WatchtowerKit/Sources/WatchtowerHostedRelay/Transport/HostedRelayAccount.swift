import Foundation
import os
import WatchtowerRelayProto

/// The phone's relay account as the subscription screen reads it (`get_account_state`).
public struct RelayAccountState: Equatable, Sendable {
    public enum Entitlement: Equatable, Sendable { case none, active, grace, expired, revoked }

    public let entitlement: Entitlement
    public let until: Date?
    /// The subscription moved to another phone.
    public let moved: Bool
    /// The Macs in the account's slots.
    public let macs: [String]

    public init(entitlement: Entitlement, until: Date?, moved: Bool, macs: [String]) {
        self.entitlement = entitlement
        self.until = until
        self.moved = moved
        self.macs = macs
    }

    public var paying: Bool {
        entitlement == .active || entitlement == .grace
    }
}

/// The APNs environment a push token belongs to.
public enum RelayPushEnvironment: String, Sendable { case sandbox, production }

/// The answers of `submit` a subscription screen acts on. Carries no server text.
public enum RelaySubmitRefusal: Error, Equatable, Sendable {
    /// `INVALID_TRANSACTION`: stale, foreign or unreadable.
    case invalidTransaction
    /// `TRANSFER_LIMIT`: the subscription moved three times in 30 days.
    case transferLimit
    /// The relay has no App Store keys (or no APNs key, for `registerPush`).
    case notImplemented
    /// No answer, `UNAVAILABLE` past its retries, a 5xx.
    case unreachable
    /// `UNSUPPORTED_VERSION`, or App Attest asks for an app update.
    case updateRequired
    /// App Attest failed transiently: no relay call for a while.
    case attestationBackoff
}

/// The phone's relay account over the process's `HostedRelaySession`: its id (the StoreKit
/// `appAccountToken`), its state, `submit_transaction` and `register_push`. Relay `proto/README.md`
/// "Subscriptions". Logs carry op names and codes only: never the JWS, the push token or the account id.
public struct HostedRelayAccount: Sendable {
    private static let logger = Logger(subsystem: "WatchtowerKit", category: "RelayAccount")

    let session: HostedRelaySession
    let identity: KeychainRelayIdentity

    public init(session: HostedRelaySession, identity: KeychainRelayIdentity) {
        self.session = session
        self.identity = identity
    }

    private var client: HostedRelayClient {
        session.client
    }

    /// The stored id, else `register` once and keep it (`relay.account`). Never registers while one is
    /// stored; a locked Keychain throws before any call. An answer that is no UUID is
    /// `HostedRelayError.undecodable` and nothing is stored.
    public func accountID() async throws -> UUID {
        if let stored = try identity.accountID() { return stored }
        _ = try await refusing("register") { try await client.register() }
        guard let text = await client.accountID, let id = UUID(uuidString: text) else {
            Self.logger.error("relay register: the account id is no UUID")
            throw HostedRelayError.undecodable(status: 200)
        }
        return try identity.keepAccountID(id)
    }

    public func state() async throws -> RelayAccountState {
        let answer = try await refusing("getAccountState") { try await client.accountState() }
        return RelayAccountState(
            entitlement: Self.entitlement(answer.entitlement.state),
            until: answer.entitlement.untilMs > 0 ? Date(timeIntervalSince1970: TimeInterval(answer.entitlement.untilMs) / 1000) : nil,
            moved: answer.moved,
            macs: answer.macDeviceIds)
    }

    /// `submit_transaction` (the client retries `UNAVAILABLE`: a move waits for the old phone's
    /// revocation to land). The transaction must be freshly synced, never a cached JWS.
    public func submit(jws: String) async throws -> RelayAccountState.Entitlement {
        var request = Relay_V1_SubmitTransaction()
        request.signedTransaction = jws
        let answer = try await refusing("submitTransaction") { try await client.submitTransaction(request) }
        return Self.entitlement(answer.state)
    }

    public func registerPush(token: String, environment: RelayPushEnvironment) async throws {
        var request = Relay_V1_RegisterPushToken()
        request.token = token
        request.env = environment == .sandbox ? .sandbox : .production
        try await refusing("registerPush") { try await client.registerPush(request) }
    }

    // MARK: - Mapping

    static func entitlement(_ kind: Relay_V1_EntitlementKind) -> RelayAccountState.Entitlement {
        switch kind {
        case .active: .active
        case .grace: .grace
        case .expired: .expired
        case .revoked: .revoked
        default: .none
        }
    }

    private func refusing<T>(_ op: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            Self.logger.error("relay \(op, privacy: .public) failed: \(Self.code(error), privacy: .public)")
            throw refusal(for: error) ?? error
        }
    }

    private func refusal(for error: any Error) -> RelaySubmitRefusal? {
        if error is HostedRelayClient.NotImplemented { return .notImplemented }
        guard let error = error as? HostedRelayError else { return nil }
        switch error {
        case .server(let code, _):
            switch code {
            case .invalidTransaction: return .invalidTransaction
            case .transferLimit: return .transferLimit
            case .attestationRequired, .attestationFailed, .unsupportedVersion: return .updateRequired
            case .unavailable: return .unreachable
            default: return nil
            }
        case .unreachable:
            return .unreachable
        case .undecodable(let status):
            return (500..<600).contains(status) ? .unreachable : nil
        case .unsupportedVersion, .attestation(.updateRequired):
            return .updateRequired
        case .attestation(.retryLater):
            return .attestationBackoff
        case .attestation(.notSupported):
            return nil
        }
    }

    /// An error's code for logs: the relay code or the case, never a message.
    private static func code(_ error: any Error) -> String {
        if error is HostedRelayClient.NotImplemented { return "notImplemented" }
        guard let error = error as? HostedRelayError else { return String(describing: type(of: error)) }
        if case .server(let code, _) = error { return String(describing: code) }
        return String(describing: error)
    }
}
