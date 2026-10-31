import CryptoKit
import Foundation
import WatchtowerHostedRelay
import WatchtowerRelayProto

/// Registration, challenges, login and sessions (README "Attestation (App Attest)").
/// Attestation bytes are `FakeAppAttest`'s JSON; a key id is compared as the raw
/// bytes of the proto `key_id`, i.e. `Data(base64Encoded:)` of the fake's key id string.
extension FakeHostedRelay {
    private static let registerNonceBytes = 56
    private static let registerNoncePrefixBytes = 24
    private static let loginNonceBytes = 32
    private static let signatureBytes = 64
    /// A register nonce issued this far ahead of the clock still counts (Worker `register-nonce.ts`).
    private static let maxNonceSkew: TimeInterval = 60

    private var relayOrigin: RelayOrigin {
        guard let origin = try? RelayOrigin(origin) else { preconditionFailure("FakeHostedRelay: invalid origin") }
        return origin
    }

    /// The attestation rules apply to this device (README: off on dev; exempt probe devices).
    private func attests(_ deviceID: String) -> Bool {
        switch state.attestMode {
        case .off: return false
        case .enforce(let exempt): return !exempt.contains(deviceID)
        }
    }

    // MARK: - Register

    /// README "Registration": the nonce, the Ed25519 signature over the register hash
    /// and the attestation are checked before any device state is touched. As the
    /// Worker, a failed nonce or signature is `ATTESTATION_FAILED`, and in `off` mode
    /// (or for an exempt device) none of the three is checked.
    func register(_ op: Relay_V1_RegisterDevice) throws -> Relay_V1_Response {
        guard op.deviceKind == .phone || op.deviceKind == .mac, op.authPub.count == 32 else { throw RelayFailure.invalid }
        let deviceID = RelayAuthMessages.deviceID(publicKey: op.authPub)
        var attestedKey: Data?
        if attests(deviceID) {
            attestedKey = try checkRegisterAttestation(op, deviceID: deviceID)
        }
        var device = state.devices[deviceID] ?? newDevice(deviceID, op)
        // README "Re-registering": the new key replaces the stored one.
        guard device.kind == op.deviceKind else { throw RelayFailure.forbidden }
        if let attestedKey, attestedKey != device.attestKeyID {
            device.attestKeyID = attestedKey
            device.attestCounter = 0
        }
        state.devices[deviceID] = device
        var response = Relay_V1_Response()
        response.registered.deviceID = deviceID
        response.registered.accountID = device.accountID ?? ""
        return response
    }

    private func newDevice(_ deviceID: String, _ op: Relay_V1_RegisterDevice) -> Device {
        var accountID: String?
        if op.deviceKind == .phone {
            let id = UUID().uuidString.lowercased()
            state.accounts[id] = Account(id: id, phoneID: deviceID)
            accountID = id
        }
        return Device(id: deviceID, kind: op.deviceKind, authPub: op.authPub, accountID: accountID)
    }

    /// The attested key id, or the refusal (README "Who must attest").
    private func checkRegisterAttestation(_ op: Relay_V1_RegisterDevice, deviceID: String) throws -> Data {
        guard op.hasAttestation else { throw RelayFailure(.attestationRequired, "attestation required") }
        let failed = RelayFailure(.attestationFailed, "attestation failed")
        guard registerNonceValid(op.nonce, deviceID: deviceID) else { throw failed }
        let hash = RelayAuthMessages.registerClientDataHash(nonce: op.nonce, authPub: op.authPub, origin: relayOrigin)
        guard Self.signatureValid(op.signature, by: op.authPub, over: hash) else { throw failed }
        guard case .appAttest(let attest) = op.attestation.kind else {
            throw RelayFailure(.attestationRequired, "attestation required")
        }
        guard Self.attestationValid(attest, clientDataHash: hash) else { throw failed }
        return attest.keyID
    }

    // MARK: - Challenge

