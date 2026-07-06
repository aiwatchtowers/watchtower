import Foundation

/// CloudKit zone identifiers. rawValue is the CKRecordZone name (Plan 2).
public enum CloudZoneID: String, Codable, CaseIterable {
    case data = "DataZone"
    case relay = "RelayZone"
}

/// One record on the wire: identity + opaque payload. The real transport
/// (Plan 2) maps this 1:1 onto a CKRecord with `payload` in encryptedValues.
public struct CloudRecord: Equatable {
    public let recordName: String
    public let zone: CloudZoneID
    public let kind: String
    public let modifiedAt: Date
    public let payload: Data

    public init(recordName: String, zone: CloudZoneID, kind: String, modifiedAt: Date, payload: Data) {
        self.recordName = recordName
        self.zone = zone
        self.kind = kind
        self.modifiedAt = modifiedAt
        self.payload = payload
    }
}

/// Opaque, monotonically increasing per-zone change cursor.
public struct CloudChangeToken: Codable, Equatable {
    public let value: Int

    public init(value: Int) {
        self.value = value
    }
}

public struct CloudChangeBatch: Equatable {
    public let changed: [CloudRecord]
    public let deletedRecordNames: [String]
    public let newToken: CloudChangeToken

    public init(changed: [CloudRecord], deletedRecordNames: [String], newToken: CloudChangeToken) {
        self.changed = changed
        self.deletedRecordNames = deletedRecordNames
        self.newToken = newToken
    }
}

/// The seam that hides CloudKit. Everything above this protocol is unit-testable
/// against InMemoryCloudTransport; only Plan 2's CKSyncEngine adapter touches CloudKit.
public protocol CloudSyncTransport {
    func save(_ records: [CloudRecord]) async throws
    /// Deleting is idempotent: deleting a recordName that was never saved
    /// (or is already deleted) succeeds silently. CloudKit adapters must
    /// swallow the server's unknown-item error to honor this.
    func delete(recordNames: [String], in zone: CloudZoneID) async throws
    /// `changed` and `deletedRecordNames` are in first-seen event order.
    /// Consumers should not rely on stricter ordering — the real CloudKit
    /// adapter only guarantees this much. Visibility of a device's OWN saves
    /// in `changes` is transport-dependent and possibly delayed: the in-memory
    /// fake sees them immediately, the CloudKit adapter only after the engine
    /// re-fetches them.
    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch
}
