# Realtime Dictation — Apple streaming engine + dictation-model picker

**Date:** 2026-08-15
**Status:** Approved design, pre-implementation
**Builds on:** `2026-08-15-dictation-ux-v2-design.md` (capsule/pause UX — branch `feature/dictation-ux-v2`); `2026-08-11-voice-dictation-design.md` (v1 plumbing)

## Problem

Dictation rides the meeting transcription stack: 10-second Whisper windows over the meeting model. For meetings (30 s windows) that trade-off is right; for voice notes it is wrong twice over — text appears in ten-second lumps, and the meeting model (owner runs full `large-v3`) takes a minute-plus to cold-load before the first live chunk can even decode. The owner wants Siri-style dictation: words appear as they are spoken.

## Decisions (owner-approved)

- **Siri-style realtime** — words appear while speaking and refine in place; not phrase-per-window.
- **Single-pass, no re-decode.** The chosen dictation engine's own output IS the raw text handed to the AI cleanup (`dictate clean`). No second pass by the meeting model. (A two-pass design was considered and dropped: with Apple's transcriber plus the AI cleanup, a Whisper re-decode buys little and costs stop-latency and the big-model load.)
- **Dictation gets its own model picker**, Settings → Transcription → **Dictation model**, listing only dictation-suitable engines:
  - **Apple** (`SpeechTranscriber`, macOS 26+) — DEFAULT where available. Natively streaming (volatile → finalized results), zero download of Whisper weights, negligible load time.
  - **Whisper turbo** (`large-v3-v20240930`), **Whisper small** (`small`), **Whisper base** (`base`) — pseudo-streaming via short windows (~4 s).
  - Excluded by design: full `large-v3` (load cost), `distil` (English-only), Parakeet (batch-only), Qwen3 (heavy MLX, own windower).
- **No automatic language fallback.** Apple is locale-pinned; the owner dictates ru/en and accepts that mixed-language or uk dictation on the Apple engine may mangle the live text — switching to a Whisper variant in the same picker is the remedy. Known caveat, documented, not auto-handled.
- **The meeting stack is untouched** — `StreamingTranscriber`/`WindowedTranscriber`/`WindowPlanner`, the live↔batch pins, the meeting model choice, and `MeetingRecorderCenter` semantics all stay as-is. Dictation stops being a consumer of the meeting *model* but remains a consumer of the transcription *machinery* where it fits (Whisper lanes).
- The UX v2 capsule, pause/resume, safety automations, field highlight, and Esc-cancels semantics are unchanged.

## 1. Settings

- New key `dictation.model`, values: `"apple"`, `"large-v3-v20240930"`, `"small"`, `"base"`.
- Absent key resolves to `"apple"` when `AppleDictationSession.isSupported` (macOS 26+), else `"small"` — new installs get realtime out of the box, older systems get the fastest sensible Whisper.
- Settings → Transcription gains a "Dictation model" picker showing only the available options (Apple row hidden on macOS < 26). The meeting Engine/Model pickers are unchanged and no longer affect dictation.

## 2. Engine seam

```swift
/// One dictation transcription session: consumes the mic's 16 kHz stream,
/// emits display updates while running, returns the final raw text.
protocol DictationTranscribing {
    /// Full replacement text for the dictated span so far:
    /// finalized prefix + current volatile tail.
    /// The session ends when the sample stream finishes; the returned
    /// string is the engine's final raw transcript (single-pass).
    func run(samples: AsyncStream<[Float]>,
             onUpdate: @escaping @MainActor (String) -> Void) async throws -> String
}
```

- **`AppleDictationSession`** (new, macOS 26+, `Sources/Services/Transcription/AppleDictationSession.swift`): wraps `SpeechAnalyzer`/`SpeechTranscriber` streaming. Volatile results replace the tail, finalized results accumulate; every change fires `onUpdate` with the full accumulated string. Locale: `transcription.forceLang` when set (ru/uk/en → matching locale), else `Locale.current`. First use may require a one-time language-asset install (`AssetInventory`) — surfaced as the engine-loading badge, not a distinct UI. `static var isSupported: Bool` gates on OS + locale availability.
- **Whisper lanes** reuse the existing provider machinery as a consumer: the dictation engine factory builds a `WhisperKitProvider` transcriber for the picked variant with a dictation config override `windowSec = 4` (v1's `windowSec = 10` override, tightened), `diarization = false`. Live pseudo-stream via the provider's existing `makeLiveSession`; the live output is the final raw text exactly as today. A thin `WhisperDictationSession` adapter conforms the existing path to `DictationTranscribing`.

## 3. DictationCenter changes

- The engine factory resolves from `dictation.model` (new `dictationEngineKey()`), not from the meeting `transcription.provider`/`transcription.model` keys. The warm-engine key (`warmEngineKey`) and the Settings-change invalidation follow the new key.
- `capture()` runs the session through `DictationTranscribing.run`; `onUpdate` feeds `liveText` as a **full replacement** (not append) — `DictationSpan.compose` already recomposes from `base`, so volatile refinement lands in the field naturally.
- Single-pass: the session's returned string is `rawText` → cleanup, as the live path already works today.
- **Buffer stays the safety net:** samples are still buffered from t0; if the session throws mid-dictation, the existing fallback batch-decodes the buffer — with the dictation engine (Whisper lanes) or, for the Apple lane, a batch re-run of a fresh Apple session over the buffered audio; if that also fails, the existing `.failed`-with-raw semantics apply. Speech is never lost by an engine failure.
- Engine-slot handshake (`meetingCaptureWillStart`, `hasResidentEngine`, warm TTL) keeps its semantics; the resident engine is now the (small) dictation engine. The Apple session holds no Whisper engine — `hasResidentEngine` is false for the Apple lane outside an active load, and the meeting recorder never needs to wait on it (its parked-live-pass check just sees no resident engine).
- `isEngineLoading` stays the badge driver: near-instant for Apple (asset install on first run), seconds for small/base.

## 4. UX

- No new chrome: the UX v2 capsule, levels, timer, pause, highlight all apply. The only visible change is speed — words appear as spoken (Apple) or every ~4 s (Whisper lanes), and the "Loading model…" badge becomes momentary for the default lane.
- Pause gates the mic samples (UX v2); the session simply receives no samples while paused — no session-side pause API.

## 5. Testing

- `DictationTranscribing` fake driving scripted updates: volatile replace → finalized accumulate → final return; pins that `liveText` is full-replacement, that pause produces no updates, that the returned final (not the last update) becomes `rawText`, and that a thrown session falls back to the buffer decode.
- Apple session logic (volatile/final accumulation, locale resolution) unit-tested behind the seam with `SpeechTranscriber` mocked; no real analyzer in tests.
- Whisper lane: config override (windowSec 4, dictation model key) pinned; existing DictationCenter suite keeps passing with the seam in place.
- Settings resolution: absent key → apple-on-26 / small-below; picker filtering.

## Out of scope

- Automatic per-language engine switching (uk detection).
- Realtime for meeting transcription.
- Qwen3/Parakeet dictation lanes.
- Changing the cleanup CLI or prompts.
