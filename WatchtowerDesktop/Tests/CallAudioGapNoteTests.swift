import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

final class CallAudioGapNoteTests: XCTestCase {
    private typealias Gap = CallAudioWatch.Gap

    func testNoGapsSaysNothing() {
        XCTAssertNil(CallAudioGapNote.text([], totalSec: 600))
    }

    func testOneOrTwoGapsAreListed() {
        XCTAssertEqual(CallAudioGapNote.text([Gap(startSec: 929, endSec: nil)], totalSec: 2191),
                       "No call audio from 15:29 to the end — the transcript there may hold only your microphone.")
        XCTAssertEqual(CallAudioGapNote.text([Gap(startSec: 600, endSec: 780), Gap(startSec: 1200, endSec: nil)], totalSec: 1500),
                       "No call audio from 10:00 to 13:00 and from 20:00 to the end — the transcript there may hold only your microphone.")
    }

    func testManyGapsAreSummarized() {
        let gaps = [Gap(startSec: 60, endSec: 240), Gap(startSec: 600, endSec: 780), Gap(startSec: 1200, endSec: nil)]
        XCTAssertEqual(CallAudioGapNote.text(gaps, totalSec: 1440),
                       "No call audio in 3 stretches, 10 min in total, first at 1:00 — the transcript there may hold only your microphone.")
    }

    // The note is read from the recording's activity sidecar: a call heard
    // for 90 s and then silent for 200 s is one open gap.
    func testLoadReadsTheSidecarNextToTheAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("rec_test.caf")
        let lines = Array(repeating: "0.002000 0.050000", count: 900) + Array(repeating: "0.002000 0.000000", count: 2000)
        try lines.joined(separator: "\n").write(to: MicActivity.url(for: audio), atomically: true, encoding: .utf8)

        XCTAssertEqual(CallAudioGapNote.load(audioPath: audio.path),
                       "No call audio from 1:30 to the end — the transcript there may hold only your microphone.")
        // Degenerate: no sidecar / no path → no note.
        XCTAssertNil(CallAudioGapNote.load(audioPath: dir.appendingPathComponent("rec_none.caf").path))
        XCTAssertNil(CallAudioGapNote.load(audioPath: nil))
    }

    func testNoSpeechMessageNamesTheMissingCallAudio() {
        let silent = MicActivity(bins: Array(repeating: .init(mic: 0.002, sys: 0), count: 600))
        XCTAssertTrue(MeetingRecorderCenter.noSpeechMessage(silent).contains("no call audio was captured at all"))
        let dropped = MicActivity(bins: Array(repeating: .init(mic: 0.002, sys: 0.05), count: 900)
            + Array(repeating: .init(mic: 0.002, sys: 0), count: 1500))
        XCTAssertTrue(MeetingRecorderCenter.noSpeechMessage(dropped).contains("call audio stopped at 1:30"))
        XCTAssertEqual(MeetingRecorderCenter.noSpeechMessage(nil), "No speech recognized")
        let steady = MicActivity(bins: Array(repeating: .init(mic: 0.002, sys: 0.05), count: 600))
        XCTAssertEqual(MeetingRecorderCenter.noSpeechMessage(steady), "No speech recognized")
    }
}
