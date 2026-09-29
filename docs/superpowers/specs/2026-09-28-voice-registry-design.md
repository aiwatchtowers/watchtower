# Voice registry — learn who is speaking, keep learning, share prints

**Status:** design, owner-approved section by section on 2026-09-28. Implementation plan to follow.
**Scope:** Desktop (Swift) owns all logic; Go owns only the schema. Sub-project **B** of a three-part
effort (A = transcript slicing quality, B = this, C = import/export — folded into B §5).

## 0. Why

Speaker names in transcripts are mostly `Speaker N` today. The only way to teach a voice is a manual
rename inside the Transcript tab, which the owner does not use: they rarely open the app. An
owner-run research spike on real recordings (numbers kept in the owner's private archive, not in this
repo) established:

- Voice embeddings from the FluidAudio diarizer separate people well **across meetings** once they are
  anchored by owner-confirmed examples: matching against the nearest confirmed example of each person,
  with a cosine threshold of ~0.70 and a margin over the runner-up of ~0.10, was near-perfectly precise
  in leave-one-recording-out evaluation, while a 0.55–0.70 band was mostly wrong (the true person had
  no print yet and a look-alike won).
- The embeddings persisted in `meeting_transcripts.speakers_json` (streaming diarizer) are in the same
  space as the offline diarizer's, so recordings whose audio was already swept by retention can still be
  named from their stored embeddings.
- An attendee check catches look-alikes but also fires on people who joined without an invite, so it
  must gate auto-labeling, not the candidate pool.
- A single averaged print per person handles channel differences (meeting-room mic vs. conference
  audio) poorly; per-sample nearest-neighbour matching does not.
- Owner-facing labeling only works with audio: cards without clips were useless, and weak/short
  voices were noise. The system must filter what it shows.
- Text-only (LLM) name guessing without an attendee list failed outright; with one it confused the
  addressee with the speaker. It is not a substitute for voice identity.

The owner's requirements:

1. After a meeting, listen to samples of unknown voices and assign people.
2. The system keeps learning; when it is unsure it asks.
3. Import/export voice prints so the system gets smarter, shared with colleagues, without leaking more
   than necessary.
4. Remove the in-transcript speaker rename and the LLM name suggestions; when a label is wrong, the
   owner opens that voice's samples and relabels.
5. Train in bulk "like the research spike": cross-meeting groups, suggestions, live quality numbers.

## 1. Data model

Schema lives in Go (goose migration, `internal/db/schema.sql`, `TestSchemaGolden`,
`TestAllTablesExist`) and is mirrored in `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`.

### 1.1 `voice_prints` — a person (reshaped)

| Column | Notes |
|---|---|
| `id` | PK, preserved by the table rebuild |
| `person_key` TEXT UNIQUE | lower-cased email; the merge key across sources. Without an email: the normalized name, exactly as `SpeakerNaming.personKey` does today |
| `display_name` TEXT | |
| `created_at`, `updated_at` | |

`embedding` and `sample_count` are dropped (SQLite table rebuild). Owner identity stays derived from
`google_accounts` emails (`VoicePrintMatcher.isOwnerPrint`), no flag column.

### 1.2 `voice_samples` — confirmed voice examples (new)

