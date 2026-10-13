import Foundation
import os
import WatchtowerSync

/// The Mac this phone is linked to (mobile POC spec §2.3): the hub, the
/// database scope it syncs through, and the share URLs kept from the scan.
struct LinkRecord: Codable, Equatable, Sendable {
    let hubID: String
    let macName: String
    let scope: DeviceScope
    /// The Mac user's `userRecordID.recordName` (the code's `owner_user`):
    /// in `shared` scope, the owner of every shared zone.
    let ownerName: String
    /// This phone's iCloud user when it linked. Another account signing in
    /// ends the link (spec §9).
    let userRecordName: String
    /// The single-use code the link was made with.
    let nonce: String
    /// The two `CKShare.url`s of a `shared` link (nil in `private` scope):
    /// kept so the shares can be accepted again (spec §2.3 fallback F2).
    let dataShareURL: String?
    let relayShareURL: String?

    /// The database the phone's transport syncs for this link.
    var databaseScope: CloudDatabaseScope {
        scope == .shared ? .shared(ownerName: ownerName) : .private
    }
}

/// A link written to the Mac and not answered yet (spec §2.3 step 5). Kept
/// across a kill, so a relaunch resumes the wait for what is left of it.
struct PendingLink: Codable, Equatable, Sendable {
    let link: LinkRecord
    /// The end of the 60 s grant wait, on the phone's clock.
    let deadline: Date
    /// This phone's grant as the replica held it just before the device
    /// record was written: an earlier answer (a refusal of another code) is
    /// not this scan's.
    let baseline: DeviceGrant?
    /// `baseline` was read (nil then means no grant). false while the sync
    /// stack restarts, before the device record is written; a value saved
    /// by an older build reads false.
    let baselineCaptured: Bool
    /// The scanned code's `iat`, on the Mac's clock (mobile E2E review M-3):
    /// a `linked` keybox decided before it is an older link, not this scan's
    /// confirmation. nil in a value an older build saved.
    let issuedAt: Date?

    init(link: LinkRecord, deadline: Date, baseline: DeviceGrant?, baselineCaptured: Bool, issuedAt: Date? = nil) {
        self.link = link
        self.deadline = deadline
        self.baseline = baseline
        self.baselineCaptured = baselineCaptured
        self.issuedAt = issuedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        link = try container.decode(LinkRecord.self, forKey: .link)
        deadline = try container.decode(Date.self, forKey: .deadline)
        baseline = try container.decodeIfPresent(DeviceGrant.self, forKey: .baseline)
        baselineCaptured = try container.decodeIfPresent(Bool.self, forKey: .baselineCaptured) ?? false
        issuedAt = try container.decodeIfPresent(Date.self, forKey: .issuedAt)
    }
}

/// The phone's link, persisted in `UserDefaults`: the one record the link
/// flow writes and the app boots from (which database to sync, which
/// device to be).
final class LinkStore {
    private let defaults: UserDefaults
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "LinkStore")

    private enum Keys {
        static let link = "link.record"
        static let pending = "link.pending"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var link: LinkRecord? {
        get { read(LinkRecord.self, key: Keys.link) }
        set { write(newValue, key: Keys.link) }
    }

    var pending: PendingLink? {
        get { read(PendingLink.self, key: Keys.pending) }
        set { write(newValue, key: Keys.pending) }
    }

    /// The database the app syncs at boot: the link's, else a pending
    /// link's, else the phone's own private database.
    var bootScope: CloudDatabaseScope {
        link?.databaseScope ?? pending?.link.databaseScope ?? .private
    }

    /// The hub whose zones the app syncs at boot: the link's, else a pending
    /// link's, else `AppEnvironment.unlinkedHubID` (F1's single-link bridge
    /// until F2's `HubRegistry`).
    var bootHubID: String {
        link?.hubID ?? pending?.link.hubID ?? AppEnvironment.unlinkedHubID
    }

    /// Plain JSON (local state, not wire format: RelayCoder's snake-case
    /// keys would not round-trip `hubID`). An unreadable value reads as
    /// absent and is logged: the phone then shows Welcome rather than run a
    /// link it cannot read.
    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.logger.error("unreadable \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T?, key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Self.logger.error("could not save \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
