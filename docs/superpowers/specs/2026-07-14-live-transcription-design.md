# Live (in-progress) Meeting Transcription — Design

**Date:** 2026-07-14
**Branch:** feature/meeting-transcriber
**Builds on:** [2026-07-13-meeting-transcriber-design.md](2026-07-13-meeting-transcriber-design.md)
**Status:** design approved, pending implementation plan

## 1. Problem

Today transcription is strictly batch: `MeetingRecorderCenter.startRecording` writes the
whole meeting to a `.caf` file, and only on `stopAndProcess` is the file decoded in full and
fed to `WindowedTranscriber` window-by-window. The user waits for the entire transcription
*after* the recording ends.

The user wants transcription to run **while recording is in progress** — not live subtitles,
but a "pulse" view: normal-sized chunks appear as they are transcribed so the user can watch
progress and judge transcription quality mid-meeting. **Quality is the priority.** Some lag is
fine.

## 2. Chosen shape (option "C")

- **Full-size windows, single-pass.** Windows stay at the current 20 s (quality does not
  degrade; ru/uk/en sticky-language detection stays reliable on full windows).
- Transcription runs **in parallel with recording**; each finished chunk is shown immediately.
- **Single-pass:** what is shown during the meeting is what is saved to the DB and fed to
  recap. No second pass, no short "draft" windows.
- Expected lag ≈ 20–25 s (window length + processing). This is acceptable — the user asked for
  a pulse, not subtitles.

