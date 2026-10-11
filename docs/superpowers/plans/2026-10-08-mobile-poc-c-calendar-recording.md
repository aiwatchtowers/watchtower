# Mobile POC C: calendar and recording (#425)

**Goal:** from the iPhone, the owner sees the agenda and event prep. They record a meeting or a voice note, even with the phone locked, and get the Mac's transcript and recap back on the phone.

**Architecture:**
- The hub publishes three capped projections: `calendar_event` (deduplicated, with no `raw_json`), `meeting_transcript` (recap fields, with the segments as a CKAsset) and `recording_job` (Mac-side progress).
- The phone uploads AAC `.m4a` recordings as `recording_upload` relay records that carry `event_id`.
- The Mac ingests each upload into the existing recordings directory and enqueues the existing transcription pipeline directly, with no opt-in. Transcription only ever runs on the Mac.

**Specs:** `docs/superpowers/specs/2026-10-07-mobile-poc-business.md` and `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` (§4.10–§4.12, §5.3, §6.4, §13 C).

**Requires plan A:** `docs/superpowers/plans/2026-10-08-mobile-poc-a-skeleton.md`.

## Global constraints (verbatim from the spec)

**Carried over from plan A**
- All of plan A's Global constraints apply: container, zones, scopes, timing, payload guard 900_000, visual rules, hygiene, English, the inner loop only.

**Never published**
- `calendar_events.raw_json`, `meeting_transcripts.audio_path`, `speakers_json` (voice embeddings), `notes_md`, chapters other than `overall_summary`.

**calendar_event**
- Window: `start_time` from local today 00:00 − 1 day to + 14 days. `event_status = 'cancelled'` is excluded. At most 500 events, earliest first.
- Dedup: same non-empty `ical_uid` and same `start_time` → one record. Keep the row with a `conference_url`, else the lowest `id`.
- Text caps: `title` and `location` 300; `description` 2000, plain text.
- `attendees`: ≤ 100, each reduced to email, display name and response status.
- `prep_bullets`: `talking_points[].text` then `suggested_prep[]`, first 8, each ≤ 300.
- `linked_targets`: ≤ 20, `{id, text ≤ 200, status}`, `project_id IS NULL` only, read-only.

**meeting_transcript**
- Window: created in the last 30 days, or its event is in the calendar window. At most 200, newest first. `title` 300.
- Recap: `summary`, `key_decisions[]`, `action_items[]`, `open_questions[]`, each list ≤ 50 entries of ≤ 500.
- Recap join: `r.transcript_id = t.id OR (r.event_id IS NOT NULL AND r.event_id = t.event_id)`. Ad-hoc recordings use `summary_json` instead.
- `overview`: `chapters_json.overall_summary`, 2000.
- `speakers[]`: names only, ≤ 20.
- Segments travel as CKAsset `segments.json` holding `[{start_sec, end_sec, speaker, text}]`, non-deleted segments only.
  - A legacy row becomes one segment.
  - The asset is ≤ 20 MB, else clipped with `segments_clipped`.

**recording_job**
- `status`: `received`, `queued`, `transcribing`, `diarizing`, `summarizing`, `done`, `failed`.
- `percent`: 0–100, from `transcribing(done:total:)`.
- `transcript_id`; `error` ≤ 300.
- Kept 7 days after `done`/`failed`, at most 100. It is a fast-lane kind.

**Recording**
- Format: AAC, mono, 64 kbps, `.m4a`, `sample_format = "aac-64k-mono"`.
- Length: auto-stop at 3 h, with a notice 5 min before. Asset ≤ 90 MB.
- Mark-moment offsets stay on the phone (jump points); they are not sent.

**recording_upload**
- `RecordingUploadPayload` + `event_id?` (absent when nil) + `device_id`.
- Statuses: `pending`, `received`, `failed`. On `received` the Mac rewrites the record without the asset, and the phone deletes its file.
- The accepted duplicate-ingest edge is kept: a crash between the ack save and the processed mark re-copies the audio.

**Other rules**
- "Make target" from action items is hidden until D.
- `.m4a` sits next to `.caf` in the recordings directory, `MeetingRecorderCenter.defaultRecordingsDirectory()` (Go mirror `internal/config/config.go:797`). The Go orphan sweep (`internal/daemon/daemon.go:957`) keys on the `rec_` prefix only.

**Contracts that must stay green, unchanged**
- The meeting-transcriber suites: the single-engine invariant, live↔batch equivalence (`StreamingTranscriberTests.testMatchesBatchOnSameSamples`), recovery, voice registry.
- PROJ-01, for `linked_targets`.

