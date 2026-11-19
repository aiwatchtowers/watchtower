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

    /// The alert envelope's header with its body length patched so the whole envelope is `total` bytes and parses
    /// (signed: header + body + 64-byte signature); only the push cap can refuse it.
    private func sized(_ good: Data, total: Int) throws -> Data {
        let bodyLength = UInt32(total - EnvelopeHeader.length - Envelope.signatureLength)
        var header = Data(good.prefix(EnvelopeHeader.length))
        for index in 0 ..< 4 { header[64 + index] = UInt8((bodyLength >> UInt32(8 * (3 - index))) & 0xFF) }
        let out = header + Data(repeating: 0, count: total - EnvelopeHeader.length)
        XCTAssertEqual(out.count, total)
        _ = try Envelope.parse(out)
        return out
    }

    func testTheCapIsExactlyTheGoHubs() throws {
        let good = try sealed("alertPush")
        XCTAssertEqual(RelayPushWake.maxEnvelopeBytes, 3021)
        let atCap = try sized(good, total: 3021)
        XCTAssertEqual(wake.alertSource(for: try alertBody(atCap)), .inline(hubID: E2EFixtureKeys.hubIDString, envelope: atCap))
        XCTAssertNil(wake.alertSource(for: try alertBody(try sized(good, total: 3022))))
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
            ("3022 bytes", try alertBody(try sized(good, total: 3022))),
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

    // MARK: the notification extension's inline path (Task 12)

    private struct Fixture {
        var envelope: Data
        var epoch: UInt32
        var expected: WorkAlertPayload
    }

    private func fixture() throws -> Fixture {
        struct Item: Decodable { var envelope: String; var payload: String }
        struct Doc: Decodable { var epoch: UInt32; var cases: [String: Item] }
        let doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: Self.sealedURL))
        let item = try XCTUnwrap(doc.cases["alertPush"])
        return Fixture(
            envelope: Data(hex: item.envelope), epoch: doc.epoch,
            expected: try JSONDecoder().decode(WorkAlertPayload.self, from: Data(hex: item.payload)))
    }

    private func material(epochs: [UInt32]) throws -> AlertMaterial {
        let k = try E2EFixtureKeys()
        return AlertMaterial(
            epochs: epochs.map {
                EpochKeys(epoch: $0, dataKey: HPKEEnvelopeVectors.dataKeyBytes, alertKey: E2EFixtureKeys.sequence(0xD0, 0xEF))
            },
            hubSigningKey: k.hubSig.publicKey.rawRepresentation)
    }

    func testAnInlineAlertOpensWithNoNetwork() async throws {
        let item = try fixture()
        NoNetworkProtocol.reset()
        URLProtocol.registerClass(NoNetworkProtocol.self)
        defer { URLProtocol.unregisterClass(NoNetworkProtocol.self) }

        let cloud = StubPushWake(origin: nil, source: nil)
        let source = try XCTUnwrap(PushRouting.alertSource(for: alertBody(item.envelope), cloudKit: cloud))
        let envelope = try await PushRouting.envelope(for: source, timeout: 1, cloudKit: cloud)
        let payload = AlertOpener(material: try material(epochs: [item.epoch]))
            .open(wireName: source.wireName, envelope: try XCTUnwrap(envelope))
        XCTAssertEqual(payload, item.expected)
        let content = WorkAlertContent(payload: try XCTUnwrap(payload), hubID: source.hubID)
        XCTAssertEqual(content.title, item.expected.title)
        XCTAssertEqual(content.body, item.expected.body)
        XCTAssertEqual(NoNetworkProtocol.calls, 0, "the inline path makes no network call")
    }

    func testAnInlineAlertCarriesTheTapAndSweepFields() throws {
        let item = try fixture()
        let source = try XCTUnwrap(wake.alertSource(for: alertBody(item.envelope)))
        let content = WorkAlertContent(payload: item.expected, hubID: source.hubID)
        XCTAssertEqual(content.userInfo[WorkAlertContent.Key.hub], E2EFixtureKeys.hubIDString)
        XCTAssertEqual(content.userInfo[WorkAlertContent.Key.event], item.expected.event.rawValue)
        XCTAssertEqual(content.userInfo[WorkAlertContent.Key.key], "ask-42")
        XCTAssertEqual(content.userInfo[WorkAlertContent.Key.ask], item.expected.askID.map(String.init))
        XCTAssertEqual(
            content.threadID,
            item.expected.sessionID.map { "session-\($0)" } ?? "workbench-\(item.expected.workbenchID)")
    }

    func testAnOldEpochOpensWithARetainedKeyAndFailsWithout() throws {
        let item = try fixture()
        let held = AlertOpener(material: try material(epochs: [item.epoch, item.epoch + 1]))
        XCTAssertEqual(held.open(wireName: AlertSource.inlineWireName, envelope: item.envelope), item.expected)
        let dropped = AlertOpener(material: try material(epochs: [item.epoch + 1]))
        XCTAssertNil(dropped.open(wireName: AlertSource.inlineWireName, envelope: item.envelope))
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

/// Counts every request that reaches the URL loading system; fails each one.
private final class NoNetworkProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var calls: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }
    override static func canInit(with request: URLRequest) -> Bool { lock.withLock { count += 1 }; return true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
