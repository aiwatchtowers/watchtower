import Foundation
import WatchtowerRelayProto

/// Typed calls for the phone's ops, over `perform`. An answer of the wrong kind
/// throws `.undecodable(status: 200)`. The Mac's ops (`set_hub_readers`,
/// `send_alert`) have no helper: the phone never sends them (R4, R18).
extension HostedRelayClient {
    public func save(_ request: Relay_V1_Save) async throws -> Relay_V1_SaveResult {
        guard case .save(let result) = try await perform(.save(request)).result else { throw Self.wrongAnswer }
        return result
    }

    public func delete(_ request: Relay_V1_Delete) async throws -> Relay_V1_DeleteResult {
        guard case .delete(let result) = try await perform(.delete(request)).result else { throw Self.wrongAnswer }
        return result
    }

    /// A `TOKEN_EXPIRED` answer is the caller's: reset the zone's `since_seq` and pull again.
    public func changes(_ request: Relay_V1_Changes) async throws -> Relay_V1_ChangesResult {
        guard case .changes(let result) = try await perform(.changes(request)).result else { throw Self.wrongAnswer }
        return result
    }

    public func createUpload(_ request: Relay_V1_CreateUpload) async throws -> Relay_V1_Upload {
        guard case .upload(let result) = try await perform(.createUpload(request)).result else { throw Self.wrongAnswer }
        return result
    }

    public func getDownload(_ request: Relay_V1_GetDownload) async throws -> Relay_V1_Download {
        guard case .download(let result) = try await perform(.getDownload(request)).result else { throw Self.wrongAnswer }
        return result
    }

    public func addSlot(_ request: Relay_V1_AddMacSlot) async throws {
        try await performOk(.addSlot(request))
    }

    public func removeSlot(_ request: Relay_V1_RemoveMacSlot) async throws {
        try await performOk(.removeSlot(request))
    }

    public func openPairing(_ request: Relay_V1_OpenPairingSlot) async throws -> Relay_V1_PairingSlot {
        guard case .pairingSlot(let result) = try await perform(.openPairing(request)).result else { throw Self.wrongAnswer }
        return result
    }

    public func closePairing(_ request: Relay_V1_ClosePairingSlot) async throws {
        try await performOk(.closePairing(request))
    }

    public func promotePairing(_ request: Relay_V1_PromotePairing) async throws {
        try await performOk(.promotePairing(request))
    }

    public func registerPush(_ request: Relay_V1_RegisterPushToken) async throws {
        try await performOk(.registerPush(request))
    }

    public func submitTransaction(_ request: Relay_V1_SubmitTransaction) async throws -> Relay_V1_EntitlementState {
        guard case .entitlement(let result) = try await perform(.submitTransaction(request)).result else { throw Self.wrongAnswer }
        return result
    }

    public func accountState() async throws -> Relay_V1_AccountState {
        guard case .accountState(let result) = try await perform(.getAccountState(Relay_V1_GetAccountState())).result else {
            throw Self.wrongAnswer
        }
        return result
    }

    /// `GetChallenge` for this device: a single-use nonce (`LOGIN`, `VOUCH`) or a register nonce.
    public func challenge(purpose: Relay_V1_ChallengePurpose) async throws -> Data {
        try await challengeNonce(purpose: purpose)
    }

    /// `vouch_hub` for the request's hub (`hubDeviceID`, `authPub`; nonce and attestation are
    /// filled here). Each attempt is GetChallenge{VOUCH}, an assertion over the vouch
    /// `clientDataHash` and the op, run in the attestor's turn on the session taken before it
    /// (a login inside the turn would wait for it). `UNAVAILABLE` repeats the whole attempt, ≤ 30 s
    /// in all; `UNAUTHENTICATED`, or no App Attest key to assert with, logs in again outside the
    /// turn (a fresh attestation when the key is gone) and makes one more attempt. Every other
    /// answer is thrown as it came: the vouch retry table is `HostedRelayPairing.vouch`'s.
    public func vouchHub(_ request: Relay_V1_VouchHub) async throws {
        guard attestor.isSupported else { throw HostedRelayError.attestation(.notSupported) }
        var stale: String?
        while true {
            let token = try await sessionToken(stale: stale)
            do {
                let response = try await Self.retryingUnavailable(.vouchHub(request), clock: clock) {
                    try await attestor.withAssertionTurn { try await self.vouchAttempt(request, token: token) }
                }
                guard case .ok = response.result else { throw Self.wrongAnswer }
                return
            } catch HostedRelayError.server(code: .unauthenticated, _) where stale == nil {
                Self.logger.info("relay vouchHub: unauthenticated, logging in again")
                stale = token
            } catch is NoAssertionKey {
                Self.logger.info("relay vouchHub: no App Attest key, logging in again, attesting \(stale == nil)")
                guard stale == nil else { throw HostedRelayError.attestation(.updateRequired) }
                stale = token
            }
        }
    }

    /// One `vouch_hub`: a new `VOUCH` nonce, a new assertion, the op on `token`.
    private func vouchAttempt(_ request: Relay_V1_VouchHub, token: String) async throws -> Relay_V1_Response {
        var vouch = request
        vouch.nonce = try await challengeNonce(purpose: .vouch)
        let hash = RelayAuthMessages.vouchClientDataHash(
            nonce: vouch.nonce, hubDeviceID: vouch.hubDeviceID, authPub: vouch.authPub, origin: origin
        )
        vouch.attestation = try await attesting { try await self.attestor.vouchAssertion(clientDataHash: hash) }
        return try await post(.vouchHub(vouch), token: token)
    }

    private func performOk(_ op: Relay_V1_Request.OneOf_Op) async throws {
        guard case .ok = try await perform(op).result else { throw Self.wrongAnswer }
    }

    private static var wrongAnswer: HostedRelayError {
        .undecodable(status: 200)
    }
}
