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
            ("apple", AppleTranscriber(speechDetector: LoudDetector()) { audio, _ in
                log.record(audio.muted())
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

    func testWordAcrossAChunkSeamIsKept() async throws {
        // Board #564: 0.4 s of speech at 29.8–30.2 s. Cut at the 30 s seam,
        // each piece (0.2 s) is under the detector's minimum speech; the
        // overlapping chunk sees it whole.
        var samples = [Float](repeating: 0.001, count: 60 * rate)
        let word = (29 * rate + rate * 8 / 10)..<(30 * rate + rate * 2 / 10)
        for i in word { samples[i] = 0.4 }
        let log = BufferDecodeLog()
        _ = try await ParakeetTranscriber(speechDetector: MinimumSpeechDetector()) { buffer in
            log.record(buffer)
            return "x"
        }.transcribe(samples, config: TranscriptionConfig()) { _, _ in }
        let input = try XCTUnwrap(log.decoded.first, "the word is speech: the recording is decoded")
        XCTAssertTrue(input[word].allSatisfy { $0 == 0.4 }, "the word reaches the engine unmuted")
    }

    /// Every chunk length it was asked about; speech = the loud samples.
    private final class ChunkLog: SpeechDetector, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [Int] = []
        var lengths: [Int] { lock.withLock { asked } }
        func speechRanges(in samples: [Float]) async throws -> [Range<Int>] {
            lock.withLock { asked.append(samples.count) }
            return try await LoudDetector().speechRanges(in: samples)
        }
    }

    func testChunkBoundaries() async {
        // 30 s chunks stepping 28 s; the last chunk ends at the recording's end.
        let second = rate
        let cases: [(samples: Int, chunks: [Int])] = [
            (1, [1]),
            (30 * second, [30 * second]),
            (58 * second, [30 * second, 30 * second]),
            (58 * second + 1, [30 * second, 30 * second, 2 * second + 1])
        ]
        for (count, chunks) in cases {
            let detector = ChunkLog()
            _ = await speechOnlyBuffer([Float](repeating: 0.001, count: count), detector: detector,
                                       config: TranscriptionConfig())
            XCTAssertEqual(detector.lengths, chunks, "\(count) samples")
        }
    }

    func testMultiChunkAllSpeechRecordingIsNotCopied() async throws {
        // 45 s of speech: two chunks whose ranges only cover the whole
        // recording once merged.
        let samples = [Float](repeating: 0.3, count: 45 * rate)
        let (audio, _) = await speechOnlyBuffer(samples, detector: ChunkLog(), config: TranscriptionConfig())
        let speech = try XCTUnwrap(audio)
        XCTAssertNil(speech.speech, "nothing to mute")
        XCTAssertEqual(baseAddress(speech.muted()), baseAddress(samples), "nothing copied")
    }

    /// `LoudDetector` with Silero's segmentation rules that matter at a
    /// seam: a run shorter than 0.3 s is not speech, and every window with
    /// under 0.3 s of speech is silent.
    private final class MinimumSpeechDetector: SpeechDetector, @unchecked Sendable {
        func speechRanges(in samples: [Float]) async throws -> [Range<Int>] {
            let minimum = Int(0.3 * Double(TranscriptionConfig.sampleRate))
            return try await LoudDetector().speechRanges(in: samples).filter { $0.count >= minimum }
        }
    }

    // MARK: Memory (board #564)

    private func baseAddress(_ samples: [Float]) -> UnsafeRawPointer? {
        samples.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    func testAppleGetsTheRecordingItselfAndMutesIntoItsPCMBuffer() async throws {
        // No muted copy of the recording besides the analyzer's own PCM
        // buffer: the decode is handed the caller's samples (same storage)
        // and the speech ranges, and the PCM copy mutes on the way.
        let samples = noisy()
        final class Box: @unchecked Sendable { var audio: SpeechOnlyAudio? }
        let box = Box()
        _ = try await AppleTranscriber(speechDetector: LoudDetector()) { audio, _ in
            box.audio = audio
            return "x"
        }.transcribe(samples, config: TranscriptionConfig()) { _, _ in }
        let audio = try XCTUnwrap(box.audio)
        XCTAssertEqual(baseAddress(audio.samples), baseAddress(samples), "the recording is not copied")
        XCTAssertEqual(audio.speech, [0..<rate, (3 * rate)..<(4 * rate)])

        let buffer = try AppleTranscriber.makePCMBuffer(audio: audio)
        let channel = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0],
                                                count: Int(buffer.frameLength)))
        XCTAssertEqual(channel, audio.muted(), "the PCM buffer holds the muted recording")
    }

    func testAllSpeechRecordingIsNotCopied() async throws {
        let samples = [Float](repeating: 0.3, count: 2 * rate)
        final class Box: @unchecked Sendable { var decoded: [Float]? }
        let box = Box()
        _ = try await ParakeetTranscriber(speechDetector: LoudDetector()) { input in
            box.decoded = input
            return "x"
        }.transcribe(samples, config: TranscriptionConfig()) { _, _ in }
        let decoded = try XCTUnwrap(box.decoded)
        XCTAssertEqual(baseAddress(decoded), baseAddress(samples), "nothing to mute, nothing copied")
    }
}
