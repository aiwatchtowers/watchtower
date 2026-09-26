# Qwen3 Windowed Transcription (batch + live) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound Qwen3 transcription memory by decoding in WindowPlanner windows, and enable live transcription for the Qwen3 engine through the same single code path.

**Architecture:** A new Qwen3-private `Qwen3Windower` mirrors `StreamingTranscriber`'s buffer/boundary loop over the shared `WindowPlanner`, decoding each window with an injected synchronous closure. Batch feeds the windower a single-yield `AsyncStream`; live feeds it the recorder's real stream — batch↔live equivalence holds by construction. The Whisper-internal stack (`WindowedTranscriber`/`StreamingTranscriber`/`resolveWindowLanguage` and their pin test) is not touched.

**Tech Stack:** Swift 5.10 (SwiftPM package `WatchtowerDesktop`), XCTest, speech-swift 0.0.7 (`Qwen3ASRModel`), existing `WindowPlanner`/`TranscriptionConfig`/`StreamChunk` types.

**Spec:** `docs/superpowers/specs/2026-07-30-qwen3-windowed-transcription-design.md`

## Global Constraints

- Swift language mode 5.10, macOS 14 floor; build with a Swift 6+ toolchain (Xcode 16+).
- Do NOT modify `WindowedTranscriber.swift`, `StreamingTranscriber.swift`, `WindowPlanner.swift`, or `StreamingTranscriberTests` — they are Whisper-internal per CLAUDE.md.
- speech-swift stays pinned to 0.0.7; no new package dependencies (no SileroVAD).
- No test may load the real Qwen3 model or touch MLX/Metal — `swift test` must pass on a machine without `mlx.metallib`.
- Error semantics: a failed window is skipped and remembered; throw only if EVERY window failed; cooperative cancellation via `Task.isCancelled` returns partial output without throwing.
- Language: `forcedLanguage` set → hint every window, `langStats[forced] = speechWindowCount`; else `nil` (model auto-detects), `langStats` empty, segment language label `"auto"`.
- All commits: English messages, `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.
- Run all commands from the worktree root `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/qwen3-windowed` (Swift commands from its `WatchtowerDesktop/` subdir). Never `cd` to the main checkout; verify `git branch --show-current` prints `worktree-qwen3-windowed` before committing.

---

### Task 1: Qwen3Windower core

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/Providers/Qwen3Windower.swift`
- Test (create): `WatchtowerDesktop/Tests/Providers/Qwen3WindowerTests.swift`

**Interfaces:**
- Consumes: `WindowPlanner(config:)`, `.nextRange(start:total:isFinal:sample:)`, `.nextStart(after:)`, `.isLastWindow(start:total:)` (all existing, `WindowPlanner.swift`); `TranscriptionConfig` (`windowSec`, `overlapSec`, `boundarySnapSec`, `forcedLanguage`, `TranscriptionConfig.sampleRate == 16_000`); `TranscriptSegment(text:startSec:endSec:language:)`; `TranscriptionOutput(text:langStats:segments:)`; `StreamChunk(index:text:language:)` (internal type in `StreamingTranscriber.swift`).
- Produces: `struct Qwen3Windower { init(config: TranscriptionConfig, decode: @escaping ([Float]) throws -> String); func run(samples: AsyncStream<[Float]>, windowTotal: Int, progress: @escaping @Sendable (Int, Int) -> Void, onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput }` — Task 2 wraps this for both batch and live.

- [ ] **Step 1: Write the failing tests**

Create `WatchtowerDesktop/Tests/Providers/Qwen3WindowerTests.swift`:

```swift
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
```

Note: `decode` is a plain (non-`@Sendable`) closure invoked synchronously inside `run`, so it may capture and mutate a local `var n`. `progress`/`onChunk` ARE `@Sendable` and must go through the `Sink` reference class — mutating a captured local from a `@Sendable` closure is a compile error.

- [ ] **Step 2: Run tests to verify they fail to compile (no Qwen3Windower yet)**

