# Calendar Quick Wins: Stable Code Signing + Visible Recording↔Event Link

**Date:** 2026-07-31
**Status:** Approved by owner
**Scope:** Two small independent fixes bundled into one spec: (A1) stop macOS from re-prompting recording permissions on every rebuild; (A2) make the recording↔calendar-event link visible in the UI on both sides.

---

## A1. Stable code signing (fixes recurring TCC permission prompts)

### Problem

Every meeting recording triggers fresh macOS permission dialogs for microphone and system audio. Root cause is **not** application code:

- The only mic request is `AVCaptureDevice.requestAccess(for: .audio)` in `SystemAudioRecorder.swift:88` — it is idempotent and silent when a grant exists. System audio TCC comes from the CoreAudio process tap (`SystemAudioRecorder.swift:93-101`).
- `Info.plist` keys are correct (`NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription` — `scripts/build-app.sh:145-148`), bundle id is stable (`com.watchtower.desktop`).
- The cause is **ad-hoc signing**. Both `make app-dev` and `make app` without `CODESIGN_IDENTITY` sign with `--sign -` (`scripts/build-app.sh:189-205`). An ad-hoc signature has no designated requirement, so TCC pins the grant to the bundle's cdhash — which changes every build (Go binary embeds `BuildDate`/`Commit` via ldflags, `build-app.sh:48-49,58`). New cdhash → "different app" → grant lost.

A valid stable identity exists in the keychain: `Developer ID Application: Vadym Trunov (7WFLZDVUV3)`.

### Design

Change `scripts/build-app.sh` signing logic — one path for dev and release:

1. If `CODESIGN_IDENTITY` is set and found in the keychain → sign with it (current `elif` branch behavior, `--options runtime`).
2. Else auto-detect: `security find-identity -v -p codesigning` grepped for `Developer ID Application`; if exactly one is found → sign with it (same flags as case 1).
3. Else fall back to ad-hoc (`--sign -`) with a loud warning in the build log explaining that TCC grants will not survive rebuilds.

The dev-mode special case (`$DEV_MODE` → always ad-hoc) is removed; `--dev` keeps its other behaviors (fast build flags etc.) but signs the same way. Notarization is NOT required for TCC persistence and stays out of scope (the notarize profile is currently expired anyway).

No Swift/Go code changes. No permission primer UI (owner decision: with a stable signature the dialog appears exactly once per machine, a primer is redundant).

### Verification

- Build twice in a row; `codesign -dv` shows the same authority both times.
- Grant mic + system audio once, rebuild, start a recording: no new TCC dialogs (aligns with the "No TCC prompts from Watchtower" P0 rule).
- On a machine without the certificate the build still succeeds (ad-hoc + warning).

---

## A2. Visible recording↔event link

### Problem

The data link is complete (`meeting_transcripts.event_id`, recap dual-path), but the UI hides it:

- The expanded event row (`eventDetail`, `CalendarEventsView.swift:298-349`) shows location/organizer/attendees/description only — recordings and recap are visible solely inside the Meeting Prep pane (`MeetingNotesView`, reached via the "Prepare" button).
- `RecordingDetailView` gives no indication of which event a linked recording belongs to (the "Link to event…" button merely disappears when `eventID != nil`, `RecordingDetailView.swift:136-145`).
- `RecordingsListView` distinguishes linked recordings only by a `calendar` icon (`RecordingsListView.swift:52`).

### Design

**Event side — "Recordings" section in the expanded event row.** In `eventDetail`, below the existing description block, render linked recordings via the existing `MeetingTranscriptQueries.fetchForEvent(eventID)`: one compact row per recording (created-at date, duration, recap/notes badges). Tapping a row switches `CalendarMode` to `.recordings` and selects that recording in `RecordingsView` (selection is passed down; RecordingsView gains an optional external selection binding). The section is hidden when there are no recordings. A recap indicator appears when the event has a `meeting_recaps` row.

**Recording side — linked-event header.** In `RecordingDetailView`'s header, when `transcript.eventID != nil`, show "Linked to: <event title> · <event date>" resolved via a lightweight query against `calendar_events` (title, start_time only). Tapping navigates to the Events mode with that event expanded. If the event row no longer exists (event pruned by sync retention), show a plain "Linked to a past event" label without navigation — never an error.

**List — event subtitle.** `fetchRecordingList` adds a LEFT JOIN to `calendar_events` for `event_title` only (stays within the perf guard: no heavy columns). `RecordingsListView` renders it as a secondary line for linked recordings.

### Testing

- Swift: query test for `fetchRecordingList` including the joined `event_title` (and NULL for ad-hoc rows); query test for the event-title resolution with a missing event row.
- UI logic: expanded event with 0 recordings hides the section; with ≥1 shows rows.

### Out of scope

- Unlinking a recording from an event (not requested).
- Any Go/schema changes — this is Swift-only.
