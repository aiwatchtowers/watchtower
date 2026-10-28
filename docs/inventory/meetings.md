# Meeting recordings — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `cmd/meeting_transcript*.go`,
> `internal/meeting/`, `internal/db/meeting_transcripts.go`,
> `internal/db/meeting_recaps.go`, or any reader that selects from
> `meeting_transcripts`, `meeting_recaps` or `transcripts_fts`, read this file
> first. A new reader whose output can reach a model must skip private
> recordings (MEETPRIV-02) and gets a guard test here.

**Module:** `cmd/meeting_transcript.go`, `cmd/meeting_transcript_export.go`, `internal/meeting/export.go`, `internal/db/meeting_transcripts.go`, `internal/db/meeting_recaps.go` (`RecapNotPrivate`, also used by `internal/kb`; `GetMeetingRecapForAI`), `internal/db/migrations/00163_meeting_transcript_private.sql`, `internal/db/migrations/00164_meeting_private_kb_dirty.sql`, and the readers listed under MEETPRIV-02
**Last full audit:** 2026-10-28 (created)
**Owner approval:** board #906; feature note `docs/features/private-meetings.md`.

---

## MEETPRIV-01 — nothing is generated for a private recording

**Status:** Enforced (Go). Desktop half (AI actions hidden or disabled with "Private recording — not sent to AI") pending in the Desktop lane.

**Observable:** `transcript save --private` stores the row with `private = 1` and calls no generator: the envelope reports `recap_ok: false`, `recap_skipped: true` (a Bool, as for the too-short skip), `recap_skipped_reason: "private"`, `chapters_ok: false`, `chapters_skipped: true`, `chapters_skipped_reason: "private"` (the too-short skip has no reason key and no `chapters_skipped`). `transcript recap|notes|chapters|followup <id>` on a private row exits 1 with `recording <id> is private` before any pipeline run, generator call or write; the same check (`loadTranscriptForAI`) guards the save path's generators.

**Why locked:** The owner marks a recording private so that its content never reaches an AI provider. One generator call is enough to break that promise.

**Test guards:**
- `cmd/meeting_transcript_private_test.go::TestMeetPriv01_SavePrivateGeneratesNothing`
- `cmd/meeting_transcript_private_test.go::TestMeetPriv01_AICommandsRefusePrivate`
- `cmd/meeting_transcript_private_test.go::TestMeetPriv01_SaveTooShortKeepsBoolSkip`
- `internal/db/meeting_private_test.go::TestMeetPriv01_InsertStoresPrivate`

**Locked since:** 2026-10-28

---

## MEETPRIV-02 — no prompt-feeding reader sees a private recording or the recap it owns

**Status:** Enforced (Go).

**Observable:** A private recording, and the `meeting_recaps` row it owns (`transcript_id` = a private id; a recap with no recording is kept), is absent from: the knowledge index sources `transcript` and `recap` (`Build` renders nil, `Keys` leaves it out; migration 00164's trigger marks both in `kb_dirty` when the flag flips, so a recording turned private is deleted from the index on the next pass and one turned public comes back); deleting a private recording deletes the recaps it owns (00164's `BEFORE DELETE` trigger) instead of letting the `ON DELETE SET NULL` foreign key turn them into readable recaps with no recording — a public recording's recap still outlives it; `SearchTranscripts` and so `list_transcripts` with a query and both `get_task_context` meetings paths (Jira and Linear); `list_transcripts` without a query (`ListMeetingTranscripts` skips private rows by default; only the owner's CLI `transcript list` sets `IncludePrivate`); `get_transcript` (answers `recording <id> is private`); a transcript's event recap in the transcript tools, the memory calendar episode and the notes prompt (`GetMeetingRecapForAI`); ideas mining (`ListTranscriptsForIdeasAfter`, including the recap join); catch-up (`ListCatchupMeetings`, both sub-queries); the automation reads `list_meeting_recaps` / `get_meeting_recap` (`ListMeetingRecaps`, `GetMeetingRecapByID`, `GetMeetingRecapByEventID`).

**Why locked:** Each of these readers ends in a prompt. A reader that forgets the filter sends the recording to a provider without any visible sign.