```bash
cd /Users/user/PhpstormProjects/watchtower/.claude/worktrees/qwen3-windowed/WatchtowerDesktop
swift test --filter Qwen3WindowerTests > /tmp/qwen3windower-red.log 2>&1; echo "exit=$?"
```
Expected: `exit=1`, log contains `cannot find 'Qwen3Windower' in scope`. Check the log with Read/grep, never pipe the build through `tail` alone.

- [ ] **Step 3: Implement Qwen3Windower**

Create `WatchtowerDesktop/Sources/Services/Transcription/Providers/Qwen3Windower.swift`:

```swift
import Foundation

/// Qwen3-private windowed decode loop: cuts the recording into WindowPlanner
/// windows (same silence-snapped boundaries the Whisper stack uses) and decodes
/// each window with the injected closure, so peak memory is bounded by one
/// window instead of the whole clip. Batch and live both run THIS loop — batch
/// wraps the full buffer in a single-yield stream — so their outputs are
/// identical by construction rather than by a pinned invariant.
///
/// Deliberately NOT the Whisper stack: WindowedTranscriber/StreamingTranscriber
/// are Whisper-internal (sticky language detection Qwen3 cannot feed). Qwen3
/// exposes no language detection, so segments are labeled with the forced
/// language or "auto", and langStats is populated only when a language is
/// forced.
///
/// Error semantics mirror StreamingTranscriber: a window whose decode throws is
/// skipped and remembered, the run throws only when every window failed, and a
/// cancelled run returns its partial output promptly.
struct Qwen3Windower {
    let config: TranscriptionConfig
    /// Synchronous whole-window decode (production: `Qwen3ASRModel.transcribe`,
    /// a blocking MLX call; tests: a fake). Called serially, never concurrently.
    let decode: ([Float]) throws -> String

    init(config: TranscriptionConfig, decode: @escaping ([Float]) throws -> String) {
        self.config = config
        self.decode = decode
    }

    /// `windowTotal` is the pre-planned window count batch passes through to
    /// `progress` (0 when unknown, i.e. live). `progress` fires after every
    /// window including silent/failed ones, mirroring WindowedTranscriber.
    func run(samples: AsyncStream<[Float]>,
             windowTotal: Int,
             progress: @escaping @Sendable (Int, Int) -> Void,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput {
        let planner = WindowPlanner(config: config)
        let label = config.forcedLanguage ?? "auto"

        var buffer: [Float] = []      // buffer[0] is absolute sample `consumedBase`
        var consumedBase = 0
        var absStart = 0

        var texts: [String] = []
        var segments: [TranscriptSegment] = []
        var lastDecodeError: Error?
        var chunkIndex = 0
        var processed = 0

        func process(window: [Float], windowStart: Int) {
            processed += 1
            defer { progress(processed, windowTotal) }
            let text: String
            do {
                text = try decode(window)
            } catch {
                lastDecodeError = error
                return // skipped: not in text/segments, chunk indices stay contiguous
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return } // silent window
            let rate = Double(TranscriptionConfig.sampleRate)
            texts.append(trimmed)
            segments.append(TranscriptSegment(text: trimmed,
                                              startSec: Double(windowStart) / rate,
                                              endSec: Double(windowStart + window.count) / rate,
                                              language: label))
            chunkIndex += 1
            onChunk(StreamChunk(index: chunkIndex, text: trimmed, language: label))
        }

        // Decodes the window and drops consumed samples from the buffer.
        func emit(_ range: Range<Int>) {
            let window = Array(buffer[(range.lowerBound - consumedBase)..<(range.upperBound - consumedBase)])
            process(window: window, windowStart: range.lowerBound)
            absStart = planner.nextStart(after: range)
            let drop = absStart - consumedBase
            if drop > 0 {
                buffer.removeFirst(min(drop, buffer.count))
                consumedBase += drop
            }
        }

        for await piece in samples {
            if Task.isCancelled { break }
            buffer.append(contentsOf: piece)
            while let range = planner.nextRange(
                start: absStart,
                total: consumedBase + buffer.count,
                isFinal: false,
                sample: { buffer[$0 - consumedBase] }
            ) {
                if Task.isCancelled { break }
                emit(range)
            }
            if Task.isCancelled { break }
        }

        // Stream closed: the total is final; the remainder can still hold
        // several windows (snapped cuts land short of nominal ends).
        while !Task.isCancelled,
              let range = planner.nextRange(
                  start: absStart,
                  total: consumedBase + buffer.count,
                  isFinal: true,
                  sample: { buffer[$0 - consumedBase] }
              ) {
            let isLast = planner.isLastWindow(start: range.lowerBound, total: consumedBase + buffer.count)
            emit(range)
            if isLast { break }
        }

        if texts.isEmpty, let lastDecodeError {
            throw lastDecodeError
        }
        var langStats: [String: Int] = [:]
        if let forced = config.forcedLanguage, !texts.isEmpty {
            langStats[forced] = texts.count
        }
        return TranscriptionOutput(text: texts.joined(separator: "\n"),
                                   langStats: langStats,
                                   segments: segments)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter Qwen3WindowerTests > /tmp/qwen3windower-green.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`, all Qwen3WindowerTests pass. If `testCancellationStopsFurtherDecodes` proves flaky (it should not — cancellation is checked synchronously before each window), investigate rather than delete or loosen it.

