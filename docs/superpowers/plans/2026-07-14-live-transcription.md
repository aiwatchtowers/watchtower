# Live (in-progress) Meeting Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transcribe a meeting *while it is still recording* — full-size 20 s windows processed as audio arrives, chunks shown live so the user can watch quality; single-pass (what is shown is what is saved).

**Architecture:** A new `StreamingTranscriber` consumes a live 16 kHz PCM sample stream tapped from `SystemAudioRecorder` (already produced in that format) and emits finished chunks. `MeetingRecorderCenter` loads the engine once at record-start, drives the live pass, and on stop saves the live result directly (no re-decode). The existing batch path (`WindowedTranscriber` over the decoded file) stays intact as the fallback and the crash-recovery/retry path — the `.caf` file remains the source of truth.

**Tech Stack:** Swift 5.10, SwiftUI, `@Observable`, `AsyncStream`, WhisperKit (0.18.x) behind the injectable `TranscriptionEngine` seam, XCTest.

## Global Constraints

- Desktop app: macOS 14+ (SwiftUI, Swift 5.10); the recorder tap path is macOS 14.4+ (`SystemAudioRecorder` already availability-gates this).
- All new units are tested WITHOUT CoreAudio or WhisperKit — the recorder, engine, and decode step are injected seams, exactly as in the existing `MeetingRecorderCenterTests`.
- The live pass is a Swift-side accelerator only. NO changes to persistence, crash recovery, retry, `meeting_transcripts`, the Go/CLI side, or `docs/inventory/`.
- The live pass never surfaces an error mid-meeting: engine-load or streaming failure silently drops to the stop-time batch fallback (spec §5).
- The model is whatever `transcription.model` UserDefaults holds (default `large-v3`); do NOT force turbo.
- Do NOT modify existing `WindowedTranscriberTests` or `MeetingRecorderCenterTests` assertions — the engine-reuse-on-start design (Task 4) is specifically shaped to keep them green. If a change seems to require relaxing one, stop and ask the owner (CLAUDE.md rule).
- Verify with real exit codes; run Swift tests as `cd WatchtowerDesktop && swift test 2>&1 | tee /tmp/swift-test.log` and check `${PIPESTATUS[0]}` / grep the log — never judge by a tail.

---

### Task 1: Extract shared window-language resolution

`WindowedTranscriber.chooseLanguage` is the non-trivial sticky-language logic. `StreamingTranscriber` (Task 2) needs the identical logic. Extract it to a free function both call, so the two paths cannot drift. This is a pure refactor: the existing `WindowedTranscriberTests` are the characterization tests and must stay green unchanged.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/TranscriptionEngine.swift` (add the free function at file end)
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/WindowedTranscriber.swift:88-102` (delete the private method, call the shared function)
- Test: `WatchtowerDesktop/Tests/WindowedTranscriberTests.swift` (unchanged — run to confirm green)

**Interfaces:**
- Produces: `func resolveWindowLanguage(for window: [Float], previous: String?, config: TranscriptionConfig, engine: TranscriptionEngine) async -> String` — sticky-fallback language selection; a detection error is treated as low confidence (fallback), never fatal. Callers pass `config.forcedLanguage` handling themselves (the function is only called when `forcedLanguage == nil`).

- [ ] **Step 1: Add the shared function**

Append to `TranscriptionEngine.swift`:

```swift
/// Detection with sticky fallback, shared by WindowedTranscriber (batch) and
/// StreamingTranscriber (live) so their language selection cannot drift. A
/// detection error is treated as low confidence (fallback), never fatal.
/// Only called when `config.forcedLanguage == nil`.
func resolveWindowLanguage(
    for window: [Float],
    previous: String?,
    config: TranscriptionConfig,
    engine: TranscriptionEngine
) async -> String {
    let fallback = previous ?? config.firstWindowDefault
    guard let probs = try? await engine.detectLanguage(window) else {
        return fallback
    }
    let restricted = probs
        .filter { config.langset.contains($0.key) }
        .sorted { $0.value > $1.value }
    guard let best = restricted.first else { return fallback }
    let runnerUp = restricted.dropFirst().first?.value ?? 0
    if best.value >= config.langThreshold && (best.value - runnerUp) >= config.margin {
        return best.key
    }
    return fallback
}
```

- [ ] **Step 2: Point WindowedTranscriber at it**

In `WindowedTranscriber.swift`, delete the private `chooseLanguage(for:previous:)` method (lines ~86-102) and change its call site (line ~54):

```swift
            } else {
                language = await resolveWindowLanguage(for: window, previous: prevLang, config: config, engine: engine)
            }
```

