import Foundation
import WatchtowerSync

/// The demo replica for unsigned simulator builds and the signed build's
/// demo (`AppRoot.tour`, Welcome's Try the Demo): records pushed through
/// the transport exactly as the hub would publish them, so the hydrator and
/// every decode path run end to end. Sub-projects B and C extend it with
/// their slices.
///
/// Runs ONLY on the `.inMemoryDemo` backend: the `.live` backend
/// starts empty and hydrates from the user's own zone (the gate lives in
/// `HubSession.startTransport`). Record names are fixed, so a
/// re-seed upserts instead of adding rows (ReplicaWiringTests pins the tally).
enum DemoSeed {
    /// One demo Mac: the identity its heartbeat and grant carry. The demo
    /// shows two (multi-hub spec §7), each on its own in-memory transport
    /// with its own content.
    struct Hub: Equatable {
        let hubID: String
        let macName: String
        let flavor: HubFlavor
    }

    /// The Mac with the full demo (today's seed): Workbench, sessions,
    /// calendar and the phone recording.
    static let primary = Hub(hubID: "demo-hub", macName: "Acme Mac", flavor: .default)
    /// The second Mac: one workbench, three targets, one open ask, no
    /// calendar.
    static let secondary = Hub(hubID: "demo-hub-home", macName: "Home Mac", flavor: .default)
    static let hubs = [primary, secondary]

    static let macName = primary.macName
    static let hubID = primary.hubID
    static let ownerUser = "_demo-owner"

    /// The phone the demo replica is linked as: its id is the demo
    /// pairing's device id (`DemoSeed+E2E`).
    static let device = LinkedDevice(
        deviceID: DemoPairing.phoneIdentity.deviceID.uuidString,
        name: "Demo iPhone",
        model: "iPhone",
        appVersion: "demo",
        scope: .private,
        userRecordName: ownerUser
    )

    static func hub(id: String) -> Hub? {
        hubs.first { $0.hubID == id }
    }

    /// The registry row a demo hub shows as: linked through the demo
    /// device, in the private scope.
    static func link(for hub: Hub, now: Date) -> LinkRecord {
        LinkRecord(
            hubID: hub.hubID,
            macName: hub.macName,
            scope: .private,
            ownerName: ownerUser,
            userRecordName: ownerUser,
            nonce: "demo",
            dataShareURL: nil,
            relayShareURL: nil,
            deviceID: device.deviceID,
            linkedAt: now
        )
    }

    static func load(into transport: any CloudSyncTransport, hub: Hub = primary, now: Date = Date()) async throws {
        try await transport.save(try records(now: now, hub: hub))
    }

    static func records(now: Date, hub: Hub = primary) throws -> [CloudRecord] {
        let hubID = hub.hubID
        let macName = hub.macName
        // A fresh heartbeat every launch: Settings demos an online Mac, which
        // turns offline if the app stays open past the 2100 s threshold.
        let heartbeat = HeartbeatPayload(
            updatedAt: now,
            appVersion: "demo",
            hubID: hubID,
            macName: macName,
            flavor: hub.flavor,
            lastPublishAt: now,
            lastRelayAt: now,
            relayBacklog: 0,
            accounts: [
                HeartbeatAccount(kind: .slack, label: "acme", status: "ok"),
                HeartbeatAccount(kind: .google, label: "me@example.com", status: "ok"),
                HeartbeatAccount(kind: .jira, label: "Acme Jira", status: "error")
            ],
            enabledAt: now.addingTimeInterval(-86_400),
            ownerUser: ownerUser,
            sharing: .none
        )
        // Linked, typing allowed: with the phone's toggle on, the workchat
        // shows its composer.
        let linkedAt = now.addingTimeInterval(-3_600)
        let grant = DeviceGrant(
            deviceID: device.deviceID,
            hubID: hubID,
            name: device.name,
            scope: device.scope,
            linked: true,
            linkedAt: linkedAt,
            typingAllowed: true,
            startSessionsAllowed: true,
            decidedAt: linkedAt
        )
        let common = [
            try CloudRecordFactory.record(for: heartbeat, modifiedAt: now),
            try keyboxRecord(for: grant, modifiedAt: now)
        ]
        guard hub.hubID == primary.hubID else { return common + (try secondaryWorkbenchRecords(now: now)) }
        return common
            + (try workbenchRecords(now: now))
            + (try sessionDetailRecords(now: now))
            + (try sessionChatRecords(now: now))
            + (try calendarRecords(now: now))
    }
}

// MARK: - Linking over Relay (relay client Phase 3 Task 10)

extension DemoSeed {
    /// The relay link states the tour shows (mockup section 7): a confirmed link still finishing to "build-box",
    /// and the relay ids of the Macs in the demo account's slots. Never written to a live phone's store.
    enum Relay {
        static let finishingHubID = "demo-hub-build"
        static let finishingName = "build-box"
        /// The demo Macs' relay device ids: 52 characters a–z2–7, made up.
        static let finishingMac = String(repeating: "b", count: 52)
        static let workMac = String(repeating: "w", count: 52)
        static let unknownMac = String(repeating: "u", count: 52)

        /// The finishing link in `state`.
        static func finishingLink(_ state: PromotedLink.State, now: Date) -> PromotedLink {
            var record = LinkRecord(
                hubID: finishingHubID, macName: finishingName, scope: .private, ownerName: "", userRecordName: "",
                nonce: "demo", dataShareURL: nil, relayShareURL: nil, deviceID: device.deviceID, linkedAt: now
            )
            record.setRelay(mac: finishingMac)
            // Made-up key bytes: the demo's vouch is never sent.
            record.relayAuthPub = WireBytes.base64URL(Data(repeating: 0x42, count: 32))
            return PromotedLink(link: record, slot: "demo-slot", slotExpiresAt: now.addingTimeInterval(600), state: state, since: now)
        }

        /// "Work Mac" linked on this iPhone over Relay.
        static func workLink(now: Date) -> LinkRecord {
            var record = LinkRecord(
                hubID: "demo-hub-work", macName: "Work Mac", scope: .private, ownerName: "", userRecordName: "", nonce: "demo",
                dataShareURL: nil, relayShareURL: nil, deviceID: device.deviceID, linkedAt: now
            )
            record.setRelay(mac: workMac)
            return record
        }
    }
}
