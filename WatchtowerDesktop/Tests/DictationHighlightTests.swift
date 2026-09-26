import XCTest
@testable import WatchtowerDesktop

/// `DictationHighlightState.derive` is the pure core of the
/// `.dictationHighlight` field modifier — testable without rendering.
final class DictationHighlightTests: XCTestCase {

    func test_matchingTarget_recording_isRecording() {
        XCTAssertEqual(
            DictationHighlightState.derive(activeTargetID: "t", phase: .recording, targetID: "t"),
            .recording
        )
    }

    func test_matchingTarget_paused_isPaused() {
        XCTAssertEqual(
            DictationHighlightState.derive(activeTargetID: "t", phase: .paused, targetID: "t"),
            .paused
        )
    }

    func test_matchingTarget_nonHighlightPhases_areNone() {
        // .stopping/.cleaning included by contract: the highlight goes out the
        // moment the mic stops listening, not when the text finally lands.
        let phases: [DictationPhase] = [.cleaning, .stopping, .idle, .failed("x")]
        for phase in phases {
            XCTAssertEqual(
                DictationHighlightState.derive(activeTargetID: "t", phase: phase, targetID: "t"),
                DictationHighlightState.none,
                "phase \(phase) must not highlight"
            )
        }
    }

    func test_nonMatchingTarget_recording_isNone() {
        XCTAssertEqual(
            DictationHighlightState.derive(activeTargetID: "other", phase: .recording, targetID: "t"),
            DictationHighlightState.none
        )
    }

    func test_nilActiveTarget_isNone() {
        XCTAssertEqual(
            DictationHighlightState.derive(activeTargetID: nil, phase: .recording, targetID: "t"),
            DictationHighlightState.none
        )
    }

    func test_nilActiveTarget_emptyTargetSentinel_isNone() {
        // The ChatInput nil-target sentinel (`dictationTargetID ?? ""`) must
        // never light up: "" never matches a real activeTargetID, and a nil
        // activeTargetID matches nothing.
        XCTAssertEqual(
            DictationHighlightState.derive(activeTargetID: nil, phase: .recording, targetID: ""),
            DictationHighlightState.none
        )
    }
}
