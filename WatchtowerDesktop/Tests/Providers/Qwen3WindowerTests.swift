import XCTest
@testable import WatchtowerDesktop

/// Deterministic samples: low-amplitude pseudo-noise so silence-snapping has
/// energy variation to work with, without loading any model.
private func makeSamples(seconds: Double) -> [Float] {
    let n = Int(seconds * Double(TranscriptionConfig.sampleRate))
    var state: UInt64 = 0x9E3779B97F4A7C15
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        out[i] = (Float(state >> 40) / Float(1 << 24) - 0.5) * 0.2
    }
    return out
}

private func batchStream(_ samples: [Float]) -> AsyncStream<[Float]> {
    AsyncStream { c in
        c.yield(samples)
        c.finish()
    }
}

private func pieceStream(_ samples: [Float], pieceSize: Int) -> AsyncStream<[Float]> {
    AsyncStream { c in
        var i = 0
        while i < samples.count {
            let end = min(i + pieceSize, samples.count)
            c.yield(Array(samples[i..<end]))
            i = end
        }
        c.finish()
    }
}

/// `onChunk`/`progress` are `@Sendable`, so they cannot mutate captured locals —
/// collect through a reference sink instead (house pattern: `ChunkSink` in
/// `StreamingTranscriberTests`).
private final class Sink: @unchecked Sendable {
    var chunks: [StreamChunk] = []
    var progress: [[Int]] = []
}

final class Qwen3WindowerTests: XCTestCase {
    private var config: TranscriptionConfig {
        var c = TranscriptionConfig()
        c.windowSec = 2.0          // small windows keep tests fast
        c.overlapSec = 0.2
        c.boundarySnapSec = 0.25
        return c
    }

    /// The windower must cut exactly the windows WindowPlanner plans on the
    /// same samples — the memory bound and the batch/live equivalence both
    /// hang off this.
    func testWindowsMatchPlannerPlan() async throws {
        let samples = makeSamples(seconds: 7.3)
        let planner = WindowPlanner(config: config)
        let planned = planner.planWindows(total: samples.count) { samples[$0] }

        final class Box: @unchecked Sendable { var sizes: [Int] = [] }
        let box = Box()
        let windower = Qwen3Windower(config: config) { window in
            box.sizes.append(window.count)
            return "w"
        }
        _ = try await windower.run(samples: batchStream(samples), windowTotal: planned.count,
                                   progress: { _, _ in }, onChunk: { _ in })
        XCTAssertEqual(box.sizes, planned.map(\.count))
        XCTAssertGreaterThan(planned.count, 1, "test must exercise multiple windows")
    }

    func testBatchEqualsLiveOnSameSamples() async throws {
        let samples = makeSamples(seconds: 7.3)
        func run(_ stream: AsyncStream<[Float]>) async throws -> TranscriptionOutput {
            var n = 0
            let windower = Qwen3Windower(config: config) { window in
                n += 1
                return "w\(n) len\(window.count)"
            }
            return try await windower.run(samples: stream, windowTotal: 0,
                                          progress: { _, _ in }, onChunk: { _ in })
        }
        let batch = try await run(batchStream(samples))
        let live = try await run(pieceStream(samples, pieceSize: 800)) // 50 ms pieces
        XCTAssertEqual(batch, live)
    }

    func testTextJoinSegmentsAndChunks() async throws {
        let samples = makeSamples(seconds: 5.0)
        var n = 0
        let sink = Sink()
        let windower = Qwen3Windower(config: config) { _ in
            n += 1
            return " w\(n) \n"     // whitespace must be trimmed
        }
        let out = try await windower.run(samples: batchStream(samples), windowTotal: 0,
                                         progress: { _, _ in }, onChunk: { sink.chunks.append($0) })

        let planner = WindowPlanner(config: config)
        let planned = planner.planWindows(total: samples.count) { samples[$0] }
        XCTAssertEqual(out.text, (1...planned.count).map { "w\($0)" }.joined(separator: "\n"))
        XCTAssertEqual(out.segments.count, planned.count)
        for (seg, range) in zip(out.segments, planned) {
            XCTAssertEqual(seg.startSec, Double(range.lowerBound) / 16_000, accuracy: 1e-9)
            XCTAssertEqual(seg.endSec, Double(range.upperBound) / 16_000, accuracy: 1e-9)
            XCTAssertEqual(seg.language, "auto")
        }
        XCTAssertEqual(out.langStats, [:])
        XCTAssertEqual(sink.chunks.map(\.index), Array(1...planned.count))
        XCTAssertEqual(sink.chunks.map(\.text), (1...planned.count).map { "w\($0)" })
        XCTAssertEqual(Set(sink.chunks.map(\.language)), ["auto"])
    }