- [ ] **Step 5: Commit**

```bash
cd /Users/user/PhpstormProjects/watchtower/.claude/worktrees/qwen3-windowed
git add WatchtowerDesktop/Sources/Services/Transcription/Providers/Qwen3Windower.swift WatchtowerDesktop/Tests/Providers/Qwen3WindowerTests.swift
git commit -m "feat(desktop): Qwen3Windower — windowed decode loop over WindowPlanner

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Wire the windower into Qwen3Provider (batch + live)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/Providers/Qwen3Provider.swift` (whole `Qwen3Transcriber` class + `supportsLive` + doc headers)
- Test (modify): `WatchtowerDesktop/Tests/Providers/Qwen3ProviderTests.swift`

**Interfaces:**
- Consumes: `Qwen3Windower(config:decode:)` and `.run(samples:windowTotal:progress:onChunk:)` from Task 1; `Qwen3ASRModel.transcribe(audio:sampleRate:language:maxTokens:context:)` (speech-swift, blocking, returns `String`); `WindowPlanner.planWindows(total:sample:)`; `TranscriptionLiveSession` protocol (`run(samples:onChunk:) async throws -> TranscriptionOutput`).
- Produces: `Qwen3Provider.supportsLive == true`; `Qwen3Transcriber.makeLiveSession(config:)` returns a non-nil `Qwen3LiveSession` — `MeetingRecorderCenter` (line ~244) starts live automatically on non-nil, `RecordingIndicatorView` shows the panel off `supportsLive`; no signature changes to `Transcriber`.

- [ ] **Step 1: Update the provider test (failing first)**

In `WatchtowerDesktop/Tests/Providers/Qwen3ProviderTests.swift`, replace the `supportsLive` assertion inside `testMetadata` and add a live-session test:

```swift
    func testMetadata() throws {
        let p = Qwen3Provider()
        XCTAssertEqual(type(of: p).id, "qwen3")
        XCTAssertTrue(p.supportsLive)
        if Qwen3Provider.isAppleSilicon {
            XCTAssertEqual(p.availability(), .available)
        } else {
            XCTAssertEqual(p.availability(), .unavailable(reason: "Requires Apple Silicon"))
        }
        let langs = p.supportedLanguages(model: "Qwen3-ASR-0.6B")
        XCTAssertNotNil(langs)
        XCTAssertTrue(try XCTUnwrap(langs).isSuperset(of: ["ru", "uk", "en"]))
    }
```

