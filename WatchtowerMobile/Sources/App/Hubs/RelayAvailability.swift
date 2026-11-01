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

    /// `parts` is called only for a configured origin, at most once.
    init(config: RelayConfig, parts makeParts: () throws -> RelayParts) throws {
        guard config.origin != nil else {
            availability = .off(.notConfigured)
            parts = nil
            return
        }
        let parts = try makeParts()
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
            let client = HostedRelayClient(
                origin: origin,
                signer: try identity.signer(),
                kind: .phone,
                attestor: RelayAttestor(attest: parts.attest, keys: identity, clock: parts.clock),
                http: parts.http,
                sockets: parts.sockets,
                clock: parts.clock
            )
            let session = HostedRelaySession(client: client)
            built = session
            return session
        }
    }
}
