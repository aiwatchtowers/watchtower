# Dictation UX v2 — pause/resume, capsule control, live levels

**Date:** 2026-08-15
**Status:** Approved design, pre-implementation
**Predecessor:** `2026-08-11-voice-dictation-design.md` (v1 — the plumbing this design keeps intact)

## Problem

Four owner complaints about the v1 dictation UI:

1. The mic button is a bare `Image(systemName: "mic.fill")` in `.plain` style — too small to hit, no visual weight.
2. Engine load shows a bare spinner with no text; a cold WhisperKit load runs tens of seconds and reads as a hang — even though the mic is *already capturing* during the load (`MicRecorder.start()` runs before `resolveTranscriber`, and the unbounded `AsyncStream` buffers every sample).
3. There is no pause at all. Clicking the red mic = stop = finalize + AI cleanup. The owner expects a pause.
4. The target text field does not react visually while dictation writes into it — no signal about *where* the dictation is going.
5. (Added) No live volume level anywhere — neither in dictation nor in meeting recording — so there is no "the mic is alive" feedback.

## Decisions (owner-approved)

- Real pause/resume, not stop-with-catch-up.
- Expanding capsule control: normal-size mic button at rest, a capsule with level bars / timer / Pause / Stop while active.
- Loading presents as "already listening" (levels live, timer running) with a small "Loading model…" badge — no dedicated loading state visible to the user.
- Pause is implemented by gating samples (approach A): the mic stays hot while paused; safety automations below make sure it can never stay hot forever.
- Stop during engine load **finalizes** (waits for the engine, batch-decodes the buffer) instead of cancelling — speech spoken during the load is never lost. Cancel/Esc is the only discard path.
- Explicit Stop stays the delivery trigger (it alone runs `dictate clean`); pause never finalizes.
- Safety automations: silence > 2 min while recording → auto-pause; paused > 5 min → auto-stop with delivery. Constants in code, not Settings (v1).
- Rollout everywhere: the three inline surfaces (ChatInput, IdeaCreateSheet, Recording Notes tab) and Quick Capture.
- Meeting recording capsule also gains live levels — both mic and system RMS.

## 1. State machine (`DictationCenter`)

Phases become:

```
idle → recording ⇄ paused → stopping → cleaning → idle
                              ↘ failed (retriable, as today)
```

- **`loadingEngine` disappears as a visible phase.** After `recorder.start()` succeeds the center is `.recording` immediately; the engine loads concurrently and a new published flag `isEngineLoading: Bool` drives the badge. Live chunks start once the engine has loaded and caught up on the buffered stream. (`DictationPhase.loadingEngine` is removed; callers that matched on it move to `isEngineLoading`.)
- **`.paused`** — `MicRecorder.setPaused(true)`: the tap and `AVAudioEngine` keep running, converted samples are simply not yielded. To the Whisper windows a pause is a seamless audio splice, not a gap. Resume is instant.
- **`.stopping`** — new internal phase covering "stop pressed, waiting for the engine / batch decode" so the capsule can show "Transcribing…" when a stop lands during engine load. Skipped (straight to `.cleaning`) when the live pass already has the text.
- **Stop** at any point finalizes: wait for the engine if still loading, batch-decode the buffer if no usable live output, then `dictate clean`, then deliver. **Cancel** (Esc, host view disappearing, Quick Capture window closing) is the only discard path.
- New published fields:
  - `micLevel: Float` — RMS per chunk, computed in the existing feed loop in `capture()`.
  - `elapsed: Duration` — accumulated *recording* time; paused time does not tick. Derived from monotonic timestamps + accumulated pause spans, not a per-second timer.
  - `isEngineLoading: Bool`.

`DictationSpan`, the revert-toast ("Raw") logic, and the cleanup path (`runCleanup`, `DictationCleanService`) are unchanged.

## 2. Safety automations

Two code-constant automations guarantee the mic can never stay hot indefinitely even though pause keeps the session alive:

- **Silence auto-pause:** RMS below a silence threshold for > 2 consecutive minutes while `.recording` → auto-pause. Uses the same per-chunk RMS already computed for `micLevel` — no new DSP.
- **Pause timeout auto-stop:** `.paused` for > 5 min → the center performs a normal Stop (finalize + clean + deliver). Nothing is lost, nothing keeps holding the mic or the engine.

