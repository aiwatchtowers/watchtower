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

    /// `extraPackets`: how many packets past the written length the decode
    /// may run. ADTS carries no priming/remainder info, so its decode keeps
    /// the encoder's 2112-frame priming and the last packet's padding.
    private func assertDecodesFully(fileExtension: String, extraPackets: Int = 2) throws {
        let url = try AACFixture.write(durationSec: durationSec, fileExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioFileDecoder.decodePCM16k(url: url)

        // AAC priming/remainder trims a few packets; expect within one packet
        // (1024 frames) of the written length, and definitely not near-empty.
        let expected = Int(sampleRate * durationSec)
        XCTAssertGreaterThan(samples.count, expected - 2 * 1024, "decoded far fewer samples than written")
        XCTAssertLessThan(samples.count, expected + extraPackets * 1024, "decoded more samples than written")
        let peak = samples.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "decoded audio is silent — data lost")
    }

    func testDecodesAACInCAFToTheLastFrame() throws {
        try assertDecodesFully(fileExtension: "caf")
    }

    func testDecodesADTSToTheLastFrame() throws {
        try assertDecodesFully(fileExtension: "aac", extraPackets: 4)
    }

    func testDecodesLegacyM4AToTheLastFrame() throws {
        try assertDecodesFully(fileExtension: "m4a")
    }
}
