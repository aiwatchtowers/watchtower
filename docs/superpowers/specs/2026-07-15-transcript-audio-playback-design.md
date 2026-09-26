# Transcript Text + Audio Playback for Meeting Recordings — Design

**Date:** 2026-07-15
**Branch:** feature/meeting-transcriber
**Status:** design approved, pending implementation plan

## 1. Problem

Two gaps in reviewing a finished recording:

1. **Ad-hoc recordings show no transcript text.** `CalendarEventsView.adHocRow` (recordings not
   linked to a calendar event) renders only title/date/duration/summary. The full
   `transcriptText` is fetched but never displayed. Event-linked recordings
   (`TranscriptSectionView.transcriptRow`) already expose it via a `DisclosureGroup` with a
   selectable `ScrollView` of text — the ad-hoc path never got the same treatment.
2. **No audio playback anywhere.** `MeetingTranscript.audioPath` points at the source `.caf` file
   (until the retention-day sweep NULLs it, default 30 days — see
   `docs/inventory/` and `ConfigService.transcriptAudioRetentionDays`), but nothing in the app
   plays it back. The only existing use of `audioPath` is `TranscriptSectionView`'s
   "Re-transcribe" button.

Trigger: a 20 s ad-hoc test recording finished transcribing (slowly, a separate/already-known
cost), and the user wanted to (a) read the transcript log and (b) listen to the source audio —
neither was possible.

## 2. Scope

Both entry points get the same treatment:
- `CalendarEventsView.adHocRow` (ad-hoc, unlinked recordings)
- `TranscriptSectionView.transcriptRow` (event-linked recordings)

No changes to the Go/CLI side, persistence, or retention sweep — this is purely a Swift/Desktop
read-and-playback feature over data that already exists.

## 3. Architecture

Three new/changed pieces, one dedupe:

```
AppState
  └── audioPlaybackCenter: AudioPlaybackCenter      (new, @Observable, one AVAudioPlayer)
                │
                ├── used by ── AudioPlayerControlView   (new, reusable SwiftUI view)
                │                     │
                │                     ├── embedded in ── TranscriptSectionView.transcriptRow (event-linked)
                │                     └── embedded in ── CalendarEventsView.adHocRow          (ad-hoc, becomes a DisclosureGroup)
                │
     TranscriptFormatting.swift (new)  ← formatDuration/formattedDate/langBadges,
                                          deduped out of both views above
```

### 3.1 `AudioPlaybackCenter` (new)

