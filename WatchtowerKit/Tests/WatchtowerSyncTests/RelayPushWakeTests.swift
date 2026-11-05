import XCTest
@testable import WatchtowerSync

final class RelayPushWakeTests: XCTestCase {
    private let wake = RelayPushWake()

    private struct Case: Decodable { var envelope: String }
    private struct File: Decodable { var cases: [String: Case] }

    private static let sealedURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerSyncTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerKit
        .deletingLastPathComponent() // repo
        .appendingPathComponent("internal/hub/secure/testdata/go-sealed.json")

    private func sealed(_ name: String) throws -> Data {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.sealedURL))
        return Data(hex: try XCTUnwrap(file.cases[name]).envelope)
    }

    /// The relay's alert body (`worker/src/push/apns.ts`) as APNs delivers it to the app.
    private func alertBody(e: Any) throws -> [AnyHashable: Any] {
        var object: [String: Any] = ["aps": ["mutable-content": 1, "alert": ["title": "Watchtower"]]]
        object["e"] = e
        let data = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
    }

    private func alertBody(_ envelope: Data) throws -> [AnyHashable: Any] {
        try alertBody(e: envelope.base64EncodedString())
    }

    func testASilentBodyIsARelayOrigin() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"aps":{"content-available":1}}"#.utf8)) as? [AnyHashable: Any])
        XCTAssertEqual(wake.origin(ofRemoteNotification: body), .hostedRelay)
        XCTAssertNil(wake.alertSource(for: body))
    }

    func testAnAlertBodyIsAnInlineSource() throws {
        let envelope = try sealed("alertPush")
        let body = try alertBody(envelope)
        XCTAssertNil(wake.origin(ofRemoteNotification: body), "an alert push is no silent wake")
        XCTAssertEqual(wake.alertSource(for: body), .inline(hubID: E2EFixtureKeys.hubIDString, envelope: envelope))
    }

    func testTheHubIDKeysTheAlertMaterial() throws {
        guard case .inline(let hubID, _) = try XCTUnwrap(wake.alertSource(for: alertBody(sealed("alertPush")))) else {
            return XCTFail("expected an inline source")
        }
        XCTAssertEqual(hubID, hubID.uppercased())
        let backend = FakeKeychainBackend()
        let material = AlertMaterial(epochs: [], hubSigningKey: Data(repeating: 7, count: 32))
        backend.plant("alert.\(E2EFixtureKeys.hubIDString)", try JSONEncoder().encode(material), group: "TEAM.alerts")
        let found = try KeychainPhoneKeyStore.alertMaterial(hubID, backend: backend, alertGroup: "TEAM.alerts")
        XCTAssertNotNil(found, "the source's hub id is the spelling the alert store keys on")
    }

    func testBrokenPushesAreNotAlerts() throws {
        let good = try sealed("alertPush")
        var otherSender = good
        otherSender[22] ^= 0xFF
        let standard = good.base64EncodedString()
        let urlSafe = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let unpadded = standard.replacingOccurrences(of: "=", with: "")
        let padded = !good.count.isMultiple(of: 3)
        XCTAssertNotEqual(urlSafe, standard, "the fixture uses a character the url-safe alphabet renames")
        XCTAssertTrue(padded, "the fixture needs padding for the unpadded row to differ")
        let table: [(String, [AnyHashable: Any])] = [
            ("no e", ["aps": ["mutable-content": 1]]),
            ("e a number", try alertBody(e: 42)),
            ("unpadded", try alertBody(e: unpadded)),
            ("url-safe alphabet", try alertBody(e: urlSafe)),
            ("3022 bytes", try alertBody(Data(good + Data(repeating: 0, count: 3022 - good.count)))),
            ("truncated", try alertBody(good.prefix(good.count - 5))),
            ("class data", try alertBody(try sealed("data"))),
            ("another sender", try alertBody(otherSender))
        ]
        for (name, body) in table {
            XCTAssertNil(wake.alertSource(for: body), name)
        }
    }

    func testACloudKitPayloadKeepsItsAnswer() throws {
        let cloud = StubPushWake(origin: .shared, source: .inline(hubID: "H", envelope: Data([9])))
        let withCK: [AnyHashable: Any] = ["aps": ["content-available": 1], "ck": ["nid": "x"]]
        XCTAssertEqual(PushRouting.origin(ofRemoteNotification: withCK, cloudKit: cloud), .shared)
        XCTAssertEqual(PushRouting.alertSource(for: withCK, cloudKit: cloud), .inline(hubID: "H", envelope: Data([9])))
        // Without "ck" the relay reads it, whatever CloudKit would say.
        let silent: [AnyHashable: Any] = ["aps": ["content-available": 1]]
        XCTAssertEqual(PushRouting.origin(ofRemoteNotification: silent, cloudKit: cloud), .hostedRelay)
        XCTAssertNil(PushRouting.alertSource(for: silent, cloudKit: cloud))
        // Private and shared both pass through CloudKit's own answer.
        for scope in [PushOrigin.private, .shared] {
            let stub = StubPushWake(origin: scope, source: nil)
            XCTAssertEqual(PushRouting.origin(ofRemoteNotification: withCK, cloudKit: stub), scope)
        }
    }

    func testAnEmptyPayloadHasNoOrigin() {
        XCTAssertNil(wake.origin(ofRemoteNotification: [:]))
        XCTAssertNil(wake.alertSource(for: [:]))
        XCTAssertNil(PushRouting.origin(ofRemoteNotification: [:], cloudKit: StubPushWake(origin: nil, source: nil)))
    }

    func testAFetchRecordSourceIsRefused() async throws {
        let ref = AlertRecordRef(hubID: "H", wireName: "w", zoneName: "z", ownerName: "o")
        do {
            _ = try await wake.envelope(for: .fetchRecord(ref), timeout: 1)
            XCTFail("expected UnsupportedRouteError")
        } catch {
            XCTAssertTrue(error is UnsupportedRouteError)
        }
        let inline = try await wake.envelope(for: .inline(hubID: "H", envelope: Data([1])), timeout: 1)
        XCTAssertEqual(inline, Data([1]))
        let subscribed = try await wake.subscribeAlerts(hubID: "H", route: .hostedRelay(macDeviceID: "m"))
        XCTAssertFalse(subscribed)
        do {
            _ = try await wake.subscribeAlerts(hubID: "H", route: .cloudKit(.private))
            XCTFail("expected UnsupportedRouteError")
        } catch {
            XCTAssertTrue(error is UnsupportedRouteError)
        }
    }
}

private struct StubPushWake: PushWake {
    var origin: PushOrigin?
    var source: AlertSource?
    func subscribeAlerts(hubID: String, route: HubRoute) async throws -> Bool { false }
    func unsubscribeAlerts(hubID: String, route: HubRoute) async throws {}
    func origin(ofRemoteNotification userInfo: [AnyHashable: Any]) -> PushOrigin? { origin }
    func alertSource(for userInfo: [AnyHashable: Any]) -> AlertSource? { source }
    func envelope(for source: AlertSource, timeout: TimeInterval) async throws -> Data? { nil }
}
