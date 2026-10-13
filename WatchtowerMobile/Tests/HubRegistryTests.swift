import XCTest
@testable import WatchtowerMobile
import WatchtowerSync

final class HubRegistryTests: XCTestCase {
    private func link(_ hub: String, mac: String = "Acme Mac", scope: DeviceScope = .private) -> LinkRecord {
        LinkRecord(
            hubID: hub, macName: mac, scope: scope, ownerName: "_owner-acme", userRecordName: "_owner-acme",
            nonce: "nonce-\(hub)", dataShareURL: nil, relayShareURL: nil, deviceID: "device-acme-1", linkedAt: nil
        )
    }

    func testRowsKeepLinkOrderAndTheLimitRefusesAFifthHub() throws {
        let registry = try HubRegistry.inMemory()
        let now = Date(timeIntervalSince1970: 1_000)
        for hub in ["hub-a", "hub-b", "hub-c", "hub-d"] { try registry.upsert(link(hub), now: now) }
        XCTAssertEqual(try registry.rows().map(\.hubID), ["hub-a", "hub-b", "hub-c", "hub-d"])
        XCTAssertTrue(try registry.isFull(adding: "hub-e"))
        XCTAssertFalse(try registry.isFull(adding: "hub-b"), "re-linking a linked hub is not a fifth")
        XCTAssertThrowsError(try registry.upsert(link("hub-e"), now: now)) { XCTAssertEqual($0 as? HubRegistryError, .full) }
    }

    func testRelinkKeepsTheOrderAndClearsTheRemovedState() throws {
        let registry = try HubRegistry.inMemory()
        let now = Date(timeIntervalSince1970: 1_000)
        try registry.upsert(link("hub-a"), now: now)
        try registry.upsert(link("hub-b"), now: now)
        try registry.setState(.unlinkedByMac, for: "hub-a")
        try registry.setGrantMissingSince(now, for: "hub-a")
        try registry.upsert(link("hub-a", mac: "Acme Mac 2"), now: now)
        let row = try XCTUnwrap(registry.row("hub-a"))
        XCTAssertEqual(row.state, .linked)
        XCTAssertNil(row.grantMissingSince)
        XCTAssertEqual(row.link.macName, "Acme Mac 2")
        XCTAssertEqual(try registry.rows().map(\.hubID), ["hub-a", "hub-b"])
    }

    func testMoveRemoveAndActiveSurviveReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let now = Date(timeIntervalSince1970: 1_000)
        do {
            let registry = try HubRegistry(path: path)
            for hub in ["hub-a", "hub-b", "hub-c"] { try registry.upsert(link(hub), now: now) }
            try registry.move("hub-c", to: 0)
            try registry.setActive("hub-b")
            try registry.noteHeartbeat(flavor: "corp", at: now, for: "hub-b")
            try registry.remove("hub-a")
        }
        let reopened = try HubRegistry(path: path)
        XCTAssertEqual(try reopened.rows().map(\.hubID), ["hub-c", "hub-b"])
        XCTAssertEqual(try reopened.activeHubID, "hub-b")
        XCTAssertEqual(try reopened.row("hub-b")?.flavor, "corp")
        XCTAssertEqual(try reopened.row("hub-b")?.lastHeartbeatAt, now)
    }

    func testRemovingTheActiveHubClearsActive() throws {
        let registry = try HubRegistry.inMemory()
        try registry.upsert(link("hub-a"), now: Date())
        try registry.setActive("hub-a")
        try registry.remove("hub-a")
        XCTAssertNil(try registry.activeHubID)
    }

    func testSharedScopeRoundTrips() throws {
        let registry = try HubRegistry.inMemory()
        let shared = LinkRecord(
            hubID: "hub-home", macName: "Home Mac", scope: .shared, ownerName: "_owner-home", userRecordName: "_owner-acme",
            nonce: "n", dataShareURL: "https://example.com/d", relayShareURL: "https://example.com/r",
            deviceID: "device-acme-1", linkedAt: Date(timeIntervalSince1970: 5)
        )
        try registry.upsert(shared, now: Date())
        XCTAssertEqual(try registry.row("hub-home")?.link, shared)
        XCTAssertEqual(try registry.row("hub-home")?.link.databaseScope, .shared(ownerName: "_owner-home"))
    }

    func testDuplicateMacNamesGetAHubSuffix() {
        let now = Date()
        func row(_ hub: String, _ mac: String, _ order: Int) -> HubRow {
            HubRow(
                link: link(hub, mac: mac), flavor: nil, sortOrder: order, state: .linked,
                grantMissingSince: nil, lastHeartbeatAt: nil, linkedOn: now
            )
        }
        let rows = [row("a1b2c3d4-x", "MacBook Pro", 0), row("e5f6a7b8-y", "MacBook Pro", 1), row("hub-home", "Home Mac", 2)]
        XCTAssertEqual(HubDisplayName.names(for: rows), [
            "a1b2c3d4-x": "MacBook Pro · a1b2",
            "e5f6a7b8-y": "MacBook Pro · e5f6",
            "hub-home": "Home Mac"
        ])
    }

    func testPathsAreHubScoped() {
        let paths = HubPaths(
            groupDirectory: URL(fileURLWithPath: "/g"),
            localDirectory: URL(fileURLWithPath: "/l"),
            recordingsBase: URL(fileURLWithPath: "/r")
        )
        XCTAssertEqual(paths.replicaPath("hub-a"), "/g/hubs/hub-a/replica.sqlite")
        XCTAssertEqual(paths.transportStorePath("hub-a"), "/l/hubs/hub-a/cloudkit-transport.sqlite")
        XCTAssertEqual(paths.recordingsDirectory("hub-a").path, "/r/hubs/hub-a")
        XCTAssertEqual(paths.holdDirectory.path, "/r/.held")
        XCTAssertEqual(paths.registryPath, "/l/hubs.sqlite")
    }

    func testRemoveHubFilesDeletesAllThreeDirectoriesAndOrphansAreSeenInEither() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let paths = HubPaths(
            groupDirectory: base.appendingPathComponent("g"),
            localDirectory: base.appendingPathComponent("l"),
            recordingsBase: base.appendingPathComponent("r")
        )
        try paths.prepare("hub-a")
        try FileManager.default.createDirectory(at: paths.localHubDirectory("hub-b"), withIntermediateDirectories: true)
        XCTAssertEqual(Set(try paths.hubIDsOnDisk()), ["hub-a", "hub-b"])
        try paths.removeHubFiles("hub-a")
        for directory in [paths.hubDirectory("hub-a"), paths.localHubDirectory("hub-a"), paths.recordingsDirectory("hub-a")] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), directory.lastPathComponent)
        }
    }

    /// Ruling 1: a hub id is a path component of the hub's files, which a
    /// removal deletes recursively: only a plain name is one.
    func testOnlyAPlainNameIsAHubID() {
        for valid in ["hub-acme", "hub-1234", "hub_home.2"] {
            XCTAssertTrue(HubPaths.isValidHubID(valid), valid)
        }
        for invalid in ["", ".", "..", ".hidden", "../hub-acme", "hub/acme", "hub\\acme", "hub\u{0}acme", "/"] {
            XCTAssertFalse(HubPaths.isValidHubID(invalid), invalid.debugDescription)
        }
    }
}
