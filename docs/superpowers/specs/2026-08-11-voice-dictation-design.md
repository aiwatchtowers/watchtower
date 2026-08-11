# Voice Dictation — Design

**Date:** 2026-08-11
**Status:** Approved by owner (brainstorm 2026-08-11)

## Goal

Let the owner dictate text instead of typing it, anywhere free-form text is written in
the Desktop app: the idea create sheet, meeting notes, every Discuss chat, and a global
"quick capture" flow that turns a spoken thought into a registry idea without opening
the main window. Dictation is transcribe-then-clean: Whisper produces a raw transcript
live while the owner speaks; on stop, a light AI pass turns it into polished text shaped
for the destination.

## Non-goals (v1)

- Crash recovery for in-flight dictations (a dictation is minutes long; the recovery
  path is "say it again").
- Voice *commands* ("create a target called…") — this is dictation, not a voice UI.
- A dedicated dictation model setting — dictation rides the existing Settings engine
  and model choice.
- Settings toggle for engine residency (a fixed idle TTL covers it).
- iOS/mobile.

## Architecture

### DictationCenter (new, Swift)

An `@Observable` center living on `AppState` (the `MeetingRecorderCenter` /
`TranscriptNotesCenter` house pattern: async state survives navigation). One dictation
at a time, app-wide.

State machine: `idle → loadingEngine → recording(liveText) → cleaning → idle`, plus
`failed(message)` with retry. The center owns:

- the target text binding and the span boundary (dictated text is appended at the end
  of the field; the center remembers where its span starts so cleanup can replace
  exactly the dictated span),
- the raw transcript (kept after cleanup for the "Raw" revert affordance),
- the in-memory 16 kHz sample buffer (source for batch decode; ~4 MB/min, never
  written to disk),
- the cleanup mode for the active dictation.

### MicRecorder (new, Swift)

A lightweight mic-only capture: `AVAudioEngine` input-node tap, downsampled to 16 kHz
mono `Float`, exposed as `AsyncStream<[Float]>`. Deliberately none of the meeting
recorder's machinery: no system audio, no aggregate device, no `MicAGC`, no
`rec_X.activity` sidecars, no files on disk. The mic TCC permission is already granted
in practice (meeting recording uses the mic); the standard system prompt on first use
is expected and acceptable — it is user-initiated from the app, not a daemon-spawned
CLI prompt.

### Transcription path

Reuses the existing provider stack and the Settings engine/model choice, with a
dictation-tuned config: `TranscriptionConfig.fromDefaults` overridden with
`windowSec = 10` (the meeting default of 30 s is too laggy for a live dictation
preview) and `diarization = false`; the `transcription.liveTranscription` meeting
toggle is not consulted — dictation live-ness is decided by the provider alone.

- Live-capable provider (WhisperKit via `StreamingTranscriber`, Qwen3 via its own
  windower loop): raw text streams into the field window by window while speaking.
- Batch-only provider (Apple, Parakeet): only a level/recording indicator while
  speaking; decode runs on stop from the in-memory buffer.

Dictation is a *consumer* of the transcription stack. It must not modify
`StreamingTranscriber`, `WindowedTranscriber`, `WindowPlanner`, or the live↔batch
equivalence pins.

### Engine lifecycle ("sticky engine")

- The first dictation loads the engine (visible `loadingEngine` state; warm load is
  seconds).
- After a dictation ends the engine stays resident for **15 minutes** past last use
  (constant in v1), then unloads. Dictations cluster in practice; the second and later
  ones in a cluster start instantly.
- **Single-engine invariant, both directions:**
  - While `MeetingRecorderCenter.isBusy` (active capture OR any non-failed processing
    job), the dictation mic button is disabled with an explanatory tooltip.
  - Starting a meeting recording immediately unloads an *idle* resident dictation
    engine; if a dictation is actively recording, it is auto-stopped (what was said is
    cleaned and delivered to its field) — meeting capture wins.

### AI cleanup: CLI command + prompt

- New prompt **`dictation.clean`** (cheap/light tier, registered for both claude and
  codex providers per the add-ai-prompt flow). One prompt, a mode parameter in the
  user message.