### Model
The live pass uses **the model already selected in Settings** (`transcription.model`, default
`large-v3`). We do NOT force `large-v3-turbo`. Consequence the user accepted: on `large-v3` the
M1-Pro-class real-time factor is marginal (≈1.2–1.5×), so lag may slowly accumulate on a long
meeting and the tail finishes shortly *after* Stop (a shorter version of today's wait). A user
who wants a near-empty tail can switch to `large-v3-turbo` themselves (~5× faster, +0.39 pp WER
— negligible, especially on ru/uk).

### Feasibility (recorded for posterity)
- large-v3 on M2 ≈ 1.9× real-time; M1 Pro ≈ 1.2–1.5× → marginal but > 1, so it generally keeps
  up; the tail may finish after Stop.
- large-v3-turbo ≈ 5× on Apple Silicon, ~1.5–2 GB RAM, +0.39 pp WER — comfortable headroom, lag
  stays flat all meeting.
- True 1–2 s subtitles are NOT achievable on on-device Whisper without a different incremental
  decoder architecture — out of scope and not requested.
- Resource cost: continuous ANE use + audio capture over a long meeting noticeably drains
  battery and warms the machine. On mains power it is a non-issue.

## 3. Architecture

Three changes, **zero** breakage of the existing batch path.

```
SystemAudioRecorder ──(live 16k PCM chunks)──► StreamingTranscriber ──(chunk text)──► MeetingRecorderCenter ──► UI
        │                                                                                      │
        └──────────────(writes .caf file, as today)───────────────────────────────────────────┘
                                    file = source of truth for crash recovery / retry
```

### 3.1 `AudioRecording` protocol — live sample stream
Add `var liveSamples: AsyncStream<[Float]> { get }` delivering 16 kHz mono Float32 samples.

`SystemAudioRecorder` already produces exactly this format in `appendDownsampled`
(`outBuffer` = converter output, 16 kHz mono Float32) right before writing to the file. The tap
point is there: after a successful `audioFile.write`, copy `outBuffer`'s float channel data into
the stream continuation. **No decoding anywhere.** The fake recorder in tests emits samples
manually — no CoreAudio.

The stream continuation buffers (unbounded) so samples captured before the engine finishes
loading are not lost.

### 3.2 `StreamingTranscriber` (new)
Consumes the sample stream, accumulates samples into a buffer, and cuts **the same 20 s windows
with the same step** as `WindowedTranscriber`. Processes each full window as soon as enough
samples have arrived and emits `(chunkText, lang)`. On stream close (Stop) it finalizes the
remaining tail (≤ 20 s) as the last window and returns a final `TranscriptionOutput` — **same
shape** (`text` + `langStats`) with the **same sticky-language logic**.

The window-slicing math and `chooseLanguage` are **shared** between `StreamingTranscriber` and
`WindowedTranscriber` (extracted, not duplicated), so the two paths cannot drift.

**Invariant:** the final output of the streaming path and the batch path over the same samples
are equivalent (same window boundaries, same sticky language, same `langStats` shape). This is
what guarantees single-pass does not cost quality.

### 3.3 `MeetingRecorderCenter` — lifecycle

**`startRecording`** (recording never waits for the model):
1. Start `recorder` — audio hits the file immediately, even while weights download.
2. In the background, `engineFactory(config)`. While it loads (first run = weight download),
   live samples buffer in the stream — nothing is lost.
3. When the engine is ready, `StreamingTranscriber` drains the queued samples and catches up.

If the engine never loads (no network for download, CoreML error): the live pass silently does
not start, recording continues normally, and Stop runs the batch path from the file. No
mid-meeting error in the user's face.

**Phases.** `.recording(startedAt:)` keeps its meaning ("we are capturing"). During recording
the Center accumulates an observable `liveChunks: [LiveChunk]` (text + language + index) — a
**separate field**, not stuffed into the enum's associated value, so live-text updates do not
replay the phase and cannot disturb the phase-transition guard tests. A live-engine sub-state
(`liveEngine: .off | .loading | .running | .unavailable`) drives the UI's "live vs fallback"
signal.

**`stopAndProcess`** branches on whether the live pass was alive:
- **Live path worked** → close the sample stream, `StreamingTranscriber` finishes the tail,
  returns the final `TranscriptionOutput`, go straight to the existing `saveTranscript`. **The
  file is NOT decoded or transcribed again.**
- **Live path absent / failed** → today's `transcribeAndSave(audioURL:)`: decode file + batch
  `WindowedTranscriber`.

**Crash recovery / retry** — unchanged. `pendingAudioURL`, sidecar persist,
`restorePendingOnLaunch`, `retryTranscription` all work through the file exactly as today. The
in-memory live transcript is an ephemeral accelerator; if it does not survive to save, truth is
re-derived from the file.

**"начал → ушёл → вернулся":** live chunks live in the `AppState`-held Center, never in a
view-local VM — leave the event screen and come back, the live text is still there. Same
contract as `TargetExtractCenter`.

## 4. UI — expandable panel from the capsule

Only the `.recording` phase of `RecordingIndicatorView` changes.

**Collapsed (default, as today + one control):**
```
🔴  12:34   [›]   [■ Stop]
```
`›` expands. A tiny live-engine indicator sits alongside: spinner on `.loading`, nothing on
`.running`, a muted "text unavailable" glyph on `.unavailable`.

**Expanded:**
```
┌────────────────────────────────────┐
│ 🔴 12:34        [ru]      [⌄] [■]   │
│────────────────────────────────────│
│ …earlier chunks…                    │
│ [ru] Давайте обсудим релиз…          │
│ [en] So the deadline is next Friday │
│ [uk] Я підготую документацію…        │  ← autoscroll to bottom
└────────────────────────────────────┘
```
- Autoscrolling list of finished chunks; language tag per chunk (the user explicitly wants to
  judge transcription quality, and language on a multilingual meeting is part of that).
- `⌄` collapses back to the capsule.
- Fixed max size (≈ 420×320) with an inner `ScrollView`. Stays the global bottom-trailing
  overlay — visible from every screen, survives navigation.
- Expanded/collapsed is view-local `@State` (a pure visual preference; no reason to live in the
  Center).
- `.loading`: panel shows "Loading transcription model…". `.unavailable`: "Live transcript
  unavailable — the transcription will appear after you stop." Honest, non-alarming.

Other capsule phases (`.transcribing` fallback path, `.summarizing`, `.failed`, recovered pill)
are unchanged.

## 5. Error handling & edge cases

| Situation | Behavior |
|---|---|
| Engine never loaded by end of meeting | Live path `.unavailable`; Stop runs batch from file. Queued sample tail is discarded (file is complete anyway). |
| `StreamingTranscriber` errors on one window | Same as `WindowedTranscriber`: window skipped, language does not stick, continue. Total engine failure (no text at all) → Stop falls back to batch from file, not an empty transcript. |
| large-v3 can't keep up (RTF < 1) | Stream queue grows; tail is finished at Stop — exactly today's wait, just shorter. UI honestly shows catch-up progress. |
| Silence / no speech whole meeting | Live chunks empty; final empty → existing "No speech recognized" branch. |
| Recording cut short (`writeFailed`) | As today: `stop()` throws, partial file kept; fallback batch works on what was written. |
| Stop pressed before engine ready | Close stream; if no chunk ready → fallback batch from file. |

## 6. Testing

All without CoreAudio / WhisperKit — engine and recorder are injected (as today).

- **`StreamingTranscriberTests`** — feed a known sample stream in arbitrarily-sized pieces
  (including non-window-multiples); assert window boundaries and `langStats` match
  `WindowedTranscriber` on the same samples; tail finalizes on close; empty stream → empty
  output; **degenerate input** (stream closes mid-window, single short chunk) per the
  test-degenerate-clean-exit rule.
- **`MeetingRecorderCenterTests`** (extend; existing tests untouched) — live path succeeds →
  saved without re-decoding; engine `.unavailable` → fallback batch; crash/relaunch → recovery
  from file; "начал → ушёл → вернулся" live chunks intact.
- Fake recorder drives a controllable `liveSamples` stream; fake engine returns predictable
  per-window text.

**Verify (not just tests):** build the dev app (`make app-dev`), record a short real meeting,
confirm by eye that live text flows with the expected lag and the final matches the batch
result — per the "drive the feature, not only tests" rule.

## 7. Out of scope
- True low-latency subtitles (1–2 s) — needs a different incremental decoder.
- Forcing turbo or any model-selection UX change — the user picks the model in Settings.
- Any change to persistence, crash recovery, retry, `meeting_transcripts`, or the Go/CLI side —
  the live pass is purely a Swift-side accelerator over the existing save path.