- [ ] **Step 3: Build and run the existing transcriber tests**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/b.log; echo "build:${PIPESTATUS[0]}"`
Then: `swift test --filter WindowedTranscriberTests 2>&1 | tee /tmp/t.log; echo "test:${PIPESTATUS[0]}"`
Expected: build 0, test 0, all `WindowedTranscriberTests` pass unchanged.

- [ ] **Step 4: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/Transcription/TranscriptionEngine.swift WatchtowerDesktop/Sources/Services/Transcription/WindowedTranscriber.swift
git commit -m "refactor(transcriber): extract shared resolveWindowLanguage

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `StreamingTranscriber`

Consumes an `AsyncStream<[Float]>` of 16 kHz mono samples, cuts the **same windows** as `WindowedTranscriber` (same window/step math, same "exact-window-length is one window" rule), processes each full window as it becomes available, emits finished (speech) chunks, and on stream close finalizes the truncated tail. Returns the same `TranscriptionOutput`. Total engine failure (no speech + an error) throws, matching batch.

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/StreamingTranscriber.swift`
- Test: `WatchtowerDesktop/Tests/StreamingTranscriberTests.swift`

**Interfaces:**
- Consumes: `resolveWindowLanguage(...)` (Task 1); `TranscriptionEngine`, `TranscriptionConfig`, `TranscriptionOutput` (existing).
- Produces:
  - `struct StreamChunk: Equatable, Sendable { let index: Int; let text: String; let language: String }` (`index` 1-based over speech chunks).
  - `struct StreamingTranscriber { let engine: TranscriptionEngine; let config: TranscriptionConfig; func run(samples: AsyncStream<[Float]>, onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput }`

- [ ] **Step 1: Write the failing tests**

Create `StreamingTranscriberTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

/// Records forced languages + window sizes; returns canned texts in call order.
private final class MockEngine: TranscriptionEngine, @unchecked Sendable {
    var texts: [Result<String, Error>] = []
    var detections: [[String: Float]] = []
    struct MockError: Error {}
    private(set) var transcribedLanguages: [String] = []
    private(set) var windowSizes: [Int] = []
    private var detectIdx = 0

    func detectLanguage(_ samples: [Float]) async throws -> [String: Float] {
        defer { detectIdx += 1 }
        return detectIdx < detections.count ? detections[detectIdx] : [:]
    }
    func transcribeWindow(_ samples: [Float], language: String) async throws -> String {
        windowSizes.append(samples.count)
        transcribedLanguages.append(language)
        let idx = transcribedLanguages.count - 1
        return idx < texts.count ? try texts[idx].get() : ""
    }
}

private final class ChunkSink: @unchecked Sendable {
    private(set) var chunks: [StreamChunk] = []
    func record(_ c: StreamChunk) { chunks.append(c) }
}

final class StreamingTranscriberTests: XCTestCase {

    private func forcedConfig(windowSec: Double = 0.1, overlapSec: Double = 0) -> TranscriptionConfig {
        var c = TranscriptionConfig()
        c.windowSec = windowSec
        c.overlapSec = overlapSec
        c.forcedLanguage = "en"
        return c
    }

    /// Pushes `samples` into a fresh AsyncStream in `pieceSize`-sample pieces, then finishes.
    private func stream(of samples: [Float], pieceSize: Int) -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            var i = 0
            while i < samples.count {
                let end = min(i + pieceSize, samples.count)
                continuation.yield(Array(samples[i..<end]))
                i = end
            }
            continuation.finish()
        }
    }

    // 0.1 s window @ 16 kHz = 1600 samples.
    func testThreeFullWindowsPlusTail() async throws {
        let engine = MockEngine()
        engine.texts = [.success("a"), .success("b"), .success("c")]
        let sink = ChunkSink()
        let transcriber = StreamingTranscriber(engine: engine, config: forcedConfig())
        // 3.5 windows = 5600 samples, pushed in ragged 700-sample pieces.
        let output = try await transcriber.run(samples: stream(of: [Float](repeating: 0, count: 5600), pieceSize: 700)) {
            sink.record($0)
        }
        XCTAssertEqual(engine.windowSizes, [1600, 1600, 1600, 800]) // 3 full + 800 tail
        XCTAssertEqual(output.text, "a\nb\nc") // 4th window past texts → ""
        XCTAssertEqual(output.langStats, ["en": 3])
        XCTAssertEqual(sink.chunks.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(sink.chunks.map(\.index), [1, 2, 3])
    }

    func testMatchesBatchOnSameSamples() async throws {
        // Equivalence with WindowedTranscriber: same samples, same scripting → same output.
        let samples = [Float](repeating: 0, count: 5600)
        let cfg = forcedConfig()

        let batchEngine = MockEngine()
        batchEngine.texts = [.success("a"), .success("b"), .success("c"), .success("d")]
        let batchOut = try await WindowedTranscriber(engine: batchEngine, config: cfg)
            .transcribe(samples: samples) { _, _ in }

        let streamEngine = MockEngine()
        streamEngine.texts = [.success("a"), .success("b"), .success("c"), .success("d")]
        let streamOut = try await StreamingTranscriber(engine: streamEngine, config: cfg)
            .run(samples: stream(of: samples, pieceSize: 333)) { _ in }

        XCTAssertEqual(streamOut, batchOut)
        XCTAssertEqual(streamEngine.windowSizes, batchEngine.windowSizes)
    }

    func testExactWindowLengthIsSingleWindow() async throws {
        // Recording length == window length → one window, no duplicate tail (batch parity).
        let engine = MockEngine()
        engine.texts = [.success("only"), .success("dup")]
        let output = try await StreamingTranscriber(engine: engine, config: forcedConfig())
            .run(samples: stream(of: [Float](repeating: 0, count: 1600), pieceSize: 1600)) { _ in }
        XCTAssertEqual(engine.windowSizes, [1600])
        XCTAssertEqual(output.text, "only")
        XCTAssertEqual(output.langStats, ["en": 1])
    }

    func testDegenerateShortStreamIsOneTruncatedWindow() async throws {
        // Stream closes mid-window (fewer than windowSamples): the tail is the
        // single (truncated) window — a valid-but-degenerate input, not an error.
        let engine = MockEngine()
        engine.texts = [.success("hi")]
        let output = try await StreamingTranscriber(engine: engine, config: forcedConfig())
            .run(samples: stream(of: [Float](repeating: 0, count: 500), pieceSize: 120)) { _ in }
        XCTAssertEqual(engine.windowSizes, [500])
        XCTAssertEqual(output.text, "hi")
    }

    func testEmptyStreamReturnsEmpty() async throws {
        let engine = MockEngine()
        let sink = ChunkSink()
        let output = try await StreamingTranscriber(engine: engine, config: forcedConfig())
            .run(samples: AsyncStream { $0.finish() }) { sink.record($0) }
        XCTAssertEqual(output, TranscriptionOutput(text: "", langStats: [:]))
        XCTAssertTrue(engine.windowSizes.isEmpty)
        XCTAssertTrue(sink.chunks.isEmpty)
    }

    func testTotalEngineFailureThrows() async throws {
        // No speech + an error → throw (never a silent empty), matching batch.
        let engine = MockEngine()
        engine.texts = [.failure(MockEngine.MockError()), .failure(MockEngine.MockError())]
        do {
            _ = try await StreamingTranscriber(engine: engine, config: forcedConfig())
                .run(samples: stream(of: [Float](repeating: 0, count: 3200), pieceSize: 3200)) { _ in }
            XCTFail("expected throw on total engine failure")
        } catch is MockEngine.MockError { /* expected */ }
    }

    func testFailedWindowSkippedLanguageDoesNotStick() async throws {
        // Detection-driven: w2 errors → not counted, language does not stick.
        var cfg = forcedConfig()
        cfg.forcedLanguage = nil
        let engine = MockEngine()
        engine.detections = [["en": 0.9, "ru": 0.02], ["uk": 0.9, "ru": 0.02], ["ru": 0.3, "en": 0.3]]
        engine.texts = [.success("hello"), .failure(MockEngine.MockError()), .success("again")]
        let output = try await StreamingTranscriber(engine: engine, config: cfg)
            .run(samples: stream(of: [Float](repeating: 0, count: 4800), pieceSize: 1000)) { _ in }
        XCTAssertEqual(engine.transcribedLanguages, ["en", "uk", "en"])
        XCTAssertEqual(output.text, "hello\nagain")
        XCTAssertEqual(output.langStats, ["en": 2])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter StreamingTranscriberTests 2>&1 | tee /tmp/t.log; echo "test:${PIPESTATUS[0]}"`
