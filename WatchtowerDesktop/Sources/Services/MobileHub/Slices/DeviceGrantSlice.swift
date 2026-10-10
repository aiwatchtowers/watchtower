import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The `device_grant` slice (mobile POC spec §4.13), record name
/// `device_grant-<device id>`: the hub's answer to each phone that wrote a
/// `device` record, from the sidecar `MobileLinkCenter` keeps. A linked
/// phone (`devices`) reads `linked: true` with its grants; a refused link
/// attempt (`link_refusals`) reads `linked: false` with `link_refused` for
/// `refusalLifetime`. A removed phone has no record, so the publisher
/// deletes it. At most 20, the latest linked first, then the latest refused.
struct DeviceGrantSlice: SliceSource {
    let kind = SliceKind.deviceGrant

    static let maxRecords = 20
    /// The phone waits 60 s for its grant; a refusal is kept far longer.
    static let refusalLifetime: TimeInterval = 3600

    let sidecar: HubSyncState
    let hubID: String
    let now: @Sendable () -> Date
    private static let logger = Logger(subsystem: Constants.bundleID, category: "DeviceGrantSlice")

    init(sidecar: HubSyncState, hubID: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sidecar = sidecar
        self.hubID = hubID
        self.now = now
    }

    /// Reads the sidecar, not `db`: linking is the hub's own state.
    func records(_ db: Database) throws -> [SliceRecord] {
        do {
            try sidecar.pruneLinkRefusals(olderThan: now().addingTimeInterval(-Self.refusalLifetime))
        } catch {
            // Housekeeping only: the next tick prunes.
            Self.logger.warning("link refusal prune failed: \(error.localizedDescription, privacy: .public)")
        }
        let linked = try sidecar.linkedDevices().reversed().map { device in
            (device.decidedAt.map { max($0, device.linkedAt) } ?? device.linkedAt, DeviceGrant(
                deviceID: device.deviceID, hubID: hubID, name: device.name, scope: device.scope, linked: true,
                linkedAt: device.linkedAt, typingAllowed: device.typingAllowed,
                startSessionsAllowed: device.startSessionsAllowed, decidedAt: device.decidedAt
            ))
        }
        let linkedIDs = Set(linked.map(\.1.deviceID))
        let refused = try sidecar.linkRefusals().filter { !linkedIDs.contains($0.deviceID) }.map { refusal in
            (refusal.at, DeviceGrant(
                deviceID: refusal.deviceID, hubID: hubID, name: refusal.name, scope: refusal.scope, linked: false,
                linkRefused: refusal.reason, typingAllowed: false, startSessionsAllowed: true
            ))
        }
        let encoder = RelayCoder.makeEncoder()
        return try (linked + refused).prefix(Self.maxRecords).map { modifiedAt, grant in
            SliceRecord(kind: kind, id: grant.deviceID, modifiedAt: modifiedAt, payload: try encoder.encode(grant))
        }
    }
}
