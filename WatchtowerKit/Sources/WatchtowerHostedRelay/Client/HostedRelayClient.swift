import Foundation
import os
import SwiftProtobuf
import WatchtowerRelayProto

/// One device's view of the hosted relay over HTTPS: register and login with
/// App Attest, then ops on a session (the Go client `internal/hub/transport/relay/client`,
/// same retry numbers; relay `proto/README.md`). The session token lives in
/// this actor's memory only and is never logged or put in an error.
public actor HostedRelayClient {
    static let logger = Logger(subsystem: "WatchtowerKit", category: "HostedRelay")

    /// `UNAVAILABLE` retry (proto README "Errors"): 0.5 s doubling to 8 s, at most 30 s in total.
    static let unavailableFirstDelay = Duration.milliseconds(500)
    static let unavailableMaxDelay = Duration.seconds(8)
    static let unavailableBudget = Duration.seconds(30)

    nonisolated public let deviceID: String

    private let origin: RelayOrigin
    private let opURL: URL
    /// `GET /v1/ws` on the origin, `wss`/`ws` for `https`/`http`.
    let socketURL: URL
    private let signer: any RelaySigner
    private let kind: Relay_V1_DeviceKind
    private let attestor: RelayAttestor
    private let http: any RelayHTTP
    // The WebSocket side (`connect`, HostedRelayConnection.swift).
    let sockets: any RelaySocketDialer
    let backoff: @Sendable (Int) -> Duration
    let onGoingAway: (@Sendable () -> Void)?
    let clock: any RelayClock

    private var token: String?
    /// The login in flight, shared by every caller that needs a session meanwhile.
    private var loginTask: Task<String, any Error>?
    public private(set) var accountID: String?

    public init(
        origin: RelayOrigin,
        signer: any RelaySigner,
        kind: Relay_V1_DeviceKind,
        attestor: RelayAttestor,
        http: any RelayHTTP,
        sockets: any RelaySocketDialer,
        clock: any RelayClock,
        backoff: @escaping @Sendable (Int) -> Duration = { HostedRelayClient.defaultBackoff($0) },
        onGoingAway: (@Sendable () -> Void)? = nil
    ) {
        self.origin = origin
        self.opURL = origin.url.appendingPathComponent("v1/op")
        self.socketURL = Self.socketURL(origin.url)
        self.signer = signer
        self.kind = kind
        self.attestor = attestor
        self.http = http
        self.sockets = sockets
        self.clock = clock
        self.backoff = backoff
        self.onGoingAway = onGoingAway
        self.deviceID = RelayAuthMessages.deviceID(publicKey: signer.publicKey)
    }

    /// The Go `DefaultBackoff`: 500 ms doubling per attempt up to 60 s, drawn
    /// uniformly from the upper half of that window.
    public static func defaultBackoff(_ attempt: Int) -> Duration {
        let ceilingMs = min(500 << min(max(attempt, 0), 8), 60_000)
        return .milliseconds(ceilingMs / 2 + Int.random(in: 0...(ceilingMs / 2)))
    }

    // MARK: - Register and login

    /// Registers the device (idempotent; also a re-register): `challenge{REGISTER}`,
    /// a fresh App Attest attestation and an Ed25519 signature over the register
    /// `clientDataHash`, then `register`. Keeps the phone's account id.
    public func register() async throws -> String {
        guard attestor.isSupported else { throw HostedRelayError.attestation(.notSupported) }
        let nonce = try await challengeNonce(purpose: .register)
        let hash = RelayAuthMessages.registerClientDataHash(nonce: nonce, authPub: signer.publicKey, origin: origin)

        var register = Relay_V1_RegisterDevice()
        register.deviceKind = kind
        register.authPub = signer.publicKey
        register.nonce = nonce
        register.attestation = try await attesting { try await self.attestor.registerAttestation(clientDataHash: hash) }
        register.signature = try signer.sign(hash)

        let response: Relay_V1_Response
        do {
            response = try await perform(.register(register))
        } catch HostedRelayError.server(code: let code, _) where code == .attestationRequired || code == .attestationFailed {
            // A register always carries a fresh attestation: a refusal means "update the app".
            Self.logger.error("relay register: \(String(describing: code), privacy: .public)")
            throw HostedRelayError.attestation(.updateRequired)
        }
        guard case .registered(let registered) = response.result, registered.deviceID == deviceID else {
            Self.logger.error("relay register: unexpected answer")
            throw HostedRelayError.undecodable(status: 200)
        }
        accountID = registered.accountID
        return deviceID
    }

    /// Opens a new session (joining a login already in flight).
    public func login() async throws {
        _ = try await sharedLogin()
    }

    /// A session token: the current one unless it is `stale` (the token a
    /// request or a connection was refused with), else one login shared by
    /// concurrent callers.
    func sessionToken(stale: String?) async throws -> String {
        if let token, token != stale { return token }
        let fresh = try await sharedLogin()
        guard let stale, fresh == stale else { return fresh }
        // The login we joined issued the very token we were refused with: log in for real.
        return try await sharedLogin()
    }

    /// Joins the login in flight or starts one. `loginTask` is cleared on the
    /// actor by the login itself, in the same step that stores the token, so
    /// no caller can join a login that has already finished.
    private func sharedLogin() async throws -> String {
        if let loginTask { return try await loginTask.value }
        let task = Task {
            do {
                return try await self.loginOnce()
            } catch {
                self.loginTask = nil
                throw error
            }
        }
        loginTask = task
        return try await task.value
    }

    /// Challenge-response login with App Attest (proto README "Login" and
    /// "Failure paths on the client"). `ATTESTATION_FAILED` on an assertion
    /// login gets one login with a fresh attestation; a refusal after that, or
    /// `ATTESTATION_REQUIRED`, is `.updateRequired`. A failed login keeps the
    /// session in hand.
    private func loginOnce() async throws -> String {
        guard attestor.isSupported else { throw HostedRelayError.attestation(.notSupported) }
        while true {
            let nonce = try await challengeNonce(purpose: .login)
            let hash = RelayAuthMessages.loginClientDataHash(nonce: nonce, deviceID: deviceID, origin: origin)

            var login = Relay_V1_Login()
            login.deviceID = deviceID
            login.nonce = nonce
            login.signature = try signer.sign(RelayAuthMessages.loginMessage(nonce: nonce, deviceID: deviceID, origin: origin))
            login.attestation = try await attesting { try await self.attestor.loginAttestation(clientDataHash: hash) }
            let asserted: Bool
            if case .appAttestAssertion = login.attestation.kind { asserted = true } else { asserted = false }

            let response: Relay_V1_Response
            do {
                response = try await perform(.login(login))
            } catch HostedRelayError.server(code: .attestationRequired, _) {
                Self.logger.error("relay login: attestation_required")
                throw HostedRelayError.attestation(.updateRequired)
            } catch HostedRelayError.server(code: .attestationFailed, _) {
                var again = false
                if asserted { again = await attestor.serverRefusedAssertion() }
                Self.logger.error("relay login: attestation_failed, asserted \(asserted), attesting again \(again)")
                guard again else { throw HostedRelayError.attestation(.updateRequired) }
                continue
            }
            guard case .session(let session) = response.result, !session.token.isEmpty else {
                Self.logger.error("relay login: unexpected answer")
                throw HostedRelayError.undecodable(status: 200)
            }
            await attestor.loginSucceeded()
            token = session.token
            loginTask = nil
            return session.token
        }
    }

    private func challengeNonce(purpose: Relay_V1_ChallengePurpose) async throws -> Data {
        var challenge = Relay_V1_GetChallenge()
        challenge.deviceID = deviceID
        challenge.purpose = purpose
        let response = try await perform(.challenge(challenge))
        guard case .challenge(let answer) = response.result else {
            Self.logger.error("relay challenge: unexpected answer")
            throw HostedRelayError.undecodable(status: 200)
        }
        return answer.nonce
    }

    /// Runs an attestor call, wrapping its `HostedRelayAttestError` as `.attestation`.
    private func attesting(_ body: () async throws -> Relay_V1_Attestation) async throws -> Relay_V1_Attestation {
        do {
            return try await body()
        } catch let error as HostedRelayAttestError {
            throw HostedRelayError.attestation(error)
        }
    }

    // MARK: - Ops

    /// One op over HTTPS: session (single-flight login), UNAUTHENTICATED → one relogin and one retry,
    /// UNAVAILABLE → 0.5 s doubling to 8 s, ≤ 30 s total, then the error.
    public func perform(_ op: Relay_V1_Request.OneOf_Op) async throws -> Relay_V1_Response {
        try await Self.retryingUnavailable(op, clock: clock) { try await performOnce(op) }
    }

    /// Runs `attempt` again while it fails with `UNAVAILABLE`: 0.5 s doubling
    /// to 8 s, at most 30 s in total, then the error. Shared by HTTPS and the socket.
    static func retryingUnavailable(
        _ op: Relay_V1_Request.OneOf_Op,
        clock: any RelayClock,
        _ attempt: () async throws -> Relay_V1_Response
    ) async throws -> Relay_V1_Response {
        let start = clock.now()
        var delay = unavailableFirstDelay
        while true {
            do {
                return try await attempt()
            } catch HostedRelayError.server(code: .unavailable, let retryAfter) {
                let left = unavailableBudget - duration(clock.now().timeIntervalSince(start))
                guard left > .zero else { throw HostedRelayError.server(code: .unavailable, retryAfter: retryAfter) }
                logger.info("relay \(name(op), privacy: .public): unavailable, retrying")
                try await clock.sleep(for: min(delay, left))
                delay = min(delay * 2, unavailableMaxDelay)
            }
        }
    }

    private func performOnce(_ op: Relay_V1_Request.OneOf_Op) async throws -> Relay_V1_Response {
        switch op {
        case .register, .challenge, .login:
            return try await post(op, token: nil)
        default:
            break
        }
        let current = try await sessionToken(stale: nil)
        do {
            return try await post(op, token: current)
        } catch HostedRelayError.server(code: .unauthenticated, _) {
            Self.logger.info("relay \(Self.name(op), privacy: .public): unauthenticated, logging in again")
            let fresh = try await sessionToken(stale: current)
            return try await post(op, token: fresh)
        }
    }

    private func post(_ op: Relay_V1_Request.OneOf_Op, token: String?) async throws -> Relay_V1_Response {
        var request = Relay_V1_Request()
        request.op = op
        var headers = [
            "Content-Type": "application/x-protobuf",
            "Relay-Protocol-Version": String(HostedRelay.protocolVersion)
        ]
        if let token { headers["Authorization"] = "Bearer \(token)" }

        let status: Int
        let body: Data
        do {
            (status, body) = try await http.post(opURL, body: try request.serializedData(), headers: headers)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            Self.logger.error("relay \(Self.name(op), privacy: .public): no answer")
            throw HostedRelayError.unreachable
        }

        guard let response = try? Relay_V1_Response(serializedBytes: body) else {
            Self.logger.error("relay \(Self.name(op), privacy: .public): undecodable answer, HTTP \(status)")
            throw HostedRelayError.undecodable(status: status)
        }
        if case .error(let error) = response.result {
            Self.logger.error("relay \(Self.name(op), privacy: .public): \(String(describing: error.code), privacy: .public), HTTP \(status)")
            throw Self.error(error)
        }
        guard (200..<300).contains(status) else {
            Self.logger.error("relay \(Self.name(op), privacy: .public): HTTP \(status) without an error")
            throw HostedRelayError.undecodable(status: status)
        }
        return response
    }

    private static func duration(_ interval: TimeInterval) -> Duration {
        .seconds(interval)
    }

    private static func socketURL(_ origin: URL) -> URL {
        let url = origin.appendingPathComponent("v1/ws")
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = parts.scheme?.lowercased() == "http" ? "ws" : "wss"
        return parts.url ?? url
    }

    /// A relay `Response.error` as the error the client throws (`post`'s mapping).
    static func error(_ error: Relay_V1_Error) -> HostedRelayError {
        if error.code == .unsupportedVersion { return .unsupportedVersion }
        return .server(code: error.code, retryAfter: error.hasRetryAfterS ? error.retryAfterS : nil)
    }

    /// The op's case name (`removeSlot`), for logs: the label only, never its fields.
    static func name(_ op: Relay_V1_Request.OneOf_Op) -> String {
        Mirror(reflecting: op).children.first?.label ?? "unknown"
    }
}