    /// README "Registration" 1: `REGISTER` answers a stateless nonce valid 5 minutes;
    /// `LOGIN` (the default) a single-use nonce valid 60 s.
    func challenge(_ op: Relay_V1_GetChallenge) throws -> Relay_V1_Response {
        guard !op.deviceID.isEmpty else { throw RelayFailure.unauthenticated }
        var response = Relay_V1_Response()
        if op.purpose == .register {
            response.challenge.nonce = issueRegisterNonce(deviceID: op.deviceID)
            return response
        }
        guard state.devices[op.deviceID] != nil else { throw RelayFailure.unauthenticated }
        let now = now
        let nonce = Self.randomBytes(Self.loginNonceBytes)
        var nonces = state.loginNonces[op.deviceID, default: [:]].filter { $0.value > now }
        nonces[nonce] = now.addingTimeInterval(RelayTTL.loginNonce)
        state.loginNonces[op.deviceID] = nonces
        response.challenge.nonce = nonce
        return response
    }

    /// 16 random bytes ‖ 8-byte big-endian issue time (ms) ‖ HMAC("register" ‖ device id ‖ both).
    private func issueRegisterNonce(deviceID: String) -> Data {
        var prefix = Self.randomBytes(16)
        withUnsafeBytes(of: UInt64(Self.ms(now)).bigEndian) { prefix.append(contentsOf: $0) }
        return prefix + registerNonceMAC(deviceID: deviceID, prefix: prefix)
    }

