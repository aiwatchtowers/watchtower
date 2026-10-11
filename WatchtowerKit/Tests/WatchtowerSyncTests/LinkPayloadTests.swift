import XCTest
@testable import WatchtowerSync

final class LinkPayloadTests: XCTestCase {
    // A frozen v1 code (spec §2.3): sorted keys, unescaped slashes, base64url
    // without padding. Changing the encoder's output breaks this fixture.
    private static let fixtureURL = "watchtower://link?d=eyJjb250YWluZXIiOiJpQ2xvdWQuY29tLmFpd2F0Y2h0b3dlcnMud2F0Y2h0b3dlciIsImRhdGFfc2hhcmUiOiJodHRwczovL3d3dy5pY2xvdWQuY29tL3NoYXJlLzBhQmNEZUZnSGlKa0xtTm9QcVJzVHVWd1giLCJleHAiOjE3MDAwMDA2MDAsImh1Yl9pZCI6IjhGMEMyQTUxLTNCN0UtNEMxRC05QTZGLTJFNUI3RDlDMUEzNCIsImlhdCI6MTcwMDAwMDAwMCwibWFjX25hbWUiOiJBY21lIE1hY0Jvb2sgUHJvIiwibm9uY2UiOiJBQUVDQXdRRkJnY0lDUW9MREEwT0R4QVJFaE1VRlJZWEdCa2FHeHdkSGg4Iiwib3duZXJfdXNlciI6Il8wMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZiIsInJlbGF5X3NoYXJlIjoiaHR0cHM6Ly93d3cuaWNsb3VkLmNvbS9zaGFyZS8well4V3ZVdFNyUXBPbk1sS2pJaEdmRWRDIiwidiI6MX0"

    private static let fixturePayload = LinkPayload(
        hubID: "8F0C2A51-3B7E-4C1D-9A6F-2E5B7D9C1A34",
        macName: "Acme MacBook Pro",
        ownerUser: "_0123456789abcdef0123456789abcdef",
        nonce: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
        iat: 1_700_000_000,
        exp: 1_700_000_600,
        dataShare: "https://www.icloud.com/share/0aBcDeFgHiJkLmNoPqRsTuVwX",
        relayShare: "https://www.icloud.com/share/0zYxWvUtSrQpOnMlKjIhGfEdC"
    )