Expected: FAIL — `StreamingTranscriber` / `StreamChunk` undefined (build error).

- [ ] **Step 3: Implement `StreamingTranscriber`**

Create `StreamingTranscriber.swift`:

```swift
import Foundation

/// One finished (speech) window emitted by the live transcriber.
struct StreamChunk: Equatable, Sendable {
    let index: Int      // 1-based over speech chunks
    let text: String
    let language: String
}

/// Live counterpart to `WindowedTranscriber`: consumes a running sample stream
/// and produces the SAME windowing/sticky-language result incrementally.
///
/// A window at absolute offset `start` is a "full, non-last" window as soon as
/// strictly more than `start + windowSamples` samples have arrived (i.e. there
/// is at least one sample beyond it — exactly `WindowedTranscriber`'s condition
/// for NOT breaking). The one remaining window at stream close is the last one,
/// truncated to the total length — matching the batch "exact-window-length is a
/// single window" rule. Silent/failed windows never stick and are not counted;
/// total engine failure throws rather than masquerading as all-silence.
struct StreamingTranscriber {
    let engine: TranscriptionEngine
    let config: TranscriptionConfig

    func run(samples: AsyncStream<[Float]>,
             onChunk: @escaping @Sendable (StreamChunk) -> Void) async throws -> TranscriptionOutput {
        let sampleRate = Double(TranscriptionConfig.sampleRate)
        let windowSamples = max(1, Int(config.windowSec * sampleRate))
        let step = max(1, windowSamples - Int(config.overlapSec * sampleRate))

        var buffer: [Float] = []      // buffer[0] is absolute sample `consumedBase`
        var consumedBase = 0
        var absStart = 0

        var texts: [String] = []
        var langStats: [String: Int] = [:]
        var prevLang: String?
        var lastEngineError: Error?
        var chunkIndex = 0

        func process(window: [Float]) async {
            let language: String
            if let forced = config.forcedLanguage {
                language = forced
            } else {
                language = await resolveWindowLanguage(for: window, previous: prevLang, config: config, engine: engine)
            }
            let text: String
            do {
                text = try await engine.transcribeWindow(window, language: language)
            } catch {
                lastEngineError = error
                return // skip: not counted, language does not stick
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            texts.append(trimmed)
            prevLang = language
            langStats[language, default: 0] += 1
            chunkIndex += 1
            onChunk(StreamChunk(index: chunkIndex, text: trimmed, language: language))
        }

        for await piece in samples {
            buffer.append(contentsOf: piece)
            // Emit every window we can now prove is not the last one.
            while consumedBase + buffer.count > absStart + windowSamples {
                let localStart = absStart - consumedBase
                let window = Array(buffer[localStart..<localStart + windowSamples])
                await process(window: window)
                absStart += step
                let drop = absStart - consumedBase
                if drop > 0 {
                    buffer.removeFirst(min(drop, buffer.count))
                    consumedBase += drop
                }
            }
        }

        // Stream closed: the single remaining window (if any) is the last one,
        // truncated to whatever samples are left.
        let totalCount = consumedBase + buffer.count
        if absStart < totalCount {
            let localStart = absStart - consumedBase
            let window = Array(buffer[localStart..<buffer.count])
            await process(window: window)
        }

        if texts.isEmpty, let lastEngineError {
            throw lastEngineError
        }
        return TranscriptionOutput(text: texts.joined(separator: "\n"), langStats: langStats)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter StreamingTranscriberTests 2>&1 | tee /tmp/t.log; echo "test:${PIPESTATUS[0]}"`
