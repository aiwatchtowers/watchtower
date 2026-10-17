import Foundation
import GRDB
import WatchtowerSync

/// The `device_grant` slice (mobile POC spec §4.13), record name
/// `device_grant-<device id>`: the hub's answer to each phone that wrote a
/// `device` record, from the sidecar `MobileLinkCenter` keeps. A linked
/// phone (`devices`) reads `linked: true` with its grants; a refused link
/// attempt (`link_refusals`) reads `linked: false` with `link_refused` for
/// `refusalLifetime`. A removed phone has no record, so the publisher
/// deletes it — and the phone reads that deletion as its removal (#64), so
/// every linked phone's keybox is published, never capped: the pending
/// requests, refusals and revoked phones fill the room left under 20, in
/// that order, the latest first.
///
/// Mobile E2E (spec §2.3, D7): the payload is a `Keybox` carrying the grant,
/// which the hub's `SecureTransport` seals to the phone's agreement key under
/// the key-free name `keybox-<device id>` and signs with `hub_sig`. A phone
/// linked with keys (its hello confirmed on the Mac) gets the current epoch's
/// keys and `K_meta`; a pending request (`pending_devices`) reads
/// `awaitingConfirmation: true` with no keys, the hub's `confirmNonce` and
/// the `linkCodeTag` of the code it was made with (SAS v2, sealed to that
/// phone only); a refusal has no keys. Keys are
/// never wrapped for a device that is not linked. A phone removed on the Mac
/// or unlinked by itself (`revoked_devices`, D9) reads `linked: false,
/// revoked: true` without keys for `revokedLifetime`, sealed to its own key,
/// then its record is deleted. Precedence: linked, pending, refused (only a
/// newer attempt than the removal, which cleared the old refusal), revoked.
/// The plain name uses the uppercase `uuidString` form (F30), the form the
/// transport and the phone use.
struct DeviceGrantSlice: SliceSource {
    let kind = SliceKind.deviceGrant

    static let maxRecords = 20
    /// The phone waits 60 s for its grant; a refusal is kept far longer.
    static let refusalLifetime: TimeInterval = 3600
    /// D9: a removed phone is told for 7 days.
    static let revokedLifetime: TimeInterval = 7 * 86_400

    let sidecar: HubSyncState
    let hubID: String
    /// The epoch keys a linked phone's keybox carries; nil: no keys in any keybox (a hub without E2E keys publishes
    /// nothing anyway).
    let keyring: HubKeyring?
    let now: @Sendable () -> Date

    init(sidecar: HubSyncState, hubID: String, keyring: HubKeyring? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sidecar = sidecar
        self.hubID = hubID
        self.keyring = keyring
        self.now = now
    }

    /// Reads the sidecar, not `db`: linking is the hub's own state. Reads only: an expired refusal or revoked
    /// phone is filtered out here and pruned by `MobileLinkCenter.pruneExpiredAnswers`.
    func records(_ db: Database) throws -> [SliceRecord] {
        // Only a phone linked through a confirmed hello has keys stored, and only its keybox carries the epoch keys.
        let keyed = Set(try sidecar.deviceKeyRows().map { $0.deviceID.uppercased() })
        let keys = try keyed.isEmpty ? nil : keyring?.keyboxKeys()
        let linked = try sidecar.linkedDevices().reversed().map { device in
            (device.decidedAt.map { max($0, device.linkedAt) } ?? device.linkedAt, Keybox(grant: DeviceGrant(
                deviceID: device.deviceID, hubID: hubID, name: device.name, scope: device.scope, linked: true,
                linkedAt: device.linkedAt, typingAllowed: device.typingAllowed,
                startSessionsAllowed: device.startSessionsAllowed, permissionsAllowed: device.permissionsAllowed,
                decidedAt: device.decidedAt
            ), keys: keyed.contains(device.deviceID.uppercased()) ? keys : nil))
        }
        var answered = Set(linked.map { $0.1.grant.deviceID.uppercased() })
        let pending = try sidecar.pendingDevices().reversed().filter { !answered.contains($0.deviceID.uppercased()) }.map { request in
            (request.receivedAt, Keybox(grant: DeviceGrant(
                deviceID: request.deviceID, hubID: hubID, name: request.name, scope: request.scope, linked: false,
                typingAllowed: false, startSessionsAllowed: true, permissionsAllowed: false, awaitingConfirmation: true,
                confirmNonce: WireBytes.base64URL(request.confirmNonce),
                linkCodeTag: WireBytes.fromBase64URL(request.linkNonce).map { KeyDerivation.linkCodeTag(linkNonce: $0) }
            ), keys: nil))
        }
        answered.formUnion(pending.map { $0.1.grant.deviceID.uppercased() })
        let refusedSince = now().addingTimeInterval(-Self.refusalLifetime)
        let unexpired = try sidecar.linkRefusals().filter { $0.at >= refusedSince && !answered.contains($0.deviceID.uppercased()) }
        let refused = unexpired.map { refusal in
            (refusal.at, Keybox(grant: DeviceGrant(
                deviceID: refusal.deviceID, hubID: hubID, name: refusal.name, scope: refusal.scope, linked: false,
                // The refusal's time: a second identical refusal still
                // differs, so the phone reads it as an answer.
                linkRefused: refusal.reason, typingAllowed: false, startSessionsAllowed: true,
                permissionsAllowed: false, decidedAt: refusal.at
            ), keys: nil))
        }
        answered.formUnion(refused.map { $0.1.grant.deviceID.uppercased() })
        let revokedSince = now().addingTimeInterval(-Self.revokedLifetime)
        let current = try sidecar.revokedDevices().filter {
            $0.removedAt > revokedSince && !answered.contains($0.deviceID.uppercased())
        }
        let revoked = current.map { device in
            (device.removedAt, Keybox(grant: DeviceGrant(
                deviceID: device.deviceID, hubID: hubID, name: device.name, scope: device.scope, linked: false,
                typingAllowed: false, startSessionsAllowed: true, permissionsAllowed: false,
                decidedAt: device.removedAt, revoked: true
            ), keys: nil))
        }
        let encoder = RelayCoder.makeEncoder()
        let room = max(0, Self.maxRecords - linked.count)
        return try (linked + (pending + refused + revoked).prefix(room)).map { modifiedAt, keybox in
            SliceRecord(
                kind: kind, id: UUID(uuidString: keybox.grant.deviceID)?.uuidString ?? keybox.grant.deviceID,
                modifiedAt: modifiedAt, payload: try encoder.encode(keybox)
            )
        }
    }
}
