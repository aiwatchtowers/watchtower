import CloudKit

/// Which CloudKit database the transport syncs (mobile POC spec §2.3).
///
/// - `private`: the Mac hub, and a phone on the Mac's Apple ID. Zones live
///   in this account's private database and the transport creates them.
/// - `shared(ownerName:)`: a phone on a different Apple ID, reaching the
///   Mac's zones through accepted zone-wide shares in its shared database.
///   `ownerName` is the Mac user's `userRecordID.recordName` (the QR's
///   `owner_user`), the owner of every shared zone. A participant cannot
///   create or delete zones, so the transport never issues zone writes.
public enum CloudDatabaseScope: Equatable, Sendable {
    case `private`
    case shared(ownerName: String)

    /// Whether the transport may save (create) and delete zones.
    var writesZones: Bool {
        if case .private = self { return true }
        return false
    }

    func zoneID(for zone: CloudZoneID) -> CKRecordZone.ID {
        switch self {
        case .private:
            return CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
        case .shared(let ownerName):
            return CKRecordZone.ID(zoneName: zone.rawValue, ownerName: ownerName)
        }
    }

    /// Maps a server zone id back to one of this scope's zones. In `shared`
    /// scope a zone of another owner is not ours, whatever its name. The
    /// private scope matches by name only, as the branch always did.
    func cloudZone(for zoneID: CKRecordZone.ID) -> CloudZoneID? {
        guard let zone = CloudZoneID(rawValue: zoneID.zoneName) else { return nil }
        if case .shared(let ownerName) = self, zoneID.ownerName != ownerName { return nil }
        return zone
    }

    func database(in container: CKContainer) -> CKDatabase {
        switch self {
        case .private: return container.privateCloudDatabase
        case .shared: return container.sharedCloudDatabase
        }
    }
}