Expected: test 0, all pass.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/Transcription/StreamingTranscriber.swift WatchtowerDesktop/Tests/StreamingTranscriberTests.swift
git commit -m "feat(transcriber): StreamingTranscriber for live windowed transcription

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Live sample stream on the recorder

Add a live 16 kHz mono sample stream to the `AudioRecording` protocol and emit it from `SystemAudioRecorder` (from the already-16 kHz `outBuffer` in `appendDownsampled`). `stop()` must finish the stream so the live transcriber's `for await` ends. Update the existing test `FakeRecorder`s to conform.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/AudioRecording.swift` (protocol)
- Modify: `WatchtowerDesktop/Sources/Services/Transcription/SystemAudioRecorder.swift` (emit + finish; both `SystemAudioRecorder` facade and `TapRecorderImpl`)
- Modify: `WatchtowerDesktop/Tests/MeetingRecorderCenterTests.swift` (`FakeRecorder` conformance only — no assertion changes)

**Interfaces:**
- Produces: `var liveSamples: AsyncStream<[Float]> { get }` on `AudioRecording` — 16 kHz mono Float32 pieces delivered as captured; finishes on `stop()`. A recording that never emits (e.g. a fake) yields nothing and finishes on stop.

- [ ] **Step 1: Extend the protocol**

In `AudioRecording.swift`, add to the protocol:

```swift
    /// Live 16 kHz mono Float32 samples delivered as they are captured, for
    /// in-progress transcription. Finishes when `stop()` is called. Consuming it
    /// is optional — a recording works identically whether or not anyone reads it.
    var liveSamples: AsyncStream<[Float]> { get }
```

- [ ] **Step 2: Emit from SystemAudioRecorder**

In `SystemAudioRecorder.swift`:

Facade `SystemAudioRecorder` — forward to the impl (create the stream up front so it exists before `start`, and finish it if start never happens is unnecessary; the impl owns it once started). Add:

```swift
    private var liveContinuation: AsyncStream<[Float]>.Continuation?
    let liveSamples: AsyncStream<[Float]>

    init() {
        var continuation: AsyncStream<[Float]>.Continuation!
        liveSamples = AsyncStream { continuation = $0 }
        liveContinuation = continuation
    }
```

Pass `liveContinuation` into `TapRecorderImpl` at `start` and hand ownership over. In `TapRecorderImpl` add a stored `let liveContinuation: AsyncStream<[Float]>.Continuation?` (init param), then in `appendDownsampled`, right after `framesWritten += Int64(outBuffer.frameLength)`:

```swift
            if let live = liveContinuation, let data = outBuffer.floatChannelData?[0] {
                let n = Int(outBuffer.frameLength)
                live.yield(Array(UnsafeBufferPointer(start: data, count: n)))
            }
```

In `TapRecorderImpl.stop()` (and `deinit`), after teardown finish the stream:

```swift
        liveContinuation?.finish()
```

Wire the facade: change `TapRecorderImpl` construction in `SystemAudioRecorder.start` to `TapRecorderImpl(liveContinuation: liveContinuation)`; null out `liveContinuation` on the facade after handing it off. (Detail: the facade holds the continuation only to pass it in; the impl finishes it.)

- [ ] **Step 3: Make FakeRecorder conform (test-only)**

In `MeetingRecorderCenterTests.swift`, extend `FakeRecorder`:

