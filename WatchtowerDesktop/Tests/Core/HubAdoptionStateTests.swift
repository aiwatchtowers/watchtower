import Foundation
import XCTest
@testable import WatchtowerCore

/// The hand-over's copy and its reading of `hub adopt --status --json` (go
/// hub plan 3 Task 22, mockup sections 4–6, ask #906).
final class HubAdoptionStateTests: XCTestCase {
    func testStateCopy() {
        XCTAssertEqual(HubAdoptionState.sectionTitle, "Mobile")

        XCTAssertEqual(HubAdoptionState.checking.title, "Loading…")
        XCTAssertNil(HubAdoptionState.checking.detail)
        XCTAssertNil(HubAdoptionState.checking.retryTitle)

        let moving = HubAdoptionState.inProgress(step: "rename")
        XCTAssertEqual(moving.title, "Moving Mobile to the new version…")
        XCTAssertEqual(moving.detail, "Step 3 of 5. Your phones stay linked; this takes a moment.")
        XCTAssertEqual(moving.compactDetail, "Step 3 of 5.")
        XCTAssertNil(moving.retryTitle)
        XCTAssertEqual(moving.progress ?? 0, 0.6, accuracy: 0.0001)

        let schema = HubAdoptionState.failed(reason: "swift_schema")
        XCTAssertEqual(schema.title, "Mobile could not move to the new version")
        XCTAssertEqual(schema.detail, "The old Mobile data has a format this version does not know. Nothing was changed.")
        XCTAssertEqual(schema.compactDetail, schema.detail)
        XCTAssertEqual(schema.retryTitle, "Retry")
        XCTAssertNil(schema.progress)
        XCTAssertEqual(HubAdoptionState.failed(reason: "no_keys").detail,
                       "This Mac's encryption keys are missing. Your phones need to be linked again.")
        XCTAssertEqual(HubAdoptionState.failed(reason: "something_new").detail,
                       "Something went wrong during the move. Retry continues where it stopped.")

        XCTAssertEqual(HubAdoptionState.done.title, "Mobile moved to the new version")
        XCTAssertNil(HubAdoptionState.done.retryTitle)
        XCTAssertEqual(HubAdoptionState.notNeeded.title, "")
        XCTAssertNil(HubAdoptionState.notNeeded.detail)
    }

    /// Every class the Go verb or the driver can end in has its own line,
    /// each one a full sentence and none of them naming a file.
    func testEveryFailureClassHasItsLine() {
        let classes = [
            "swift_schema", "swift_corrupt", "swift_hub_id", "swift_busy", "no_hub_id", "no_keys", "wrong_keys",
            "bad_keys", "keychain_unavailable", "keychain_refused", "cleanup_failed", "no_sidecar",
            "adoption_unfinished", "not_adopted", "locked", "no_cli", "failed"
        ]
        for reason in classes {
            let text = try? XCTUnwrap(HubAdoptionState.reasonTexts[reason], reason)
            XCTAssertEqual(HubAdoptionState.failed(reason: reason).detail, text, reason)
            XCTAssertTrue(text?.hasSuffix(".") == true, reason)
            XCTAssertFalse(text?.contains("hubstate") == true, reason)
        }
        XCTAssertEqual(Set(HubAdoptionState.reasonTexts.keys), Set(classes))
    }

    func testStepsAsTheOwnerSeesThem() {
        let table: [(String, Int)] = [
            ("", 1), ("copy", 1), ("verify", 2), ("rename", 3), ("migrate", 4), ("recordings", 4),
            ("settings", 4), ("transport", 4), ("moved", 4), ("done", 4), ("keys", 5), ("cleanup", 5)
        ]
        for (step, number) in table {
            XCTAssertEqual(HubAdoptionState.stepNumber(step), number, step)
        }
    }

    func testShownStates() {
        XCTAssertTrue(HubAdoptionState.checking.isShown)
        XCTAssertTrue(HubAdoptionState.inProgress(step: "copy").isShown)
        XCTAssertTrue(HubAdoptionState.failed(reason: "failed").isShown)
        XCTAssertFalse(HubAdoptionState.notNeeded.isShown, "nothing to hand over draws nothing")
        XCTAssertFalse(HubAdoptionState.done.isShown)
    }

    /// The pinned keys of `hub adopt --status --json` (cmd/hub_adopt.go).
    func testDecodesPinnedStatusKeys() throws {
        let json = #"""
        {"step":"migrate","imported":{"devices":1,"jobs":2,"skipped":0,"audio_left":0},"error":"",
         "hub_id":"hub-acme","identity":"staged","swift_state":"present",
         "pending_recordings":[{"upload_id":"u-1","audio_name":"rec_20261101_100000.m4a"}]}
        """#
        let status = try JSONDecoder().decode(HubAdoptStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, HubAdoptStatus(
            step: "migrate", hubID: "hub-acme", identity: "staged", swiftState: "present",
            pendingRecordings: [.init(uploadID: "u-1", audioName: "rec_20261101_100000.m4a")]
        ))
    }

    func testNextStepTable() {
        let table: [(HubAdoptStatus, HubAdoptStatus.Next)] = [
            (HubAdoptStatus(swiftState: "absent"), .nothing),
            (HubAdoptStatus(swiftState: "ignored"), .nothing),
            (HubAdoptStatus(swiftState: "present"), .adoptState),
            (HubAdoptStatus(step: "moved", swiftState: "absent"), .adoptState),
            (HubAdoptStatus(step: "verify", error: "swift_schema", swiftState: "present"), .adoptState),
            (HubAdoptStatus(step: "done", identity: "none"), .handOverKeys),
            (HubAdoptStatus(step: "done", identity: "staged"), .handOverKeys),
            (HubAdoptStatus(step: "done", identity: "adopted"), .deleteDesktopKeys),
            (HubAdoptStatus(step: "done", identity: "confirmed", swiftState: "ignored"), .finished)
        ]
        for (status, next) in table {
            XCTAssertEqual(status.next, next, "\(status)")
        }
    }

    func testSettingsKeys() throws {
        let data = try JSONEncoder().encode(HubAdoptSettings(enabled: true, startSessionAllows: ["dev-a": true]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertEqual(object["start_session_allows"] as? [String: Bool], ["dev-a": true])
    }
}
