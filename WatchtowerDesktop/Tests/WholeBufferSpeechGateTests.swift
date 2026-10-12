import XCTest
import WatchtowerCore
@testable import WatchtowerDesktop

/// Records what the whole-buffer engine was handed; returns a canned text.
private final class BufferDecodeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [[Float]] = []
    var decoded: [[Float]] { lock.withLock { inputs } }
    func record(_ samples: [Float]) { lock.withLock { inputs.append(samples) } }
}

/// Spec D5 (board #554): Parakeet and Apple mute everything outside the
/// detected speech before decoding the whole buffer, skip a recording with
/// no speech, and filter the phrase list out of their text.
final class WholeBufferSpeechGateTests: XCTestCase {
    private let rate = TranscriptionConfig.sampleRate

    /// 0–1 s "speech" at 0.3, 1–3 s low noise at 0.001 (below the fake
    /// detector's level), 3–4 s "speech" at 0.2.
    private func noisy() -> [Float] {
        var samples = [Float](repeating: 0.001, count: 4 * rate)
        for i in 0..<rate { samples[i] = 0.3 }
        for i in (3 * rate)..<(4 * rate) { samples[i] = 0.2 }
        return samples
    }

    /// Speech = samples at or above 0.1 (the fake for this suite).
    private final class LoudDetector: SpeechDetector, @unchecked Sendable {
        func speechRanges(in samples: [Float]) async throws -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var start: Int?
            for (i, s) in samples.enumerated() {
                if abs(s) >= 0.1, start == nil { start = i }
                if abs(s) < 0.1, let open = start { ranges.append(open..<i); start = nil }
            }
            if let open = start { ranges.append(open..<samples.count) }
            return ranges
        }
    }

    private func transcribers(_ text: String, log: BufferDecodeLog) -> [(String, Transcriber)] {
        [
            ("parakeet", ParakeetTranscriber(speechDetector: LoudDetector()) { samples in
                log.record(samples)
                return text
            }),
            ("apple", AppleTranscriber(speechDetector: LoudDetector()) { samples, _ in
                log.record(samples)
                return text
            })
        ]
    }

    func testOnlySpeechReachesTheEngine() async throws {
        let log = BufferDecodeLog()
        for (name, transcriber) in transcribers("hello", log: log) {
            let output = try await transcriber.transcribe(noisy(), config: TranscriptionConfig()) { _, _ in }
            let input = try XCTUnwrap(log.decoded.last, name)
            XCTAssertEqual(input.count, 4 * rate, name)
            XCTAssertEqual(Array(input[0..<rate]), [Float](repeating: 0.3, count: rate), "\(name): speech unchanged")
            XCTAssertTrue(input[rate..<(3 * rate)].allSatisfy { $0 == 0 }, "\(name): the gap is muted to exact zeros")
            XCTAssertEqual(Array(input[(3 * rate)...]), [Float](repeating: 0.2, count: rate), name)
            XCTAssertEqual(output.text, "hello", name)
        }
        XCTAssertEqual(log.decoded.count, 2)
    }

    func testPhraseListIsFilteredFromTheirText() async throws {
        for (name, transcriber) in transcribers("Продолжение следует...", log: BufferDecodeLog()) {
            let output = try await transcriber.transcribe(noisy(), config: TranscriptionConfig()) { _, _ in }
            XCTAssertEqual(output.text, "", name)
            XCTAssertEqual(output.langStats, [:], name)
        }
    }

    func testRecordingWithoutSpeechIsNotDecoded() async throws {
        let log = BufferDecodeLog()
        for (name, transcriber) in transcribers("Thanks for watching!", log: log) {
            let output = try await transcriber.transcribe([Float](repeating: 0.001, count: 40 * rate),
                                                          config: TranscriptionConfig()) { _, _ in }
            XCTAssertEqual(output.text, "", name)
        }
        XCTAssertTrue(log.decoded.isEmpty)
    }

    func testGateOffDecodesTheRawBufferAndText() async throws {
        let log = BufferDecodeLog()
        var config = TranscriptionConfig()
        config.speechGate = false
        for (name, transcriber) in transcribers("Продолжение следует...", log: log) {
            let output = try await transcriber.transcribe(noisy(), config: config) { _, _ in }
            XCTAssertEqual(output.text, "Продолжение следует...", name)
        }
        XCTAssertEqual(log.decoded, [noisy(), noisy()], "nothing muted with the kill switch off")
    }

    func testLongRecordingIsDetectedInChunks() async throws {
        // Speech at 45–46 s, in the second 30 s chunk: its offsets must be lifted.
        var samples = [Float](repeating: 0.001, count: 70 * rate)
        for i in (45 * rate)..<(46 * rate) { samples[i] = 0.4 }
        let log = BufferDecodeLog()
        _ = try await ParakeetTranscriber(speechDetector: LoudDetector()) { buffer in
            log.record(buffer)
            return "x"
        }.transcribe(samples, config: TranscriptionConfig()) { _, _ in }
        let input = try XCTUnwrap(log.decoded.first)
        XCTAssertTrue(input[(45 * rate)..<(46 * rate)].allSatisfy { $0 == 0.4 })
        XCTAssertEqual(input.filter { $0 != 0 }.count, rate)
    }
}