```swift
    // Live-sample plumbing: a test can push samples then finish, or leave it to
    // finish on stop() (the default: empty stream → live pass yields nothing).
    private var liveContinuation: AsyncStream<[Float]>.Continuation!
    let liveSamples: AsyncStream<[Float]>

    init() {
        var c: AsyncStream<[Float]>.Continuation!
        liveSamples = AsyncStream { c = $0 }
        liveContinuation = c
    }

    /// Emit one live piece (test drives the live path with this).
    func emitLive(_ samples: [Float]) { liveContinuation.yield(samples) }
```

And in `stop()`, before returning, finish the stream:

```swift
        liveContinuation.finish()
```

(Also finish it in `start` error paths is not needed — stop is the single close point; tests that never stop just leak a finished-on-dealloc stream, which is fine.)

- [ ] **Step 4: Build and run the full suite**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/b.log; echo "build:${PIPESTATUS[0]}"`
Then: `swift test 2>&1 | tee /tmp/t.log; echo "test:${PIPESTATUS[0]}"`
Expected: build 0, test 0. Existing `MeetingRecorderCenterTests` still pass — the Center doesn't consume `liveSamples` yet, so behavior is unchanged.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/Transcription/AudioRecording.swift WatchtowerDesktop/Sources/Services/Transcription/SystemAudioRecorder.swift WatchtowerDesktop/Tests/MeetingRecorderCenterTests.swift
git commit -m "feat(transcriber): live 16kHz sample stream on AudioRecording

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Live pass orchestration in `MeetingRecorderCenter`

Load the engine once at record-start, run `StreamingTranscriber` over `recorder.liveSamples`, accumulate live chunks, and on stop save the live result directly (no re-decode). Reuse the loaded engine for the batch fallback so existing `engineLoads` assertions stay valid. Fall back to today's decode+batch path when the live pass did not produce usable text.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MeetingRecorderCenter.swift`
- Test: `WatchtowerDesktop/Tests/MeetingRecorderCenterTests.swift` (ADD new tests; existing untouched)

**Interfaces:**
- Consumes: `StreamingTranscriber`, `StreamChunk` (Task 2); `recorder.liveSamples` (Task 3).
- Produces (observable, read by the UI in Task 5):
  - `enum LiveEngineState: Equatable { case off, loading, running, unavailable }`
  - `struct LiveChunk: Equatable, Identifiable { let id: Int; let text: String; let language: String }`
  - `private(set) var liveEngineState: LiveEngineState`
  - `private(set) var liveChunks: [LiveChunk]`

- [ ] **Step 1: Write the failing tests**

Add to `MeetingRecorderCenterTests.swift` (a scripted engine that produces live chunks needs a config with small windows; reuse `threeWindowConfig`). Add a decode spy via a local flag:

```swift
    // MARK: Live pass

    func testLivePathSavesWithoutRedecoding() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        var decodeCalls = 0
        var engineLoads = 0
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in engineLoads += 1; return ScriptedEngine(texts: ["live one", "live two"]) },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 1600) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
        )

        await center.startRecording(eventID: nil, title: "Live meeting")
        // Feed 3.5 windows of samples while "recording", then stop (finishes the stream).
        recorder.emitLive([Float](repeating: 0, count: 5600))
        await center.stopAndProcess(config: threeWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(decodeCalls, 0, "the live result is saved directly — the file must not be re-decoded")
        XCTAssertEqual(engineLoads, 1, "the engine loads once at start and is reused")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertNil(center.pendingAudioURL)
    }

    func testLiveChunksAccumulateAndSurviveViewLifetime() async throws {
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in ScriptedEngine(texts: ["alpha", "beta"]) },
            decode: stubDecode(sampleCount: 1600),
            runnerResolver: { FakeCLIRunner(stdout: self.recapOKEnvelope) },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
        )

        await center.startRecording(eventID: nil, title: "Live")
        recorder.emitLive([Float](repeating: 0, count: 3200)) // 2 full windows worth
        // Let the live task drain the emitted samples.
        for _ in 0..<12 { await Task.yield() }

        XCTAssertFalse(center.liveChunks.isEmpty, "live chunks must accumulate during recording")
        XCTAssertEqual(center.liveChunks.first?.text, "alpha")

        await center.stopAndProcess(config: threeWindowConfig())
        XCTAssertEqual(center.phase, .idle)
    }

    func testLiveEngineUnavailableFallsBackToBatch() async throws {
        struct EngineLoadError: Error {}
        let audio = try makeDummyAudioFile()
        defer { try? FileManager.default.removeItem(at: audio); removeSidecars(audio) }

        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: 1)
        var engineCalls = 0
        var decodeCalls = 0
        let runner = FakeCLIRunner(stdout: recapOKEnvelope)
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in
                engineCalls += 1
                if engineCalls == 1 { throw EngineLoadError() } // live load fails
                return ScriptedEngine(texts: ["batch recovered"])  // stop-time fallback succeeds
            },
            decode: { _ in decodeCalls += 1; return [Float](repeating: 0, count: 1600) },
            runnerResolver: { runner },
            notifier: FakeNotifier(),
            defaults: try isolatedDefaults()
        )

        await center.startRecording(eventID: nil, title: "Live")
        // Live engine failed to load → recording continues, no error surfaced.
        guard case .recording = center.phase else { return XCTFail("recording must continue after live-load failure") }
        // The engine loads on a background task; drain the main actor so the
        // .unavailable transition lands before we assert on it.
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(center.liveEngineState, .unavailable)

        await center.stopAndProcess(config: singleWindowConfig())

        XCTAssertEqual(center.phase, .idle)
        XCTAssertEqual(decodeCalls, 1, "fallback decodes the file")
        XCTAssertEqual(runner.invocations.count, 1)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter MeetingRecorderCenterTests 2>&1 | tee /tmp/t.log; echo "test:${PIPESTATUS[0]}"`
