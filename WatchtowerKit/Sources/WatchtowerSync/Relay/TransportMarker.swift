import Foundation

/// The hub's transport marker (sim rule 12a; Go hub Phase 3 contract points 4 and 6a): the data-zone record of plain
/// kind `transport`, id `marker`, whose payload is the latest `transport_switched` without its `keybox` and
/// `device_id`. The hub writes it into the data zone of the transport it moves to and of the one it leaves, and never
/// deletes it, so a phone that missed the control still learns where the hub went. The replica stores it like any
/// data record; `ReplicaHydrator` decodes it and hands it to the phone's transport follower.
public struct TransportMarker: Equatable, Sendable {
    /// The record's plain kind and name.
    public static let kind = "transport"
    public static let recordName = "transport-marker"

    public let target: TransportKind
    public let epoch: UInt32
    /// The device id of the phone whose switch it was, or `entitlement_expired`.
    public let by: String
    public let at: Date

    public init(target: TransportKind, epoch: UInt32, by: String, at: Date) {
        self.target = target
        self.epoch = epoch
        self.by = by
        self.at = at
    }

    /// The marker in a payload (RelayCoder JSON, as `ControlPayload`): `target`, `epoch`, `by` and `at` must all be
    /// there, and `target` must name a transport this build knows.
    public static func decode(_ payload: Data) throws -> Self {
        let body = try RelayCoder.makeDecoder().decode(Body.self, from: payload)
        guard let raw = body.target else { throw TransportMarkerError.missingField("target") }
        guard let target = TransportKind(rawValue: raw) else { throw TransportMarkerError.unknownTarget(raw) }
        guard let epoch = body.epoch else { throw TransportMarkerError.missingField("epoch") }
        guard let by = body.by else { throw TransportMarkerError.missingField("by") }
        guard let at = body.at else { throw TransportMarkerError.missingField("at") }
        return Self(target: target, epoch: epoch, by: by, at: at)
    }

    /// The fields the phone reads; the rest (`id`, `kind`, `hub_id`) is ignored.
    private struct Body: Decodable {
        let target: String?
        let epoch: UInt32?
        let by: String?
        let at: Date?
    }
}

/// Why a marker payload is not one this build follows.
public enum TransportMarkerError: Error, Equatable {
    /// A field the marker must carry is absent (its wire name).
    case missingField(String)
    /// `target` names a transport this build does not know (a newer hub's).
    case unknownTarget(String)
}