| Column | Notes |
|---|---|
| `id` | PK |
| `person_id` | → `voice_prints.id` `ON DELETE CASCADE` |
| `embedding` BLOB | 256 × float32, L2-normalized, little-endian (today's encoding) |
| `model_version` TEXT | embedding-model version (FluidAudio speaker model), **not** the ASR engine; samples of another version never take part in matching |
| `origin` TEXT CHECK (`owner`,`auto`,`imported`) | |
| `anchor` INTEGER 0/1 | 1 only for `origin='owner'` |
| `status` TEXT CHECK (`active`,`pending`,`retired`) | `pending` = imported, not yet confirmed; `retired` = evicted by the cap or rejected, kept for rollback bookkeeping |
| `transcript_id` | → `meeting_transcripts.id` `ON DELETE SET NULL` (a sample outlives its recording); NULL for imported |
| `cluster_label` TEXT | the cluster's label in that recording (research-seeded rows carry a `research:` prefix) |
| `channel` TEXT CHECK (`room`,`remote`,`unknown`) | from the `.activity` sidecar: share of the cluster's speech that came through system audio |
| `score` REAL | similarity at creation; NULL for `owner` |
| `speech_sec` REAL | clean speech behind the sample |
| `import_id` | → `voice_imports.id` `ON DELETE CASCADE` |
| `created_at` | |

Indexes: `(person_id, status)`, `(transcript_id)`.

### 1.3 `voice_imports` — import log (new)

`id`, `sender_name`, `sender_email`, `file_sha256` (UNIQUE — re-importing the same file is a no-op),
`people_count`, `sample_count`, `model_version`, `imported_at`.

### 1.4 `voice_label_queue` — "who spoke" tasks (new)

| Column | Notes |
|---|---|
| `id` | PK |
| `transcript_id` | → `meeting_transcripts.id` `ON DELETE CASCADE` |
| `cluster_label` | |
| `reason` TEXT CHECK (`unsure`,`unknown`,`import_confirm`,`conflict`,`relabel`) | |
| `suggested_person_id` | nullable → `voice_prints.id` `ON DELETE SET NULL` |
| `score` REAL | |
| `status` TEXT CHECK (`pending`,`done`,`skipped`) | |
| `created_at`, `resolved_at` | |

Partial UNIQUE `(transcript_id, cluster_label) WHERE status='pending'`; index `(status, created_at)`.

### 1.5 `meeting_transcripts`

- `speakers_json` per cluster grows from `{speaker, embedding}` to
  `{speaker, original_label, embedding, person_id, label_source, score, matched_sample_id, channel,
  clips: [{start, end}], speech_sec, model_version}`. `label_source` ∈ `owner`/`auto`/`none`. Missing
  fields decode as `label_source: none`, missing `model_version` as the current (first) version — the
  research spike confirmed legacy embeddings come from the same model. The column is still never
  selected by the recordings list projection (perf guard).
- New column `speaker_names_changed_at TEXT` — set by Swift whenever a relabel/retro pass changes
  names; the recording detail compares it with the recap/notes timestamps to offer a regeneration.
  *Implementation note (2026-09-29):* `updated_at` cannot serve as the ad-hoc recap's timestamp (a
  relabel bumps it in the same write), so the ad-hoc recap gets its own `summary_updated_at`, stamped
  by Go's recap writer; an event recap uses `meeting_recaps.updated_at`. The hint covers the recap
  (its button regenerates the recap), not the notes.
  *Implementation note (2026-09-29, final re-review N1/N7):* the hint compares against the recap the
  Recap tab actually renders and is offered only when its Regenerate can refresh it. The recording's
  own `meeting_recaps` row (`transcript_id = id`) is refreshed in place by `transcript recap <id>`
  (the collision guard still protects a pasted or another recording's event recap, and still governs
  the save path); such a row is compared by `summary_updated_at` when the recording also holds a
  `summary_json` copy (`linkToEvent` copies it with the link time as `updated_at`), else by its own
  `updated_at`. Another source's event recap shows no hint.
- *Implementation note (2026-09-29):* each cluster may also carry `rejected_person_ids` — the people
  the owner said it is NOT (a rejected auto label, or a relabel away from a wrong name). Retro/`decide`
  never assigns a rejected person to that cluster; naming it as that person by hand lifts the rejection.

### 1.6 Invariants

1. An `auto` sample is created only if it matches (≥ 0.70) at least one `anchor` sample of the same
   person. No anchor ⇒ no self-training for that person; imported samples are never anchors.
2. Owner-identity rows are never `imported`; import never creates samples for the owner's emails or
   for reserved labels (`Я`, `Speaker N` — `SpeakerNaming.isReserved`).
3. Labeling decisions (confident band, retro, self-training) use only `status='active'` samples with
   the current `model_version`. `pending` imported samples are scored separately and can only produce
   an `import_confirm` suggestion; `retired` samples are never scored.
4. Export takes only `origin IN ('owner','auto') AND status='active'` — received prints are never
   re-shared.
5. Retro relabel (§4) only ever changes clusters with `label_source='none'`.

### 1.7 Migration of existing data

- Each existing `voice_prints` row → one person + one `owner`, `anchor=1` sample at the current model
  version. Existing transcripts are not rewritten; clusters whose label is already a name get
  `label_source: owner` lazily on decode (a named, non-`Speaker N` label reads as owner-set), so retro
  relabel never touches them.
- **Research labels.** The owner's labels from the research spike (confirmed by ear) are seeded as
  `owner`/`anchor` samples by a one-off script after this migration ships — dry-run report first, then
  apply with a DB backup (the `relink_calendar` precedent). The regular import path is not used: by
  invariant 2 it never creates `owner` samples. Persons merge with the migrated rows by `person_key`.
  Research auto-labels are **not** seeded; the product's retro pass recomputes them under product rules.