**Docs**
- `docs/features/mobile-companion.md` (calendar and recording).
- `docs/features/meeting-transcriber.md` (phone ingest line).
- `docs/app-guide.md` (iPhone Calendar and Recordings).

## Review focus

Five failure modes that no task's spec-derived tests cover. Each one has a test added to the task that owns it.

1. **Phone call or Siri interruption mid-recording.** The recording pauses and resumes into the same file and is finalised once; the timer excludes the gap → Task 6.
2. **Time zones and daylight saving.** The window's local midnight on a DST-change day; all-day events whose date must not shift by a day in UTC; an event spanning midnight → Task 2.
3. **Mac disk full or recordings dir unwritable** during ingest → `failed` with `write_failed`. The phone keeps its file and offers Retry; no half-written `.m4a` is left → Task 4.
4. **Event deleted or cancelled after the phone recorded for it.** The upload still ingests, and the transcript ends up ad-hoc (`event_id` set to NULL by the FK rule), never failing → Task 4.
5. **Mac busy capturing its own meeting** when a phone upload arrives. The job is queued behind the capture and never interrupts it (single-engine invariant) → Task 3.

---

## Task 1: Kit mirrors and recording upload payload

**Depends on:** A-Task 3. **Lane:** Kit.

**Files:**
- Adapt `WatchtowerKit/Sources/WatchtowerKit/Models/CalendarEvent.swift` and `MeetingTranscript.swift`; create `RecordingJob.swift`.
- `Relay/RecordingUploadPayload.swift`: add `event_id?` and `device_id`.
- Re-pin the `RecordingUploadPayloadTests` fixtures.

**Interfaces:** `SliceKind` raw values `calendar_event`, `meeting_transcript` (existing) and `recording_job` (new). Fields exactly as in spec §4.10–§4.12.

**Tests (`CalendarMirrorFixtureTests`, `RecordingUploadPayloadTests`):**
- Every kind decodes its frozen fixture.
- A nil `event_id` is an absent key, and a fixture without it decodes to nil.
- `segments.json` with zero segments decodes to an empty list.
- An unknown `recording_job.status` decodes as `queued`.

**Checks:** `make kit-test FILTER='CalendarMirrorFixtureTests|RecordingUploadPayloadTests'`, `make lint-diff`.

## Task 2: calendar_event projection

**Depends on:** A-Task 6, Task 1. **Lane:** Desktop Swift. Pure logic; does not need A-Task 14.

**Files:** `WatchtowerDesktop/Sources/Services/MobileHub/Slices/CalendarEventSlice.swift`.

**Sources:**
- `CalendarQueries.fetchEvents(from:to:)` (`WatchtowerCore/Database/Queries/CalendarQueries.swift:44`);
- `meeting_prep_cache.result_json` (Go shape `internal/meeting/pipeline.go`);
- `meeting_transcripts.chapters_json` `converted_target_id`, then `targets` with `project_id IS NULL`.

**Tests (`CalendarEventSliceTests`):**
- **Hidden column:** a key scan of every payload finds no `raw_json`.
- **Dedup:**
  - two accounts' copies with the same `ical_uid` and start → one record (the one with `conference_url`);
  - the same `ical_uid` with different starts (recurring) → two records;
  - an empty `ical_uid` → never deduplicated.
- **Cancelled:** a cancelled event is not published.
- **Window edges:** an event at exactly now + 14 days is published, and one a second past it is not. One at local today − 1 day 00:00 is published.
- **Caps:** 501 events → the 500 earliest. 101 attendees → 100.
- **Prep:** no prep cache → empty `prep_bullets`, no `prep_generated_at`. Prep with 12 bullets → 8.
- **Linked targets:** a workbench target from a converted action item is excluded (PROJ-01).
- **Description:** HTML in `description` → plain text, clipped at 2000.
- **Review focus 2:**
  - a window computed in `Europe/Kyiv` on the DST-change day still starts at local 00:00;
  - an all-day event `2026-10-25` stays on 25 October for a UTC−7 Mac;
  - an event from 23:30 to 00:30 appears on both days.

**Checks:** `make test-swift FILTER=CalendarEventSliceTests`, `make lint-diff`.

## Task 3: MeetingRecorderCenter phone ingest

**Depends on:** none (main-only). **Lane:** Desktop Swift, ML stack: no other Swift lane links at the same time.