- New CLI command **`watchtower dictate clean --mode idea|note|chat --transcript-file
  <path>`**. The transcript travels by file (never argv; stdin threshold rules apply
  as elsewhere). Pure transform: no DB reads or writes. Output is a JSON envelope on
  stdout:
  - `idea` → `{"mode":"idea","title":"…","body":"…"}`
  - `note` → `{"mode":"note","markdown":"…"}`
  - `chat` → `{"mode":"chat","text":"…"}`
  - failure → non-zero exit with the error on stderr (no JSON envelope)
- Cleanup output language = dictation language (Russian in → Russian out).
- Mode semantics:
  - **idea**: distill to an idea title + body. The sheet fills the body always and the
    title only when the title field is empty.
  - **note**: coherent markdown note; keep the author's structure and level of detail,
    remove fillers and false starts.
  - **chat**: minimal cleanup only — drop fillers/self-corrections, preserve the
    intent verbatim (the Discuss secretary interprets the text downstream; heavy
    rewriting would distort the owner's intent).
- Swift-side failure handling: if `dictate clean` fails, the raw transcript stays in
  the field and a non-blocking error is shown ("cleanup failed, raw text kept") —
  never silently drop either the error or the dictated text.

### UI primitive

`DictationButton(text: Binding<String>, mode: DictationMode)` — a mic button placed
next to a text field. Behavior:

- Tap → engine loads if needed → pulsing recording indicator; raw text appends into
  the bound field as windows finish (live providers).
- Tap again (or Esc) → stop → `cleaning` spinner → the dictated span is replaced by
  the cleaned text.
- A transient "Raw" affordance (the Transcript-tab undo-toast precedent) reverts the
  span to the raw transcript.
- Empty transcript (silence) → the span is removed quietly, no error.
- Only one field can dictate at a time; other mic buttons are disabled while one is
  active.

## Surfaces (rollout phases, one PR)

1. **Phase 1 — primitive + Ideas:** `DictationCenter`, `MicRecorder`,
   `DictationButton`, `dictate clean` CLI + `dictation.clean` prompt. Integration:
   `IdeaCreateSheet` (mode `idea`, fills `title` + `essence`).
2. **Phase 2 — Notes + chats:** the recording Notes editor (mode `note`) and the
   shared `ChatInput` component (mode `chat`) — one integration point covers the
   Situation, Target, Track, Idea, and Meeting Discuss chats.
3. **Phase 3 — quick capture:** tray menu item "New voice idea" + a global hotkey via
   Carbon `RegisterEventHotKey` (chosen precisely because it needs **no**
   Accessibility permission — no TCC prompt; an `NSEvent` global monitor would
   trigger one, which is a P0 for this project). A small floating panel shows the
   live transcript; on stop the cleaned result is inserted directly into the ideas
   registry via `IdeaQueries.createManual` (the existing manual-create Swift path:
   `status='active'`, `source='owner'`, one `idea_mentions` provenance row),
   with a confirmation toast linking to the Ideas tab.

## Edge cases

- Engine load failure → `failed` state on the button with retry; the field is
  untouched.
- Cleanup failure → raw text kept + visible non-blocking error.
- Silence → span removed, no error.
- Meeting recording starts mid-dictation → dictation auto-stops and finishes its
  cleanup; meeting capture proceeds.
- App quit mid-dictation → dictation is cancelled; `QuitCoordinator` does **not**
  count dictation as busy (it does not warrant a confirm dialog).
- Batch-only provider → no live preview; text arrives after stop.

## Testing

- **Swift:** `DictationCenter` state machine against fake engine/recorder (existing
  fake precedent), including: start → navigate away → return (surviving-state rule);
  stop with zero samples (valid-but-degenerate input); auto-stop when meeting capture
  starts; cleanup-failure keeps raw text; span replacement with pre-existing field
  text. Envelope parsing for all three modes.
- **Go:** `dictate clean` command test with a fake AI provider (house pattern);
  prompt rendering for the three modes; envelope shape on success and failure.
- **Pins:** the live↔batch transcriber equivalence pins are untouched — dictation
  consumes the stack, it does not edit it.

## Decisions log

- Transcribe-then-clean (not raw dictation) — owner choice.
- All four surfaces, phased in one PR — owner choice.
- Live preview during speech, cleanup on stop, raw revert — owner choice.
- Context-aware cleanup modes (idea/note/chat) — owner choice.
- Sticky engine with 15-min idle TTL instead of always-resident — owner approved
  (always-resident costs ~1.5–2 GB unified memory for large-v3-turbo for ~5 s of
  saved load time; this Mac has a history of swap pressure).
