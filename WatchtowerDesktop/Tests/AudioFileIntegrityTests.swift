import XCTest

@testable import WatchtowerDesktop

/// A recording whose writer was never closed holds every AAC byte but no
/// packet table, and reads as 0 packets — which used to decode to an empty
/// sample stream and fail the job as "No speech recognized". The recorder
/// must refuse to report such a file as a finished recording, and the decoder
/// must say what is wrong with it instead of returning nothing.
final class AudioFileIntegrityTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup = []
        super.tearDown()
    }

    private func finalizedFixture(durationSec: Double = 2) throws -> URL {
        let url = try AACFixture.write(durationSec: durationSec)
        cleanup.append(url)
        return url
    }

    private func unfinalizedFixture() throws -> URL {
        let url = try AACFixture.unfinalizedCopy(of: finalizedFixture())
        cleanup.append(url)
        return url
    }

    // MARK: inspect

    func testFinalizedFileListsItsPackets() throws {
        guard case .finalized(let packets) = try AudioFileIntegrity.inspect(url: finalizedFixture()) else {
            return XCTFail("a closed AAC file must list its packets")
        }
        // 2 s at 16 kHz is ~32 packets of 1024 frames, plus priming.
        XCTAssertGreaterThan(packets, 30)
    }

    func testUnfinalizedFileIsDetected() throws {
        guard case .unfinalized(let bytes) = try AudioFileIntegrity.inspect(url: unfinalizedFixture()) else {
            return XCTFail("a file with audio bytes but no packet table must read as unfinalized")
        }
        XCTAssertGreaterThan(bytes, 0)
    }

    func testMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).caf")
        XCTAssertThrowsError(try AudioFileIntegrity.inspect(url: missing))
    }

    // MARK: recorder's after-close check

    func testVerifyFinalizedAcceptsAClosedFile() throws {
        XCTAssertNoThrow(try SystemAudioRecorder.verifyFinalized(url: finalizedFixture(), framesWritten: 32_000))
    }

    func testVerifyFinalizedAcceptsAVeryShortClosedFile() throws {
        // Under one AAC packet of input: the encoder only emits it on close.
        XCTAssertNoThrow(try SystemAudioRecorder.verifyFinalized(
            url: finalizedFixture(durationSec: 0.01), framesWritten: 160
        ))
    }

    func testVerifyFinalizedRejectsAnUnfinalizedFile() throws {
        XCTAssertThrowsError(try SystemAudioRecorder.verifyFinalized(url: unfinalizedFixture(), framesWritten: 32_000)) {
            guard case AudioRecordingError.notFinalized = $0 else {
                return XCTFail("expected .notFinalized, got \($0)")
            }
            XCTAssertTrue($0.localizedDescription.contains("kept"), "the message must say the audio is kept")
        }
    }

    func testVerifyFinalizedRejectsAnUnreadableFile() throws {
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).caf")
        try Data("not audio".utf8).write(to: garbage)
        cleanup.append(garbage)
        XCTAssertThrowsError(try SystemAudioRecorder.verifyFinalized(url: garbage, framesWritten: 32_000)) {
            guard case AudioRecordingError.notFinalized = $0 else {
                return XCTFail("expected .notFinalized, got \($0)")
            }
        }
    }

    func testVerifyFinalizedSkipsARecordingThatWroteNothing() throws {
        // Nothing was written, so 0 packets is the truth, not a lost table.
        XCTAssertNoThrow(try SystemAudioRecorder.verifyFinalized(url: unfinalizedFixture(), framesWritten: 0))
    }

    // MARK: decoder

    func testDecoderThrowsNotFinalizedInsteadOfReturningNoSamples() throws {
        XCTAssertThrowsError(try AudioFileDecoder.decodePCM16k(url: unfinalizedFixture())) {
            guard case AudioFileDecoderError.notFinalized = $0 else {
                return XCTFail("expected .notFinalized, got \($0)")
            }
            XCTAssertTrue($0.localizedDescription.contains("not finalized"))
        }
    }
}