Both durations and the silence threshold are injectable for tests (the `engineIdleTTL` constructor-parameter precedent).

## 3. Capsule control (`DictationCapsule`)

Replaces `DictationButton`'s active states; `DictationButton` keeps its name, span management, and callback wiring — only the rendering changes.

- **Rest:** mic button with a visible background and a ~28 pt hit zone (today: bare glyph).
- **Recording:** animated expansion into a capsule: `[level bars | 0:42 | ⏸ | ■]`. While `isEngineLoading`, a compact "Loading model…" badge rides alongside and disappears when the first live chunk arrives (or the flag clears).
- **Paused:** `[Paused | 0:42 | ▶ | ■]`, static (no pulse).
- **Stopping/Cleaning:** `[spinner | Transcribing… / Cleaning…]`.
- **Failed:** as today — warning glyph + retry, message in the tooltip.

Esc now means Cancel (discard) — the `onExitCommand` binding moves from `stop()` to `cancel()`, since Stop has an explicit, always-visible button in the capsule and finalizing on Esc would surprise anyone using it to back out.

## 4. Field highlight

New `ViewModifier` — `.dictationHighlight(targetID:)` — applied to the text field next to each `DictationButton`:

- Accent-colored border with a soft pulse while `.recording`; static accent border while `.paused`; subtle background tint in both.
- Reads `DictationCenter` from the environment; active only when `center.activeTargetID == targetID`.
- Applied on all three inline surfaces (ChatInput, IdeaCreateSheet essence field, Recording Notes editor).

## 5. Quick Capture

Same states in its own window: opens straight into "Listening…" with live level + timer + loading badge; Pause/Stop/Cancel buttons; safety automations apply unchanged. `QuickCaptureState.derive` gains `.paused` (and the stopping projection); the ownership rules (`ownsCapture`) are untouched.

## 6. Meeting-recorder handshake

`meetingCaptureWillStart()` semantics with the new phases:

- `.recording`, `.paused`, and the (now internal) engine-loading window all take the finalize path: stop → deliver → drop the engine as soon as transcription completes (the existing `.recording` branch becomes the common one).
- The old "cancel during loadingEngine" branch dies with the phase — speech buffered during a load is real and gets delivered.
- `.idle`/`.failed`/`.cleaning` branches unchanged. The single-engine invariant and `dropEngineAfterCleanup` mechanics are untouched.

## 7. Meeting recording levels

- `SystemAudioRecorder` exposes live levels — the same per-cycle mic RMS / system RMS it already computes for the `rec_X.activity` sidecar (raw pre-AGC values), throttled to ~10 Hz onto the MainActor via a callback/published hop (the IOProc runs on the audio thread).
- `MeetingRecorderCenter` republishes as `captureLevels: (mic: Float, system: Float)`.
- The recording capsule in `RecordingIndicatorView` renders two mini level indicators (mic + system), answering both "is my mic alive" and "is system audio actually being captured" at a glance.
- No change to the sidecar format, the AGC, or `RoleAssigner`.

## Testing

- `DictationCenterTests`: pause gates samples out of the buffer; resume continues the same session; stop-during-engine-load delivers text; silence auto-pause and pause-timeout auto-stop (injected thresholds/clock); handshake from `.paused` finalizes; cancel still discards.
- `QuickCaptureState.derive`: new `.paused`/stopping cases.
- `DictationSpan`: unchanged, existing tests stand.
- Capsule/highlight follow the async-state house rule (start → navigate away → come back), covered via the existing environment-injection pattern.
- Meeting levels: throttling math and raw-vs-AGC source pinned in `SystemAudioRecorder` tests.

## Out of scope (v1 of this redesign)

- Settings knobs for the automation timeouts/threshold.
- Releasing the mic hardware while paused (approach B) — revisit only if the hot-mic indicator during pause proves annoying in practice.
- Waveform history rendering; simple level bars only.
- Any change to Go, the CLI, or the cleanup prompt.
