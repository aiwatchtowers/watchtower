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

/// Transport extension for consumer-driven compaction. Separated from
/// `CloudSyncTransport` (Plan 2 binding rule: the seam gains no new
/// requirements) so conformers that don't buffer (e.g. the test fake) need
/// not provide an implementation.
///
/// Retention/hygiene interaction: the relay buffer must retain full history
/// until hygiene's aged-record scan (`changes(in: .relay, since: nil)`)
/// finds and deletes stale records. Call `compact` only AFTER hygiene has
/// had a chance to scan — the Plan 3 Task 4 hydrator is the intended consumer.
/// A silent no-op default is intentionally absent: a conformer that forgets
/// to implement compaction would silently accumulate the buffer forever.
public protocol CompactingTransport: CloudSyncTransport {
    func compact(in zone: CloudZoneID, keepSince token: CloudChangeToken) async throws
}

/// Transport extension for age-based retention of the local event buffer —
/// like `CompactingTransport`, kept off the seam so conformers that don't
/// buffer need not implement it. Intended caller: the desktop relay hygiene,
/// whose server-side deletes only ever APPEND (deletion) events, so without
/// a sweep the relay buffer grows forever.
///
/// Semantics (see `TransportStore.sweepEvents` for the full argument): delete
/// only events older than `cutoff` AND at or below the consumer floor `token`.
/// Age-based so it cannot re-blind hygiene's full-zone aged-record scan;
/// token-floored so it can never delete an event a consumer has not read yet
/// (a device offline past the cutoff buffers old-modifiedAt records on its
/// first pull — those must survive until processed).
public protocol SweepingTransport: CloudSyncTransport {
    @discardableResult
    func sweepEvents(in zone: CloudZoneID, olderThan cutoff: Date, upTo token: CloudChangeToken) async throws -> Int
}
