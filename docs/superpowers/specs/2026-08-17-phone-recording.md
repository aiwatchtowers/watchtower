# Phone Recording → Mac Transcription — Spec (2026-08-17)

Workstream 1 of the mobile reanimation plan. The phone records audio; the
file travels to the Mac through the RelayZone as a `CKAsset`; the Mac drops
it into `MeetingRecorderCenter`'s recordings directory and transcribes it
with the EXISTING batch pipeline; the transcript returns to the phone via
the EXISTING `meeting_transcript` slice. No on-phone transcription.

## Goal

- Record on iPhone (AAC ~64 kbps mono, `.m4a`), surviving lock/background
  and phone-call interruptions.
- Upload reliably: local file persists until the Mac acknowledges receipt.
- Mac ingest reuses the meeting recorder's crash-recovery path (`rec_*` +
  `.meta` sidecar + the ProcessingJob queue) — no second transcription path.
- Zero new sync work for the return trip.

## Wire format (FROZEN by literal fixtures in RelayPayloadTests)

New `RelayRecordKind` case: `recordingUpload = "recording_upload"`.

New payload `RecordingUploadPayload` (RelayCoder: snake_case keys,
Unix-second dates, sorted keys):

```json
{
  "duration_sec": 754,
  "ended_at": 1700000754,
  "error_message": "…",          // only when status == "failed"
  "id": "R1",                     // client-generated recording id (UUID)
  "sample_format": "aac-64k-mono",
  "started_at": 1700000000,
  "status": "pending",            // pending | received | failed
  "title_hint": "Standup"        // optional; absent key when nil
}
```

Record name: `recupload-<id>`. Lifecycle mirrors the action ack pattern:

1. Phone saves the record with `status: "pending"` and the audio attached
   as a `CKAsset` (bypasses the ~1 MB per-record payload cap).
2. Desktop hub ingests the file, REWRITES the same record with
   `status: "received"` (or `"failed"` + `error_message`) and NO asset —
   the rewrite drops the asset field, freeing iCloud storage.
3. Phone's `RelayFeed` routes the echo; `received` deletes the local copy.

### Asset transport (seam extension)

`CloudRecord` gains `assetFileURL: URL?` (default nil — existing call
sites and wire behavior unchanged):

- `CloudKitTransport.ckRecord`: non-nil → `ck["asset"] = CKAsset(fileURL:)`;
  nil → the field is removed on rewrite. Plain field, not encryptedValues
  (CKAsset is not an encryptedValues type; asset content is encrypted by
  CloudKit itself).
- `cloudRecord(from:)`: `(ck["asset"] as? CKAsset)?.fileURL`.
- `TransportStore`: new `asset_path TEXT` column on `events` + `pending`
  (ALTER TABLE patch, same pattern as `notify_level`).
- Fetched CKAsset files are temporary: `bufferFetchedChanges` stashes a
  durable copy under `<store dir>/transport-assets/<recordName>` (skipped
  for in-memory stores; a stash failure keeps the original URL,
  best-effort). The hub deletes the stashed file after a successful ingest;
  a replayed batch is absorbed by the relay processed-set.
- `InMemoryCloudTransport` passes the URL through unchanged (test double).

## Phone side

### Capture (app target, no unit tests — thin AVFoundation shell)

- `PhoneRecorderController` (@MainActor @Observable, WatchtowerMobile):
  AVAudioSession `.playAndRecord`→`.record` + AVAudioRecorder,
  kAudioFormatMPEG4AAC, 1 channel, 44.1 kHz, 64 kbps.
- Files land in Application Support/phone-recordings/`<uuid>.m4a` —
  local-first, survive app kill.
- `audio` UIBackgroundModes entry (Info.plist) so recording survives
  lock/background.
- AVAudioSession interruption (phone call) → stop + finalize the segment
  gracefully (the recording is kept and queued, not lost).

### Upload state machine (WatchtowerKit — unit-testable off-simulator)

`ReplicaStore` gains a `phone_recordings` table:

```
id TEXT PRIMARY KEY, file_path TEXT, started_at REAL, ended_at REAL,
duration_sec INTEGER, title_hint TEXT, sample_format TEXT,
state TEXT CHECK(state IN ('waiting','uploading','delivered','failed')),
error_message TEXT
```

`RecordingUploader` (public actor, Kit):

- `register(fileURL:startedAt:endedAt:titleHint:)` — inserts a `waiting`
  row. Degenerate guard: zero-length file or duration < 1 s → the file is
  deleted and NO row is created (discarded, returns nil).