**Files:** `WatchtowerDesktop/Sources/Services/MeetingRecorderCenter.swift`:
- Accept `.m4a` next to `.caf`:
  - in `scanRecoverable` (`:1665`, filter `:1675`);
  - in `recoverySortKey` (`:1654`; `:1655` becomes `deletingPathExtension`);
  - in `uniqueRecordingURL(in:date:)` (`:1791`, `:1793`, `:1797`), which gains `fileExtension:`.
- The decode path (`:1367`) reads `.m4a`.
- Add `ingestPhoneRecording(audioURL:eventID:title:config:)`. It writes `rec_<ts>.m4a` and its `.meta` (`writeMetaSidecar` `:1624`, `metaURL` `:1615`), then enqueues a `ProcessingJob` directly, not through `addRecoverable` (`:1261`).
- Add the callbacks `onJobPhase(audioURL:phase:)` and `onJobFinished(audioURL:transcriptID:)`.
- The helpers the hub calls off the main actor become `nonisolated`.
- Docs: a phone-ingest line in `docs/features/meeting-transcriber.md`.

**Tests (`MeetingRecorderPhoneIngestTests`):**
- **Recovery and naming:**
  - an `.m4a` with `.meta` is found by `scanRecoverable`;
  - `rec_X.m4a`, `rec_X-2.m4a` and `rec_X-10.m4a` sort chronologically, mixed with `.caf` files;
  - `uniqueRecordingURL(fileExtension: "m4a")` adds `-N` while either extension exists.
- **Decode:** an AAC fixture (1 s, generated in the test) decodes to the expected sample count ±1 %.
- **Event link:** ingest with an `eventID` → the saved transcript is linked to the event and `registryLoader` gets the event id. Ingest without one → an ad-hoc transcript.
- **Mic only:** a recording with no system or activity channel completes, with roles skipped and no failed job.
- **Callbacks:** `onJobPhase` reports `transcribing(done: 3, total: 12)`, and `onJobFinished` reports the transcript id.
- **Review focus 5:** while a Desktop capture is running, an ingest queues a job and the capture state is unchanged; the job runs after the capture stops.

**Guards that must stay green, unchanged:** the existing `MeetingRecorderCenter*Tests`, `StreamingTranscriberTests.testMatchesBatchOnSameSamples`, and the recovery tests.

**Checks:** `make test-swift FILTER='MeetingRecorderPhoneIngestTests|MeetingRecorderCenter|StreamingTranscriberTests'`, `make lint-diff`.

## Task 4: hub recording upload and the recording_job slice

**Depends on:** A-Task 6, Tasks 1 and 3. **Lane:** Desktop Swift.

**Files:**
- `MobileHub/RelayProcessor.swift`: `processRecordingUpload` and `ingestAsset` ported, passing `event_id`.
- The sidecar table `phone_recordings(upload_id, audio_path, transcript_id)`.
- `Slices/RecordingJobSlice.swift`, on the fast lane.

**Tests (`RelayProcessorRecordingUploadTests`, `RecordingJobSliceTests`):**
- **Ack:** a valid upload → `.m4a` and `.meta` written → `received`, with the asset dropped from the rewrite.
- **Duplicate:** a duplicate delivery after `received` ingests nothing.
- **Missing asset:** → `failed`, and the phone keeps its file.
- **Progress:** `recording_job` reports `queued`, then `transcribing` 25 %, then `done` with `transcript_id`.
- **Failure:** a failed job → `failed` with `error` ≤ 300.
- **Pruning:** a record 7 days + 1 s after `done` is deleted. 101 jobs → 100.
- **Review focus 3:** an unwritable recordings dir → `failed` / `write_failed`, and no partial `.m4a` is left.
- **Review focus 4:** an `event_id` whose event was deleted → ingested as ad-hoc, never failed.
- **Device gate:** an upload from an unlinked `device_id` → `device_not_linked` and nothing written.

**Checks:** `make test-swift FILTER='RelayProcessorRecordingUploadTests|RecordingJobSliceTests'`, `make lint-diff`.

## Task 5: meeting_transcript projection with the segments asset

