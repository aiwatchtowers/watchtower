# Realtime Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per `docs/superpowers/specs/2026-08-15-dictation-realtime-design.md` — dictation gets its own model picker (`dictation.model`: apple / turbo / small / base) and a Siri-style streaming lane on Apple `SpeechTranscriber` (macOS 26+); single-pass everywhere (the chosen engine's output is the raw text), meeting stack untouched.

**Architecture:** New `DictationTranscribing` seam with two conformers — `AppleDictationSession` (native volatile/final streaming, reusing `AppleProvider`'s locale catalog + PCM conversion) and `WhisperDictationSession` (adapter over the existing provider live/batch machinery with `windowSec = 4`). `DictationCenter` resolves its engine from the new `dictation.model` key (never the meeting keys), keeps the warm-engine slot for Whisper lanes only, and treats the t0 buffer as the failure fallback for both lanes.

**Tech Stack:** Swift/SwiftUI, Speech.framework (macOS 26), existing WhisperKit provider machinery, XCTest.

## Global Constraints

- Base branch for this work and its PR: `feature/dictation-ux-v2` (stacked). Worktree: `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/decisions-split`, branch `feature/dictation-realtime`.
- Spec is contractual: `docs/superpowers/specs/2026-08-15-dictation-realtime-design.md`. UX v2 spec's guarantees (pause, automations, capsule, handshake) must keep holding.
- The meeting stack is OFF-LIMITS: `StreamingTranscriber`, `WindowedTranscriber`, `WindowPlanner`, the live↔batch pins, `MeetingRecorderCenter`, meeting Settings keys.
- Repo language English; inner loop `swift test --filter <Class>`; `make lint-diff` before commits; never delete `.build`.
- Controller commits; subagents never run git mutations.

## File Structure

- `Sources/Services/Transcription/DictationEngineChoice.swift` — NEW: pure settings resolution (Task 1)
- `Sources/Services/Transcription/DictationSession.swift` — NEW: `DictationTranscribing` protocol + `WhisperDictationSession` (Task 2)
- `Sources/Services/Transcription/AppleDictationSession.swift` — NEW (Task 3), plus pure `AppleDictationAccumulator`
- `Sources/Services/DictationCenter.swift` — rewire (Tasks 2–3)
- `Sources/Views/Settings/*` (transcription section) — picker (Task 4)
- Tests: `DictationEngineChoiceTests.swift`, `DictationSessionTests.swift`, `AppleDictationAccumulatorTests.swift`, updates to `DictationCenterTests.swift`, `TranscriptionSettingsTests.swift`

---

### Task 0: Baseline

- [ ] Confirm branch `feature/dictation-realtime` (stacked on feature/dictation-ux-v2); `cd WatchtowerDesktop && swift test --filter DictationCenterTests` green (41 tests).

---

### Task 1: `DictationEngineChoice` — settings resolution

**Files:** Create `Sources/Services/Transcription/DictationEngineChoice.swift`; Test `Tests/DictationEngineChoiceTests.swift`.

**Interfaces (produces):**

```swift
/// The dictation-model picker's domain: which engine dictation runs on.
/// Deliberately decoupled from the meeting Engine/Model settings.
enum DictationEngineChoice: Equatable {
    case apple
    case whisper(model: String)   // "large-v3-v20240930" | "small" | "base"

    /// Raw values stored under UserDefaults key "dictation.model".
    static let defaultsKey = "dictation.model"
    static let whisperModels = ["large-v3-v20240930", "small", "base"]

    /// Absent/unknown key → .apple when appleSupported, else .whisper("small").
    /// "apple" stored but appleSupported false (OS downgrade/sync'd prefs) → .whisper("small").
    static func resolve(rawValue: String?, appleSupported: Bool) -> DictationEngineChoice

    /// Convenience used by DictationCenter: reads the injected defaults and
    /// AppleDictationSession.isSupported (parameterized for tests).
    static func current(defaults: UserDefaults, appleSupported: Bool) -> DictationEngineChoice

    /// Stable engine-slot key ("apple" / "whisper|<model>") — replaces the
    /// meeting-keys engineKey() in DictationCenter's warm logic.
    var engineKey: String { get }
}
```

- [ ] **1.1 Failing tests:** resolve(nil, true) == .apple; resolve(nil, false) == .whisper("small"); resolve("apple", false) == .whisper("small"); resolve("small", *) == .whisper("small"); resolve("large-v3-v20240930", true) == .whisper(turbo); resolve("garbage", true) == .apple (unknown = absent); engineKey values "apple" / "whisper|small".
- [ ] **1.2** Run `swift test --filter DictationEngineChoiceTests` → FAIL; implement; PASS.
- [ ] **1.3** Commit: `feat(dictation): DictationEngineChoice settings resolution`.

---

### Task 2: `DictationTranscribing` seam + Whisper lane + DictationCenter rewiring

**Files:** Create `Sources/Services/Transcription/DictationSession.swift`; Modify `Sources/Services/DictationCenter.swift`; Tests: new `Tests/DictationSessionTests.swift`, update `Tests/DictationCenterTests.swift`, extend `Tests/Helpers/DictationTestSupport.swift`.

**Interfaces (produces):**

```swift
/// One dictation transcription session (spec §2): consumes the mic stream,
/// emits full-replacement display updates, returns the final raw text.
protocol DictationTranscribing {
    func run(samples: AsyncStream<[Float]>,
             onUpdate: @escaping @MainActor (String) -> Void) async throws -> String
}

/// Whisper pseudo-streaming lane: the existing provider live session over
/// ~4 s windows; accumulated chunk text is both the updates and the final.
/// Throws DictationSessionError.liveUnsupported when the transcriber has no
/// live session — the center then batch-decodes its buffer (same fallback
/// as an engine failure).
struct WhisperDictationSession: DictationTranscribing {
    let transcriber: Transcriber
    let config: TranscriptionConfig
}
enum DictationSessionError: Error { case liveUnsupported }
```

**DictationCenter changes (contract):**
- `start()` resolves `DictationEngineChoice.current(...)` once per dictation; stores it for the run.
- Whisper lanes: `resolveTranscriber` keyed by `choice.engineKey` (replaces the meeting-keys `currentEngineKey()`); config gets `windowSec = 4` (was 10) and `model = <choice model>` before the engine factory call — `defaultEngineFactory` must consume the model from the config rather than re-reading Settings (check its signature; if it reads defaults keys, add a model override parameter — smallest change wins, meeting callers unchanged).
- `capture()` becomes lane-uniform: build the session (`WhisperDictationSession(transcriber:config:)` for whisper; Task 3 adds apple), `session.run(samples: teedStream, onUpdate:)`; `onUpdate` full-REPLACES `liveText` (not append) behind the existing `phase == .recording` guard, then calls `onLiveText(liveText)`. The returned string is `rawText`. On any throw (including `.liveUnsupported`): batch-decode the t0 buffer with the lane's batch path (whisper: `transcriber.transcribe(buffer, config)`) — the existing fallback semantics, now explicit.
- Buffering, micLevel, silence tracking, pause gating, automations, handshake, `.stopping/.cleaning` flow: UNCHANGED.
- Warm slot: whisper lanes park/reuse exactly as today under the new key; a `dictation.model` Settings change invalidates it (existing stale-key test adapts from `transcription.model` to `dictation.model`).

- [ ] **2.1 Failing tests.**
  - `DictationSessionTests`: `WhisperDictationSession` over a `TestTranscriber(supportsLive: true)` emits accumulated full-text updates and returns the final text; over `supportsLive: false` throws `.liveUnsupported`.
  - `DictationCenterTests` updates: fixtures move their model defaults from `transcription.model` to `dictation.model` (set `"small"` so tests take the whisper lane deterministically — never apple); `testWarmEngineIsDroppedWhenModelSettingChangesBetweenDictations` flips `dictation.model` instead; add `testDictationConfigUsesFourSecondWindowsAndDictationModel` (spy engineFactory captures the config: windowSec == 4, model == "small", diarization == false); add `testLiveTextIsFullReplacementNotAppend` (scripted session emits "hello", then "hello world corrected" → field binding sees the replacement, not concatenation) — drive via a `FakeDictationSession` injected through a new test-only session factory hook (`sessionFactory` closure on the center, defaulting to the real lanes; the `engineFactory` injection precedent).
- [ ] **2.2** FAIL → implement → `swift test --filter 'DictationCenterTests|DictationSessionTests|QuickCaptureViewModelTests|DictationButtonViewTests'` all green (3× for the center suite); `swift build`.
- [ ] **2.3** Commit: `feat(dictation): dictation-model engine resolution + 4s whisper lane behind DictationTranscribing seam`.

---

### Task 3: `AppleDictationSession` — native streaming lane

**Files:** Create `Sources/Services/Transcription/AppleDictationSession.swift`; Modify `Sources/Services/DictationCenter.swift` (apple branch); Tests: new `Tests/AppleDictationAccumulatorTests.swift`, extend `Tests/DictationCenterTests.swift`.

**Interfaces (produces):**

```swift
/// Volatile/final accumulation, pure (no Speech.framework) so it's testable:
/// finalized pieces accumulate; a volatile piece replaces the tail only.
struct AppleDictationAccumulator {
    private(set) var finalized: String = ""
    private(set) var volatileTail: String = ""
    var display: String { get }              // finalized [+ " " +] volatileTail
    mutating func accept(text: String, isFinal: Bool)
}

/// macOS 26+ streaming session over SpeechAnalyzer/SpeechTranscriber.
/// isSupported gates OS availability (mirrors AppleProvider.availability()).
final class AppleDictationSession: DictationTranscribing {
    static var isSupported: Bool { get }
    init(locale: Locale)
    // run(): streams AnalyzerInput per sample chunk (converting via the
    // AppleTranscriber.makePCMBuffer/converted helpers — promote those two
    // statics to internal on AppleTranscriber for reuse, do NOT copy them),
    // consumes transcriberModule.results INCLUDING volatile ones through the
    // accumulator, fires onUpdate(display) on every change, returns the
    // finalized text after finalizeAndFinishThroughEndOfInput().
}
```

**Wiring contract:**
- Locale: `AppleLocaleCatalog.resolveLocale(langset: config.langset)` — same rule as batch (forceLang honored via the existing config langset construction).
- DictationCenter apple branch: no Transcriber load, no warm slot — `isEngineLoading` covers only the session setup + (first-run) asset install via `AppleProvider().prefetch` semantics (call `AssetInventory.assetInstallationRequest` through the session's setup; reuse, don't duplicate, the prefetch flow — extract a small shared helper if needed). `hasResidentEngine` must be false for the apple lane whenever no whisper engine is parked (the meeting recorder must never wait on an apple dictation).
- Fallback: a thrown apple session → batch decode of the t0 buffer via the existing `AppleTranscriber().transcribe(buffer, config)`; if THAT throws → existing failed-with-raw semantics.
- `engineBecameIdle`/drop paths: apple lane has nothing to drop; `meetingCaptureWillStart()` during an apple dictation still finalizes via `stop()` (unchanged switch) and `dropEngineImmediately()` remains a guarded no-op with no warm engine.

- [ ] **3.1 Failing tests.**
  - `AppleDictationAccumulatorTests` (pure): final("hello") → display "hello"; volatile("wor") → "hello wor"; volatile("world") replaces tail → "hello world"; final("world") → finalized "hello world", tail empty; volatile-only start; empty pieces ignored.
  - `DictationCenterTests`: `testAppleLaneNeverHoldsTheEngineSlot` — defaults `dictation.model = "apple"`, inject a `FakeDictationSession` via the session factory; during recording assert `hasResidentEngine == false`; meeting handshake mid-recording still finalizes and fires `engineReleased`. `testAppleSessionFailureFallsBackToBufferDecode` — session factory throws after samples were emitted; inject a batch fallback (spy) and assert the buffer decode delivered the text.
- [ ] **3.2** FAIL → implement → center suite 3×, accumulator suite, `swift build`. NOTE: `AppleDictationSession` itself compiles under `#available(macOS 26, *)` guards exactly like `AppleTranscriber`; its analyzer internals are NOT unit-tested (no Speech mocking) — the accumulator and the center wiring are.
- [ ] **3.3** Commit: `feat(dictation): Apple SpeechTranscriber streaming lane`.

---

### Task 4: Settings picker

**Files:** Modify the Settings transcription section (find the meeting Engine/Model pickers — `grep -rn "transcription.provider" Sources/Views/Settings/`); Test: extend `Tests/TranscriptionSettingsTests.swift`.

- "Dictation model" picker bound to `dictation.model` via `@AppStorage`, options: Apple (only when `AppleDictationSession.isSupported`), Whisper turbo (`large-v3-v20240930`), Whisper small (`small`), Whisper base (`base`); labels "Apple (realtime)", "Whisper large-v3 turbo", "Whisper small (fast)", "Whisper base (fastest)". Placed next to the meeting Model picker with a one-line caption: "Used for voice dictation only; meetings use the model above."
- Unset storage shows the resolved default (Apple on 26+) — bind through a resolved-value proxy, not a raw empty selection.
- [ ] **4.1** Tests: picker option list filters Apple by support flag (drive the pure option-building helper; follow the file's existing test style); resolution proxy maps absent → default.
- [ ] **4.2** FAIL → implement → `swift test --filter TranscriptionSettingsTests` + `swift build`; `make lint-diff`.
- [ ] **4.3** Commit: `feat(dictation): dictation-model picker in Settings`.

---

### Task 5: Gate + review + stacked PR

- [ ] **5.1** Full `swift test` (zero failures, real exit code), `swift build`, `go build ./...`, `make lint-swift`, `make lint-diff`, `sentrux gate .` (if god-files grew legitimately, recompute baseline per repo precedent).
- [ ] **5.2** `local-review` skill, BASE_BRANCH=feature/dictation-ux-v2 (per-branch panel mode — this is a stacked PR into the feature branch, not main).
- [ ] **5.3** Push, `gh pr create --base feature/dictation-ux-v2`, drive CI green (dedupe-gate/dead-webhook → `gh workflow run CI --ref feature/dictation-realtime`).

## Self-Review Notes

- Spec §1 → Tasks 1+4; §2 → Tasks 2–3; §3 → Task 2 (+3 apple branch); §4 no-op (UX unchanged — asserted by existing suites staying green); §5 → per-task tests. Single-pass pinned by `testLiveTextIsFullReplacementNotAppend` + session-return-is-rawText assertions; buffer fallback pinned per lane.
- Names cross-checked: `DictationEngineChoice.engineKey` (1→2), `DictationTranscribing`/`DictationSessionError.liveUnsupported` (2→3), `AppleDictationSession.isSupported` (3→4 picker filter), `dictation.model` key everywhere.
