import Foundation
import WatchtowerSync

/// The demo replica for unsigned simulator builds: records pushed through
/// the transport exactly as the hub would publish them, so the hydrator and
/// every decode path run end to end. Sub-projects B and C extend it with
/// their slices.
///
/// Runs ONLY on the `.inMemoryDemo` transport kind, and only in DEBUG: the
/// `.cloudKit` kind starts empty and hydrates from the user's own zone (the
/// gate lives in `AppEnvironment.bootstrap`). Record names are fixed, so a
/// re-seed upserts instead of adding rows (ReplicaWiringTests pins the tally).
enum DemoSeed {
    static let macName = "Acme Mac"
    static let hubID = "demo-hub"
    static let ownerUser = "_demo-owner"

    /// The phone the demo replica is linked as.
    static let device = LinkedDevice(
        deviceID: "demo-device",
        name: "Demo iPhone",
        model: "iPhone",
        appVersion: "demo",
        scope: .private,
        userRecordName: ownerUser
    )

    static func load(into transport: any CloudSyncTransport, now: Date = Date()) async throws {
        try await transport.save(try records(now: now))
    }

    static func records(now: Date) throws -> [CloudRecord] {
        // A fresh heartbeat every launch: Settings demos an online Mac, which
        // turns offline if the app stays open past the 720 s threshold.
        let heartbeat = HeartbeatPayload(
            updatedAt: now,
            appVersion: "demo",
            hubID: hubID,
            macName: macName,
            flavor: .default,
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
        // Linked, typing not allowed yet: the Settings toggle demos
        // "Waiting for your Mac to confirm".
        let linkedAt = now.addingTimeInterval(-3_600)
        let grant = DeviceGrant(
            deviceID: device.deviceID,
            hubID: hubID,
            name: device.name,
            scope: device.scope,
            linked: true,
            linkedAt: linkedAt,
            typingAllowed: false,
            startSessionsAllowed: true,
            decidedAt: linkedAt
        )
        return [
            try CloudRecordFactory.record(for: heartbeat, modifiedAt: now),
            try CloudRecordFactory.record(for: grant, modifiedAt: now)
        ] + (try workbenchRecords(now: now)) + (try sessionDetailRecords(now: now)) + (try calendarRecords(now: now))
    }
}
