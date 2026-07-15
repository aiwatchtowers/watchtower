import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class TranscriptAudioControlTests: XCTestCase {
    private func makeTranscript(id: Int64? = 1, audioPath: String? = "/tmp/rec.caf") -> MeetingTranscript {
        MeetingTranscript(
            id: id,
            eventID: nil,
            title: "Test",
            audioPath: audioPath,
            durationSec: 20,
            langStats: "{}",
            transcriptText: "hello",
            summaryJSON: nil,
            createdAt: "2026-07-15T10:00:00Z",
            updatedAt: "2026-07-15T10:00:00Z"
        )
    }

    func testShowsPlayerWhenAudioPathPresent() throws {
        let view = TranscriptAudioControl(transcript: makeTranscript(), center: AudioPlaybackCenter())
        XCTAssertNoThrow(try view.inspect().find(ViewType.Button.self))
    }

    func testShowsDeletedCaptionWhenAudioPathNil() throws {
        let view = TranscriptAudioControl(transcript: makeTranscript(audioPath: nil), center: AudioPlaybackCenter())
        XCTAssertNoThrow(try view.inspect().find(text: "Recording deleted"))
    }
}