    func testForcedLanguageLabelsAndStats() async throws {
        var c = config
        c.forcedLanguage = "ru"
        let samples = makeSamples(seconds: 5.0)
        let windower = Qwen3Windower(config: c) { _ in "text" }
        let out = try await windower.run(samples: batchStream(samples), windowTotal: 0,
                                         progress: { _, _ in }, onChunk: { _ in })
        XCTAssertFalse(out.segments.isEmpty)
        XCTAssertEqual(Set(out.segments.map(\.language)), ["ru"])
        XCTAssertEqual(out.langStats, ["ru": out.segments.count])
    }

    /// Valid-but-degenerate input: silent windows (empty decode) are dropped
    /// from text/segments/chunks and chunk indices stay contiguous.
    func testEmptyWindowsDropped() async throws {
        let samples = makeSamples(seconds: 7.3)
        var n = 0
        let sink = Sink()
        let windower = Qwen3Windower(config: config) { _ in
            n += 1
            return n == 2 ? "   " : "w\(n)"
        }
        let out = try await windower.run(samples: batchStream(samples), windowTotal: 0,
                                         progress: { _, _ in }, onChunk: { sink.chunks.append($0) })
        XCTAssertFalse(out.text.contains("w2"))
        XCTAssertGreaterThanOrEqual(n, 3)
        XCTAssertEqual(sink.chunks.map(\.index), Array(1...sink.chunks.count), "indices must stay contiguous")
        XCTAssertEqual(out.segments.count, sink.chunks.count)
    }

    func testAllWindowsFailedThrows() async {
        struct DecodeError: Error {}
        let samples = makeSamples(seconds: 5.0)
        let windower = Qwen3Windower(config: config) { _ in throw DecodeError() }
        do {
            _ = try await windower.run(samples: batchStream(samples), windowTotal: 0,
                                       progress: { _, _ in }, onChunk: { _ in })
            XCTFail("expected throw")
        } catch is DecodeError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testPartialFailureReturnsPartialText() async throws {
        struct DecodeError: Error {}
        let samples = makeSamples(seconds: 7.3)
        var n = 0
        let windower = Qwen3Windower(config: config) { _ in
            n += 1
            if n == 1 { throw DecodeError() }
            return "w\(n)"
        }
        let out = try await windower.run(samples: batchStream(samples), windowTotal: 0,
                                         progress: { _, _ in }, onChunk: { _ in })
        XCTAssertFalse(out.text.isEmpty)
        XCTAssertFalse(out.text.contains("w1"))
    }

    /// Progress mirrors WindowedTranscriber: fires after EVERY window,
    /// including failed/silent ones, as (done, windowTotal-passed-through).
    func testProgressCountsEveryWindow() async throws {
        let samples = makeSamples(seconds: 7.3)
        let planner = WindowPlanner(config: config)
        let total = planner.planWindows(total: samples.count) { samples[$0] }.count
        let sink = Sink()
        var n = 0
        let windower = Qwen3Windower(config: config) { _ in
            n += 1
            return n == 1 ? "" : "w"   // first window silent — still counted
        }
        _ = try await windower.run(samples: batchStream(samples), windowTotal: total,
                                   progress: { sink.progress.append([$0, $1]) }, onChunk: { _ in })
        XCTAssertEqual(sink.progress, (1...total).map { [$0, total] })
    }

    func testEmptyInputReturnsEmptyOutput() async throws {
        let windower = Qwen3Windower(config: config) { _ in
            XCTFail("decode must not be called")
            return ""
        }
        let out = try await windower.run(samples: batchStream([]), windowTotal: 0,
                                         progress: { _, _ in }, onChunk: { _ in })
        XCTAssertEqual(out, TranscriptionOutput(text: "", langStats: [:]))
    }

    /// Cancelling mid-run returns promptly with the partial output instead of
    /// decoding the remaining backlog (mirrors StreamingTranscriber semantics).
    func testCancellationStopsFurtherDecodes() async throws {
        let samples = makeSamples(seconds: 12.0)   // several windows
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let cfg = config
        let task = Task { () -> TranscriptionOutput in
            let windower = Qwen3Windower(config: cfg) { _ in
                counter.n += 1
                return "w"
            }
            return try await windower.run(
                samples: batchStream(samples), windowTotal: 0,
                progress: { _, _ in },
                onChunk: { chunk in
                    if chunk.index == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        let out = try await task.value
        XCTAssertEqual(counter.n, 1, "no further windows may be decoded after cancel")
        XCTAssertEqual(out.segments.count, 1)
    }
}
