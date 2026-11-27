import AVFoundation
import XCTest

@testable import WatchtowerDesktop

/// AudioFileDecoder must decode compressed recordings end-to-end. Regression
/// guard for the AAC EOF bug: `AVAudioFile.read(into:)` on a COMPRESSED file
/// throws a bridged nilError when called past the last packet (PCM files
/// return an empty buffer instead), so EOF detection must use framePosition,
/// not "read returned 0 frames".
final class AudioFileDecoderTests: XCTestCase {
    private let sampleRate = 16_000.0
    private let durationSec = 2.6 // deliberately NOT a whole multiple of AAC's 1024-frame packets

    private func assertDecodesFully(fileExtension: String) throws {
        let url = try AACFixture.write(durationSec: durationSec, fileExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioFileDecoder.decodePCM16k(url: url)

        // AAC priming/remainder trims a few packets; expect within one packet
        // (1024 frames) of the written length, and definitely not near-empty.
        let expected = Int(sampleRate * durationSec)
        XCTAssertGreaterThan(samples.count, expected - 2 * 1024, "decoded far fewer samples than written")
        XCTAssertLessThan(samples.count, expected + 2 * 1024, "decoded more samples than written")
        let peak = samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "decoded audio is silent — data lost")
    }

    func testDecodesAACInCAFToTheLastFrame() throws {
        try assertDecodesFully(fileExtension: "caf")
    }

    func testDecodesADTSToTheLastFrame() throws {
        try assertDecodesFully(fileExtension: "aac")
    }

    /// ADTS has no priming metadata, so the decoder trims the encoder's
    /// priming itself: a tone starting at frame 16 000 must decode at sample
    /// 16 000 (± 2 ms), as it does from a CAF — not ~132 ms late — so decoded
    /// times line up with the player and the `.activity` bins.
    func testAKnownOnsetDecodesAtItsWrittenSampleInEveryContainer() throws {
        let onset = 16_000
        for ext in ["aac", "caf", "m4a"] {
            let url = try AACFixture.writeSilenceThenTone(onsetFrame: onset, totalFrames: 48_000, fileExtension: ext)
            defer { try? FileManager.default.removeItem(at: url) }
            let samples = try AudioFileDecoder.decodePCM16k(url: url)
            let first = try XCTUnwrap(samples.firstIndex { abs($0) > 0.05 }, ext)
            XCTAssertEqual(first, onset, accuracy: 32, "\(ext): onset decoded at \(first)")
            XCTAssertEqual(samples.count, 48_000, accuracy: 1023, "\(ext): under one packet of padding")
        }
    }

    /// The priming the decoder trims is read from an AAC encoder for the
    /// file's own format; for the recorder's settings it is Apple's AAC-LC
    /// 2112 frames (measured: the onset above decodes 2113 samples late
    /// untrimmed). Non-ADTS containers trim nothing here.
    func testADTSPrimingIsTheEncodersAndOtherContainersHaveNone() throws {
        for (ext, expected) in [("aac", 2112), ("caf", 0), ("m4a", 0)] {
            let url = try AACFixture.write(durationSec: 1, fileExtension: ext)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(AudioFileDecoder.adtsPrimingFrames(of: file, at: url), AVAudioFramePosition(expected), ext)
        }
    }

    func testDecodesLegacyM4AToTheLastFrame() throws {
        try assertDecodesFully(fileExtension: "m4a")
    }
}