Expected: FAIL — `liveChunks` / `liveEngineState` / `emitLive`-driven behavior undefined or default (decode still called, engineLoads 2, etc.).

- [ ] **Step 3: Implement the live pass**

In `MeetingRecorderCenter.swift`:

Add observable state and types (near the existing `phase` declaration):

```swift
    enum LiveEngineState: Equatable { case off, loading, running, unavailable }
    struct LiveChunk: Equatable, Identifiable { let id: Int; let text: String; let language: String }

    private(set) var liveEngineState: LiveEngineState = .off
    private(set) var liveChunks: [LiveChunk] = []

    /// Engine loaded at record-start for the live pass, reused for the stop-time
    /// batch fallback so we never load twice on a single recording.
    private var loadedEngine: TranscriptionEngine?
    /// The running live transcription; its value is the final output, or nil when
    /// the live pass never ran or produced no usable text (→ batch fallback).
    private var liveTask: Task<TranscriptionOutput?, Never>?
    /// The active recorder's live sample stream, consumed by `liveTask`.
    private var liveRecorder: AudioRecording?
```

In `startRecording`, after `phase = .recording(startedAt: Date())` (the success branch), start the live pass:

```swift
            pendingAudioURL = url
            phase = .recording(startedAt: Date())
            startLivePass(recorder: recorder, config: config)
```

Note: `startRecording` currently takes no `config`. Add a `config: TranscriptionConfig` parameter to `startRecording(eventID:title:config:)` and thread it from the caller (Task 5 updates the view). Existing tests call `startRecording(eventID:title:)` — keep the signature backward compatible by giving `config` a default:

```swift
    func startRecording(eventID: String?, title: String?, config: TranscriptionConfig = .fromDefaults()) async {
```

Wait — existing tests must not read real UserDefaults for config. They pass `singleWindowConfig()`/`threeWindowConfig()` only to `stopAndProcess`. The live pass in existing tests should be harmless (empty stream). Using `.fromDefaults()` on the isolated suite yields default windows (20 s) — with an empty live stream that produces nothing, so the fallback still runs at `stopAndProcess`'s config. That is fine. Do NOT change existing test calls.

Add the live-pass methods:

```swift
    /// Loads the engine and runs StreamingTranscriber over the recorder's live
    /// samples. Never fails the recording: a load/stream failure only sets
    /// `liveEngineState` and leaves the batch fallback to handle stop.
    private func startLivePass(recorder: AudioRecording, config: TranscriptionConfig) {
        liveChunks = []
        liveEngineState = .loading
        liveRecorder = recorder
        loadedEngine = nil
        liveTask = Task { [weak self] () -> TranscriptionOutput? in
            guard let self else { return nil }
            let engine: TranscriptionEngine
            do {
                engine = try await self.engineFactory(config)
            } catch {
                await MainActor.run { self.liveEngineState = .unavailable }
                return nil
            }
            await MainActor.run {
                self.loadedEngine = engine
                self.liveEngineState = .running
            }
            let transcriber = StreamingTranscriber(engine: engine, config: config)
            do {
                return try await transcriber.run(samples: recorder.liveSamples) { chunk in
                    Task { @MainActor in
                        self.liveChunks.append(LiveChunk(id: chunk.index, text: chunk.text, language: chunk.language))
                    }
                }
            } catch {
                return nil // total engine failure → batch fallback from file
            }
        }
    }
```

Rewrite `stopAndProcess` to try the live result first:

```swift
    func stopAndProcess(config: TranscriptionConfig) async {
        guard case .recording = phase, let recorder else { return }
        self.recorder = nil

        let result: RecordingResult
        do {
            result = try await recorder.stop() // also finishes liveSamples
        } catch {
            liveTask?.cancel(); liveTask = nil; liveRecorder = nil
            fail(error.localizedDescription)
            return
        }

        pendingAudioURL = result.audioURL
        persistPendingDefaults(audioURL: result.audioURL)

        // Live path: the stream is now finished, so awaiting the task finalizes
        // the tail. A usable result is saved directly — no re-decode.
        if let liveTask {
            phase = .transcribing(done: 0, total: 0)
            let liveOutput = await liveTask.value
            self.liveTask = nil
            liveRecorder = nil
            if let liveOutput,
               !liveOutput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let durationSec = result.durationSec
                Self.persistTranscript(liveOutput, durationSec: durationSec, audioURL: result.audioURL)
                await saveTranscript(
                    text: liveOutput.text,
                    durationSec: durationSec,
                    langStats: liveOutput.langStats,
                    audioURL: result.audioURL
                )
                loadedEngine = nil
                return
            }
        }

        // Fallback: today's decode + batch path (reuses the loaded engine if any).
        await transcribeAndSave(audioURL: result.audioURL, config: config)
    }
```