    private func registerNonceMAC(deviceID: String, prefix: Data) -> Data {
        let input = Data("register".utf8) + Data(deviceID.utf8) + prefix
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: state.nonceKey))
    }

    private func registerNonceValid(_ nonce: Data, deviceID: String) -> Bool {
        guard nonce.count == Self.registerNonceBytes else { return false }
        let bytes = [UInt8](nonce)
        let prefix = Data(bytes[0..<Self.registerNoncePrefixBytes])
        let issuedMs = bytes[16..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let issued = Date(timeIntervalSince1970: TimeInterval(issuedMs) / 1000)
        let age = now.timeIntervalSince(issued)
        guard age < RelayTTL.registerNonce, -age <= Self.maxNonceSkew else { return false }
        return Data(bytes[Self.registerNoncePrefixBytes...]) == registerNonceMAC(deviceID: deviceID, prefix: prefix)
    }

    // MARK: - Login

    /// README "Login": the nonce is consumed, then the Ed25519 signature over
    /// nonce ‖ device_id ‖ origin is checked, then the stored-key rules apply.
    ///
    /// README and Worker differ here, and the Worker wins (R20). The README says every
    /// attestation decision of a login comes only after the signature holds. The Worker
    /// (relay@3a99bd7 `worker/src/http/op.ts`, `loginAttestation`) verifies a fresh
    /// `app_attest` first, before the nonce is consumed and before `DeviceDO.login`
    /// checks the signature. So a bad fresh attestation is `ATTESTATION_FAILED` whatever
    /// the signature. An assertion, or no attestation at all, is still decided after the
    /// signature (`worker/src/do/device.ts`, `login`).
    func login(_ op: Relay_V1_Login) throws -> Relay_V1_Response {
        guard op.nonce.count == Self.loginNonceBytes else { throw RelayFailure.invalid }
        guard !op.deviceID.isEmpty else { throw RelayFailure.unauthenticated }
        if attests(op.deviceID), op.hasAttestation, case .appAttest(let attest) = op.attestation.kind {
            let hash = RelayAuthMessages.loginClientDataHash(nonce: op.nonce, deviceID: op.deviceID, origin: relayOrigin)
            guard Self.attestationValid(attest, clientDataHash: hash) else {
                throw RelayFailure(.attestationFailed, "attestation failed")
            }
        }
        let expiry = state.loginNonces[op.deviceID]?.removeValue(forKey: op.nonce)
        guard let expiry, now < expiry, var device = state.devices[op.deviceID] else { throw RelayFailure.unauthenticated }
        let message = RelayAuthMessages.loginMessage(nonce: op.nonce, deviceID: device.id, origin: relayOrigin)
        guard Self.signatureValid(op.signature, by: device.authPub, over: message) else { throw RelayFailure.unauthenticated }
        if attests(device.id) {
            try checkLoginAttestation(op, &device)
            state.devices[device.id] = device
        }
        let expiresAt = now.addingTimeInterval(RelayTTL.session)
        let token = Self.randomBytes(32).base64EncodedString()
        state.sessions[token] = Session(deviceID: device.id, kind: device.kind, expiresAt: expiresAt)
        var response = Relay_V1_Response()
        response.session.token = token
        response.session.expiresAtMs = Self.ms(expiresAt)
        return response
    }

    /// An assertion by the stored key with a strictly greater counter, or a fresh
    /// attestation (lost-key path) that replaces the key; nothing at all is `ATTESTATION_REQUIRED`,
    /// an assertion without a stored key `ATTESTATION_FAILED`.
    private func checkLoginAttestation(_ op: Relay_V1_Login, _ device: inout Device) throws {
        let failed = RelayFailure(.attestationFailed, "attestation failed")
        let hash = RelayAuthMessages.loginClientDataHash(nonce: op.nonce, deviceID: device.id, origin: relayOrigin)
        switch op.hasAttestation ? op.attestation.kind : nil {
        case .appAttest(let attest):
            // Verified in `login` before the nonce and the signature (the Worker's order).
            if attest.keyID != device.attestKeyID {
                device.attestKeyID = attest.keyID
                device.attestCounter = 0
            }
        case .appAttestAssertion(let assertion):
            guard let keyID = device.attestKeyID,
                  let counter = Self.assertionCounter(assertion.assertion, keyID: keyID, clientDataHash: hash),
                  counter > device.attestCounter
            else { throw failed }
            device.attestCounter = counter
        case nil:
            throw RelayFailure(.attestationRequired, "attestation required")
        }
    }

    // MARK: - Sessions

    /// README "HTTP status": a missing, unknown or expired token is `UNAUTHENTICATED`.
    func session(bearer: String?) throws -> Session {
        guard let bearer, let session = state.sessions[bearer] else { throw RelayFailure.unauthenticated }
        guard now < session.expiresAt else {
            state.sessions[bearer] = nil
            throw RelayFailure.unauthenticated
        }
        return session
    }

    // MARK: - Crypto and FakeAppAttest bytes

    private static func signatureValid(_ signature: Data, by publicKey: Data, over message: Data) -> Bool {
        guard signature.count == signatureBytes,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func keyIDMatches(_ object: [String: Any], _ keyID: Data) -> Bool {
        guard let string = object["key_id"] as? String, let bytes = Data(base64Encoded: string) else { return false }
        return !keyID.isEmpty && bytes == keyID
    }

    /// `FakeAppAttest.attestKey`'s object over `clientDataHash` for the request's key id.
    private static func attestationValid(_ attest: Relay_V1_AppAttest, clientDataHash: Data) -> Bool {
        guard let object = json(attest.attestationObject) else { return false }
        return object["fake_app_attest"] as? Int == 1
            && object["app_id"] as? String == FakeAppAttest.appID
            && object["client_data_hash"] as? String == clientDataHash.base64EncodedString()
            && keyIDMatches(object, attest.keyID)
    }

    /// The counter of `FakeAppAttest.generateAssertion`'s bytes by `keyID` over `clientDataHash`.
    private static func assertionCounter(_ assertion: Data, keyID: Data, clientDataHash: Data) -> Int? {
        guard let object = json(assertion),
              keyIDMatches(object, keyID),
              object["client_data_hash"] as? String == clientDataHash.base64EncodedString()
        else { return nil }
        return object["counter"] as? Int
    }
}
