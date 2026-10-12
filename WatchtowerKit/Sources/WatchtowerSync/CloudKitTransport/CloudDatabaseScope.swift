import CloudKit

/// Which CloudKit database the transport syncs (mobile POC spec §2.3).
///
/// - `private`: the Mac hub, and a phone on the Mac's Apple ID. Zones live
///   in this account's private database; the hub creates them.
/// - `shared(ownerName:)`: a phone on a different Apple ID, reaching the
///   Mac's zones through accepted zone-wide shares in its shared database.
///   `ownerName` is the Mac user's `userRecordID.recordName` (the QR's
///   `owner_user`), the owner of every shared zone. A participant cannot
///   create or delete zones; only the hub role writes them (`TransportRole`).
///
/// The zones themselves are per hub: see `HubZones`.
public enum CloudDatabaseScope: Equatable, Sendable {
    case `private`
    case shared(ownerName: String)

    func database(in container: CKContainer) -> CKDatabase {
        switch self {
        case .private: return container.privateCloudDatabase
        case .shared: return container.sharedCloudDatabase
        }
    }
}
