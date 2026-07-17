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

    /// Writes a sine wave through the same AAC writer settings SystemAudioRecorder uses.
    private func writeAACFixture(fileExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decoder-fixture-\(UUID().uuidString).\(fileExtension)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * durationSec)
        ), let data = buffer.floatChannelData else {
            XCTFail("fixture allocation failed")
            throw AudioFileDecoderError.unsupportedFormat
        }
        let frames = Int(sampleRate * durationSec)
        for i in 0..<frames {
            data[0][i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
        return url
    }

    private func assertDecodesFully(fileExtension: String) throws {
        let url = try writeAACFixture(fileExtension: fileExtension)
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

    func testDecodesLegacyM4AToTheLastFrame() throws {
        try assertDecodesFully(fileExtension: "m4a")
    }
}
