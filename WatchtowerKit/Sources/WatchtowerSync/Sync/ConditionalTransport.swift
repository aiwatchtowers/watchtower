import Foundation

/// What a conditional write expects to find under its record name.
public enum WriteExpectation: Equatable, Sendable {
    /// Write whatever is there (an unconditional write).
    case none
    /// Write only when no record exists under the name.
    case absent
    /// Write only over the version whose `CloudRecord.recordSeq` is this value.
    case seq(UInt64)
}

public struct ConditionalSave: Equatable, Sendable {
    public let record: CloudRecord
    public let expect: WriteExpectation

    public init(record: CloudRecord, expect: WriteExpectation) {
        self.record = record
        self.expect = expect
    }
}

public struct ConditionalDelete: Equatable, Sendable {
    public let recordName: String
    public let zone: CloudZoneID
    public let expect: WriteExpectation

    public init(recordName: String, zone: CloudZoneID, expect: WriteExpectation) {
        self.recordName = recordName
        self.zone = zone
        self.expect = expect
    }
}

/// Why a write did not land. A flush stops at a non-`.permanent` refusal of a control or an action. A `.permanent`
/// refusal never stops it: the action moves to Not delivered, the control stays queued for the next pass, and the flush goes on.
public enum TransportRefusal: Equatable, Sendable {
    /// No network, the service or the account is away for now.
    case unreachable
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    /// Hosted relay (Phase 2+); never produced on CloudKit.
    case entitlementInactive
    /// A failure retrying may clear (cancelled, response lost, unknown codes).
    case transient(code: String)
    /// Retrying can only repeat it: the zone is gone, permission lost, the record alone too large.
    case permanent(code: String)

    public var isPermanent: Bool {
        if case .permanent = self { return true }
        return false
    }
}

public enum SaveOutcome: Equatable, Sendable {
    case saved(recordSeq: UInt64)
    case conflict(current: CloudRecord)
    case refused(TransportRefusal)
}

public enum DeleteOutcome: Equatable, Sendable {
    case deleted
    case conflict(current: CloudRecord)
    case refused(TransportRefusal)
}

/// Transport extension for writes that land only when the record is in the state the writer expects. Kept off
/// `CloudSyncTransport` (the seam keeps its three requirements) like `CompactingTransport` and `SweepingTransport`.
public protocol ConditionalTransport: CloudSyncTransport {
    /// One outcome per item, in order. A call-level failure (no network) is `.refused` for every item; it throws only for local errors.
    func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome]
    /// An absent record counts as `.deleted` (the seam's idempotent delete).
    func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome]
}
