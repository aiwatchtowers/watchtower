import Foundation
import XCTest
@testable import WatchtowerDesktop

/// The codec a duplicate instance uses to hand its notification response to the
/// survivor. Only the pure functions are covered: the distributed-notification
/// transport and the `UNUserNotificationCenter` delegate around it need live
/// AppKit/UN plumbing and stay out of `swift test`.
final class NotificationForwardingTests: XCTestCase {

    private func roundTrip(userInfo: [AnyHashable: Any]) -> ForwardedNotificationResponse? {
        guard let json = NotificationForwarding.encode(userInfo: userInfo) else {
            XCTFail("encode returned nil")
            return nil
        }
        return NotificationForwarding.decode(json)
    }

    /// The structural contract behind the hardening: the action identifier never
    /// reaches the wire, so no forged post can name an action button.
    func testEncodedJSONCarriesNoActionID() {
        let json = NotificationForwarding.encode(
            userInfo: ["type": "meeting_reminder", "eventId": "evt-1"]
        )

        XCTAssertNotNil(json)
        XCTAssertFalse(json?.contains("actionID") ?? true)
        XCTAssertFalse(json?.contains(NotificationService.joinRecordActionID) ?? true)
    }

    /// An attacker posting the pre-hardening shape gets a payload and nothing else:
    /// the identifier is not a field any more, so there is no route from the bus to
    /// `JoinMeetingAction.join(forceRecord:)`.
    func testDecodeIgnoresAnActionIDInTheBlob() {
        let raw = """
        {"actionID":"\(NotificationService.joinRecordActionID)",\
        "payload":{"type":"meeting_reminder","eventId":"evt-1"}}
        """

        let decoded = NotificationForwarding.decode(raw)

        XCTAssertEqual(decoded?.payload, ["type": "meeting_reminder", "eventId": "evt-1"])
        // The routing view is the payload plus the digestId coercion — the smuggled
        // identifier is not reachable under any key.
        XCTAssertNil(decoded?.userInfo["actionID"])
        XCTAssertFalse(decoded?.userInfo.keys.contains { "\($0)" == "actionID" } ?? true)
    }

    /// The same holds for a literal that never was one of ours.
    func testDecodeIgnoresAnUnknownActionIDInTheBlob() {
        let decoded = NotificationForwarding.decode(
            "{\"actionID\":\"com.watchtower.joinRecord\",\"payload\":{\"type\":\"decision\"}}"
        )

        XCTAssertEqual(decoded?.payload, ["type": "decision"])
        XCTAssertNil(decoded?.userInfo["actionID"])
    }

    /// Every routed key survives the crossing, including `digestId` — the one
    /// value that is an Int in the push and text on the wire.
    func testRoundTripCarriesEveryRoutedKey() {
        let decoded = roundTrip(
            userInfo: [
                "type": "meeting_reminder",
                "digestId": 4242,
                "eventId": "evt-1",
                "conferenceUrl": "https://meet.google.com/abc-defg-hij"
            ]
        )

        XCTAssertEqual(decoded?.payload["type"], "meeting_reminder")
        XCTAssertEqual(decoded?.payload["digestId"], "4242")
        XCTAssertEqual(decoded?.payload["eventId"], "evt-1")
        XCTAssertEqual(decoded?.payload["conferenceUrl"], "https://meet.google.com/abc-defg-hij")

        // The routing view hands `digestId` back as the Int `navigateToDigest` takes.
        XCTAssertEqual(decoded?.userInfo["digestId"] as? Int, 4242)
        XCTAssertEqual(decoded?.userInfo["type"] as? String, "meeting_reminder")
        XCTAssertEqual(decoded?.userInfo["eventId"] as? String, "evt-1")
    }

    /// A push carries more than the delegate routes on (`eventTitle`, `trackId`, …);
    /// none of it crosses the process boundary.
    func testEncodeDropsUnroutedKeys() {
        let decoded = roundTrip(userInfo: ["type": "track_update", "trackId": "T-9", "eventTitle": "Standup"])

        XCTAssertEqual(decoded?.payload, ["type": "track_update"])
        XCTAssertNil(decoded?.userInfo["trackId"])
        XCTAssertNil(decoded?.userInfo["eventTitle"])
    }

    /// A response with no routed keys at all still encodes: the survivor receives an
    /// empty payload and falls through to the routing table's default, which is what
    /// this process would have done itself.
    func testEncodeWithNoRoutedKeysYieldsEmptyPayload() {
        let decoded = roundTrip(userInfo: ["unrelated": "value"])

        XCTAssertEqual(decoded?.payload, [:])
        XCTAssertNil(decoded?.userInfo["type"])
    }

    /// Missing `type` is not a decode failure — the payload simply lacks the key and
    /// routing takes its default branch rather than the survivor crashing on garbage.
    func testDecodeWithoutTypeStillCarriesTheOtherKeys() {
        let decoded = roundTrip(userInfo: ["eventId": "evt-2"])

        XCTAssertNil(decoded?.userInfo["type"])
        XCTAssertEqual(decoded?.userInfo["eventId"] as? String, "evt-2")
    }

    /// A `digestId` that is not a number is dropped rather than handed on as text
    /// under an Int key: routing then lands on the digests tab instead of a wrong row.
    func testUnparseableDigestIDIsDroppedFromRoutingUserInfo() {
        let decoded = roundTrip(userInfo: ["type": "decision", "digestId": "not-a-number"])

        XCTAssertEqual(decoded?.payload["digestId"], "not-a-number")
        XCTAssertNil(decoded?.userInfo["digestId"])
    }

    /// Anything that is not our JSON on the wire decodes to nil — never a crash,
    /// never a half-built response.
    func testDecodeRejectsGarbage() {
        XCTAssertNil(NotificationForwarding.decode(""))
        XCTAssertNil(NotificationForwarding.decode("not json at all"))
        XCTAssertNil(NotificationForwarding.decode("{\"actionID\":\"a\"}"))
        XCTAssertNil(NotificationForwarding.decode("{\"payload\":42}"))
        XCTAssertNil(NotificationForwarding.decode("{\"payload\":{\"type\":7}}"))
    }
}
