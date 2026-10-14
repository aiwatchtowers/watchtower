import CryptoKit
import Foundation

/// Which side of the link a `SecureTransport` seals and opens for.
public enum SecureRole: Equatable, Sendable {
    case hub(hubID: UUID)
    case phone(hubID: UUID, deviceID: UUID)

    public var hubID: UUID {
        switch self {
        case .hub(let hubID), .phone(let hubID, _): return hubID
        }
    }
}

/// The key material `SecureTransport` needs, by role. A locked keychain surfaces as `KeyStoreError.locked`
/// (never as "absent"); the transport maps it to `SecureTransportError.keysUnavailable` on reads.
public protocol SecureKeyProvider: Sendable {
    var role: SecureRole { get }
    func metaKey() throws -> SymmetricKey
    func currentEpoch() throws -> UInt32
    func dataKey(epoch: UInt32) throws -> SymmetricKey
    func alertKey(epoch: UInt32) throws -> SymmetricKey
    func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey
    /// Accepted relay epochs for a sender: the current one, and the previous one for 7 days (D10).
    /// false for a device this side holds no relay key for (an unknown or removed phone).
    func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool
    /// Every device whose relay keys this side holds: the hub's linked phones; on a phone, the phone itself.
    /// The hub opens its own h2p echoes with these (F2): an h2p header names the hub as sender, not the
    /// recipient, so the hub tries each device's h2p key (one AEAD check per linked phone).
    func relayDeviceIDs() throws -> [UUID]
    func nextSeq() throws -> UInt64
    // hub only (a phone provider throws SecureTransportError.wrongRole):
    func hubSigner() throws -> Curve25519.Signing.PrivateKey
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey
    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey?
    // phone only (a hub provider throws SecureTransportError.wrongRole):
    func deviceSigner() throws -> Curve25519.Signing.PrivateKey
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey
    func linkNonce() throws -> Data
}

public enum SecureTransportError: Error, Equatable {
    /// The call does not fit this side's role (a phone writing DataZone, a hub asked for a device key).
    case wrongRole
    /// The keys exist but cannot be read now (locked device), or are not there yet: keep the token, retry.
    case keysUnavailable
    /// A plain kind this role does not seal.
    case unknownKind(String)
    /// A keybox (plain record name) for a device the hub has no agreement key for.
    case noKeyboxRecipient(String)
    /// A hub echo (plain record name) with neither `sealed` info nor a payload `device_id` to seal it to.
    case noRelayRecipient(String)
}

/// Persisted wire → plain name map (F19): the hub passes its sidecar (`slice_state.wire_name`, Task 10/11), so a
/// rejection of a record CKSyncEngine queued in an earlier launch still maps back. nil on the phone.
public protocol WireNameIndex: Sendable {
    func plainName(forWire wireName: String) -> String?
}

/// A relay record this transport will not hand over (F2): another phone's, a removed phone's, a stranger's, or an
/// older version of a record the rollback guard has seen newer (`reason == "rolledBack"`). Hygiene ages them out
/// by wire name.
public struct UnopenableRecord: Equatable, Sendable {
    public let wireName: String
    public let modifiedAt: Date      // plaintext on the wire (spec §2.4)
    /// A short code (`authenticationFailed`, `noRelayKey`, `rolledBack`, ...); never key material.
    public let reason: String
    /// The server's own date for the record (`CloudRecord.serverModifiedAt`).
    public let serverModifiedAt: Date?

    public init(wireName: String, modifiedAt: Date, reason: String, serverModifiedAt: Date? = nil) {
        self.wireName = wireName
        self.modifiedAt = modifiedAt
        self.reason = reason
        self.serverModifiedAt = serverModifiedAt
    }
}
