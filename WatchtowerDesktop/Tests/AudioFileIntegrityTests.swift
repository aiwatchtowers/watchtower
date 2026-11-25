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

    func testFileClosedWithNoWritesIsEmpty() throws {
        let url = try AACFixture.writeEmpty()
        cleanup.append(url)
        XCTAssertEqual(try AudioFileIntegrity.inspect(url: url), .empty)
    }

    func testMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).caf")
        XCTAssertThrowsError(try AudioFileIntegrity.inspect(url: missing))
    }

    // MARK: recorder's after-close check

    private func verify(_ url: URL, framesWritten: Int64) throws {
        try SystemAudioRecorder.verifyFinalized(RecordingResult(audioURL: url, durationSec: 2), framesWritten: framesWritten)
    }

    func testVerifyFinalizedAcceptsAClosedFile() throws {
        XCTAssertNoThrow(try verify(finalizedFixture(), framesWritten: 32_000))
    }

    func testVerifyFinalizedAcceptsAVeryShortClosedFile() throws {
        // Under one AAC packet of input: the encoder only emits it on close.
        XCTAssertNoThrow(try verify(finalizedFixture(durationSec: 0.01), framesWritten: 160))
    }

    func testVerifyFinalizedRejectsAnUnfinalizedFile() throws {
        let url = try unfinalizedFixture()
        XCTAssertThrowsError(try verify(url, framesWritten: 32_000)) {
            guard case AudioRecordingError.notFinalized(let kept) = $0 else {
                return XCTFail("expected .notFinalized, got \($0)")
            }
            XCTAssertEqual(kept, RecordingResult(audioURL: url, durationSec: 2), "the error carries the would-be result")
            XCTAssertTrue($0.localizedDescription.contains("kept"), "the message must say the audio is kept")
        }
    }

    func testVerifyFinalizedRejectsAnUnreadableFile() throws {
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).caf")
        try Data("not audio".utf8).write(to: garbage)
        cleanup.append(garbage)
        XCTAssertThrowsError(try verify(garbage, framesWritten: 32_000)) {
            guard case AudioRecordingError.notFinalized = $0 else {
                return XCTFail("expected .notFinalized, got \($0)")
            }
        }
    }

    func testVerifyFinalizedRejectsAnEmptyFileWhenFramesWereWritten() throws {
        let url = try AACFixture.writeEmpty()
        cleanup.append(url)
        XCTAssertThrowsError(try verify(url, framesWritten: 32_000)) {
            guard case AudioRecordingError.notFinalized(let kept) = $0 else {
                return XCTFail("expected .notFinalized, got \($0)")
            }
            XCTAssertEqual(kept, RecordingResult(audioURL: url, durationSec: 2))
        }
    }

    func testVerifyFinalizedSkipsARecordingThatWroteNothing() throws {
        // Nothing was written, so 0 packets is the truth, not a lost table.
        XCTAssertNoThrow(try verify(unfinalizedFixture(), framesWritten: 0))
    }

    // MARK: ADTS (today's recorder format)

    /// The point of ADTS: a writer that is never closed (macOS 14, or a
    /// leaked one) still leaves a file that lists its packets, passes the
    /// recorder's check and decodes — only the encoder's unflushed tail is
    /// lost.
    func testUnclosedADTSFileIsReadableAndDecodes() throws {
        let (url, writer) = try AACFixture.writeUnclosed(durationSec: 2, fileExtension: "aac")
        cleanup.append(url)
        try withExtendedLifetime(writer) {
            guard case .finalized(let packets) = try AudioFileIntegrity.inspect(url: url) else {
                return XCTFail("an unclosed ADTS file must list the packets on disk")
            }
            XCTAssertGreaterThan(packets, 0)
            XCTAssertNoThrow(try verify(url, framesWritten: 32_000), "an unclosed ADTS file is not unfinalized")
            let samples = try AudioFileDecoder.decodePCM16k(url: url)
            XCTAssertGreaterThan(samples.count, 32_000 / 2, "most of the written audio must decode")
            XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.1, "decoded audio is silent — data lost")
        }
    }

    func testClosedADTSFileListsItsPackets() throws {
        let url = try AACFixture.write(durationSec: 2, fileExtension: "aac")
        cleanup.append(url)
        guard case .finalized(let packets) = try AudioFileIntegrity.inspect(url: url) else {
            return XCTFail("a closed ADTS file must list its packets")
        }
        XCTAssertGreaterThan(packets, 30)
    }

    /// A zero-byte or garbage `.aac` has no readable packet: the header read
    /// fails and the recorder's check fails a stop that wrote frames. The
    /// decode throws on garbage; a zero-byte file is what a recording with
    /// no frames leaves (`testDecoderReturnsNoSamplesForAnEmptyADTSFile`).
    func testEmptyOrGarbageADTSFileFailsHonestly() throws {
        for (name, bytes) in [("empty", Data()), ("garbage", Data("not audio, not adts".utf8))] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).aac")
            try bytes.write(to: url)
            cleanup.append(url)
            XCTAssertThrowsError(try AudioFileIntegrity.inspect(url: url), name) {
                XCTAssertTrue($0 is AudioFileIntegrity.Unreadable, "\(name): got \($0)")
            }
            XCTAssertThrowsError(try verify(url, framesWritten: 32_000), name) {
                guard case AudioRecordingError.notFinalized = $0 else {
                    return XCTFail("\(name): expected .notFinalized, got \($0)")
                }
            }
            XCTAssertThrowsError(try AudioFileDecoder.rejectUnfinalized(length: 0, at: url), name)
        }
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).aac")
        try Data("not audio, not adts".utf8).write(to: garbage)
        cleanup.append(garbage)
        XCTAssertThrowsError(try AudioFileDecoder.decodePCM16k(url: garbage), "garbage must not decode to silence")
    }

    /// Zero frames written leave a 0-byte `.aac`; like the empty CAF it
    /// replaces, it decodes to no samples (the job then reports no speech)
    /// rather than an open error.
    func testDecoderReturnsNoSamplesForAnEmptyADTSFile() throws {
        let url = try AACFixture.writeEmpty(fileExtension: "aac")
        cleanup.append(url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(size, 0, "an ADTS writer closed with nothing written leaves 0 bytes")
        XCTAssertEqual(try AudioFileDecoder.decodePCM16k(url: url), [])
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

    func testDecoderReturnsNoSamplesForAFileClosedWithNoWrites() throws {
        // Truly empty, not unfinalized: the honest result is no samples.
        let url = try AACFixture.writeEmpty()
        cleanup.append(url)
        XCTAssertEqual(try AudioFileDecoder.decodePCM16k(url: url), [])
    }

    func testDecoderFailsWhenTheHeaderOfAnEmptyFileIsUnreadable() throws {
        // The header read must never fall through to "no samples" on error.
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).caf")
        try Data("not audio".utf8).write(to: garbage)
        cleanup.append(garbage)
        XCTAssertThrowsError(try AudioFileDecoder.rejectUnfinalized(length: 0, at: garbage)) {
            guard case AudioFileDecoderError.conversionFailed(let detail) = $0 else {
                return XCTFail("expected .conversionFailed, got \($0)")
            }
            XCTAssertTrue(detail.contains("OSStatus"), "got: \(detail)")
        }
        XCTAssertNoThrow(try AudioFileDecoder.rejectUnfinalized(length: 1024, at: garbage),
                         "a file listing frames needs no header check")
    }
}