(`testRegistered` stays unchanged. No test constructs `Qwen3Transcriber` — that would need a loaded `Qwen3ASRModel`, which tests must not load; the windower behavior is already covered by Task 1's tests.)

- [ ] **Step 2: Run to verify the changed assertion fails**

```bash
cd /Users/user/PhpstormProjects/watchtower/.claude/worktrees/qwen3-windowed/WatchtowerDesktop
swift test --filter Qwen3ProviderTests > /tmp/qwen3provider-red.log 2>&1; echo "exit=$?"
```
Expected: `exit=1`, `testMetadata` fails on `XCTAssertTrue(p.supportsLive)`.

- [ ] **Step 3: Rewire the provider**

In `WatchtowerDesktop/Sources/Services/Transcription/Providers/Qwen3Provider.swift`:

(a) Flip `supportsLive` on `Qwen3Provider`:

```swift
    var supportsLive: Bool { true }
```

(b) Update the file-header doc comment: replace the sentence "Batch-only — the package's public `Qwen3ASRModel.transcribe` call is a plain synchronous batch API with no streaming/session surface, so `supportsLive` is false and `makeLiveSession` always returns nil." with:

```swift
/// to the pluggable `TranscriptionProvider` contract. The package's public
/// `Qwen3ASRModel.transcribe` is a plain synchronous whole-buffer call whose
/// memory grows with clip length (~0.6 GB GPU peak per audio minute), so both
/// batch and live decode through `Qwen3Windower` — WindowPlanner windows,
/// one bounded `transcribe` call each. Live input is our own loop (speech-swift
/// 0.0.7 has no live-input API; its StreamingASR takes a complete buffer).
```

(c) Replace the whole `Qwen3Transcriber` class (and its doc comment) at the bottom of the file with:

```swift
/// Wraps a loaded `Qwen3ASRModel` behind `Qwen3Windower`: batch wraps the full
/// buffer in a single-yield stream, live runs the recorder's real stream —
/// one code path, so batch and live cannot drift. Each ~20 s window is one
/// bounded `transcribe` call instead of the whole clip in one shot.
/// `@unchecked Sendable` is sound here: one instance is created per recording,
/// decode calls are serial inside one windower run, never shared concurrently
/// (same single-use invariant as `WhisperKitEngine`; the Qwen3 model is
/// documented upstream as not thread-safe, which this usage respects).
final class Qwen3Transcriber: Transcriber, @unchecked Sendable {
    private let model: Qwen3ASRModel
    init(model: Qwen3ASRModel) { self.model = model }

    private func windower(config: TranscriptionConfig) -> Qwen3Windower {
        let model = self.model
        let forced = config.forcedLanguage
        // `transcribe` strips any auto-detected "language XX" prefix internally
        // (see the package's `generateText`), so with no forced language the
        // model auto-detects per window and no tag reaches the text.
        return Qwen3Windower(config: config) { window in
            model.transcribe(audio: window, sampleRate: 16_000, language: forced)
        }
    }

    func transcribe(
        _ samples: [Float],
        config: TranscriptionConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> TranscriptionOutput {
        let planner = WindowPlanner(config: config)
        let total = planner.planWindows(total: samples.count) { samples[$0] }.count
        let stream = AsyncStream<[Float]> { continuation in
            continuation.yield(samples)
            continuation.finish()
        }
        return try await windower(config: config)
            .run(samples: stream, windowTotal: total, progress: progress, onChunk: { _ in })
    }

    func makeLiveSession(config: TranscriptionConfig) -> TranscriptionLiveSession? {
        Qwen3LiveSession(windower: windower(config: config))
    }
}

/// Live session over the same windower (see `Qwen3Transcriber` for the
/// single-use `@unchecked Sendable` justification).
final class Qwen3LiveSession: TranscriptionLiveSession, @unchecked Sendable {
    let windower: Qwen3Windower
    init(windower: Qwen3Windower) { self.windower = windower }

    func run(samples: AsyncStream<[Float]>,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput {
        try await windower.run(samples: samples, windowTotal: 0, progress: { _, _ in }, onChunk: onChunk)
    }
}
```

Note: `Qwen3ASRModel.transcribe(audio:sampleRate:language:maxTokens:context:)` — `language` and the rest have defaults, so `model.transcribe(audio: window, sampleRate: 16_000, language: forced)` compiles with `forced == nil` meaning auto-detect.

- [ ] **Step 4: Run provider + windower tests, then the full suite**

```bash
swift test --filter 'Qwen3' > /tmp/qwen3-wired.log 2>&1; echo "exit=$?"
swift build > /tmp/qwen3-build.log 2>&1; echo "exit=$?"
```
Expected: both `exit=0`. Then the full suite (regression gate — StreamingTranscriber pin tests must stay green):

```bash
swift test > /tmp/qwen3-fullsuite.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`. If FluidAudio-dependent tests misbehave on this machine, check the log against the known-gotchas note in memory (`project_transcriber_snapping_diarization`) before assuming your change broke them.

- [ ] **Step 5: Commit**

```bash
cd /Users/user/PhpstormProjects/watchtower/.claude/worktrees/qwen3-windowed
git add WatchtowerDesktop/Sources/Services/Transcription/Providers/Qwen3Provider.swift WatchtowerDesktop/Tests/Providers/Qwen3ProviderTests.swift
git commit -m "feat(desktop): windowed batch + live transcription for the Qwen3 engine

Qwen3 now decodes in WindowPlanner windows (bounded memory instead of
whole-clip, ~0.6 GB GPU peak per audio minute before) and gains live
transcription through the same Qwen3Windower code path. Windowed output
carries timestamped segments, so the diarization post-pass (speaker roles)
now works for Qwen3 recordings too.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Documentation sync

**Files:**
- Modify: `CLAUDE.md` (Meeting Transcriber section, "Built-in providers" bullet)
- Modify: `docs/app-guide.md` (Settings → General → Transcription bullet)

**Interfaces:**
- Consumes: the shipped behavior from Task 2 (Qwen3 live + windowed batch).
- Produces: docs matching reality; no code.

- [ ] **Step 1: Update CLAUDE.md**

In the "Built-in providers" bullet of the Meeting Transcriber section, make these two edits:

1. The WhisperKit sentence "supportsLive=true — live transcription remains WhisperKit-only for now; its `WindowedTranscriber`/`StreamingTranscriber`/`resolveWindowLanguage` and the live↔batch pin test `StreamingTranscriberTests.testMatchesBatchOnSameSamples` are Whisper-internal" becomes:

```
supportsLive=true — its `WindowedTranscriber`/`StreamingTranscriber`/`resolveWindowLanguage` and the live↔batch pin test `StreamingTranscriberTests.testMatchesBatchOnSameSamples` are Whisper-internal
```

2. The Qwen3 entry "`Qwen3Provider` (soniqo/speech-swift, batch-only, Apple-Silicon-gated)" becomes:

```
`Qwen3Provider` (soniqo/speech-swift, Apple-Silicon-gated; batch AND live both decode through `Qwen3Windower` — WindowPlanner windows over one shared loop, bounded memory, no sticky language: forced hint or per-window auto-detect, segments labeled "auto")
```

Also update the later sentence "Live (in-progress) transcription (WhisperKit only)" to "Live (in-progress) transcription (WhisperKit and Qwen3)".

- [ ] **Step 2: Update docs/app-guide.md**

In the "Settings → General → Transcription" bullet, the sentence listing batch-only engines currently reads "batch-only engines (Apple, Parakeet, Qwen3) showing no live text during recording is expected, not a failure." Change the engine list to "(Apple, Parakeet)" since Qwen3 is no longer batch-only.

- [ ] **Step 3: Verify no stale claims remain**

```bash
cd /Users/user/PhpstormProjects/watchtower/.claude/worktrees/qwen3-windowed
grep -rn "WhisperKit-only\|batch-only" CLAUDE.md docs/app-guide.md
```
Expected: no line still claims live is WhisperKit-only or that Qwen3 is batch-only.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/app-guide.md
git commit -m "docs: Qwen3 engine is windowed and supports live transcription

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
