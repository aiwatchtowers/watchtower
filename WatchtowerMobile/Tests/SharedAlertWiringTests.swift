import UserNotifications
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Work alerts on a phone on another Apple ID (ask #622): a shared-scope hub has no query subscription (D14), so
/// after each fetch the phone opens the `ask_alert` records it has not shown with `AlertOpener` and posts a local
/// notification for each, once. Never the real notification center or CloudKit: the poster is a fake.
@MainActor
final class SharedAlertWiringTests: XCTestCase {
    @MainActor
    private final class Posted {
        var requests: [UNNotificationRequest] = []
        var posting: LocalAlertPosting { LocalAlertPosting { self.requests.append($0) } }
    }

    private let hubID = TestE2E.hubID.uuidString
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func payload(_ key: String, ask: Int64? = nil, session: Int64? = 7) -> WorkAlertPayload {
        WorkAlertPayload(
            event: ask == nil ? .sessionStopped : .ask, key: key, workbenchID: 3, workbenchName: "Acme", sessionID: session,
            askID: ask, requestID: nil, title: "Acme · Lane totals", body: ask == nil ? "Waiting for you" : "Which wording?",
            quick: false)
    }

    private func alertRecord(id: String, payload: Data) -> CloudRecord {
        CloudRecord(
            recordName: SliceKind.askAlert.recordName(id: id), zone: .data, kind: SliceKind.askAlert.rawValue,
            modifiedAt: stamp, payload: payload)
    }

    /// The Mac publishes `payload` as its sealed `ask_alert` (under `K_alert`) into `transport`.
    private func publish(_ payload: WorkAlertPayload, id: String, into transport: InMemoryCloudTransport) async throws {
        try await TestPhone.hub(over: transport).save([alertRecord(id: id, payload: try JSONEncoder().encode(payload))])
    }

    private func session(
        transport: InMemoryCloudTransport,
        route: HubRoute,
        posted: Posted,
        replicaPath: String? = nil,
        defaults: UserDefaults? = nil
    ) throws -> HubSession {
        let session = try HubSession(
            transport: transport,
            replicaPath: try replicaPath ?? makeReplicaPath(),
            backend: .live,
            hubID: hubID,
            keys: try TestPhone.keys(),
            defaults: try defaults ?? makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            route: route,
            alertPosting: posted.posting,
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) } // swiftlint:disable:this trailing_closure
        )
        closeAtTeardown(session)
        return session
    }

    /// The phone-wide switch lives in the app group's suite: a test that turns it off turns it back on.
    private func keepWorkAlerts(_ settings: DeviceSettings) {
        let before = settings.workAlerts
        addTeardownBlock { @MainActor in settings.workAlerts = before }
    }

    func testTheFirstFetchOfASharedHubIsSilent() async throws {
        let transport = InMemoryCloudTransport()
        try await publish(payload("ask-41", ask: 41), id: "41", into: transport)
        try await publish(payload("stop-7-1700000000000"), id: "stop-7", into: transport)
        let (posted, defaults) = (Posted(), try makeDefaults())
        let env = try session(transport: transport, route: .cloudKit(.shared(ownerName: "_owner")), posted: posted, defaults: defaults)
        keepWorkAlerts(env.deviceSettings)
        env.deviceSettings.workAlerts = true

        _ = await env.refresh(.pull)
        _ = await env.refresh(.pull)
        XCTAssertTrue(posted.requests.isEmpty, "what the Mac kept before the first fetch is history, not news")
        let seen = try XCTUnwrap(defaults.dictionary(forKey: SharedAlertPoster.postedDefaultsKey(hubID: hubID)) as? [String: String])
        XCTAssertEqual(Set(seen.values), ["ask-41", "stop-7-1700000000000"], "both count as seen")
    }

    func testASharedHubPostsEachNewAlertOnce() async throws {
        let transport = InMemoryCloudTransport()
        try await publish(payload("ask-41", ask: 41), id: "41", into: transport)
        let posted = Posted()
        let env = try session(transport: transport, route: .cloudKit(.shared(ownerName: "_owner")), posted: posted)
        keepWorkAlerts(env.deviceSettings)
        env.deviceSettings.workAlerts = true

        _ = await env.refresh(.pull)
        XCTAssertTrue(posted.requests.isEmpty, "the first fetch is silent")
        try await publish(payload("ask-42", ask: 42), id: "42", into: transport)
        _ = await env.refresh(.pull)
        XCTAssertEqual(posted.requests.map(\.identifier), [SharedAlertPoster.identifier(hubID: hubID, key: "ask-42")])
        let content = try XCTUnwrap(posted.requests.first?.content)
        let expected = WorkAlertContent(payload: payload("ask-42", ask: 42), hubID: hubID)
        XCTAssertEqual(content.title, expected.title)
        XCTAssertEqual(content.body, expected.body)
        XCTAssertEqual(content.threadIdentifier, expected.threadID)
        XCTAssertEqual(content.userInfo as? [String: String], expected.userInfo)
        XCTAssertEqual(
            AlertDestination.destination(userInfo: content.userInfo), .ask(hubID: hubID, askID: 42), "a tap routes as a push's")

        _ = await env.refresh(.pull)
        XCTAssertEqual(posted.requests.count, 1, "a second fetch with the same record posts nothing")

        try await publish(payload("stop-7-1700000000000"), id: "stop-7", into: transport)
        _ = await env.refresh(.push)
        XCTAssertEqual(posted.requests.map(\.identifier).last, SharedAlertPoster.identifier(hubID: hubID, key: "stop-7-1700000000000"))
        XCTAssertEqual(posted.requests.count, 2)
    }

    func testARelaunchDoesNotPostAgainAndAGoneRecordIsForgotten() async throws {
        let transport = InMemoryCloudTransport()
        let (path, defaults) = (try makeReplicaPath(), try makeDefaults())
        let first = Posted()
        let before = try session(
            transport: transport, route: .cloudKit(.shared(ownerName: "_owner")), posted: first, replicaPath: path, defaults: defaults
        )
        keepWorkAlerts(before.deviceSettings)
        before.deviceSettings.workAlerts = true
        _ = await before.refresh(.pull)
        try await publish(payload("ask-42", ask: 42), id: "42", into: transport)
        _ = await before.refresh(.pull)
        XCTAssertEqual(first.requests.count, 1)
        await before.shutDown()
        before.closeDatabases()

        let second = Posted()
        let after = try session(
            transport: transport, route: .cloudKit(.shared(ownerName: "_owner")), posted: second, replicaPath: path, defaults: defaults
        )
        _ = await after.refresh(.pull)
        XCTAssertTrue(second.requests.isEmpty, "a relaunch never posts an alert again")

        let wire = try XCTUnwrap(try after.store.alertEnvelopes().first?.wireName)
        try await transport.delete(recordNames: [wire], in: .data)
        _ = await after.refresh(.pull)
        XCTAssertEqual(defaults.dictionary(forKey: SharedAlertPoster.postedDefaultsKey(hubID: hubID))?.count, 0, "a gone record's entry is dropped")
    }

    func testTheSwitchOffPostsNothing() async throws {
        let transport = InMemoryCloudTransport()
        try await publish(payload("ask-42", ask: 42), id: "42", into: transport)
        let posted = Posted()
        let env = try session(transport: transport, route: .cloudKit(.shared(ownerName: "_owner")), posted: posted)
        keepWorkAlerts(env.deviceSettings)
        env.deviceSettings.workAlerts = false

        _ = await env.refresh(.pull)
        env.deviceSettings.workAlerts = true
        _ = await env.refresh(.pull)
        XCTAssertTrue(posted.requests.isEmpty, "off posts nothing, and turning it on does not post what came while off")
    }

    func testAPrivateHubPostsNothingLocally() async throws {
        let transport = InMemoryCloudTransport()
        try await publish(payload("ask-42", ask: 42), id: "42", into: transport)
        let posted = Posted()
        let env = try session(transport: transport, route: .cloudKit(.private), posted: posted)
        keepWorkAlerts(env.deviceSettings)
        env.deviceSettings.workAlerts = true

        _ = await env.refresh(.pull)
        XCTAssertEqual(try env.store.alertEnvelopes().count, 1, "the alert is there")
        XCTAssertTrue(posted.requests.isEmpty, "the push subscription covers a private hub")
    }

    func testAnAlertThatDoesNotOpenIsSkipped() async throws {
        let transport = InMemoryCloudTransport()
        let posted = Posted()
        let env = try session(transport: transport, route: .cloudKit(.shared(ownerName: "_owner")), posted: posted)
        keepWorkAlerts(env.deviceSettings)
        env.deviceSettings.workAlerts = true
        _ = await env.refresh(.pull)

        // An old ask-shaped payload (no `event`) does not decode.
        try await TestPhone.hub(over: transport).save([alertRecord(id: "41", payload: Data("{\"id\":41}".utf8))])
        try await publish(payload("ask-42", ask: 42), id: "42", into: transport)
        _ = await env.refresh(.pull)
        XCTAssertEqual(posted.requests.map(\.identifier), [SharedAlertPoster.identifier(hubID: hubID, key: "ask-42")])
    }
}
