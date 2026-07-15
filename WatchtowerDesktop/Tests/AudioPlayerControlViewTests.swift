import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

private final class FakePlayback: AudioPlayback {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 10
    private(set) var isPlaying = false

    @discardableResult
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}

private struct BoomError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
final class AudioPlayerControlViewTests: XCTestCase {
    func testTapStartsPlaybackOnIdleRow() throws {
        let center = AudioPlaybackCenter(playerFactory: { _ in FakePlayback() })
        let view = AudioPlayerControlView(
            transcriptID: 1,
            audioURL: URL(fileURLWithPath: "/tmp/rec.caf"),
            knownDuration: 10,
            center: center
        )

        try view.inspect().find(ViewType.Button.self).tap()

        XCTAssertEqual(center.activeTranscriptID, 1)
        XCTAssertTrue(center.isPlaying)
    }

    func testSecondTapPausesTheSameRow() throws {
        let center = AudioPlaybackCenter(playerFactory: { _ in FakePlayback() })
        let view = AudioPlayerControlView(
            transcriptID: 1,
            audioURL: URL(fileURLWithPath: "/tmp/rec.caf"),
            knownDuration: 10,
            center: center
        )

        try view.inspect().find(ViewType.Button.self).tap()
        try view.inspect().find(ViewType.Button.self).tap()

        XCTAssertFalse(center.isPlaying)
        XCTAssertEqual(center.activeTranscriptID, 1)
    }

    func testShowsErrorMessageWhenPlaybackFails() throws {
        let center = AudioPlaybackCenter(playerFactory: { _ in throw BoomError() })
        let view = AudioPlayerControlView(
            transcriptID: 1,
            audioURL: URL(fileURLWithPath: "/tmp/rec.caf"),
            knownDuration: 10,
            center: center
        )

        try view.inspect().find(ViewType.Button.self).tap()

        XCTAssertNoThrow(try view.inspect().find(text: "boom"))
    }

    func testNoErrorMessageShownBeforeAnyPlayAttempt() throws {
        let center = AudioPlaybackCenter(playerFactory: { _ in FakePlayback() })
        let view = AudioPlayerControlView(
            transcriptID: 1,
            audioURL: URL(fileURLWithPath: "/tmp/rec.caf"),
            knownDuration: 10,
            center: center
        )

        XCTAssertThrowsError(try view.inspect().find(text: "boom"))
    }
}
