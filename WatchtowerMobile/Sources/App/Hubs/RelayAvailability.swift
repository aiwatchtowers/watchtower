import Foundation
import os
import WatchtowerHostedRelay
import WatchtowerSync

/// Whether this phone may use the hosted relay at all: an origin is configured (`RelayConfig`) and the device
/// has App Attest. `.off` routes every hub over CloudKit and builds nothing relay-shaped (relay client Phase 3,
/// dark ship; R18).
enum RelayAvailability: Equatable, Sendable {
    enum Off: Equatable, Sendable {
        /// No origin: every committed build setting, so every Release build.
        case notConfigured
        /// App Attest is not supported on this device: the relay refuses it.
        case unsupportedDevice
    }

    case off(Off)
    case available(RelayOrigin)

    static func evaluate(config: RelayConfig, attestSupported: Bool) -> Self {
        evaluate(config: config) { attestSupported }
    }

    /// Asks `attestSupported` (a DeviceCheck call) only when an origin is configured.
    static func evaluate(config: RelayConfig, attestSupported: () -> Bool) -> Self {
        guard let origin = config.origin else { return .off(.notConfigured) }
        return attestSupported() ? .available(origin) : .off(.unsupportedDevice)
    }
}

/// What the phone's relay objects are made of. The live parts reach DeviceCheck, the Keychain and the network
/// once used, so they are built only for a configured origin (`SharedRelaySession`).
struct RelayParts: Sendable {
    var attest: any AppAttesting
    var keychain: any KeychainBackend
    /// The app's private Keychain group, never the alerts group the NotifyService extension reads.
    var keychainGroup: String?
    var http: any RelayHTTP
    var sockets: any RelaySocketDialer
    var clock: any RelayClock = SystemRelayClock()

    /// DeviceCheck's App Attest, the app's own Keychain group, ephemeral URL sessions.
    static func live(bundle: Bundle = .main) throws -> Self {
        Self(
            attest: DeviceCheckAppAttest(),
            keychain: SecItemKeychainBackend(),
            keychainGroup: try PhoneKeychain.privateGroup(in: bundle.infoDictionary ?? [:]),
            http: URLSessionRelayHTTP(),
            sockets: URLSessionRelaySocketDialer()
        )
    }
}

/// The process's one relay session (R2): every relay transport of the app attaches to it, so the device never
/// opens two sockets. Built on first use and only when the relay is `.available`; until then (and always while
/// `.off`) no relay identity, Keychain item, App Attest call or connection exists.
final class SharedRelaySession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "HostedRelay")

    let availability: RelayAvailability
    /// The parts, kept only when the relay is available.
    private let parts: RelayParts?
    private let lock = NSLock()
    private var built: HostedRelaySession?
    /// The built session's `relay_auth` signer: the device record's relay-id proof (Phase 3b Task 19).
    private var signer: (any RelaySigner)?

    /// `parts` is called only for a configured origin, at most once. Parts that cannot be built (a build
    /// without its Keychain group) leave the relay off, logged: the app still boots on CloudKit.
    init(config: RelayConfig, parts makeParts: () throws -> RelayParts) {
        guard config.origin != nil else {
            availability = .off(.notConfigured)
            parts = nil
            return
        }
        let parts: RelayParts
        do {
            parts = try makeParts()
        } catch {
            Self.logger.error("relay off: its parts could not be built")
            availability = .off(.notConfigured)
            self.parts = nil
            return
        }
        availability = RelayAvailability.evaluate(config: config) { parts.attest.isSupported }
        if case .available = availability {
            self.parts = parts
        } else {
            self.parts = nil
            Self.logger.notice("relay off: App Attest unsupported")
        }
    }

    /// The relay is off for good in this process.
    static let off = SharedRelaySession()

    private init() {
        availability = .off(.notConfigured)
        parts = nil
    }

    /// Whether the session was built.
    var isBuilt: Bool { lock.withLock { built != nil } }

    /// The session, built on first use (the relay identity is created in the Keychain then); nil while the relay
    /// is `.off`. Throws the Keychain's error (a locked device) and builds nothing then.
    func session() throws -> HostedRelaySession? {
        guard case .available(let origin) = availability, let parts else { return nil }
        return try lock.withLock {
            if let built { return built }
            let identity = KeychainRelayIdentity(backend: parts.keychain, group: parts.keychainGroup)
            let signer = try identity.signer()
            let client = HostedRelayClient(
                origin: origin,
                signer: signer,
                kind: .phone,
                attestor: RelayAttestor(attest: parts.attest, keys: identity, clock: parts.clock),
                http: parts.http,
                sockets: parts.sockets,
                clock: parts.clock
            )
            let session = HostedRelaySession(client: client)
            built = session
            self.signer = signer
            return session
        }
    }

    /// The device record's relay fields for `hubID` and `deviceID`, signed by this phone's `relay_auth` key (the
    /// session is built first); nil while the relay is `.off`.
    func relayIDProof(hubID: UUID, deviceID: UUID) throws -> RelayIDClaim? {
        guard try session() != nil, let signer = lock.withLock({ signer }) else { return nil }
        let proof = try RelayIDProof.sign(authPub: signer.publicKey, hubID: hubID, deviceID: deviceID, sign: signer.sign)
        return RelayIDClaim(relayDeviceID: proof.relayDeviceID, authPub: proof.authPub, sig: proof.sig)
    }
}

/// The link flow's relay ops on the process's one relay session (`HostedRelayPairing`): nothing is built until the
/// first op, and nothing at all while the relay is off (every op then throws `.unreachable`).
struct HostedRelayLinkOps: RelayLinkOps {
    let relay: SharedRelaySession

    var availability: RelayAvailability { relay.availability }

    private func pairing() throws -> HostedRelayPairing {
        guard let session = try relay.session() else { throw HostedRelayPairing.Refusal.unreachable }
        return HostedRelayPairing(session: session)
    }

    func phoneDeviceID() throws -> String {
        guard let session = try relay.session() else { throw HostedRelayPairing.Refusal.unreachable }
        return session.client.deviceID
    }

    func accountState() async throws -> (paying: Bool, macs: [String]) {
        try await pairing().accountState()
    }

    func open(mac: String) async throws -> (slot: String, expiresAt: Date) {
        try await pairing().open(mac: mac)
    }

    func vouch(hubDeviceID: String, authPub: Data) async throws {
        try await pairing().vouch(hubDeviceID: hubDeviceID, authPub: authPub)
    }

    func promote(slot: String) async throws {
        try await pairing().promote(slot: slot)
    }

    func close(slot: String) async {
        guard let pairing = try? pairing() else { return }
        await pairing.close(slot: slot)
    }

    func removeSlot(mac: String) async throws {
        try await pairing().removeSlot(mac: mac)
    }

    func addSlot(mac: String) async throws {
        try await pairing().addSlot(mac: mac)
    }

    func relayIDProof(hubID: UUID, deviceID: UUID) throws -> RelayIDClaim {
        guard let claim = try relay.relayIDProof(hubID: hubID, deviceID: deviceID) else {
            throw HostedRelayPairing.Refusal.unreachable
        }
        return claim
    }
}