## 2. Post-meeting pipeline

Inserted into `MeetingRecorderCenter` after diarization, before save:
transcription → diarization → **voice identification** → save.

1. **Clusters.** Per diarized cluster: embedding, `speech_sec`, channel (from `.activity`), and 2–3
   best clip spans (≥ 4 s, highest `qualityScore`, trimmed away from speaker changes). Clusters with
   < 20 s of clean speech neither match nor enqueue — they stay `Speaker N`.
2. **Identification.** Candidates = every person with active samples of the current model version.
   A person's score = cosine to their **nearest** sample.

   | Band | Condition | Effect |
   |---|---|---|
   | confident | best ≥ 0.70, best − second ≥ 0.10, person invited (or owner) | label applied, `label_source: auto` |
   | unsure | 0.55 ≤ best < 0.70; or confident but not invited; or best match only via `pending` imported samples | no label; queue `unsure` / `import_confirm` with suggestion |
   | unknown | best < 0.55 | queue `unknown`; suggestion = invited attendees not yet in the registry |
   | conflict | two people ≥ 0.70 within 0.10, or sources disagree on this voice | queue `conflict` |

   Recordings without an event: no invite check, confident threshold 0.75.
3. **Owner.** The existing owner-voice refinement of `«Я»` (`RoleAssigner.detectSelf` tie-break/veto)
   stays; it wakes up once the owner has an email-keyed anchor (the research seed provides it).
4. **Self-training.** A confidently labeled cluster becomes an `auto` sample only if best ≥ 0.80 with
   the margin, it matches an anchor of that person (invariant 1), and `speech_sec` ≥ 30. Cap: 20 active
   `auto` samples per person per channel; the oldest is retired past the cap.