**Test guards:**
- `internal/db/meeting_private_test.go::TestMeetPriv02_SearchTranscriptsSkipsPrivate`
- `internal/db/meeting_private_test.go::TestMeetPriv02_ListMeetingTranscriptsSkipsPrivateByDefault`
- `internal/db/meeting_private_test.go::TestMeetPriv02_IdeasReaderSkipsPrivate`
- `internal/db/meeting_private_test.go::TestMeetPriv02_CatchupSkipsPrivate`
- `internal/db/meeting_private_test.go::TestMeetPriv02_AutomationRecapReadsSkipPrivate`
- `internal/db/meeting_private_test.go::TestMeetPriv02_GetMeetingRecapForAISkipsPrivate`
- `internal/db/meeting_private_test.go::TestMeetPriv02_DeletingPrivateRecordingDeletesItsRecap`
- `internal/kb/meeting_private_test.go::TestMeetPriv02_PrivateRecordingNeverIndexed`
- `internal/kb/meeting_private_test.go::TestMeetPriv02_TurnedPrivateLeavesIndexNextPass` (also checks incremental = rebuild, KB-01)
- `internal/tools/transcripts_private_test.go::TestMeetPriv02_ListTranscriptsSkipsPrivate`
- `internal/tools/transcripts_private_test.go::TestMeetPriv02_GetTranscriptRefusesPrivate`
- `internal/tools/transcripts_private_test.go::TestMeetPriv02_TaskContextMeetingsSkipPrivate`
- `internal/memory/calendar_private_test.go::TestMeetPriv02_CalendarIngestSkipsPrivateRecap`
- `internal/meeting/meeting_private_test.go::TestMeetPriv02_NotesPromptSkipsPrivateRecap`

**Known limits:** the plain `GetMeetingRecap` does not filter (writers and the owner's CLI need the row) and must never feed a prompt. A workbench agent with a shell can read the database or the recordings folder directly; the chat system prompt carries `schema.sql` as reference only (no raw-SQL tool is exposed).

**Locked since:** 2026-10-28

---

## MEETPRIV-03 — linking a private recording copies no text into `meeting_recaps`

**Status:** Planned (Desktop lane: `MeetingTranscriptQueries.linkToEvent`).

**Observable:** Linking a private recording to a calendar event leaves `meeting_recaps` as it was.

**Why locked:** A copied recap would be a second, unmarked copy of the recording's content. (Go readers already skip a recap whose `transcript_id` is private.)

**Locked since:** 2026-10-28

---

## MEETPRIV-04 — turning private on later hides, turning it off generates nothing

**Status:** Enforced (Go).

**Observable:** `transcript private <id> on|off` sets the flag and prints `{"id":N,"private":true|false}`; `show` reports `private`. Already generated recap, notes and chapters stay on the row, and every MEETPRIV-02 reader skips them from then on. Turning private off re-enables the AI commands and generates nothing by itself. Deleting a recording while it is private deletes its recap with it (MEETPRIV-02); turn private off first to keep the recap. Ideas and memory already mined are not unmined.

**Test guards:**
- `cmd/meeting_transcript_private_test.go::TestMeetPriv04_PrivateCommandTogglesAndShowReports`
- `internal/db/meeting_private_test.go::TestMeetPriv04_FlagRoundTripAndKBDirtyMarks`

**Locked since:** 2026-10-28

---

## MEETPRIV-05 — export is local and always allowed

**Status:** Enforced (Go).

**Observable:** `transcript export <id> --format txt|md|srt|json [--output <file>]` works for private and public recordings alike, renders through `meeting.RenderTranscriptExport` (deleted utterances never exported; srt without segments exits 1 `no timed segments`), writes to stdout or to a file created 0600, and calls no model.

**Test guards:**
- `cmd/meeting_transcript_private_test.go::TestMeetPriv05_ExportPrivateToFile0600`
- `internal/meeting/export_test.go::TestRenderTranscriptExport` (+ `_SRTNeedsSegments`, `_JSON`)

**Locked since:** 2026-10-28

---

## Changelog

- 2026-10-28 (board #906, private meetings Go lane): file created with MEETPRIV-01..05. Migration 00164 adds the `kb_dirty` trigger on `meeting_transcripts.private`. `TestMigration147_UpgradeKeepsLegacyAndMarksPending` reads its pre-upgrade hits with SearchTranscripts' query minus the private filter (the v146 database has no `private` column); its assertions are unchanged.