`@Observable` class, held on `AppState` (same pattern as `MeetingRecorderCenter`,
`TargetExtractCenter` — survives navigation away/back, per the project's "async ops need
surviving state" rule). Wraps a single `AVAudioPlayer` instance.

Public interface:
```swift
func play(url: URL, transcriptID: Int64) throws   // stops any current playback first
func pause()
func seek(to time: TimeInterval)
var activeTranscriptID: Int64?
var isPlaying: Bool
var currentTime: TimeInterval
var duration: TimeInterval
```

- **Single active player.** `play` always stops/releases the previous `AVAudioPlayer` before
  constructing the new one. Only one recording plays at a time app-wide — the user confirmed
  this is the wanted behavior (macOS-native expectation), not two independent audio streams.
- **Progress updates** via a `Timer` (0.1–0.2 s tick) publishing `currentTime` while
  `isPlaying`; invalidated on `pause`/`stop`/deinit.
- **`play` throws** if `AVAudioPlayer(contentsOf:)` fails (e.g. file missing despite a non-nil
  `audioPath` — should not happen normally, but the file is on disk, not guaranteed). Callers
  (the control view) turn this into an inline error message, never a crash.
- Scoped to Desktop `Sources/Services/AudioPlaybackCenter.swift`.

### 3.2 `AudioPlayerControlView` (new)

Reusable SwiftUI view: play/pause button + `Slider` (scrubber, bound to `currentTime`/`duration`,
seeks `AudioPlaybackCenter` on drag-end) + `elapsed / duration` labels.

```swift
struct AudioPlayerControlView: View {
    let transcriptID: Int64
    let audioURL: URL
}
```

Reads `AudioPlaybackCenter` via `@Environment(AppState.self)`; compares
`center.activeTranscriptID == transcriptID` to decide whether it is the row currently driving
`currentTime`/`isPlaying`, or an idle row showing 0:00 / full duration.

If the transcript's `audioPath` is `nil` (deleted by the retention sweep), the caller does not
render this view at all — instead a small caption: **"Recording deleted"** (audio retention
default 30 days, transcript text is kept forever) — so the missing control is explained rather
than silently absent.

Scoped to `Sources/Views/Calendar/AudioPlayerControlView.swift`.

### 3.3 Dedupe: `TranscriptFormatting.swift` (new)

`formatDuration(_:)`, `formattedDate(_:)`, and `decodeLangStats`/`langBadges(_:)` are currently
duplicated near-verbatim in both `TranscriptSectionView` and `CalendarEventsView`. Extract them
as free functions (or an extension on `MeetingTranscript`) into
`Sources/Views/Calendar/TranscriptFormatting.swift`, and have both views (plus the new control
view, which needs duration formatting for labels) call the shared versions. Pure refactor, no
behavior change.

### 3.4 `CalendarEventsView.adHocRow` — becomes expandable

Converted from a flat `HStack` row into a `DisclosureGroup`, mirroring
`TranscriptSectionView.transcriptRow`'s shape:

- **Label** (always visible, collapsed): title, date, duration — as today.
- **Expanded content**: lang badges, summary (if present), full `transcriptText` in a
  `ScrollView` (`.textSelection(.enabled)`, max height ~300, matching the event-linked view),
  `AudioPlayerControlView` (or "Recording deleted" caption), and the existing "Link to event…"
  button.

### 3.5 `TranscriptSectionView.transcriptRow` — gains playback

Add `AudioPlayerControlView` (or the deleted-caption) inside the existing `DisclosureGroup`,
above the "Retry recap" / "Re-transcribe" button row. Text display is unchanged — it already
works.

## 4. Error handling & edge cases

| Situation | Behavior |
|---|---|
| `audioPath == nil` (retention sweep already ran) | No player control; "Recording deleted" caption instead. |
| `audioPath` set but file missing/corrupt on disk | `AudioPlaybackCenter.play` throws; control view shows an inline `Text` error, no crash. |
| User starts playback on row B while row A is playing | `AudioPlaybackCenter.play` stops A's player first; row A's control view re-renders idle (its `activeTranscriptID` check flips false). |
| User collapses a `DisclosureGroup` while its audio is playing | Playback continues (center-held state, not view-local) — same "survives navigation" pattern as the rest of the app. Stopping only happens when another row's play is pressed, or the user pauses. |
| View disappears entirely (e.g. switching calendar days) while playing | Out of scope for this pass — playback keeps running via the AppState-held center exactly as intended; no special teardown needed since the center is not view-scoped. |

## 5. Testing

- **`AudioPlaybackCenterTests`** (new) — a fake/injectable player backend (protocol-wrapped, same
  DI shape as `MeetingRecorderCenter`'s `engineFactory`) to test without touching real audio
  hardware: `play` stops a prior active player (single-active invariant); `play` on a bad URL
  surfaces an error and does not change `activeTranscriptID`; `pause`/`seek` update state as
  expected; degenerate input (zero-duration file, seek past duration) per the
  test-degenerate-clean-exit rule.
- View-level changes (`DisclosureGroup` conversion, control embedding) are not unit tested, per
  existing convention for `TranscriptSectionView`/`CalendarEventsView` — verified by hand.
- **Verify (not just tests):** build the dev app (`make app-dev`), open both an ad-hoc and an
  event-linked recording, confirm text expands and audio plays/pauses/seeks correctly, and that
  starting playback on a second recording stops the first.

## 6. Out of scope

- Any change to the Go/CLI side, the `meeting_transcripts` schema, or the audio retention sweep.
- Waveform visualization, playback speed control, or trimming/editing audio.
- Multiple simultaneous playback streams (explicitly rejected — single active player only).
- Making the transcription pipeline itself faster (the slow-transcribe report that triggered
  this feature request is a separate, already-tracked concern).
