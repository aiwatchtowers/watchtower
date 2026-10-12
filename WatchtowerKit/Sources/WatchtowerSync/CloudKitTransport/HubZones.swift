import CloudKit

/// Which side of a link a transport plays (multi-hub spec §4.1). Only the
/// hub creates, re-creates and deletes zones; a phone never does, so a zone
/// its hub removed is never resurrected — the phone reads it as unlinked.
public enum TransportRole: Equatable, Sendable {
    case hub
    case phone
}

/// The two zones of one hub (multi-hub spec §3.1, §4.1): `DataZone-<hubID>`
/// and `RelayZone-<hubID>`, owned by the hub's iCloud user. Maps a zone kind
/// to its server id and back; a zone of another hub, the single-hub build's
/// fixed-name zones, and (shared scope) another owner's zones are not ours.
public struct HubZones: Equatable, Sendable {
    public let scope: CloudDatabaseScope
    public let hubID: String

    public init(scope: CloudDatabaseScope, hubID: String) {
        self.scope = scope
        self.hubID = hubID
    }

    public static func zoneName(_ zone: CloudZoneID, hubID: String) -> String {
        "\(zone.rawValue)-\(hubID)"
    }

    public func zoneID(for zone: CloudZoneID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Self.zoneName(zone, hubID: hubID), ownerName: ownerName)
    }

    public var allZoneIDs: [CKRecordZone.ID] {
        CloudZoneID.allCases.map(zoneID(for:))
    }

    public func cloudZone(for zoneID: CKRecordZone.ID) -> CloudZoneID? {
        guard let zone = CloudZoneID.allCases.first(where: { Self.zoneName($0, hubID: hubID) == zoneID.zoneName }) else {
            return nil
        }
        if case .shared(let owner) = scope, zoneID.ownerName != owner { return nil }
        return zone
    }

    /// The single-hub build's fixed-name zones in the private database
    /// (multi-hub spec §3.6).
    static var legacyZoneIDs: [CKRecordZone.ID] {
        CloudZoneID.allCases.map(legacyZoneID)
    }

    /// One of the single-hub build's fixed-name zones.
    static func legacyZoneID(_ zone: CloudZoneID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
    }

    private var ownerName: String {
        switch scope {
        case .private: return CKCurrentUserDefaultName
        case .shared(let owner): return owner
        }
    }
}