    /// The fixture's JSON object, for building variant codes.
    private static func fixtureObject() throws -> [String: Any] {
        let data = try XCTUnwrap(LinkPayload.decodeBase64URL(dParameter(fixtureURL)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func dParameter(_ url: String) throws -> String {
        try XCTUnwrap(url.components(separatedBy: "?d=").last)
    }

    /// A `watchtower://link` URL carrying `object` as its payload.
    private static func linkURL(_ object: [String: Any]) throws -> URL {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(URL(string: "watchtower://link?d=" + LinkPayload.encodeBase64URL(json)))
    }

    private static func parse(_ string: String) throws -> Result<LinkPayload, LinkPayloadError> {
        LinkPayload.parse(try XCTUnwrap(URL(string: string)))
    }

    // MARK: - Round trip

    func testFrozenFixtureRoundTripsByteForByte() throws {
        let parsed = try Self.parse(Self.fixtureURL).get()
        XCTAssertEqual(parsed, Self.fixturePayload)
        XCTAssertEqual(parsed.v, 1)
        XCTAssertEqual(parsed.container, "iCloud.com.aiwatchtowers.watchtower")
        XCTAssertEqual(parsed.url().absoluteString, Self.fixtureURL)
        XCTAssertEqual(Self.fixturePayload.url().absoluteString, Self.fixtureURL)
    }

    func testIssueSetsExpiryNonceAndContainer() throws {
        let now = Date()
        let payload = LinkPayload.issue(
            hubID: "hub-1",
            macName: "Acme Mac",
            ownerUser: "_owner",
            dataShare: nil,
            relayShare: nil,
            now: now
        )
        XCTAssertEqual(payload.v, LinkPayload.currentVersion)
        XCTAssertEqual(payload.container, WatchtowerCloud.containerID)
        XCTAssertEqual(payload.iat, Int64(now.timeIntervalSince1970))
        XCTAssertEqual(payload.exp, payload.iat + 600)
        XCTAssertEqual(payload.nonce.count, 43)
        XCTAssertEqual(try LinkPayload.parse(payload.url()).get(), payload)
    }

    // MARK: - Rejections

    func testNewerVersionIsRejected() throws {
        var object = try Self.fixtureObject()
        object["v"] = 2
        XCTAssertEqual(LinkPayload.parse(try Self.linkURL(object)), .failure(.newerVersion))
    }

    func testNewerVersionWinsOverUnknownShape() throws {
        // A v2 code may drop v1 keys; the phone must still say "update".
        XCTAssertEqual(LinkPayload.parse(try Self.linkURL(["v": 2])), .failure(.newerVersion))
    }

    func testMissingNonceIsReported() throws {
        var object = try Self.fixtureObject()
        object.removeValue(forKey: "nonce")
        XCTAssertEqual(LinkPayload.parse(try Self.linkURL(object)), .failure(.missingField("nonce")))
    }

    func testMissingVersionIsReported() throws {
        var object = try Self.fixtureObject()
        object.removeValue(forKey: "v")
        XCTAssertEqual(LinkPayload.parse(try Self.linkURL(object)), .failure(.missingField("v")))
    }

    func testPaddedDataIsBadEncoding() throws {
        // "eyJ2IjoxfQ" is {"v":1}; with padding it is no longer canonical.
        XCTAssertEqual(try Self.parse("watchtower://link?d=eyJ2IjoxfQ=="), .failure(.badEncoding))
        XCTAssertEqual(try Self.parse(Self.fixtureURL + "="), .failure(.badEncoding))
    }

    func testInvalidCharactersAreBadEncoding() throws {
        let d = try Self.dParameter(Self.fixtureURL)
        // Standard base64 '+' and '/' are not base64url.
        XCTAssertEqual(try Self.parse("watchtower://link?d=" + d.dropLast(2) + "+/"), .failure(.badEncoding))
        XCTAssertEqual(try Self.parse("watchtower://link?d=" + d.dropLast() + "*"), .failure(.badEncoding))
        XCTAssertEqual(try Self.parse("watchtower://link?d=eyJ2IjoxfQ%20"), .failure(.badEncoding))
    }

    func testMissingOrEmptyDataIsBadEncoding() throws {
        XCTAssertEqual(try Self.parse("watchtower://link"), .failure(.badEncoding))
        XCTAssertEqual(try Self.parse("watchtower://link?d="), .failure(.badEncoding))
    }

    func testNonJSONPayloadIsBadEncoding() throws {
        let garbage = LinkPayload.encodeBase64URL(Data("not json".utf8))
        XCTAssertEqual(try Self.parse("watchtower://link?d=" + garbage), .failure(.badEncoding))
    }

    func testWrongFieldTypeIsBadEncoding() throws {
        var object = try Self.fixtureObject()
        object["iat"] = "yesterday"
        XCTAssertEqual(LinkPayload.parse(try Self.linkURL(object)), .failure(.badEncoding))
    }

    func testAnotherContainerIsRejected() throws {
        var object = try Self.fixtureObject()
        object["container"] = "iCloud.com.example.other"
        XCTAssertEqual(LinkPayload.parse(try Self.linkURL(object)), .failure(.wrongContainer))
    }

    func testOtherURLsAreNotALink() throws {
        let d = try Self.dParameter(Self.fixtureURL)
        XCTAssertEqual(try Self.parse("https://link?d=" + d), .failure(.notALink))
        XCTAssertEqual(try Self.parse("https://example.com/link?d=" + d), .failure(.notALink))
        XCTAssertEqual(try Self.parse("watchtower://open?d=" + d), .failure(.notALink))
    }

    // MARK: - Size and optional keys

    func testEncodedSizeWithBothSharesIsUnder700Bytes() throws {
        let share = "https://www.icloud.com/share/" + String(repeating: "x", count: 120 - 29)
        XCTAssertEqual(share.count, 120)
        let payload = LinkPayload.issue(
            hubID: UUID().uuidString,
            macName: String(repeating: "m", count: 60),
            ownerUser: "_" + String(repeating: "0", count: 32),
            dataShare: share,
            relayShare: share,
            now: Date()
        )
        let json = try LinkPayload.makeEncoder().encode(payload)
        XCTAssertLessThan(json.count, 700, "payload JSON is \(json.count) bytes")
        // The QR string itself (base64url adds a third) is reported for the record.
        let qr = payload.url().absoluteString.utf8.count
        XCTAssertLessThan(qr, 1_000, "QR string is \(qr) bytes")
    }

    func testAbsentShareIsAnAbsentKey() throws {
        let payload = LinkPayload.issue(
            hubID: "hub-1",
            macName: "Acme Mac",
            ownerUser: "_owner",
            dataShare: nil,
            relayShare: "https://www.icloud.com/share/0zYx",
            now: Date()
        )
        let json = try XCTUnwrap(String(data: try LinkPayload.makeEncoder().encode(payload), encoding: .utf8))
        XCTAssertFalse(json.contains("data_share"), json)
        XCTAssertFalse(json.contains("null"), json)
        XCTAssertTrue(json.contains(#""relay_share":"https://www.icloud.com/share/0zYx""#), json)

        var object = try Self.fixtureObject()
        object.removeValue(forKey: "data_share")
        object.removeValue(forKey: "relay_share")
        let parsed = try LinkPayload.parse(try Self.linkURL(object)).get()
        XCTAssertNil(parsed.dataShare)
        XCTAssertNil(parsed.relayShare)
    }

    // MARK: - Mac name (Review Focus 4: grapheme-safe clipping)

    func testMacNameOver60IsClippedTo60() {
        let payload = Self.payload(macName: String(repeating: "a", count: 61))
        XCTAssertEqual(payload.macName, String(repeating: "a", count: 60))
    }

    func testMacNameClipKeepsZWJEmojiAtTheBoundaryWhole() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        XCTAssertEqual(family.count, 1)

        // The emoji is the 60th grapheme: it stays, whole.
        let kept = Self.payload(macName: String(repeating: "a", count: 59) + family + "b")
        XCTAssertEqual(kept.macName, String(repeating: "a", count: 59) + family)

        // The emoji is the 61st grapheme: it goes, with none of its scalars left behind.
        let dropped = Self.payload(macName: String(repeating: "a", count: 60) + family)
        XCTAssertEqual(dropped.macName, String(repeating: "a", count: 60))
        XCTAssertEqual(dropped.macName.unicodeScalars.count, 60)
    }

    func testParsedMacNameOver60IsClipped() throws {
        var object = try Self.fixtureObject()
        object["mac_name"] = String(repeating: "z", count: 75)
        let parsed = try LinkPayload.parse(try Self.linkURL(object)).get()
        XCTAssertEqual(parsed.macName, String(repeating: "z", count: 60))
    }

    // MARK: - Nonce

    func testNonceIs43Base64URLCharactersAndUnique() {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var seen = Set<String>()
        for _ in 0..<1000 {
            let nonce = LinkPayload.makeNonce()
            XCTAssertEqual(nonce.count, 43)
            XCTAssertTrue(nonce.unicodeScalars.allSatisfy(allowed.contains), nonce)
            XCTAssertEqual(LinkPayload.decodeBase64URL(nonce)?.count, 32)
            seen.insert(nonce)
        }
        XCTAssertEqual(seen.count, 1000)
    }

    private static func payload(macName: String) -> LinkPayload {
        LinkPayload(
            hubID: "hub-1",
            macName: macName,
            ownerUser: "_owner",
            nonce: LinkPayload.makeNonce(),
            iat: 1,
            exp: 601
        )
    }
}