**Depends on:** A-Task 6, Task 1. **Lane:** Desktop Swift (parallel to Task 4 only if Task 4's lane is not linking).

**Files:**
- `Slices/MeetingTranscriptSlice.swift`.
- `SlicePublisher`: asset-backed records. It stages `segments.json` in the hub dir, and the hash covers the payload plus the segment content.

**Tests (`MeetingTranscriptSliceTests`):**
- **Recap join:** a recap linked only through `transcript_id` (event aged out) is found.
- **Ad-hoc:** an ad-hoc recording uses `summary_json`.
- **Legacy:** a transcript without `segments_json` → one segment holding `transcript_text`.
- **Deleted segments:** never in the asset.
- **Asset cap:** an asset over 20 MB → clipped, with `segments_clipped`.
- **Hidden columns:** a key scan finds no `audio_path`, `speakers_json` or `notes_md`.
- **Windows:** 201 transcripts → 200. One from 31 days ago with no event in the window → not published.
- **Rename:** a speaker rename changes the hash (the record is republished); an unchanged transcript does not.

**Checks:** `make test-swift FILTER=MeetingTranscriptSliceTests`, `make lint-diff`.

## Task 6: phone recorder and uploader

**Depends on:** Task 1, A-Task 11. **Lane:** phone Swift.

**Files:**
- Port `WatchtowerMobile/Sources/Features/Recording/PhoneRecorderController.swift`.
- `RecordingView` (meeting or "No meeting" voice note, timer, waveform, pause, stop, mark moment, keeps recording when locked).
- Kit `RecordingUploader` with `event_id`.
- `ReplicaStore+PhoneRecordings` (marks stored locally).

**Tests (`RecorderTests`, `RecordingUploadWiringTests`):**
- A 0-second recording → "Too short to save", never uploaded.
- **Length cap:** auto-stop at 3 h exactly (fake clock), with the notice at 2 h 55 m.
- **Mac asleep:** an upload while the Mac is asleep stays `pending`, and the list shows "Waiting for the Mac to wake".
- **Ack:** `received` → the local file is deleted. `failed` → the file is kept and Retry is offered.
- **Event link:** "Record this meeting" sets `event_id`, and "No meeting" leaves it absent.
- **Marks:** stored with second offsets and never put in the upload payload.
- **Review focus 1:** a simulated `AVAudioSession` interruption (began, then ended) → one file, the timer excludes the gap, and the status is "Paused — call in progress" during it.

**Checks:** `make mobile-test MOBILE_FILTER='RecorderTests|RecordingUploadWiringTests'`, `make lint-diff`.

## Task 7: phone calendar

**Depends on:** Task 1, A-Task 11; Task 6 for the Record buttons. **Lane:** phone Swift.

**Files:**
- `Features/Calendar/AgendaView` (week day strip; event cards with recap ready, transcribing x %, now line; current or next meeting with Record and Prep).
- `EventDetailView` (time, attendees, prep bullets, linked targets read-only, Join, Record this meeting).
- `Now` tab: the next-meeting card with Record.
- `DemoSeed`: events, transcripts and jobs.
- `docs/app-guide.md`: the iPhone Calendar section.

**Tests (`CalendarWiringTests`):**
- An all-day event has no Record button.
- No prep → "No prep yet — it is prepared on your Mac".
- "Make target" is not shown anywhere.
- A transcribing card shows the `percent` from `recording_job`.
- An empty agenda day → "No events".
- The now line is drawn only on today.
- Join opens `conference_url`. No URL → no Join.
- The Now next-meeting card picks the next non-all-day event with `end > now`.

**Checks:** `make mobile-test MOBILE_FILTER=CalendarWiringTests`, `make lint-diff`.

## Task 8: recordings list, recap and transcript view

**Depends on:** Tasks 6 and 7. **Lane:** phone Swift.

**Files:** `Features/Recordings/RecordingsListView` (sending, transcribing on Mac, waiting for the Mac to wake, ready) and `RecapView` (summary, action items, decisions, open questions, speaker transcript from `segments.json`, marks as jump points).

**Tests (`RecordingsWiringTests`):**
- **List states:**
  - `pending` with a fresh heartbeat → "Sending";
  - with a stale one → "Waiting for the Mac to wake";
  - `recording_job` `transcribing` → "Transcribing on Mac x %";
  - `done` → "Ready".
- `segments_clipped` → "Transcript shortened — the full text is on the Mac".
- A mark at 125 s scrolls to the segment covering 125 s.
- A mark past the end → the last segment.
- A recap with empty lists hides those sections.

**Checks:** `make mobile-test MOBILE_FILTER=RecordingsWiringTests`, `make lint-diff`.

## Task 9: C device check — OWNER-RUN, filed as an ask with a checklist

**Depends on:** Tasks 1–8 and A-Task 14.

**Checklist:**
- Record 10 min with the phone locked.
- Take a phone call mid-recording, then resume.
- Record for a calendar event: the transcript is linked on the Mac with attendee voice matching.
- A 2-hour recording (about 58 MB) uploads.
- Upload with the Mac asleep, then wake it: transcribing % shows, and the recap arrives.
- All of the above in `private` and `shared` scope; note that in `shared` scope the upload counts against the Mac user's quota.
