import CryptoKit
import Foundation
import os
import WatchtowerSync

/// The phone's relay identity in the Keychain: the `relay_auth` Ed25519 private
/// key (`relay.auth`, raw 32 bytes) and the App Attest key id (`relay.attestkey`,
/// UTF-8). Both items are `afterFirstUnlock` (`ThisDeviceOnly`), data-protection
/// keychain, never synchronizable, in the app's private access group — never the
/// alerts group the NotifyService extension reads. Nothing is ever logged but op
/// names and error codes.
public final class KeychainRelayIdentity: AppAttestKeyStore, @unchecked Sendable {
    private static let logger = Logger(subsystem: "WatchtowerKit", category: "HostedRelay")
    static let authAccount = "relay.auth"
    static let attestKeyAccount = "relay.attestkey"

    private let backend: any KeychainBackend
    private let group: String?
    private let lock = NSLock()

    /// `group`: the app's private Keychain group (never the alerts group).
    public init(backend: any KeychainBackend, group: String?) {
        self.backend = backend
        self.group = group
    }

    /// The stored signer; nil when none exists. Never creates.
    public func existingSigner() throws -> (any RelaySigner)? {
        try lock.withLock {
            guard let raw = try backend.read(account: Self.authAccount, group: group) else { return nil }
            return try Self.parse(raw)
        }
    }

    /// The stored signer, created on first use (`add`, never `write`: two creators
    /// never clobber; a lost race reads the winner's). A locked device throws
    /// `KeyStoreError.locked` and creates nothing; a stored key that does not parse
    /// throws `KeyStoreError.corrupt` and is kept.
    public func signer() throws -> any RelaySigner {
        try lock.withLock {
            if let raw = try backend.read(account: Self.authAccount, group: group) {
                return try Self.parse(raw)
            }
            let fresh = Curve25519.Signing.PrivateKey()
            let added = try backend.add(
                fresh.rawRepresentation, account: Self.authAccount, access: .afterFirstUnlock, group: group,
                dataProtection: true)
            if added { return Ed25519RelaySigner(fresh) }
            guard let winner = try backend.read(account: Self.authAccount, group: group) else {
                throw KeyStoreError.corrupt("relay auth key vanished after a lost create race")
            }
            return try Self.parse(winner)
        }
    }

    /// The stored App Attest key id. Any read error (locked, missing entitlement,
    /// not UTF-8 or empty) is logged by code and returns nil, which leads into the
    /// lost-key path. It never touches `relay_auth`.
    public func keyID() -> String? {
        do {
            let data = try lock.withLock { try backend.read(account: Self.attestKeyAccount, group: group) }
            guard let data else { return nil }
            guard let id = String(data: data, encoding: .utf8), !id.isEmpty else {
                Self.logger.error("relay attest key id read: not UTF-8 or empty")
                return nil
            }
            return id
        } catch {
            Self.logger.error("relay attest key id read failed: \(Self.code(error), privacy: .public)")
            return nil
        }
    }

    /// nil deletes the item. `AppAttestKeyStore` does not throw: a failed write keeps
    /// whatever was stored (or nothing) and is logged by code. A stale id is caught
    /// by the attestor's invalid-key and server-refusal paths.
    public func setKeyID(_ id: String?) {
        do {
            try lock.withLock {
                if let id {
                    try backend.write(
                        Data(id.utf8), account: Self.attestKeyAccount, access: .afterFirstUnlock, group: group,
                        dataProtection: true)
                } else {
                    try backend.delete(account: Self.attestKeyAccount, group: group)
                }
            }
        } catch {
            let op = id == nil ? "delete" : "write"
            Self.logger.error("relay attest key id \(op, privacy: .public) failed: \(Self.code(error), privacy: .public)")
        }
    }

    private static func parse(_ raw: Data) throws -> any RelaySigner {
        guard raw.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw KeyStoreError.corrupt("relay auth key is not 32 bytes")
        }
        return Ed25519RelaySigner(key)
    }

    /// A code only: never an error's description.
    private static func code(_ error: any Error) -> String {
        switch error {
        case KeyStoreError.locked: "locked"
        case KeyStoreError.missingEntitlement: "missingEntitlement"
        case KeyStoreError.corrupt: "corrupt"
        case let KeyStoreError.unexpected(status): "unexpected(\(status))"
        default: "unexpected"
        }
    }
}
