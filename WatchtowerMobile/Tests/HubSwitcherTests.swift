import Foundation
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Mac switcher (multi-hub spec §5.6): the list's items (name with a
/// duplicate suffix, flavor, the online dot by the phone's 2100 s rule, days
/// offline, Forget for long-offline and removed hubs, each hub's fetch
/// problem and open asks), the chip's other-hubs total, and a switch that
/// resets navigation to the root.
@MainActor
final class HubSwitcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let device = LinkedDevice(
        deviceID: TestPhone.deviceID(),
        name: "Acme iPhone",
        model: "iPhone",
        appVersion: "1.0",
        scope: .private,
        userRecordName: "_owner-acme"
    )

    private func row(
        _ hub: String,
        mac: String = "Acme Mac",
        order: Int = 0,
        flavor: String? = nil,
        state: HubRow.State = .linked,
        heartbeat: Date? = nil,
        linkedOn: Date? = nil
    ) -> HubRow {
        HubRow(
            link: LinkRecord(
                hubID: hub, macName: mac, scope: .private, ownerName: "_owner-acme", userRecordName: "_owner-acme",
                nonce: "nonce-\(hub)", dataShareURL: nil, relayShareURL: nil, deviceID: TestPhone.deviceID(), linkedAt: nil
            ),
            flavor: flavor, sortOrder: order, state: state, grantMissingSince: nil,
            lastHeartbeatAt: heartbeat, linkedOn: linkedOn ?? now.addingTimeInterval(-30 * 86_400)
        )
    }

    // MARK: - The items

    func testOnlineAndOfflineDaysFollowTheHeartbeatAndForgetIsOfferedForLongOfflineAndRemovedHubs() {
        let rows = [
            row(TestHub.acme, order: 0, heartbeat: now.addingTimeInterval(-600)),
            row(TestHub.home, mac: "Home Mac", order: 1, heartbeat: now.addingTimeInterval(-8 * 86_400)),
            row(TestHub.lab, mac: "Lab Mac", order: 2, state: .unlinkedByMac, heartbeat: now.addingTimeInterval(-60)),
            row(TestHub.fresh, mac: "New Mac", order: 3, linkedOn: now.addingTimeInterval(-2 * 86_400))
        ]

        let items = HubListModel.items(rows: rows, sessions: [:], activeHubID: TestHub.acme, now: now)

        XCTAssertEqual(items.map(\.id), [TestHub.acme, TestHub.home, TestHub.lab, TestHub.fresh], "registry order")
        XCTAssertTrue(items[0].online)
        XCTAssertNil(items[0].offlineDays)
        XCTAssertFalse(items[1].online)
        XCTAssertEqual(items[1].offlineDays, 8)
        XCTAssertEqual(items[3].offlineDays, 2, "never a heartbeat: counted from the link")
        XCTAssertEqual(items.map(\.canForget), [false, true, true, false])
        XCTAssertEqual(items.map(\.removedByMac), [false, false, true, false])
        XCTAssertEqual(items.map(\.isActive), [true, false, false, false])
        XCTAssertEqual(items.map(\.statusText), ["Online", "Offline 8 days", "Removed this phone", "Offline 2 days"])
    }

    func testTheOnlineDotFollowsThePhones2100SecondRule() {
        let rows = [
            row(TestHub.acme, order: 0, heartbeat: now.addingTimeInterval(-2099)),
            row(TestHub.home, mac: "Home Mac", order: 1, heartbeat: now.addingTimeInterval(-2100))
        ]

        let items = HubListModel.items(rows: rows, sessions: [:], activeHubID: TestHub.acme, now: now)

        XCTAssertEqual(items.map(\.online), [true, false])
        XCTAssertEqual(items[1].offlineDays, 0)
        XCTAssertEqual(items[1].statusText, "Offline")
    }

    func testDuplicateNamesGetTheHubIDSuffix() {
        let rows = [
            row("a1b2c3d4-x", mac: "Acme Mac", order: 0),
            row("e5f6a7b8-y", mac: "Acme Mac", order: 1),
            row(TestHub.home, mac: "Home Mac", order: 2)
        ]

        let items = HubListModel.items(rows: rows, sessions: [:], activeHubID: nil, now: now)

        XCTAssertEqual(items.map(\.name), ["Acme Mac · a1b2", "Acme Mac · e5f6", "Home Mac"])
    }

    func testTheFlavorShowsOnlyWhenItIsNotDefault() {
        let rows = [
            row(TestHub.acme, order: 0, flavor: "default"),
            row(TestHub.home, mac: "Home Mac", order: 1, flavor: "corp"),
            row(TestHub.lab, mac: "Lab Mac", order: 2)
        ]

        let items = HubListModel.items(rows: rows, sessions: [:], activeHubID: nil, now: now)

        XCTAssertEqual(items.map(\.flavor), [nil, "corp", nil])
    }

    /// §6.3: a hub whose last fetch failed shows why on its row; the other
    /// row has no problem.
    func testAFailedFetchIsTheRowsProblem() async throws {
        let base = try makeBase()
        let remote = RemoteFetchRecorder()
        let hubA = try makeSession(TestHub.acme, base: base)
        let hubB = try makeSession(TestHub.home, base: base, remote: remote)
        let env = try makeEnvironment([hubA, hubB])
        try await bootAll(env)
        remote.failing = true
        _ = await env.refreshAll(.pull)
        let rows = [row(TestHub.acme, order: 0), row(TestHub.home, mac: "Home Mac", order: 1)]

        let items = HubListModel.items(rows: rows, sessions: env.sessions, activeHubID: env.activeHubID, now: now)

        XCTAssertNil(items[0].problem)
        XCTAssertEqual(items[1].problem, hubB.lastFetchError)
        XCTAssertNotNil(items[1].problem)
    }

    /// Each row counts its own hub's open asks; the chip counts the others'.
    func testOpenAsksAreCountedPerHub() async throws {
        let base = try makeBase()
        let transportA = InMemoryCloudTransport()
        let transportB = InMemoryCloudTransport()
        try await TestHub.hub(over: transportA, TestHub.acme).save([try openAsk(11)])
        try await TestHub.hub(over: transportB, TestHub.home).save([try openAsk(21), try openAsk(22)])
        let hubA = try makeSession(TestHub.acme, base: base, transport: transportA)
        let hubB = try makeSession(TestHub.home, base: base, transport: transportB)
        let env = try makeEnvironment([hubA, hubB])
        try await bootAll(env)
        try await poll({ env.openAskTotal == 3 }, "the asks never hydrated")
        let rows = [row(TestHub.acme, order: 0), row(TestHub.home, mac: "Home Mac", order: 1)]

        let items = HubListModel.items(rows: rows, sessions: env.sessions, activeHubID: TestHub.acme, now: now)

        XCTAssertEqual(items.map(\.openAsks), [1, 2])
        XCTAssertEqual(HubListModel.otherHubsOpenAsks(items), 2)
        XCTAssertEqual(
            HubListModel.chipAccessibilityLabel(name: "Acme Mac", otherAsks: 2),
            "Acme Mac, Mac. 2 asks waiting on other Macs"
        )
        XCTAssertEqual(HubListModel.chipAccessibilityLabel(name: "Acme Mac", otherAsks: 0), "Acme Mac, Mac")
    }

    func testAddMacIsRefusedAtTheLimit() {
        let three = (0 ..< 3).map { row("hub-\($0)", mac: "Mac \($0)", order: $0) }
        let four = (0 ..< 4).map { row("hub-\($0)", mac: "Mac \($0)", order: $0) }

        XCTAssertTrue(HubListModel.canAddMac(rows: three))
        XCTAssertFalse(HubListModel.canAddMac(rows: four))
    }

    // MARK: - The switch

    /// A switch from the list resets navigation to the root: the Calendar
    /// stack empties, the tab stays.
    func testActivatingAnotherHubResetsNavigationToTheRoot() throws {
        let base = try makeBase()
        let hubA = try makeSession(TestHub.acme, base: base)
        let hubB = try makeSession(TestHub.home, base: base)
        let env = try makeEnvironment([hubA, hubB])
        env.navigation.tab = .calendar
        env.navigation.calendarPath = [.recordings, .recap(7)]

        env.activate(TestHub.home)

        XCTAssertEqual(env.activeHubID, TestHub.home)
        XCTAssertEqual(env.navigation.calendarPath, [])
        XCTAssertEqual(env.navigation.tab, .calendar, "the tab is kept")
    }

    // MARK: - Helpers

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hub-switcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    /// A cloudKit-kind session on `hubID`'s files over an in-memory
    /// transport, whose safety poll waits for good.
    private func makeSession(
        _ hubID: String,
        base: URL,
        transport: InMemoryCloudTransport = InMemoryCloudTransport(),
        remote: RemoteFetchRecorder? = nil
    ) throws -> HubSession {
        let paths = HubPaths(
            groupDirectory: base.appendingPathComponent("g"),
            localDirectory: base.appendingPathComponent("l"),
            recordingsBase: base.appendingPathComponent("r")
        )
        try paths.prepare(hubID)
        let engine = FakeAudioEngine()
        let recorderClock = FakeClock()
        let remoteFetch: (@Sendable (RemoteFetchDepth) async throws -> Void)? = remote.map { remote in
            { try await remote.fetch($0) }
        }
        let sleep: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
        let session = try HubSession(
            transport: transport,
            replicaPath: paths.replicaPath(hubID),
            transportKind: .cloudKit,
            hubID: hubID,
            linkedDevice: device,
            // The test hub's keys whatever the hub id: tests seal through the test hub.
            keys: try TestHub.keys(hubID),
            defaults: try makeDefaults(),
            recordingsDirectory: paths.recordingsDirectory(hubID),
            hold: RecordingHold(directory: paths.holdDirectory),
            makeRecorder: { uploader in
                PhoneRecorderController(
                    uploader: uploader, engine: engine, notificationCenter: NotificationCenter(),
                    now: { recorderClock.now }, tickInterval: nil
                )
            },
            remoteFetch: remoteFetch,
            sleep: sleep
        )
        addTeardownBlock { @MainActor in session.stop() }
        return session
    }

    private func makeEnvironment(_ sessions: [HubSession]) throws -> AppEnvironment {
        let env = AppEnvironment(transportKind: .cloudKit, defaults: try makeDefaults()) { _ in }
        for session in sessions {
            env.add(session)
        }
        if let first = sessions.first {
            env.activate(first.hubID)
        }
        return env
    }

    private func bootAll(_ env: AppEnvironment) async throws {
        await env.waitForBoot()
        try await poll({ env.sessions.values.allSatisfy(\.isLooping) }, "a session did not start its safety poll")
    }

    private func openAsk(_ id: Int64) throws -> CloudRecord {
        try DemoSeed.record(kind: .ownerAsk, id: id, json: DemoSeed.JSON.ask(id, workbench: 1), modifiedAt: Date())
    }
}