- `uploadPending()` — every `waiting`/`uploading` row is (re-)saved to the
  relay zone as a pending `recording_upload` record with the asset
  attached; on success the row flips to `uploading`. Called after register
  and once at app bootstrap — which IS the relaunch retry: re-saving the
  same recordName upserts into the transport's pending queue, and the
  hub's processed-set absorbs true duplicates. A transport throw leaves
  the row as-is for the next attempt.
- `applyEcho(_:)` (via RelayFeed, `RecordingUploadAcking` seam like
  `ChatChunkAssembling`): `received` → delete the local file, row →
  `delivered`; `failed` → row → `failed` + message. Echoes for unknown ids
  are no-ops (redelivery after delete). A still-`pending` payload is our
  own save reflecting back: inert.
- `retryFailed(id:)` — flips a `failed` row back to `waiting` for the next
  `uploadPending()` pass (upload retry).

`RelayFeed` routes `recording_upload` records to the uploader seam
(optional — nil keeps today's behavior; unknown-kind logging unchanged
for older builds).

### Recordings screen

Record button on the Recordings tab ONLY (owner default; voice-memo
style, no Today quick action). An "On this phone" section lists local
recordings with per-recording state: recorded (waiting) → uploading →
delivered ("sent to Mac — the transcript appears below when ready") /
failed (+ retry). The synced `meeting_transcript` list below is unchanged
— transcript-ready is represented by the transcript row itself appearing
(best-effort intermediate states per the plan).

## Desktop hub ingest

`RelayProcessor` learns `recording_upload`:

- Skip own echoes (`status != pending`) and processed records
  (sidecar `relay_processed`), exactly like actions.
- Validate the asset: present + readable + non-empty, else write back
  `failed` with a message.
- Ingest = `MeetingRecorderCenter.ingestExternalRecording(from:title:in:)`
  (new nonisolated static): `uniqueRecordingURL` with an `m4a` extension +
  copy + the SAME `.meta` sidecar (`{"eventID":null,"title":…}`) the
  crash-recovery scan expects. New files join the `rec_*` family so the Go
  orphan sweep covers them.
- Write back `received`, mark processed, delete the stashed asset copy.
- `onRecordingIngested: (@Sendable (URL, String?) -> Void)?` hook fires
  after a successful ingest; AppState wires it to
  `MeetingRecorderCenter.ingestPhoneRecording(audioURL:title:config:)`,
  which registers the file as a recoverable entry and enqueues it on the
  existing ProcessingJob queue (`.fromDefaults()` config — the same
  serial queue, engine-slot handshake, save path, and
  `meeting_transcript` publishing as every other recording). If the app
  is quit before the job runs, the sidecar makes the recording show up in
  the normal recovered-recordings flow on next launch.
- Hygiene: `recording_upload` records follow the action rule — deleted
  past 7 days, except still-pending never-processed ones.

`MeetingRecorderCenter` recovery scan (`scanRecoverable`,
`recoverySortKey`, `uniqueRecordingURL`) accepts `.m4a` alongside `.caf`;
everything else (sidecar removal on save, retry, dismiss) is
extension-agnostic already.

## Invariants

1. The phone deletes a local recording ONLY on a `received` echo.
2. The hub acknowledges `received` ONLY after `.m4a` + `.meta` are on disk
   in the recordings directory.
3. One transcription path: the hub never talks to any transcription API —
   only files + the existing MeetingRecorderCenter queue.
4. Wire formats are frozen by literal fixtures; absent-key discipline for
   optional fields (`title_hint`, `error_message`) so old/new builds
   interoperate.
5. No test seeds hardcoded wall-clock dates (fixture timestamps are frozen
   wire constants, not clock reads).

## Test plan

- Kit `RelayPayloadTests`: literal frozen fixtures for pending / received /
  failed / no-title-hint payload shapes + round trips + record name.
- Kit `CloudRecordFactoryTests` / transport tests: asset URL survives
  save→changes on InMemory; `TransportStore` persists `asset_path` across
  enqueue/pendingBatch and buffer/changes; CKRecord mapping sets/reads the
  CKAsset field, nil removes it.
- Kit `RecordingUploaderTests`: register→upload→ack→delete happy path;
  zero-length discard; upload retry after relaunch (new uploader over the
  same store re-sends); ack-after-local-delete no-op; failed echo + retry;
  transport failure leaves the row for the next pass.
- Kit `RelayFeedTests`: recording_upload echoes route to the seam; own
  pending records are skipped.
- Desktop `RelayProcessorTests`: fake asset file → `rec_*.m4a` + `.meta`
  land in a temp recordings dir, ack `received` written, hook fired;
  missing/empty asset → `failed` ack; duplicate delivery absorbed.
- Desktop `MeetingRecorderCenterTests`: `restorePendingOnLaunch` picks up
  an `.m4a` + sidecar pair (recovery scan extension).
- No simulator tests; `make mobile-build` must pass.