5. **Queue + notification.** If anything was enqueued: a macOS notification ("<meeting>: N voices — who
   is this?") and the tray counter grows. Nothing enqueued ⇒ no notification.
6. **Failure.** Any identification/queue error saves the transcript without names (the existing
   diarization-failure behavior); a recording never fails because of the registry.

All thresholds are constants in one place (`VoiceRegistryPolicy` in `WatchtowerCore`).

## 3. "Who spoke" window

**Entry points:** the post-meeting notification (that meeting's voices); tray "Voices to label (N)"
(the whole queue, newest meetings first); "Listen to samples" on a speaker name in the Transcript tab
(one voice, reason `relabel`); tray "Review voices" (§3.2); tray "Train voices" (§4.2). A dedicated
small window (the Quick Capture / Pipeline Progress precedent), not a sidebar tab; it opens from the
tray without a main window.

### 3.1 Voice card

- Meeting, date and the reason ("not recognized" / "looks like X, 0.66" / "looks like X, 0.87, but X was
  not invited" / "from <sender>'s file: is this X?" / "two sources disagree").
- 2–3 clips (4–10 s) with the transcript text of those spans, played straight from the `.caf` range —
  no clip files are written.
- Person picker: this meeting's invited attendees not yet in the registry, then registry people, then
  "new person…" (name + optional email). The suggestion is preselected.
- Actions: **Confirm**, **Don't know** (stays `Speaker N`, task closed for good), **Several people**
  (mixed cluster: no label, never used for learning), **Skip** (stays queued).
- Keys: space = play, 1–9 = pick, Enter = confirm. Target: 3–5 s per card.

**Confirm** is one write transaction: relabel the cluster (`segments_json`, `transcript_text`,
`speakers_json` with `label_source: owner` — the `renameSpeaker` mechanics, now called from here);
insert an `owner`/`anchor` sample with the cluster's channel; for `import_confirm`, flip that person's
`pending` samples from that sender to `active`; close the task. After commit, trigger retro relabel for
that person (§4).

**Self-cleaning queue:** a recording's audio swept by retention ⇒ its tasks become `skipped` (no
audio-less cards, ever); recording deleted ⇒ tasks cascade; voice recognized meanwhile by a newer
sample ⇒ task auto-closes.

### 3.2 Review mode (on demand only)

- Registry list: per person, sample counts by channel and origin, last recognition; delete a person;
  delete everything from one import sender.
- Spot-check auto labels: per person the 2–3 latest auto labels with clips, correct / wrong. Wrong ⇒
  rollback (§4.3).
- Channel gaps ("only meeting-room samples") shown as information only.

The system never schedules spot checks by itself (owner decision: unsure + unknown only, review on
demand).

### 3.3 Where the code lives

`VoiceRegistryCenter` — `@Observable`, owned by `AppState` (survives navigation, the
`MeetingRecorderCenter` shape): queue, counter, window state. Pure logic (bands, nearest-sample
matching, learning rules, caps, grouping, accuracy estimate) in `WatchtowerCore` with tests in
`Tests/Core`. Queries: `VoiceSampleQueries`, `VoiceLabelQueueQueries`, `VoiceImportQueries`. A small
AVFoundation service plays a time range of a `.caf` without writing to disk.

### 3.4 Removed

- Speaker rename inside the Transcript tab as a UI path (replaced by "Listen to samples").
- "Suggest speaker names": the `meeting.speaker_guess` prompt, its `DefaultVersions` entry and tier
  routing, `internal/meeting/speaker_guess.go`, CLI `meeting-prep transcript speaker-guess`, the Swift
  chips. The `go/parser` scans (`TestTierForSource_EveryGenerateCallIsTagged`, prompt-store wiring)
  must stay green after the removal.

## 4. Retro relabel and rollback

### 4.1 Retro relabel

**Triggers:** an owner confirmation; an import person activated; app launch (catch-up). Idempotent.
Auto samples minted on new meetings do **not** trigger it — one wrong auto sample must not spread over
history without the owner.

**Scope:** every transcript with `speakers_json`, **including recordings whose audio is gone**, but
only clusters with `label_source: none`. Only the confident band applies (with the invite check —
event links exist for most recordings). Retro never enqueues tasks and never mints samples.

**Write:** one transaction per transcript — labels, `label_source: auto`, `person_id`,
`matched_sample_id`; sets `speaker_names_changed_at`. Runs off the main actor. The knowledge-search
index picks up the new text through its content hash, no change needed.

**Recaps/notes:** when `speaker_names_changed_at` is newer than the recap or notes, the recording
shows "Speaker names were updated — regenerate the recap?". Nothing regenerates automatically (an AI
call is the owner's decision). Go needs no change: the comparison reads existing timestamps.

### 4.2 Train mode (bulk labeling, as in the research spike)

1. All unrecognized clusters from recordings that still have audio, ≥ 20 s clean speech.
2. Cross-meeting grouping by voice similarity (average linkage); clusters of the same recording or
   with different labels never merge.
3. Group suggestion: the nearest registry person if close but below confident; otherwise the
   not-yet-registered attendee present at the most of the group's meetings (invite intersection, no AI).
4. Cards ordered by total speech. One confirmation labels every cluster of the group.

Lessons built in: no card without audio (audio-less members appear only as "+N meetings without
audio — will be labeled from this"); no weak/incoherent groups; a "Several people" group is dissolved
and its clusters are regrouped more strictly next time; groups rebuild live after each confirmation
(retro relabel runs, recognized groups disappear, suggestions improve).

**Quality header:** named speech (total / by owner / auto); estimated precision and recall on the
owner's own anchors (leave-one-recording-out at the current threshold); people count and single-channel
people. A visible precision drop suggests a review; thresholds never move by themselves.

### 4.3 Rollback

- **Wrong auto label** (review or "Listen to samples"): the cluster returns to `original_label`; an
  `auto` sample minted from it is retired; every cluster whose `matched_sample_id` was that sample is
  re-matched against the remaining samples and reverted to `Speaker N` if no longer confident; the
  voice is enqueued as `relabel` if audio exists.
- **Delete a person:** samples go; their auto labels revert to `Speaker N`; owner-set names stay in
  the text as history, unlinked.
- **Delete an import:** its samples go (cascade); labels that depended only on them revert the same way.

## 5. Import / export

**File** (`.wtvoices`): format version, embedding `model_version`, sender name + email, people
(`person_key`, `display_name`) with samples (embedding, channel, `speech_sec`). **Never** audio, text,
meeting titles, dates or recording ids.

**Protection (owner chose baseline, 2026-09-28):** the whole file is AES-GCM encrypted with a key
derived from a password (PBKDF2, random salt); the password travels separately; there is no
unencrypted export. No sender signature: poisoning is already contained by "imported = suggestion
until confirmed". Recipient-bound files or signatures are a later option.

**Export** (review mode): by default every person with active samples, the owner included (colleagues
will recognize the owner), deselectable; only `owner`/`auto` active samples at the current model
version, at most 5 per person per channel (anchors first, then highest-scoring auto). Written to a temp
file and renamed.

**Import:** file + password → preview (sender, people, samples, merges by email, new people,
conflicts, model-version mismatch — mismatched samples are not imported) → one transaction: a
`voice_imports` row, samples `origin=imported`, `status=pending`.

Rules: the owner's emails and reserved labels are skipped silently; persons merge by `person_key`
(the local display name wins); a newer file from the same sender replaces that sender's previous
**pending** samples (confirmed ones stay); the same file twice is a no-op (`file_sha256`); samples from
several senders coexist with provenance; an imported sample ≥ 0.80 similar to a *different* person
(local or another sender) raises a `conflict` task the first time that voice appears.
*Implementation note (2026-09-29):* the owner's explicit confirm settles it — the confirm retires every
contradicting sample of other people (pending imports, auto samples and owner anchors alike) at ≥ 0.80
(`importConflict`) to the confirmed voice and re-matches their dependent auto labels. The owner's own
person (their emails, as in invariant 2) is exempt: their samples are never retired this way.

**Pending imported samples** only suggest (live pipeline and train mode, reason `import_confirm`);
they never label, never take part in retro, are never anchors. **One confirmation** activates that
person's samples from that sender and adds a local anchor from the owner's recording.

**Deletion:** review mode lists imports; "delete everything from <sender>".

**Owner decision recorded:** migration 00046 and the transcript-stack spec state voice prints are
"never exported". This changes to "exported only by an explicit owner action, as an encrypted file
of embeddings". Risk named explicitly: this shares colleagues' biometric identifiers without their
separate consent; the owner accepted it on 2026-09-28 (sharing the whole registry, option B).

## 6. Errors, tests, rollout

**Errors.** Nothing fails a recording (§2.6). Retro is per-transcript transactional and resumes on
launch. Import errors (wrong password, tampered/corrupt file — GCM authentication, model mismatch) are
shown in the preview with nothing written; import commits in one transaction or not at all. Export
never leaves a partial file. Audio swept ⇒ tasks skipped. Clusters without embeddings are ignored.

**Tests.**
- `Tests/Core`: bands; nearest-sample matching; margin; invite gate; no-event threshold; learning rules
  (anchor, 0.80, 30 s, cap, eviction); train-mode grouping constraints; the accuracy estimator; fixtures
  for a mixed group, one person on two channels, a look-alike stranger without a print, an uninvited
  attendee with a strong match.
- Queries: migration of existing prints; cascades (recording → tasks, import → samples); pending-task
  uniqueness; Confirm atomicity; rollback via `matched_sample_id`; **retro never touches
  `label_source != none`** (the guard test).
- Import/export: round trip on a clean DB; wrong password; flipped byte; model mismatch; owner email
  skipped; same-sender replacement; duplicate file no-op; imported samples excluded from export.
- Go: migration, `schema.sql`, schema golden, `TestAllTablesExist`; the `speaker_guess` removal keeps
  the tier and prompt-store scans green.
- Manual before merge: record → notification → label → past recordings updated → "regenerate recap"
  hint → export → import on a second DB → confirm.

**Rollout.** Settings → Transcription: "Voice recognition", **default on** (off = no identification,
queue or notifications; the registry is kept). A separate "Notify about unknown voices" toggle; the tray
queue stays regardless. The research seed runs after the migration ships (dry-run → report → apply
with backup).

**Order.** B (this) works on today's clusters and does not depend on A. A (word-level slicing +
offline diarization with an attendee upper bound) gets its own spec next and improves both samples and
transcripts. Import/export (C) is §5.

## 7. Non-goals (this version)

- Storing encrypted audio snippets to re-derive samples after an embedding-model change.
- Recipient-bound encryption, sender signatures, expiry of imported samples.
- Automatic threshold tuning; scheduled spot checks.
- Changing the diarizer or the text-to-speaker slicing (sub-project A).
- Any Go-side matching or a daemon phase for retro relabel.

## 8. Decisions log (owner, 2026-09-28)

1. Import/export purpose: share with colleagues. 2. Whose prints: the whole registry (option B), risk
accepted. 3. Imported prints: suggestion until the first confirmation. 4. Surfacing: notification after
processing + tray queue. 5. Asking: only unsure + unknown, review on demand. 6. Past recordings: auto,
only unnamed clusters, recaps regenerate on the owner's call. 7. Share numbers only, never audio;
baseline file encryption. 8. Remove in-transcript rename and LLM suggestions; relabel via "Listen to
samples". 9. Continuous self-training from confident samples, anchored to owner confirmations.
10. Many senders must work (merge by email, provenance, conflicts). 11. Bulk train mode like the
research spike, with live quality numbers. 12. Seed the owner's research labels into the product.