Make `transcribeAndSave` reuse `loadedEngine` when present:

```swift
        let engine: TranscriptionEngine
        if let loadedEngine {
            engine = loadedEngine
        } else {
            do {
                engine = try await engineFactory(config)
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
```

And clear `loadedEngine = nil` at the end of `transcribeAndSave` (both after `saveTranscript` returns and on every `fail(...)` early-return path within it). Simplest: set `loadedEngine = nil` as the first line after the decode/engine steps succeed, before transcription — the engine is captured in a local `let`.

Note on `durationSec` for the live path: `RecordingResult.durationSec` is authoritative (it comes from frames written), so the live path uses it directly rather than `samples.count / sampleRate`.

Guard the reuse in the fallback for the `.unavailable` case: when live load failed, `loadedEngine` is nil, so `transcribeAndSave` calls `engineFactory` again (second load) — exactly what `testLiveEngineUnavailableFallsBackToBatch` expects (call 2 succeeds).

- [ ] **Step 4: Run the tests**

Run: `cd WatchtowerDesktop && swift test --filter MeetingRecorderCenterTests 2>&1 | tee /tmp/t.log; echo "test:${PIPESTATUS[0]}"`
Expected: test 0 — new live tests pass AND all pre-existing tests still pass (engine-reuse keeps `engineLoads` counts correct).

- [ ] **Step 5: Run the whole Swift suite**

Run: `cd WatchtowerDesktop && swift test 2>&1 | tee /tmp/t.log; echo "test:${PIPESTATUS[0]}"`
Expected: test 0.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/MeetingRecorderCenter.swift WatchtowerDesktop/Tests/MeetingRecorderCenterTests.swift
git commit -m "feat(transcriber): live transcription pass in MeetingRecorderCenter

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Expandable live-transcript panel in the UI

The recording capsule gains an expand chevron and a live-engine indicator; expanded, it shows an autoscrolling list of live chunks. Thread the transcription config into `startRecording` so the live pass uses the user's settings.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/RecordingIndicatorView.swift`
- Modify: the caller that starts recording (search for `startRecording(eventID:` — likely `CalendarEventsView.swift`) to pass `config: .fromDefaults()`.

**Interfaces:**
- Consumes: `center.liveChunks`, `center.liveEngineState` (Task 4).

- [ ] **Step 1: Pass config into startRecording at the call site**

Run: `grep -rn "startRecording(eventID" WatchtowerDesktop/Sources/Views` to find the caller. Update it to `await center.startRecording(eventID: ..., title: ..., config: .fromDefaults())`.

- [ ] **Step 2: Add the expandable panel**

In `RecordingIndicatorView.swift`, add view state and rework the `.recording` case:

```swift
    @State private var expanded = false
```

Replace the `.recording` case body with a call to a new `recordingView`:

```swift
            case let .recording(startedAt):
                recordingView(center, startedAt: startedAt)
```

```swift
    @ViewBuilder
    private func recordingView(_ center: MeetingRecorderCenter, startedAt: Date) -> some View {
        if expanded {
            expandedPanel(center, startedAt: startedAt)
        } else {
            recordingCapsule(center, startedAt: startedAt)
        }
    }
```

Add the live-engine glyph + chevron to `recordingCapsule` (before the Stop button):

```swift
            liveEngineIndicator(center.liveEngineState)
            Button { expanded = true } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).controlSize(.small)
                .help("Show live transcript")
```

```swift
    @ViewBuilder
    private func liveEngineIndicator(_ state: MeetingRecorderCenter.LiveEngineState) -> some View {
        switch state {
        case .off, .running: EmptyView()
        case .loading: ProgressView().controlSize(.small)
        case .unavailable:
            Image(systemName: "text.badge.xmark").foregroundStyle(.secondary)
                .help("Live transcript unavailable — the transcription will appear after you stop.")
        }
    }
```

Add the expanded panel:

