import XCTest
@testable import WatchtowerDesktop

/// Real-hardware paths (actually opening `AVAudioEngine`'s input node) can't
/// run in CI, so these cover only the pure parts: the degenerate stop-without-
/// start path and the injectable permission check.
final class MicRecorderTests: XCTestCase {
    func testStopWithoutStartFinishesStream() async {
        let recorder = MicRecorder()
        recorder.stop()

        var received: [[Float]] = []
        for await chunk in recorder.samples {
            received.append(chunk)
        }
        XCTAssertTrue(received.isEmpty)
    }

    func testStartThrowsWhenPermissionDenied() async {
        let recorder = MicRecorder { false }

        do {
            try await recorder.start()
            XCTFail("expected microphonePermissionDenied")
        } catch MicRecorderError.microphonePermissionDenied {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
