# Qwen3 Windowed Transcription (batch + live) — Design

**Date:** 2026-07-30
**Status:** approved by owner (chat), pre-implementation
**Branch:** worktree-qwen3-windowed (off main; includes the mlx.metallib packaging fix)

## Problem

`Qwen3Provider` feeds the entire recording to `Qwen3ASRModel.transcribe` in one
call (speech-swift 0.0.7 exposes no chunked batch API). Measured GPU peak grows
~0.6 GB per audio minute (2 min → 2.0 GB, 5 min → 3.9 GB, 10 min → 6.1 GB), so
an hour-long meeting on a 16 GB machine is a near-certain OOM kill. Full-clip
output also carries no timestamped segments, so the diarization post-pass
(speaker roles) silently does nothing for Qwen3, and `supportsLive == false`
means no live panel while recording.

speech-swift's own `StreamingASR` is not a live-input API — it takes a complete
buffer up front (VAD-segmented decode over it). Live input has to be built on
our side, the same way the WhisperKit path does it.

## Decision

One new component, `Qwen3Windower`, gives Qwen3 bounded memory, live support,
and diarization-ready segments — without touching the Whisper-internal stack.

### 1. Core: one code path for batch and live

`Qwen3Windower` (new file `Sources/Services/Transcription/Providers/Qwen3Windower.swift`)
mirrors `StreamingTranscriber`'s buffer/boundary mechanics but is Qwen3-private:

- Windows come from the shared `WindowPlanner` — same `windowSec` (default 20 s),
  silence-snapping, and overlap the user already configures.
- Each window is decoded by a synchronous injected closure
  `decode: ([Float]) throws -> String` (production: `Qwen3ASRModel.transcribe`
  on the window; tests: a fake — no model, no Metal).
- Window texts are trimmed, empty windows dropped, survivors joined with `\n`;
  each non-empty window yields one `TranscriptSegment` with absolute
  window-start/end timestamps.
- **Batch is the same loop fed by a single-yield `AsyncStream`** holding the
  whole file buffer; live is the recorder's real stream. Batch↔live equivalence
  holds by construction (one code path), not by a pinned invariant.
- Batch pre-plans `planner.planWindows` only to know the window total for
  `progress(done, total)`; live reports chunks via `onChunk(StreamChunk)`
  exactly like the Whisper live session.

`WindowedTranscriber` / `StreamingTranscriber` / `resolveWindowLanguage` stay
Whisper-internal per CLAUDE.md; nothing in them changes and their pin test is
untouched.

### 2. Language

Qwen3 0.0.7 exposes no language detection, so there is no sticky-language
machinery:

- `TranscriptionConfig.forcedLanguage` set → passed as the `language:` hint to
  every window; `langStats` counts windows under that code.
- Otherwise `language: nil` — the model auto-detects per window internally (it
  strips its own "language XX" prefix); `langStats` stays empty (as today) and
  segments carry language label `"auto"`.

### 3. What this buys

- **Memory:** peak bounded by one ~20 s window. Measurement (10-min clip,
  32 windows) showed the MLX buffer cache DOES grow without bound across
  windows (3.9→8.2 GB; snapped windows vary in shape so cached buffers are
  never reused), so the decode closure clears the cache per window
  (`GPU.clearCache()`, Qwen3-private). Post-fix: cache 0 MB flat,
  process footprint 1.8 GB and GPU peak ~2.0 GB regardless of clip length
  (vs 6.1 GB GPU peak full-clip at 10 min), and the run got ~3× faster
  (18 s vs 52 s — cache thrash was costing time too).
- **Live:** `supportsLive → true`, `makeLiveSession` returns a session running
  the same windower; finalized window chunks appear in
  `RecordingIndicatorView`'s panel. The Settings capability caption updates by
  itself (it reads `supportsLive`).
- **Speaker roles:** timestamped segments now exist, so the diarization
  post-pass works for Qwen3. Granularity is one segment per ~20 s window —
  coarser than Whisper's sub-window segments; a window spanning two speakers
  gets one label. Documented limitation, acceptable v1.

### 4. Error handling

Same semantics as `StreamingTranscriber`:

- A window whose decode throws is skipped and remembered; the run throws only
  if **every** window failed (partial transcript beats none).
- Cooperative cancellation via `Task.isCancelled` at the loop tops.
- The `.caf` file remains the source of truth; live failure falls back to the
  batch path from file, unchanged.

### 5. Tests

`Qwen3WindowerTests` (fake decode closure, no model):

- window boundaries equal `WindowPlanner.planWindows` on the same samples;
- text join / segment timestamps / progress counts;
- batch == live output on the same samples (wrapper-level check);
- live chunk emission order and indices;
- empty-text windows dropped and not counted;
- all-windows-failed throws, some-windows-failed returns partial text;
- cancellation returns promptly with partial output.

`Qwen3ProviderTests`: `supportsLive` flips to true; metadata still sane.

### 6. Docs touched

- CLAUDE.md transcriber note: "live transcription remains WhisperKit-only" →
  WhisperKit + Qwen3; Qwen3 no longer batch-only.
- docs/app-guide.md: engine capability wording.

## Out of scope

- VAD-guided segmentation (SileroVAD) — rejected: extra model download, ≤10 s
  force-split, auto-language only, and live would still need our windower.
- Per-window language detection / sticky language for Qwen3 — no upstream API.
- Sub-window segment timestamps (Qwen3 returns plain text per window).
