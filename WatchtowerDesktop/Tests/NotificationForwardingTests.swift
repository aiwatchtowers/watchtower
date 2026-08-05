import Foundation
import UserNotifications
import XCTest
@testable import WatchtowerDesktop

/// The codec a duplicate instance uses to hand its notification response to the
/// survivor. Only the pure functions are covered: the distributed-notification
/// transport and the `UNUserNotificationCenter` delegate around it need live
/// AppKit/UN plumbing and stay out of `swift test`.
final class NotificationForwardingTests: XCTestCase {

    private func roundTrip(actionID: String, userInfo: [AnyHashable: Any]) -> ForwardedNotificationResponse? {
        guard let json = NotificationForwarding.encode(actionID: actionID, userInfo: userInfo) else {
            XCTFail("encode returned nil for action \(actionID)")
            return nil
        }
        return NotificationForwarding.decode(json)
    }

    /// Every routed key survives the crossing, including `digestId` — the one
    /// value that is an Int in the push and text on the wire.
    func testRoundTripCarriesEveryRoutedKey() {
        let decoded = roundTrip(
            actionID: NotificationService.joinRecordActionID,
            userInfo: [
                "type": "meeting_reminder",
                "digestId": 4242,
                "eventId": "evt-1",
                "conferenceUrl": "https://meet.google.com/abc-defg-hij"
            ]
        )

        XCTAssertEqual(decoded?.actionID, NotificationService.joinRecordActionID)
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
        let decoded = roundTrip(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["type": "track_update", "trackId": "T-9", "eventTitle": "Standup"]
        )

        XCTAssertEqual(decoded?.payload, ["type": "track_update"])
        XCTAssertNil(decoded?.userInfo["trackId"])
        XCTAssertNil(decoded?.userInfo["eventTitle"])
    }

    /// A response with no routed keys at all still encodes: the survivor receives an
    /// empty payload and falls through to the routing table's default, which is what
    /// this process would have done itself.
    func testEncodeWithNoRoutedKeysYieldsEmptyPayload() {
        let decoded = roundTrip(actionID: "some.action", userInfo: ["unrelated": "value"])

        XCTAssertEqual(decoded?.actionID, "some.action")
        XCTAssertEqual(decoded?.payload, [:])
        XCTAssertNil(decoded?.userInfo["type"])
    }

    /// Missing `type` is not a decode failure — the payload simply lacks the key and
    /// routing takes its default branch rather than the survivor crashing on garbage.
    func testDecodeWithoutTypeStillCarriesTheAction() {
        let decoded = roundTrip(
            actionID: NotificationService.stopRecordingActionID,
            userInfo: ["eventId": "evt-2"]
        )

        XCTAssertEqual(decoded?.actionID, NotificationService.stopRecordingActionID)
        XCTAssertNil(decoded?.userInfo["type"])
        XCTAssertEqual(decoded?.userInfo["eventId"] as? String, "evt-2")
    }

    /// A `digestId` that is not a number is dropped rather than handed on as text
    /// under an Int key: routing then lands on the digests tab instead of a wrong row.
    func testUnparseableDigestIDIsDroppedFromRoutingUserInfo() {
        let decoded = roundTrip(actionID: "a", userInfo: ["type": "decision", "digestId": "not-a-number"])

        XCTAssertEqual(decoded?.payload["digestId"], "not-a-number")
        XCTAssertNil(decoded?.userInfo["digestId"])
    }

    /// Anything that is not our JSON on the wire decodes to nil — never a crash,
    /// never a half-built response.
    func testDecodeRejectsGarbage() {
        XCTAssertNil(NotificationForwarding.decode(""))
        XCTAssertNil(NotificationForwarding.decode("not json at all"))
        XCTAssertNil(NotificationForwarding.decode("{\"actionID\":\"a\"}"))
        XCTAssertNil(NotificationForwarding.decode("{\"payload\":{\"type\":\"decision\"}}"))
        XCTAssertNil(NotificationForwarding.decode("{\"actionID\":42,\"payload\":{}}"))
    }
}
