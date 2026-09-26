# WhisperKit Model Prefetch — Design

**Date:** 2026-07-14
**Status:** approved design
**Origin:** follow-up to the Meeting Transcriber (`docs/superpowers/specs/2026-07-13-meeting-transcriber-design.md`). Today the WhisperKit model downloads lazily on first `stop()`, and the download progress is silently discarded (`MeetingRecorderCenter.defaultEngineFactory` passes `{ _ in }` as the progress callback) — the user sees a misleading indeterminate "Transcribing…" spinner while a multi-GB model actually downloads.

---

## 1. Problem & Goals

**Problem:** model download is invisible and happens at the worst possible time — right after the user stops recording, when they're waiting to see their transcript.

**Goals:**

- Start downloading the configured Whisper model *before* the user needs it, so by the time they stop a recording the model is (usually) already on disk.
- Show honest download progress, distinct from transcription progress.
- Never block or gate recording on model availability — recording must remain fully independent of WhisperKit, as it is today.

**Non-goals:**

- Eager download at app launch (explicitly rejected — see trigger choice below).
- Pre-loading the model into memory ahead of time (only the on-disk files are prefetched; `WhisperKit(config)` instantiation stays lazy in `transcribeAndSave`, avoiding holding model weights in memory before they're needed).
- Automatic retry/backoff on network failure — failures surface as an actionable state, not a silent retry loop.

---

## 2. Architecture

New service `TranscriptionModelProvisioner` (`@MainActor @Observable`, held by `AppState` next to `meetingRecorderCenter`), decoupled from `MeetingRecorderCenter.Phase`:

```swift
enum State: Equatable {
    case idle
    case downloading(progress: Double)
    case failed(String)
}
```

It is decoupled — not a new case bolted onto `Phase` — because recording and model download are independent axes: a recording can be in progress while the model is *also* downloading (e.g. the user starts recording before the calendar tab has finished priming the model). `Phase` is a single-value state machine; representing two concurrent things in one enum would force an artificial precedence between them.

`TranscriptionModelProvisioner` only ensures the model **files** are on disk — it does not instantiate `WhisperKit`. `WhisperKitEngine.load` is split so both call sites share the download step:

```swift
// WhisperKitEngine.swift
static func ensureModelFilesDownloaded(
    modelName: String,
    downloadProgress: @escaping @Sendable (Double) -> Void
) async throws {
    _ = try await WhisperKit.download(variant: modelName) { progress in
        downloadProgress(progress.fractionCompleted)
    }
}

static func load(modelName: String, downloadProgress: ...) async throws -> WhisperKitEngine {
    try await ensureModelFilesDownloaded(modelName: modelName, downloadProgress: downloadProgress)
    let modelFolder = ... // resolve local path, same as today
    let config = WhisperKitConfig(modelFolder: modelFolder.path, verbose: false, load: true)
    return WhisperKitEngine(whisperKit: try await WhisperKit(config))
}
```

`WhisperKit.download` is incremental (already-complete files are skipped), so calling it from the provisioner ahead of time and again from `load()` at transcribe time is safe and cheap when the prefetch already finished — the second call is a fast no-op disk check, not a re-download.

---

## 3. Triggers

Two trigger points (no app-launch prefetch — the user only wants this warmed by the time they'd plausibly hit Stop, not paid for on every cold start):

- **`CalendarEventsView.onAppear`** → `appState.modelProvisioner.ensureDownloaded(modelName: currentModelSetting)`, using the same `UserDefaults` key (`transcription.model`) `MeetingRecorderCenter.defaultEngineFactory` already reads.
- **Settings model `Picker` `onChange`** → `ensureDownloaded(modelName: newValue)` for the newly selected model, so switching models doesn't silently defer the cost to the next recording.

`ensureDownloaded(modelName:)` dedups:

- Same model already `.downloading` → no-op (existing `Task` keeps running).
- Different model requested while one is in flight → cancel the in-flight `Task`, start a new one for the newly requested model (only the currently-selected model is worth prefetching).
- `.failed` or `.idle` → starts a fresh download `Task`.

---

## 4. UI

`RecordingIndicatorView` changes from a single `switch` over one `Phase` to rendering **up to two independent capsules** stacked in its overlay: the existing recording/transcribing/summarizing/failed capsule (unchanged, bound to `MeetingRecorderCenter.phase`), plus a new provisioner capsule (bound to `TranscriptionModelProvisioner.state`) that can appear at the same time:

- `.downloading(progress)` → determinate `ProgressView(value: progress)` + `"Downloading model… \(Int(progress * 100))%"` — replacing the old indeterminate spinner/misleading "Transcribing…" text for the download phase specifically.
- `.failed(message)` → same visual pattern as the existing `failedCapsule`: warning icon, message, **Retry** (re-invokes `ensureDownloaded` for the same model) and **Dismiss** (hides the capsule; does not retry automatically — the next natural trigger, reopening Calendar or re-selecting the model in Settings, will try again).
- `.idle` → nothing rendered.

The existing `.transcribing(done: 0, total: 0)` → "Transcribing…" case in the recording capsule is unchanged; it now covers only the (much shorter) in-memory `WhisperKit(config)` instantiation step, since the download itself was very likely already primed by the provisioner.

---

## 5. Error handling

| Failure | Behavior |
|---|---|
| Network/HF Hub error during prefetch | `TranscriptionModelProvisioner.state = .failed(message)`; capsule shows Retry/Dismiss. Recording is unaffected — it never reads this state. |
| Prefetch never completes before recording stops | `transcribeAndSave`'s `engineFactory` → `WhisperKitEngine.load` runs its own download step as today (safety net); if the provisioner had already fetched everything this is a fast no-op, otherwise it falls back to the existing (now honestly-labeled) in-line download behavior. |
| Model changed in Settings mid-download of the old model | Old `Task` cancelled, no error surfaced for the cancelled model — cancellation is expected, not a failure. |

---

## 6. Testing

**Swift:**
- `TranscriptionModelProvisioner` unit tests with an injected download function (mirrors `MeetingRecorderCenter`'s `engineFactory` injection pattern — no real WhisperKit/network in tests):
  - dedup: calling `ensureDownloaded` twice with the same model while in flight only starts one download.
  - model-change cancellation: requesting a different model cancels the prior `Task` and starts a new one.
  - `.failed` transition on injected error, and Retry re-invokes the download for the same model.
  - Dismiss from `.failed` returns to `.idle` without retrying.
- `RecordingIndicatorView` renders both capsules simultaneously when `MeetingRecorderCenter.phase == .recording` and `TranscriptionModelProvisioner.state == .downloading` at once (the "начал → ушёл → вернулся"-style state independence check, adapted: two independent state machines, not one).
- `WhisperKitEngine.ensureModelFilesDownloaded` extraction: verify `load()` still works end-to-end (existing coverage), no new WhisperKit-facing behavior beyond the split.

**Manual acceptance:**
- Open Calendar tab on a machine without the model cached → provisioner capsule shows real progress; start and stop a recording mid-download → recording capsule and download capsule both visible; after download completes, download capsule disappears and transcription proceeds without re-downloading.
- Switch model in Settings while the old model is still downloading → old download stops, new one starts.
- Disconnect network, trigger a prefetch → `.failed` capsule with Retry; reconnect, hit Retry → succeeds.
