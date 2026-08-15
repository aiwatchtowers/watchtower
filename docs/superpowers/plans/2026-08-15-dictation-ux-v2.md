# Dictation UX v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the voice-dictation UX per `docs/superpowers/specs/2026-08-15-dictation-ux-v2-design.md`: real pause/resume, an expanding capsule control with live mic levels and a timer, "already listening" during engine load, a pulsing highlight on the target field, and live mic/system levels in the meeting-recording capsule.

**Architecture:** All Swift, all in `WatchtowerDesktop/`; no Go/CLI/prompt changes. `DictationCenter`'s state machine gains `paused`/`stopping` and loses the visible `loadingEngine` phase (replaced by an `isEngineLoading` flag over an immediate `.recording`). `MicRecorder` gains a sample gate for pause. UI: `DictationButton` renders a capsule when active; a new `dictationHighlight` modifier decorates target fields; `RecordingIndicatorView` gains level bars fed from `SystemAudioRecorder`'s existing per-cycle RMS.

**Tech Stack:** SwiftUI, `@Observable`, AsyncStream, XCTest + ViewInspector (existing patterns; see `Tests/Helpers/DictationTestSupport.swift`, `Tests/Helpers/MeetingRecorderTestSupport.swift`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-15-dictation-ux-v2-design.md` — read it before every task; its "Decisions" section is contractual.
- Everything in the repo (code, comments, commits) is English. Conversation with the owner is Russian.
- Inner loop: `cd WatchtowerDesktop && swift test --filter <TestClass>` (never unfiltered) or `make test-swift FILTER=<TestClass>` from repo root. Never delete `WatchtowerDesktop/.build`.
- Lint: `make lint-diff` from repo root before each commit batch.
- `DictationSpan`, the revert-toast ("Raw"), `runCleanup`, and `DictationCleanService` are unchanged — do not touch them.
- Single-engine invariant (dictation ⇄ meeting recorder handshake, `dropEngineAfterCleanup` mechanics) must stay intact; `MeetingRecorderCenter` internals other than the new `captureLevels` are off-limits.
- House rule: async operation state lives in app-wide centers, never view-local ("начал → ушёл → вернулся" must work).
- Commit after every task (each task ends with its own green filtered test run).

## File Structure

- `Sources/Services/Transcription/MicRecorder.swift` — pause gate (Task 1)
- `Sources/Services/DictationCenter.swift` — state machine, pause/resume, levels, automations, handshake (Tasks 2–4)
- `Sources/Views/Components/MicLevelBars.swift` — NEW, shared level-bar view + pure normalization (Task 5)
- `Sources/Views/Components/DictationButton.swift` — capsule rendering (Task 5)
- `Sources/Views/Components/DictationHighlight.swift` — NEW field-highlight modifier (Task 6)
- `Sources/Views/Chat/ChatInput.swift`, `Sources/Views/Ideas/IdeaCreateSheet.swift`, `Sources/Views/Calendar/RecordingDetailTabs.swift` — apply highlight (Task 6)
- `Sources/Views/QuickCapture/QuickCaptureView.swift` — paused/stopping states (Task 7)
- `Sources/Services/Transcription/AudioRecording.swift`, `SystemAudioRecorder.swift`, `Sources/Services/MeetingRecorderCenter.swift`, `Sources/Views/Calendar/RecordingIndicatorView.swift` — meeting levels (Task 8)

---

### Task 0: Branch setup

**Files:** none (git only).

- [ ] **Step 0.1:** From the worktree root: `git fetch origin main` then `git checkout -b feature/dictation-ux-v2 origin/main`.
- [ ] **Step 0.2:** Cherry-pick the spec commit: `git cherry-pick 0fe32e8c` (docs: dictation UX v2 design). Then commit the plan file itself: `git add docs/superpowers/plans/2026-08-15-dictation-ux-v2.md && git commit -m "docs: dictation UX v2 implementation plan"`.
- [ ] **Step 0.3:** Sanity: `cd WatchtowerDesktop && swift test --filter DictationCenterTests` — must be green before any change.

---

### Task 1: MicRecorder pause gate

**Files:**
- Modify: `Sources/Services/Transcription/MicRecorder.swift`
- Modify: `Tests/Helpers/DictationTestSupport.swift` (FakeMicRecorder)
- Test: `Tests/MicRecorderTests.swift`

**Interfaces:**
- Produces: `MicRecording.setPaused(_ paused: Bool)` — protocol requirement. While paused, no samples are yielded into `samples`; the engine/tap keep running. `FakeMicRecorder.setPaused` drops `emit()`ed chunks while paused and records `pausedStates: [Bool]`.

- [ ] **Step 1.1: Failing test** — in `MicRecorderTests.swift` a pure-fake test belongs in `DictationCenterTests`-style land, but the gate itself is testable on the fake; the real recorder's gate is exercised via the same code path (`appendDownsampled` guard). Add to `Tests/MicRecorderTests.swift`:

```swift
@MainActor
func testFakeRecorderDropsSamplesWhilePaused() async {
    let recorder = FakeMicRecorder()
    var received: [[Float]] = []
    let consume = Task { for await chunk in recorder.samples { received.append(chunk) } }
    recorder.emit([0.1])
    recorder.setPaused(true)
    recorder.emit([0.2])
    recorder.setPaused(false)
    recorder.emit([0.3])
    recorder.stop()
    _ = await consume.value
    XCTAssertEqual(received, [[0.1], [0.3]])
    XCTAssertEqual(recorder.pausedStates, [true, false])
}
```

- [ ] **Step 1.2:** Run `swift test --filter MicRecorderTests` — FAIL (no `setPaused`).
- [ ] **Step 1.3: Implement.** In `MicRecorder.swift`:
  - Protocol: add `/// While paused the capture engine keeps running but no samples are yielded. func setPaused(_ paused: Bool)` to `MicRecording`.
  - `MicRecorder`: add `private var paused = false` (guarded by `convertQueue`); `func setPaused(_ paused: Bool) { convertQueue.sync { self.paused = paused } }`; in `appendDownsampled`, after the `guard let converter` line add `guard !paused else { return }` (it already runs on `convertQueue`).
  - `FakeMicRecorder` (in `Tests/Helpers/DictationTestSupport.swift`): add `private(set) var pausedStates: [Bool] = []`, `private var paused = false`; `func setPaused(_ paused: Bool) { self.paused = paused; pausedStates.append(paused) }`; in `emit`, `guard !paused else { return }` before yielding.
- [ ] **Step 1.4:** `swift test --filter MicRecorderTests` — PASS. Also `swift test --filter DictationCenterTests` (protocol change compiles everywhere).
- [ ] **Step 1.5:** Commit: `feat(dictation): add pause gate to MicRecording`.

---

### Task 2: DictationCenter phase rework — listening-while-loading, stop finalizes, handshake

**Files:**
- Modify: `Sources/Services/DictationCenter.swift`
- Test: `Tests/DictationCenterTests.swift` (update 3 existing tests, add 2)
- Modify (compile-fix only): `Sources/Views/Components/DictationButton.swift`, `Sources/Views/QuickCapture/QuickCaptureView.swift` — mechanical `.loadingEngine` removal; real UI comes in Tasks 5/7.

**Interfaces:**
- Produces:
  - `DictationPhase` becomes `case idle, recording, paused, stopping, cleaning, failed(String)` (`paused` is wired in Task 3 but the case exists now so the enum changes once).
  - `private(set) var isEngineLoading: Bool` on `DictationCenter` — true from `start()` until the engine resolves (or the run ends).
  - `stop()` finalizes from `.recording` even while `isEngineLoading` — waits for the engine, batch-decodes the buffer, cleans, delivers. Sets `phase = .stopping` until transcription completes, then `.cleaning` as today.
  - `cancel()` remains the only discard path.
  - `meetingCaptureWillStart()`: `.recording`/`.paused`/`.stopping` → `dropEngineAfterCleanup = true; stop()`; `.idle`/`.failed`/`.cleaning` → `dropEngineImmediately()`. The loadingEngine branch dies.
  - `hasResidentEngine` becomes `warmTranscriber != nil || (phase != .idle && isEngineLoading)`.

**Implementation notes (the restructure, concretely):**
- `start()`: set `phase = .recording` (not `.loadingEngine`), `isEngineLoading = true`.
- `runDictation()` new order: `recorder.start()` → spawn the buffering/feed structure BEFORE awaiting the engine. Restructure `capture(...)` into two pieces:
  1. `startBuffering(recorder:)` — creates the teed stream + continuation upfront, starts the feed task (`for await chunk in recorder.samples { buffer.append…; teedContinuation.yield(chunk) }`), returns a small `struct CaptureBuffers { let teed: AsyncStream<[Float]>; var buffer: () -> [Float]; let feedTask: Task<Void, Never> }` — hold buffer state in a `@MainActor` box class so both the feed task and the finish path read it.
  2. After buffering starts: `transcriber = try await resolveTranscriber(config)`, then `isEngineLoading = false`. On engine-load error: `recorder.stop()`, drain feedTask, `finish(failed: "engine failed to load: …")` (unchanged failure semantics).
  3. Live path: if `phase == .recording` (mic still open) and `transcriber.makeLiveSession(config:)` is non-nil, run it over the teed stream exactly as today (the teed stream has buffered everything since t0, so the live session catches up). If the mic already stopped (`stop()` during load — feed task finished), skip the live session and go straight to batch decode of the buffer.
  4. `stop()` when `phase == .recording`: `recorder.stop()` as today; additionally set `phase = .stopping`. When the live output resolves (or batch decode runs), proceed `.stopping → .cleaning` (or the empty/failed paths as today). Note the existing live-chunk guard `self.phase == .recording` (late-tail suppression) must now check `phase == .recording` only — a `.stopping` phase means stop was pressed, and the *final* live output is still delivered via the return value, so the guard's behavior is preserved verbatim.
- `stop()` full body: `.recording → { recorder?.stop(); phase = .stopping }`; `.paused` handled in Task 3; everything else no-op. The old "stop during loadingEngine = cancel" branch is deleted.
- The empty-transcript and failure paths must reset `isEngineLoading = false` (belt-and-braces: set it false in `finish(failed:)` and in every path that reaches `.idle`).

- [ ] **Step 2.1: Update the two flipped tests + add one.** In `Tests/DictationCenterTests.swift`:
  - `testStopDuringEngineLoadCancelsTheDictation` → rename `testStopDuringEngineLoadFinalizesAndDeliversText`. New body: same gated engine factory; `start`, wait `engineLoads >= 1`; assert `center.phase == .recording && center.isEngineLoading`; `recorder.emit([Float](repeating: 0.1, count: 1_600))`; `center.stop()`; assert `center.phase == .stopping`; `gate.release()`; `await waitUntil("result delivered") { result != nil }`; assert `result == DictationCleanResult(title: nil, text: "cleaned")`, `center.phase == .idle`, `recorder.stopCalls == 1`.
  - `testMeetingCaptureWillStartDuringEngineLoadCancelsTheDictation` → rename `...FinalizesAndFreesTheSlot`. Same shape: emit samples during the gated load, call `meetingCaptureWillStart()`, then `gate.release()`; assert the result is delivered AND `hasResidentEngine == false` after delivery (engine dropped, not parked — the `dropEngineAfterCleanup` path) and `engineReleased` fired (wire `center.engineReleased = { releasedCount += 1 }`).
  - `testMeetingCaptureWillStartDuringLoadWithWarmEngineDropsItImmediately` — re-read and adapt: with the new semantics this scenario also finalizes; keep its warm-engine assertions, change the phase expectations from `.loadingEngine` to `.recording`+`isEngineLoading`.
  - All other tests asserting `XCTAssertEqual(center.phase, .loadingEngine)` (e.g. the happy path's first assert) change to `XCTAssertTrue(center.isEngineLoading)` + `XCTAssertEqual(center.phase, .recording)`.
  - Add `testCancelDuringEngineLoadDiscardsEverything`: gated load, emit, `cancel()`, assert `.idle`, `stopCalls == 1`, release gate, yield, assert no callbacks and no runner invocations (this preserves the old discard coverage under its true name).
- [ ] **Step 2.2:** `swift test --filter DictationCenterTests` — FAIL (compile + behavior).
- [ ] **Step 2.3:** Implement per the notes above. Mechanical compile-fixes in `DictationButton.swift`/`QuickCaptureView.swift`: replace `.loadingEngine` matches with `center.isEngineLoading` checks keeping today's visuals (spinner) — the real capsule/window UI lands in Tasks 5/7. `QuickCaptureState.derive`: map `.stopping` to `.cleaning` for now; `.paused` case `fatalError` is forbidden — map it to `.recording` temporarily (Task 7 does it properly).
- [ ] **Step 2.4:** `swift test --filter DictationCenterTests` then `--filter QuickCaptureViewModelTests` then `--filter DictationButtonTests` — PASS.
- [ ] **Step 2.5:** Commit: `feat(dictation): record-while-loading — stop during engine load finalizes instead of cancelling`.

---

### Task 3: Pause/resume, elapsed time, mic level

**Files:**
- Modify: `Sources/Services/DictationCenter.swift`
- Test: `Tests/DictationCenterTests.swift`

**Interfaces:**
- Produces (on `DictationCenter`):
  - `func pause()` — no-op unless `phase == .recording`. Calls `recorder?.setPaused(true)`, folds the open span into `elapsedAccumulated`, sets `phase = .paused`, arms the pause-timeout (Task 4 fills the timeout action; this task just stores the armed task).
  - `func resume()` — no-op unless `phase == .paused`. `recorder?.setPaused(false)`, `spanStartedAt = Date()`, `phase = .recording`, cancels the pause-timeout.
  - `stop()` from `.paused` finalizes exactly like from `.recording` (recorder.stop() ends the stream; the buffered audio is what it is).
  - `private(set) var micLevel: Float` — RMS of the latest sample chunk, updated in the feed loop; reset to 0 on idle/paused.
  - `private(set) var elapsedAccumulated: Duration` + `private(set) var spanStartedAt: Date?` and `func elapsed(at date: Date) -> Duration { elapsedAccumulated + (spanStartedAt.map { .seconds(date.timeIntervalSince($0)) } ?? .zero) }` — paused time never ticks. `spanStartedAt` is set when `phase` first becomes `.recording` and on every `resume()`; folded+nil'd on `pause()`, `stop()`, `cancel()`, and failure.
- Consumes: `MicRecording.setPaused` (Task 1).

- [ ] **Step 3.1: Failing tests.** Add to `DictationCenterTests`:

```swift
func testPauseGatesSamplesAndResumeContinuesSameSession() async throws {
    // Fixture: standard live-capable center (copy testLiveHappyPath fixture,
    // ScriptedEngine(texts: ["part one part two"])).
    center.start(targetID: "t1", mode: .chat, onLiveText: { _ in }, onResult: { result = $0 })
    await waitUntil("recording") { center.phase == .recording }
    recorder.emit([Float](repeating: 0.1, count: 1_600))
    center.pause()
    XCTAssertEqual(center.phase, .paused)
    XCTAssertEqual(recorder.pausedStates, [true])
    recorder.emit([Float](repeating: 0.9, count: 1_600)) // dropped by the fake's gate
    center.resume()
    XCTAssertEqual(center.phase, .recording)
    XCTAssertEqual(recorder.pausedStates, [true, false])
    recorder.emit([Float](repeating: 0.1, count: 1_600))
    center.stop()
    await waitUntil("result delivered") { result != nil }
    XCTAssertEqual(center.phase, .idle)
}

func testStopFromPausedFinalizes() async throws {
    // start → recording → emit → pause() → stop() → result delivered, phase idle.
}

func testElapsedDoesNotTickWhilePaused() async throws {
    // start → recording; grab e1 = center.elapsed(at: someDate).
    // pause(); elapsed(at: someDate + 10s) must equal elapsed at pause time (elapsedAccumulated frozen, spanStartedAt nil).
    XCTAssertNil(center.spanStartedAt)
}

func testMicLevelTracksChunkRMSAndResetsOnIdle() async throws {
    // emit a chunk of 0.5s of 0.2 amplitude → micLevel ≈ 0.2 (accuracy 0.01);
    // stop, wait idle → micLevel == 0.
}

func testMeetingCaptureWillStartFromPausedFinalizes() async throws {
    // start → pause → meetingCaptureWillStart() → result delivered, engine dropped (hasResidentEngine false).
}
```

  (Write the bodies out fully in the test file — the fixtures are verbatim copies of `testLiveHappyPathDeliversLiveTextThenCleanedResult`'s setup.)
- [ ] **Step 3.2:** `swift test --filter DictationCenterTests` — FAIL.
- [ ] **Step 3.3: Implement.** Feed-loop micLevel: in the buffering loop, `micLevel = chunk.isEmpty ? 0 : (chunk.reduce(into: Float(0)) { $0 += $1 * $1 } / Float(chunk.count)).squareRoot()`; set `micLevel = 0` on pause/idle/failed. `meetingCaptureWillStart()` adds `.paused` to the finalize branch (`dropEngineAfterCleanup = true; stop()`).
- [ ] **Step 3.4:** `swift test --filter DictationCenterTests` — PASS.
- [ ] **Step 3.5:** Commit: `feat(dictation): pause/resume, elapsed accounting, live mic level`.

---

### Task 4: Safety automations — silence auto-pause, pause-timeout auto-stop

**Files:**
- Modify: `Sources/Services/DictationCenter.swift`
- Test: `Tests/DictationCenterTests.swift`

**Interfaces:**
- Produces: two new injectable init parameters with defaults (the `engineIdleTTL` precedent):
  - `silenceAutoPauseAfter: Duration = .seconds(120)`, `pauseAutoStopAfter: Duration = .seconds(300)`, `silenceRMSThreshold: Float = 0.003`.
  - Silence tracking is **sample-clock based**, not wall-clock: in the feed loop accumulate `silentSeconds += Double(chunk.count) / 16_000` while chunk RMS < threshold (reset on a loud chunk and on resume); when `silentSeconds` exceeds `silenceAutoPauseAfter`, call `pause()`. This makes tests deterministic — emit N samples of silence, no sleeping.
  - Pause timeout: `pause()` arms `pauseTimeoutTask = Task { try? await Task.sleep(for: pauseAutoStopAfter); guard !Task.isCancelled else { return }; self.stop() }`; `resume()`/`stop()`/`cancel()` cancel it.

- [ ] **Step 4.1: Failing tests.**

```swift
func testSilenceAutoPausesAfterThreshold() async throws {
    // center built with silenceAutoPauseAfter: .seconds(1), silenceRMSThreshold: 0.01
    // emit 0.5 s of loud (0.2) → still .recording
    // emit 1.5 s of silence (0.0, chunks of 1_600) → phase becomes .paused, pausedStates == [true]
}

func testLoudChunkResetsSilenceCounter() async throws {
    // 0.8 s silence → loud chunk → 0.8 s silence → still .recording (counter reset)
}

func testPauseTimeoutAutoStopsAndDelivers() async throws {
    // center with pauseAutoStopAfter: .milliseconds(50); start, emit speech, pause()
    // → waitUntil result != nil; phase .idle (auto-stop finalized, text delivered)
}

func testResumeCancelsPauseTimeout() async throws {
    // pauseAutoStopAfter: .milliseconds(50); pause() then immediately resume();
    // sleep 100 ms; still .recording, no result yet.
}
```

- [ ] **Step 4.2:** `swift test --filter DictationCenterTests` — FAIL.
- [ ] **Step 4.3:** Implement per interface notes.
- [ ] **Step 4.4:** `swift test --filter DictationCenterTests` — PASS.
- [ ] **Step 4.5:** Commit: `feat(dictation): silence auto-pause and pause-timeout auto-stop`.

---

### Task 5: Capsule UI — MicLevelBars + DictationButton rework + Esc = cancel

**Files:**
- Create: `Sources/Views/Components/MicLevelBars.swift`
- Modify: `Sources/Views/Components/DictationButton.swift`
- Test: `Tests/DictationButtonTests.swift`, new `Tests/MicLevelBarsTests.swift`

**Interfaces:**
- Produces:
  - `struct MicLevelBars: View { let level: Float; var barCount: Int = 5 }` — renders `barCount` capsules, lit proportionally to `MicLevelBars.displayFraction(level)`.
  - `static func displayFraction(_ rms: Float) -> Float` — pure: `rms <= 0 → 0`; else `min(1, (rms / 0.15).squareRoot())` (speech RMS ~0.005–0.1 maps to a visible range).
  - `DictationButton` renders: rest = mic glyph in a 28×28 hit area with `.background(.quaternary, in: Circle())`; `.recording` = capsule `[MicLevelBars(level:) | timer | pause btn | stop btn]` + a `Text("Loading model…").font(.caption2)` badge while `center.isEngineLoading`; `.paused` = `[Text("Paused") | timer | resume btn | stop btn]`; `.stopping`/`.cleaning` = `[ProgressView | Text("Transcribing…"/"Cleaning…")]`; `.failed` unchanged. Timer via `TimelineView(.periodic(from: .now, by: 1)) { Text(format(center.elapsed(at: $0.date))) }` with mm:ss `monospacedDigit` formatting (private `static func timerLabel(_ d: Duration) -> String` for testability).
  - `.onExitCommand` calls `center.cancel()` (was `stop()`) — Esc discards, per spec ("Esc now means Cancel").
- Consumes: `center.pause()/resume()/micLevel/elapsed(at:)/isEngineLoading` (Tasks 2–4).

- [ ] **Step 5.1: Failing tests.** `MicLevelBarsTests`: `displayFraction(0) == 0`, `displayFraction(0.15) == 1`, `displayFraction(0.0375) == 0.5` (accuracy 0.001), monotonic for 0.001→0.01→0.1. `DictationButtonTests`: extend the existing ViewInspector suite — recording phase shows a pause button (`button(with: "pause")` by accessibility identifier `"dictation.pause"`), paused shows `"dictation.resume"`, both show `"dictation.stop"`; `timerLabel(.seconds(62)) == "1:02"`; Esc handler calls cancel (assert via center state: recording → simulate `onExitCommand` → phase `.idle`, no result callback). Follow the file's existing test style for driving `DictationButton` with an explicit center.
- [ ] **Step 5.2:** Run both filters — FAIL.
- [ ] **Step 5.3:** Implement. Set `.accessibilityIdentifier("dictation.pause"/"dictation.resume"/"dictation.stop")` on the buttons (ViewInspector hooks). Keep `DictationSpan`/revert-toast code untouched.
- [ ] **Step 5.4:** `swift test --filter DictationButtonTests` + `--filter MicLevelBarsTests` — PASS.
- [ ] **Step 5.5:** Commit: `feat(dictation): capsule control with level bars, timer, pause/stop; Esc cancels`.

---

### Task 6: Field highlight modifier

**Files:**
- Create: `Sources/Views/Components/DictationHighlight.swift`
- Modify: `Sources/Views/Chat/ChatInput.swift`, `Sources/Views/Ideas/IdeaCreateSheet.swift`, `Sources/Views/Calendar/RecordingDetailTabs.swift`
- Test: `Tests/DictationHighlightTests.swift` (new)

**Interfaces:**
- Produces:

```swift
/// Pure state derivation, testable without rendering.
enum DictationHighlightState: Equatable {
    case none, recording, paused
    static func derive(activeTargetID: String?, phase: DictationPhase, targetID: String) -> Self
    // activeTargetID == targetID && phase == .recording → .recording (pulsing accent border + tint)
    // activeTargetID == targetID && phase == .paused    → .paused (static accent border + tint)
    // anything else (including .stopping/.cleaning)     → .none
}

extension View {
    /// Accent border + subtle tint on the field a dictation is writing into.
    /// `center: nil` (no environment) renders unmodified.
    func dictationHighlight(targetID: String, center: DictationCenter?) -> some View
}
```

  Implementation: an `overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(pulse ? 0.9 : 0.45), lineWidth: 2))` + `background(Color.accentColor.opacity(0.06))`, with the pulse driven by `.animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)` only in `.recording`. ChatInput's rounded corner radius is 18 — make the radius a parameter `cornerRadius: CGFloat = 8`.
- Application sites: in `ChatInputContent`, on the text-input container `ZStack`'s padded box (after its existing `.overlay`), `cornerRadius: 18`, `targetID: dictationTargetID` (skip when nil); in `IdeaCreateSheet` on the essence editor, `targetID: "idea-create.essence"`; in `RecordingDetailTabs` on the notes editor, `targetID: "notes.\(transcript.id ?? 0)"` (must match the `DictationButton` targetID strings exactly — copy them from the `DictationButton(...)` call two lines away, do not retype).

- [ ] **Step 6.1: Failing test.** `DictationHighlightTests`: table-test `DictationHighlightState.derive` — matching id + `.recording` → `.recording`; matching + `.paused` → `.paused`; matching + `.cleaning`/`.stopping`/`.idle` → `.none`; non-matching id + `.recording` → `.none`; nil activeTargetID → `.none`.
- [ ] **Step 6.2:** FAIL, then implement, then PASS (`swift test --filter DictationHighlightTests`; also `--filter ChatInputViewTests` for regressions).
- [ ] **Step 6.3:** Commit: `feat(dictation): highlight the target field while dictating`.

---

### Task 7: Quick Capture — paused/stopping states + pause UI

**Files:**
- Modify: `Sources/Views/QuickCapture/QuickCaptureView.swift`
- Test: `Tests/QuickCaptureViewModelTests.swift`

**Interfaces:**
- Produces: `QuickCaptureState` gains `case paused` and `case stopping`; `derive` maps `DictationPhase.paused → .paused`, `.stopping → .stopping` (result/saved still win first; `ownsCapture` guard unchanged). View: `.paused` renders "Paused" + timer + Resume/Stop/Cancel; `.recording` gains Pause button + `MicLevelBars(level: center.micLevel)` + timer next to "Listening…", and while `center.isEngineLoading` the caption "Loading model… speak freely, nothing is lost." replaces the bare "Loading…" state (the old `.loading` case maps: `phase .idle → .loading` stays for the pre-start beat); `.stopping` renders spinner + "Transcribing…". `QuickCaptureViewModel` gains `func pause() { guard ownsCapture else { return }; center?.pause() }` and `func resume()` symmetric.
- Consumes: `center.pause()/resume()/micLevel/elapsed(at:)/isEngineLoading`.

- [ ] **Step 7.1: Failing tests.** Extend `QuickCaptureViewModelTests`' derive table: `(ownsCapture: true, phase: .paused) → .paused`; `(true, .stopping) → .stopping`; `(false, .paused) → .unavailable`; result-wins and saved-wins unchanged against the new phases (e.g. `result != nil` + `.paused` → `.resultReady`). Add pause/resume ownership tests mirroring the existing `stop()` ownership test: `pause()` without ownership is a no-op.
- [ ] **Step 7.2:** FAIL → implement → `swift test --filter QuickCaptureViewModelTests` PASS.
- [ ] **Step 7.3:** Commit: `feat(dictation): quick capture pause/resume and listening-while-loading`.

---

### Task 8: Meeting recording live levels

**Files:**
- Modify: `Sources/Services/Transcription/AudioRecording.swift`, `Sources/Services/Transcription/SystemAudioRecorder.swift`, `Sources/Services/MeetingRecorderCenter.swift`, `Sources/Views/Calendar/RecordingIndicatorView.swift`
- Modify: `Tests/Helpers/MeetingRecorderTestSupport.swift` (FakeRecorder conformance)
- Test: `Tests/MeetingRecorderCenterTests.swift`, `Tests/MicActivityTests.swift` (accumulator math if touched — prefer a separate accumulator, leave MicActivity alone)

**Interfaces:**
- Produces:

```swift
struct CaptureLevels: Equatable, Sendable {
    let mic: Float     // raw pre-AGC mic RMS over the last ~100 ms
    let system: Float  // system-channel RMS over the same window
}

// AudioRecording protocol gains:
/// Throttled (~10 Hz) live level pairs; finishes on stop(). Optional to consume.
var liveLevels: AsyncStream<CaptureLevels> { get }

// MeetingRecorderCenter gains:
private(set) var captureLevels: CaptureLevels = .init(mic: 0, system: 0)
```

  - `SystemAudioRecorder`: a tiny accumulator struct `LevelAccumulator` (new, private, pure — `mutating func add(mic: Float, sys: Float)` per frame, `mutating func flush(sampleRate: Double) -> CaptureLevels?` returning a value once ≥ 0.1 s of frames accumulated, else nil). Call `add` inside the existing per-frame loop right next to `activityAccumulator?.add(mic:sys:)` (same RAW pre-gain values); after the loop, `if let levels = levelAccumulator.flush(sampleRate: format.sampleRate) { levelsContinuation.yield(levels) }`. Continuation is created in init exactly like `liveSamples`; `stop()` finishes it.
  - `MeetingRecorderCenter`: on capture start, spawn `levelsTask = Task { @MainActor in for await l in recorder.liveLevels { self.captureLevels = l } ; self.captureLevels = .init(mic: 0, system: 0) }`; cancel/reset on stop paths (the `liveTask` lifecycle precedent in the same file).
  - `RecordingIndicatorView.recordingCapsule`: after the red dot, add `MicLevelBars(level: center.captureLevels.mic, barCount: 3).help("Microphone level")` and `MicLevelBars(level: center.captureLevels.system, barCount: 3).help("System audio level")` with `mic.fill`/`speaker.wave.2.fill` caption glyphs (font `.caption2`, secondary style).
  - `FakeRecorder` (MeetingRecorderTestSupport): conform with an `emitLevels(_:)` helper mirroring `FakeMicRecorder.emit`.

- [ ] **Step 8.1: Failing tests.** `LevelAccumulatorTests` (new file or inside `MeetingRecorderCenterTests`): feeding 0.05 s of frames returns nil; crossing 0.1 s returns RMS of exactly the accumulated frames and resets. `MeetingRecorderCenterTests`: start capture with FakeRecorder, `emitLevels(CaptureLevels(mic: 0.1, system: 0.3))`, waitUntil `center.captureLevels.mic == 0.1`; stop → levels reset to zero.
- [ ] **Step 8.2:** FAIL → implement → `swift test --filter MeetingRecorderCenterTests` (and the new filter) PASS. Also run `--filter RecordingIndicatorViewTests` and `--filter MicActivityTests` for regressions.
- [ ] **Step 8.3:** Commit: `feat(recording): live mic and system level bars in the recording capsule`.

---

### Task 9: Gate + PR

- [ ] **Step 9.1:** Full Swift suite from repo root: `make test-swift 2>&1 | tee /tmp/swift-test.log; echo "exit=$?"` — check the REAL exit code, remember XCTest failures sit above the swift-testing tail line. Go untouched, but run `go build ./...` for sanity.
- [ ] **Step 9.2:** `make lint-diff` (and fix), then full `make lint` if Desktop lint config demands it.
- [ ] **Step 9.3:** Invoke the `local-review` skill on the branch (final PR review = debate-review per that skill's rules). Triage findings critically; fix accepted ones with per-fix commits.
- [ ] **Step 9.4:** Push `feature/dictation-ux-v2`, open PR to `main` titled `feat(dictation): UX v2 — pause/resume, capsule control, live levels`, body summarizing the spec decisions + test coverage, ending with the standard generated-with footer. Use the `vadimtrunov` gh account (project memory).
- [ ] **Step 9.5:** Watch CI (`gh pr checks --watch`); fix failures until green. Remember the CI gotchas memory: "skipping" ≠ green; `workflow_dispatch` escape hatch exists.

## Self-Review Notes

- Spec §1 (state machine) → Tasks 2–3; §2 (automations) → Task 4; §3 (capsule) → Task 5; §4 (highlight) → Task 6; §5 (quick capture) → Task 7; §6 (handshake) → Task 2 + paused-case in Task 3; §7 (meeting levels) → Task 8; Esc-cancels → Task 5. Testing section covered by per-task tests; the async-state house rule is satisfied structurally (all state stays on `DictationCenter`).
- Type names cross-checked: `setPaused(_:)` (Tasks 1/3), `isEngineLoading` (2/5/7), `micLevel` (3/5/7), `elapsed(at:)` (3/5/7), `CaptureLevels`/`MicLevelBars` (5/8), `DictationHighlightState` (6).
