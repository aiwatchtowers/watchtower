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
    /// The device id this phone linked with (its `device` record's): the
    /// grant the removal check reads (#64), whatever the Keychain says
    /// later. nil in a link saved before it was kept: no removal is ever
    /// read from such a link.
    var deviceID: String?
    /// The linked grant's `linked_at` (the Mac's clock) when the link was
    /// saved; nil in an older link. A removal is read only from a heartbeat
    /// newer than it.
    var linkedAt: Date?

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

/// The link flow's state in `UserDefaults`: a link waiting for its grant,
/// which a relaunch resumes. The saved links are the hub registry's
/// (`HubRegistry`); an F1 phone's single link is read here once, by
/// `HubBoot.migrateF1`, which moves it into the registry and clears it.
final class LinkStore {
    private let defaults: UserDefaults
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "LinkStore")

    private enum Keys {
        static let legacyLink = "link.record"
        static let pending = "link.pending"
        static let legacyGrantMissingSince = "link.grantMissingSince"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The single link of F1 (`link.record`), for the migration only.
    var legacyLink: LinkRecord? {
        get { read(LinkRecord.self, key: Keys.legacyLink) }
        set { write(newValue, key: Keys.legacyLink) }
    }

    /// `link.record` holds data that does not decode: a link is saved, but
    /// `legacyLink` reads nil.
    var holdsUnreadableLink: Bool {
        defaults.object(forKey: Keys.legacyLink) != nil && legacyLink == nil
    }

    /// F1's first look of the removal check (#64), for the migration only.
    var legacyGrantMissingSince: Date? {
        get { defaults.object(forKey: Keys.legacyGrantMissingSince) as? Date }
        set { defaults.set(newValue, forKey: Keys.legacyGrantMissingSince) }
    }

    /// Removes F1's link keys.
    func clearLegacyLink() {
        defaults.removeObject(forKey: Keys.legacyLink)
        defaults.removeObject(forKey: Keys.legacyGrantMissingSince)
    }

    var pending: PendingLink? {
        get { read(PendingLink.self, key: Keys.pending) }
        set { write(newValue, key: Keys.pending) }
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
