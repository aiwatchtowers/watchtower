# Private meetings and transcript export (2026-10-28)

Board #906. Two owner asks on meeting recordings:

1. **Private** — a recording the owner marks private is never sent to an AI provider.
2. **Export** — the owner can take a recording's transcript out of the app.

## Data

`meeting_transcripts.private INTEGER NOT NULL DEFAULT 0 CHECK (private IN (0,1))` (migration 00163). Existing rows stay non-private. The flag can be set at capture start, changed while the recording is still capturing or queued, and toggled later on the saved recording. Migration 00164 adds a trigger that marks the recording's knowledge-index document and the recaps it owns in `kb_dirty` whenever the flag flips, so the index follows a Desktop write that moves no change cursor, and a second trigger that deletes the recaps a private recording owns when the recording is deleted — the `meeting_recaps.transcript_id` foreign key is `ON DELETE SET NULL`, and a recap with no recording (its `source_text` is the full transcript) is one every reader serves.

## Contract MEETPRIV

- **MEETPRIV-01 — nothing generated.** For a private row no AI generation runs: `transcript save --private` stores the row with `private = 1` and skips the recap and chapters (envelope `recap_ok: false`, `recap_skipped: true` — still a Bool, as for the too-short skip — plus `recap_skipped_reason: "private"`; for chapters `chapters_ok: false`, `chapters_skipped: true`, `chapters_skipped_reason: "private"`; the too-short skip carries no reason key). `transcript recap|notes|chapters|followup <id>` on a private row exits 1 with `recording <id> is private` and writes nothing. The Desktop hides or disables every AI action of a private recording (Generate recap/notes/chapters, follow-up draft, meeting chat) with the line "Private recording — not sent to AI".
- **MEETPRIV-02 — no prompt-feeding reader sees it.** Every Go reader whose output can reach a model skips private rows, and the `meeting_recaps` row the recording owns (`meeting_recaps.transcript_id` = a private id):
  - knowledge index sources `transcript` and `recap` (`internal/kb/source_derived.go`) — a recording turned private leaves the index on the next indexer pass (deleted document, not just skipped);
  - `SearchTranscripts` / `transcripts_fts` callers, `list_transcripts`, `get_transcript` (a private id answers `recording <id> is private`), `get_task_context` meetings;
  - ideas mining (`ListTranscriptsForIdeasAfter`), catch-up (`ListCatchupMeetings`), memory calendar ingest of recaps, automation `list_meeting_recaps` / `get_meeting_recap`;
  - any other reader found later follows the same rule. The filters are safe by default: `ListMeetingTranscripts` leaves private rows out unless `IncludePrivate` is set (only the owner's CLI `transcript list` sets it), and `internal/kb` filters recaps with the same exported `db.RecapNotPrivate`; the plain `GetMeetingRecap` (writers, the owner's CLI) never feeds a prompt;
  - deleting a private recording deletes the recaps it owns (a public recording's recap still outlives it).
- **MEETPRIV-03 — linking keeps it private.** Linking a private recording to a calendar event (`MeetingTranscriptQueries.linkToEvent`) does not copy its text into `meeting_recaps`.
- **MEETPRIV-04 — turning private on later.** Already generated recap/notes/chapters stay visible in the app but every reader above now skips them. Ideas and memory already mined from the recording are not unmined (stated in the toggle's confirmation). Turning private off re-enables the AI actions; nothing is generated automatically. Deleting the recording while it is private deletes its recap too.
- **MEETPRIV-05 — export is local and always allowed**, private or not.

What stays out of reach of this contract: a workbench agent with a shell can still read the database or the recordings folder directly; the phone (E2E, the owner's own device) still receives the recording, but the phone chat goes through the same tools and so sees nothing.

## CLI

- `watchtower meeting-prep transcript save … --private`
- `watchtower meeting-prep transcript private <id> on|off` — sets the flag; prints `{"id":N,"private":true|false}`.
- `watchtower meeting-prep transcript export <id> --format txt|md|srt|json [--output <file>]` — stdout when `--output` is absent; the file is written 0600 (atomically) and stdout stays empty. Formats:
  - `txt` — the utterances as `[hh:mm:ss] Speaker: text` lines (the legacy flat `transcript_text` for a row without segments);
  - `md` — `# <title>`, a date / duration / event line, then `**Speaker** · hh:mm:ss` + text per utterance;
  - `srt` — numbered SubRip cues from the segments' start/end (`Speaker: text`); a row without segments exits 1 (`no timed segments`);
  - `json` — `{id, title, event_id, created_at, duration_sec, private, segments:[{start_sec,end_sec,speaker,text}], transcript_text}`.
  Deleted utterances are never exported. `show` gains the `private` key.

## Desktop

- **Start:** the record button gets a **Record Privately** variant (menu on the button); Settings → Meetings (Recording section) gets **Record meetings privately by default** (`transcription.privateByDefault`, default off), which the plain button, the Join auto-record and iPhone recordings use. The flag travels in the `pending_transcripts.private` row, `ProcessingJob`, crash recovery and the save call. Stop reads the flag only once the recorder has finalized the file, so a lock flipped during Stop reaches the job.
- **During capture / while queued / recovered:** a lock toggle in `RecordingIndicatorView` (capture, job pills until the save starts — `.summarizing` shows a fixed lock for a private job —, and the recovered pill for the recording **Transcribe** takes next). Recovery fails closed: a recording with no pending row (the start's write failed or the database was not open) and the legacy imports (sidecars, the single-slot `UserDefaults` pointer) recover **private**.
- **Recording detail:** lock badge in the list row and header, a **Private** toggle in the header, AI actions disabled as above — and the action item → Target button (targets feed the briefing, day plan and chat prompts) —, an **Export** menu — Copy Transcript, Save as Text / Markdown / Subtitles (SRT) / JSON. Export runs `transcript export --format X` to stdout (the renderer lives in Go only) and the **app** writes the bytes atomically to the save panel's URL: a file written by the CLI child into a TCC-guarded folder would be checked against Watchtower.app without the panel's grant. The toggle and export runs live in `RecordingActionsCenter` on AppState (busy flags, failure and the "Copied the transcript" / "Saved to <name>" line per recording, surviving navigation). Turning Private on flips the shown row first, then drops the meeting chat's engine, so the Chat tab never rebuilds one from the stale row; a reload of a private row drops any engine of it.