```swift
    private func expandedPanel(_ center: MeetingRecorderCenter, startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.elapsed(from: startedAt, to: context.date)).font(.callout.monospacedDigit())
                }
                Spacer()
                Button { expanded = false } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).controlSize(.small)
                Button { stop(center) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.red)
            }
            Divider()
            liveTranscriptBody(center)
        }
        .padding(14)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
    }

    @ViewBuilder
    private func liveTranscriptBody(_ center: MeetingRecorderCenter) -> some View {
        switch center.liveEngineState {
        case .loading:
            Text("Loading transcription model…").font(.callout).foregroundStyle(.secondary)
        case .unavailable:
            Text("Live transcript unavailable — the transcription will appear after you stop.")
                .font(.callout).foregroundStyle(.secondary)
        case .off, .running:
            if center.liveChunks.isEmpty {
                Text("Listening…").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(center.liveChunks) { chunk in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(chunk.language).font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                    Text(chunk.text).font(.callout).textSelection(.enabled)
                                }
                                .id(chunk.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 240)
                    .onChange(of: center.liveChunks.count) {
                        if let last = center.liveChunks.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
        }
    }
```

- [ ] **Step 3: Build and confirm the suite still passes**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/b.log; echo "build:${PIPESTATUS[0]}"`
Then: `swift test 2>&1 | tee /tmp/t.log; echo "test:${PIPESTATUS[0]}"`
Expected: build 0, test 0. (The view has no unit tests — the panel is exercised in Task 6's manual verify.)

- [ ] **Step 4: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Calendar/RecordingIndicatorView.swift WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift
git commit -m "feat(transcriber): expandable live-transcript panel in the recording indicator

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Manual verification + docs

Drive the real feature (per the "run the feature, not only tests" rule) and record the dual-path note.

**Files:**
- Modify: `CLAUDE.md` (Meeting Transcriber section — one line on the live pass)
- Modify (memory): the `project_transcriber_dual_paths` note gains the live/batch-fallback pairing.

- [ ] **Step 1: Build the dev app**

Run: `make app-dev 2>&1 | tee /tmp/app.log; echo "make:${PIPESTATUS[0]}"`
Expected: make 0.

- [ ] **Step 2: Drive a real recording**

Launch the app, go to the Calendar tab, start an ad-hoc recording, speak a few sentences (ideally mixing ru/uk/en), expand the panel. Confirm by eye:
- Live chunks appear ~20–25 s after speech, with language tags.
- On `large-v3` a short tail may finish just after Stop; on `large-v3-turbo` the tail is near-empty.
- The saved transcript (Calendar → transcript section) matches what the panel showed.
- Leaving the Calendar tab and returning keeps the capsule/panel and live text (survives navigation).

Record the observed lag and whether the final matched the live text in the commit message.

- [ ] **Step 3: Update CLAUDE.md**

In the Meeting Transcriber section, add after the recording sentence:

```
- Live (in-progress) transcription: while recording, `MeetingRecorderCenter` loads the engine at start and runs `StreamingTranscriber` over the recorder's live 16 kHz sample stream, showing finished 20 s-window chunks in the `RecordingIndicatorView` expandable panel. Single-pass: the live result is saved directly on Stop (no re-decode). The `.caf` file stays the source of truth — engine-load/stream failure silently drops to the batch `WindowedTranscriber` path from the file, which also serves crash recovery/retry. Same model as Settings (`transcription.model`).
```

- [ ] **Step 4: Update the dual-paths memory note**

Append to `/Users/user/.claude/projects/-Users-user-PhpstormProjects-watchtower/memory/project_transcriber_dual_paths.md`: the live pass (StreamingTranscriber) and batch fallback (WindowedTranscriber) must stay behaviorally equivalent — `resolveWindowLanguage` is shared and `StreamingTranscriberTests.testMatchesBatchOnSameSamples` pins the equivalence; changing windowing/sticky logic means updating both + that test.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(transcriber): note live in-progress transcription path

Verified: recorded an ad-hoc meeting, live chunks appeared with ~Ns lag,
final transcript matched the panel. <fill in real numbers>

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- §2 option C (full 20 s windows, single-pass, chunks shown) → Tasks 2, 4, 5.
- §2 model = Settings → Task 4 (config threaded, no forcing) + Task 5 (call site).
- §3.1 live sample stream from `appendDownsampled` → Task 3.
- §3.2 StreamingTranscriber, shared slicing/language, batch equivalence → Tasks 1, 2 (`testMatchesBatchOnSameSamples`).
- §3.3 engine loads without blocking recording, live chunks observable, stop branch, fallback, crash-recovery untouched → Task 4.
- §4 expandable panel, language tags, loading/unavailable copy → Task 5.
- §5 edge cases (engine never loads, streaming total failure, silence, stop before ready) → Task 2 (`testTotalEngineFailureThrows`, `testEmptyStreamReturnsEmpty`, `testDegenerate…`) + Task 4 (`testLiveEngineUnavailableFallsBackToBatch`).
- §6 tests without CoreAudio/WhisperKit + manual verify → all tasks + Task 6.

**Placeholder scan:** the only intentional fill-in is the observed-lag numbers in Task 6's verify commit — that is real data captured at run time, not a code placeholder.

**Type consistency:** `resolveWindowLanguage` signature identical in Tasks 1/2. `StreamChunk`/`StreamingTranscriber.run` identical in Tasks 2/4. `LiveChunk`/`LiveEngineState`/`liveChunks`/`liveEngineState` identical in Tasks 4/5. `startRecording(eventID:title:config:)` default keeps existing test calls compiling.
