# Meeting Transcriber — Design

**Date:** 2026-07-13
**Status:** approved design
**Origin:** port of the standalone `snoop` prototype (`~/PhpstormProjects/snoop`) into Watchtower, rebuilt on native macOS APIs with zero external programs.

---

## 1. Problem & Goals

After a Google Meet call the spoken context (decisions, action items) evaporates. The `snoop` prototype solved this as a CLI pipeline (ffmpeg + BlackHole capture → mlx-whisper transcription → `claude -p` summary), but it depends on brew packages, a Python venv, a virtual audio device, and manual Audio MIDI Setup configuration.

**Goals:**

- Record a meeting from the Watchtower Desktop calendar with one click; get a stored transcript and an AI recap attached to the calendar event.
- Zero external programs: no ffmpeg, no BlackHole, no Python. Library dependencies (SPM) and one-time model weight downloads are acceptable.
- Transcription is fully local (audio never leaves the machine). Only the transcript text goes to the AI provider for the recap — same trust boundary as `snoop`.
- Preserve snoop's key quality feature: **windowed language detection** over `{ru, uk, en}` with sticky fallback, so mixed-language calls don't degrade into a single-decoder mess.
- Transcripts are queryable by the secretary chat (MCP tools).

**Non-goals (this iteration):**

- Speaker diarization.
- Auto-detection of call start / auto-recording.
- Importing pre-existing audio files (dictaphone recordings etc.) — future work; the pipeline shape supports it.
- Feeding transcripts into inbox/tracks/people pipelines as a signal source — future work.
- Loudness normalization post-processing (snoop's `loudnorm` pass). The capture-side limiter covers the main clipping risk; revisit if transcript quality suffers.
- Realtime (during-call) transcription.

---

## 2. Architecture

Split follows the repo convention: **Swift owns capture + transcription (the Mac-native, permission-bound work); Go owns storage + AI + retention (the DB-writer work).**

```
Calendar event card ──"Record"──▶ MeetingRecorderCenter (Swift, AppState)
                                     │ mic (AVAudioEngine)
                                     │ system audio (CoreAudio process tap)
                                     ▼
                          rec_<ts>.m4a (16 kHz mono AAC)
                                     │
                                     ▼
                          TranscriptionEngine (WhisperKit, on-device)
                          windowed ru/uk/en language detection
                                     │ transcript .txt (temp file)
                                     ▼
              watchtower meeting transcript save --event-id … --audio … --transcript-file …
                                     │
                     ┌───────────────┴──────────────────┐
                     ▼                                  ▼
            meeting_transcripts row          Pipeline.GenerateRecap (existing)
            (transcript, audio path)         → meeting_recaps (event-linked)
                                             → summary_json (ad-hoc)
```

Rationale for the split:

- Go stays pure-Go (no cgo/whisper.cpp/Metal build complexity; `modernc.org/sqlite` choice is deliberate).
- The app already owns the TCC surface; capture permissions belong to it.
- The CLI stays the sole writer of AI artifacts; recap generation, `pipeline_runs` audit, and prompt-store integration are all existing machinery.

---

## 3. Swift: capture

### 3.1 MeetingRecorderCenter

`@MainActor @Observable` singleton held by `AppState` — same pattern as `TargetExtractCenter` / `TrackScanCenter` (see `docs/superpowers/specs/2026-07-09-target-extract-background-design.md`):

- Single in-flight slot: starting a recording while one is active is rejected in UI (button disabled).
- State machine: `idle → recording → transcribing → summarizing → done | failed`. All state lives in the Center, never view-local — recording must survive navigation and sheet dismissal ("начал → ушёл → вернулся" test is mandatory).
- Completion/failure surfaced via `NotificationService` (native notification, no custom toast).
- Holds: current `eventId` (nullable for ad-hoc), recording start time, elapsed, transcription progress (window N of M), failure error.

### 3.2 Audio capture stack

- **Mic:** `AVAudioEngine` input node.
- **System audio (Meet participants):** CoreAudio **process tap** on the default output device (`CATapDescription` + `AudioHardwareCreateProcessTap`, macOS 14.2+; we gate the feature on **macOS 14.4+** for tap API stability). No BlackHole, no Aggregate/Multi-Output devices; headphones keep working normally.
- **Mix:** both sources converted and summed to 16 kHz mono in the render path. Mic weighted ~0.9 and a brickwall limiter applied — this ports the hard-won lessons from snoop's `record.sh` (simultaneous loud speech must not clip; no auto-leveling that pushes into clipping).
- **Output:** AAC in `.m4a` (~15 MB/hour) written incrementally via `AVAudioFile`, to `~/Library/Application Support/Watchtower/recordings/rec_<yyyyMMdd_HHmmss>.m4a`.
- On stop (user clicks Stop, or app quits mid-recording): file is finalized first; the audio file is **always preserved on disk** regardless of what happens downstream.
- Runtime gate: on macOS < 14.4 the Record button is disabled with an explanatory tooltip.

### 3.3 Permissions (TCC)

Two deliberate one-time prompts, requested by the app itself at first record:

- Microphone (`NSMicrophoneUsageDescription`).
- System Audio Recording (`NSAudioCaptureUsageDescription`).

This does not conflict with the "no TCC prompts from Watchtower" rule: that rule targets *spurious* prompts caused by spawned subprocesses inheriting the app's responsibility. These are intentional, user-initiated capability grants shown by the app for its own capture. If permission is denied, recording fails immediately with a clear message + deep link to System Settings.

---

## 4. Swift: transcription

### 4.1 Engine abstraction

`protocol TranscriptionEngine` (async, cancellable, progress callback) with the production implementation backed by **WhisperKit** (SPM dependency, CoreML, runs on ANE/GPU). Tests use a mock engine; WhisperKit never runs in CI.

- Default model: `large-v3` (configurable in Settings). WhisperKit downloads model weights on first use — download progress shown in UI; one-time network use, offline afterwards.
- Input: the recorded m4a is decoded to 16 kHz mono Float32 PCM via `AVAudioConverter`, then windows are fed to WhisperKit as raw audio arrays.

### 4.2 Windowed language detection (ported from snoop `transcribe.py`)

Direct port of the algorithm — this is the prototype's core quality asset:

- Slice audio into windows of `windowSec` (default 20 s) with 1 s overlap.
- Per window, detect language **restricted to the configured langset** (default `{ru, uk, en}`) using WhisperKit's language-detection API.
- Accept the detected language only if confidence ≥ `langThreshold` (default 0.6) **and** margin over the runner-up ≥ `margin` (default 0.2); otherwise **sticky fallback** to the previous window's language (first window falls back to `ru`).
- A window's language "sticks" (becomes the fallback) only if the window actually produced speech text.
- Transcribe each window with the chosen language forced; concatenate non-empty window texts into the transcript.
- Collect per-language window counts (`lang_stats`) for storage.
- Escape hatch: a "force language" setting disables detection entirely (snoop's `SNOOP_LANG`).

All parameters live in Desktop Settings (defaults above; the snoop env-var table maps 1:1 to settings fields).

Progress: window index / total windows reported to the Center → UI.

---

## 5. Go: storage, recap, retention, MCP

### 5.1 Schema — new table `meeting_transcripts`

Goose migration (next number), mirrored into `internal/db/schema.sql`, added to `TestAllTablesExist`, golden snapshot regenerated:

```sql
CREATE TABLE meeting_transcripts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id        TEXT REFERENCES calendar_events(id) ON DELETE SET NULL,
    title           TEXT NOT NULL,            -- event title snapshot, or user label for ad-hoc
    audio_path      TEXT,                      -- NULL after retention cleanup
    duration_sec    INTEGER NOT NULL,
    lang_stats      TEXT,                      -- JSON: {"ru": 41, "en": 7}
    transcript_text TEXT NOT NULL,
    summary_json    TEXT,                      -- recap JSON for ad-hoc recordings (event-linked ones live in meeting_recaps)
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);
CREATE INDEX idx_meeting_transcripts_event ON meeting_transcripts(event_id);
```

`ON DELETE SET NULL` (not CASCADE): calendar sync prunes stale events; a transcript must outlive its event. `title` is snapshotted at save time so an orphaned transcript stays identifiable.

No in-flight status column: recording/transcribing state lives in the Swift Center; the DB row is created only once a transcript exists.

### 5.2 CLI — `watchtower meeting transcript`

New subcommands under the existing `meeting-prep`/meeting command family:

- `save --transcript-file <path> --audio <path> --duration <sec> [--event-id <id>] [--title <s>] [--lang-stats <json>] [--progress-json]`
  1. Insert the `meeting_transcripts` row (transcript read from file — **never** as an argv value).
  2. Generate the recap by calling the existing `Pipeline.GenerateRecap` with the transcript as `source_text`:
     - event-linked → result stored in `meeting_recaps` (existing table, existing Desktop rendering — zero new recap UI);
     - ad-hoc → same recap JSON stored in `meeting_transcripts.summary_json`.
  3. Write a `pipeline_runs` audit row; stream `--progress-json` steps.
  4. Recap failure is non-fatal: the transcript row is already committed; exit reports the recap error; Desktop offers "Retry recap" (reuses the existing recap-regeneration path).
- `list` / `show <id>` — inspection/debugging parity with other artifact commands.

Prompt: reuse `meeting.recap` from the prompt store. Amend the default template with one line noting the source may be a single-track unattributed transcript (no speaker labels). No new prompt key unless recap quality demands divergence later.

### 5.3 Large AI input via stdin

Today `ClaudeGenerator`/`CodexGenerator` pass the user message as an argv value (`generateArgs`). An hour-long transcript (~100 KB+) approaches ARG_MAX risk territory. Change: when the user message exceeds a threshold (e.g. 32 KB), both generators pass it via **stdin** instead of argv (snoop's proven approach; `claude -p` reads stdin as context, codex equivalently). Below the threshold, behavior is unchanged. This is a shared-infrastructure change benefiting all pipelines.

### 5.4 Retention — daemon phase

New daemon phase `phaseTranscriptAudioCleanup` (cheap, no AI): delete audio files whose row is older than `transcripts.audio_retention_days` (default 30, configurable), then set `audio_path = NULL`. Transcript text is kept forever. Missing file on disk is not an error (idempotent).

### 5.5 MCP tools for the secretary chat

Extend the in-process `watchtower mcp` server with:

- `list_transcripts` — filter by date range and/or `event_id`; returns id, title, event linkage, duration, created_at, recap summary line.
- `get_transcript` — full transcript text + recap by id.

This lets the situation-discuss / secretary chat answer "what did we decide about X in Tuesday's meeting" the same way `list_messages` serves Slack history.

---

## 6. Desktop UI

- **Record button** on the calendar event card (`CalendarEventRow` / `MeetingNotesView` header): starts the Center for that `event_id`. Disabled while another recording is active, and on macOS < 14.4.
- **Ad-hoc recording:** toolbar button on the Calendar tab ("Record without event"). After completion the transcript can be linked to an event via a picker of time-adjacent events. Linking writes `event_id` and, if the event has no recap yet, copies the stored `summary_json` into `meeting_recaps`; if the event already has a recap, the ad-hoc recap stays in `summary_json` untouched. Nothing is regenerated.
- **Global recording indicator:** visible from any tab (recording outlives navigation); shows elapsed time; click → jump to the recording's context; Stop control.
- **Transcript section** on the event detail: collapsible "Transcript" block (full text, lang stats, duration, re-transcribe button while audio still exists) rendered next to the existing recap block. The recap itself renders through the existing `MeetingRecap` UI untouched.
- **Recordings list:** a section on the Calendar tab listing ad-hoc (and optionally all) recordings with status, for access to transcripts whose events are gone.
- Progress during transcribe/summarize phases comes from the Center (window N/M, then recap progress via `--progress-json`).

New Swift pieces: `MeetingRecorderCenter`, capture stack, `TranscriptionEngine` + WhisperKit impl, `MeetingTranscriptQueries` (GRDB read + the event-link write), transcript section views. Follows the Models → Queries → ViewModel → View convention.

---

## 7. Error handling

| Failure | Behavior |
|---|---|
| TCC permission denied | Immediate failure, message + deep link to System Settings. No file created. |
| Recording interrupted (device change, sleep, app quit) | Finalize the m4a with whatever was captured; proceed to transcription on next explicit user action (Center restores a "pending file" on launch). |
| Transcription fails / empty speech | Audio kept on disk; Center → `failed` with reason; "Transcribe again" button. Nothing written to DB. |
| `save` CLI fails (DB error) | Transcript temp file kept; Center → `failed`; retry re-invokes `save`. |
| Recap AI fails | Transcript row already committed (visible in UI); recap marked failed; existing "Retry recap" path. |
| Model weights not yet downloaded | Download starts with progress; recording is NOT blocked (capture first, transcribe after download completes). |

Failures never advance any watermark and never touch existing recaps (consistent with DASH-02 spirit).

---

## 8. Configuration

| Setting | Default | Where |
|---|---|---|
| Whisper model | `large-v3` | Desktop Settings |
| Langset | `ru,uk,en` | Desktop Settings |
| Window / threshold / margin | 20 s / 0.6 / 0.2 | Desktop Settings (advanced) |
| Force language | off | Desktop Settings (advanced) |
| `transcripts.audio_retention_days` | 30 | Go config (`internal/config`) |
| Recordings directory | App Support/Watchtower/recordings | fixed |
| AI stdin threshold | 32 KB | Go config constant |

---

## 9. Testing

**Go:**
- `transcript save` unit tests: insert + recap generation (mock generator), event-linked vs ad-hoc storage split, recap failure leaves transcript committed, transcript-file read path.
- Degenerate inputs per project rule: empty transcript file, whitespace-only transcript (valid-but-degenerate → explicit error, not silent success).
- Cleanup phase: retention boundary, missing file idempotency, `audio_path` NULLing.
- Generator stdin path: threshold boundary, both providers.
- MCP tools: list/get shapes.

**Swift:**
- Center state machine transitions incl. the mandatory "start → navigate away → return" test (in-flight state intact).
- Mock `TranscriptionEngine`: windowing/language-stick logic tested with synthetic detection results (thresholds, margins, sticky fallback, first-window default, silence windows don't stick).
- Queries round-trip against the test schema (keep `TestDatabase.swift` in sync with `schema.sql` — known drift trap).
- Build/test verification with real exit codes (no `tail` piping).

**Manual acceptance:**
- Record a real Meet call with headphones: both sides audible in transcript; headphones never switched/interrupted.
- Mixed ru/uk/en call transcribes without суржик collapse.
- Recap appears on the event via the existing recap UI.
- Kill the app mid-recording → file survives, next launch offers to transcribe it.

---

## 10. Future work (explicitly deferred)

- Import existing audio files through the same pipeline.
- Speaker diarization (two-track capture: mic and system audio recorded separately would give free me/them attribution — capture stack should not preclude this).
- Auto-record on meeting start (calendar-time trigger).
- Transcripts as a signal source for inbox/situations/tracks/people pipelines.
- Loudness normalization pre-pass if transcript quality on quiet recordings disappoints.
