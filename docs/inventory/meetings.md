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

**Module:** `cmd/meeting_transcript.go`, `cmd/meeting_transcript_export.go`, `internal/meeting/export.go`, `internal/db/meeting_transcripts.go`, `internal/db/meeting_recaps.go` (`RecapNotPrivate`, also used by `internal/kb`; `GetMeetingRecapForAI`), `internal/db/migrations/00163_meeting_transcript_private.sql`, `internal/db/migrations/00164_meeting_private_kb_dirty.sql`, the readers listed under MEETPRIV-02, and on the Desktop `MeetingRecorderCenter` (+`+Private`, `+Upgrade`), `RecordingActionsCenter`, `MeetingChatSurface`, `MeetingRecapQueries` (`fetchForRecordingForAI`, `isOwnedByPrivateRecording`), `EventRecapGate` + the calendar event page (`MeetingNotesView`), `PendingTranscriptQueries`, `MeetingTranscriptQueries` (`linkToEvent`, `convertActionItemToTarget`) and the recording detail views
**Last full audit:** 2026-10-28 (created)
**Owner approval:** board #906; feature note `docs/features/private-meetings.md`.

---

## MEETPRIV-01 — nothing is generated for a private recording

**Status:** Enforced (Go and Desktop).

**Observable:** `transcript save --private` stores the row with `private = 1` and calls no generator: the envelope reports `recap_ok: false`, `recap_skipped: true` (a Bool, as for the too-short skip), `recap_skipped_reason: "private"`, `chapters_ok: false`, `chapters_skipped: true`, `chapters_skipped_reason: "private"` (the too-short skip has no reason key and no `chapters_skipped`). `transcript recap|notes|chapters|followup <id>` on a private row exits 1 with `recording <id> is private` before any pipeline run, generator call or write; the same check (`loadTranscriptForAI`) guards the save path's generators. Desktop: every AI action of a private recording (Generate recap/notes/chapters, follow-up draft, meeting chat) is hidden or disabled with "Private recording — not sent to AI", and no meeting chat spec is built for it; the action item → Target button is off and `convertActionItemToTarget` refuses (a Target feeds the briefing, day plan and chat prompts); the flag travels from the start (Record Privately, the Settings default) through the capture lock, the queue and the save's `--private`, a lock flipped while Stop finalizes the file or before the pending row lands is kept (the kept transcript's pending row carries the job's flag, on insert and on conflict), turning private on drops the recording's chat engine after the row on screen is private, and a recovered recording whose choice is unknown (no pending row, legacy imports) comes back private.

**Why locked:** The owner marks a recording private so that its content never reaches an AI provider. One generator call is enough to break that promise.

**Test guards:**
- `cmd/meeting_transcript_private_test.go::TestMeetPriv01_SavePrivateGeneratesNothing`
- `cmd/meeting_transcript_private_test.go::TestMeetPriv01_AICommandsRefusePrivate`
- `cmd/meeting_transcript_private_test.go::TestMeetPriv01_SaveGeneratorsRefuseRowFlippedPrivate`
- `cmd/meeting_transcript_private_test.go::TestMeetPriv01_SaveTooShortKeepsBoolSkip`
- `internal/db/meeting_private_test.go::TestMeetPriv01_InsertStoresPrivate`
- `WatchtowerDesktop/Tests/MeetingRecorderPrivateTests.swift::testMeetPriv01_RecordPrivatelySavesWithPrivateFlagAndKeepsItInThePendingRow`
- `WatchtowerDesktop/Tests/MeetingRecorderPrivateTests.swift::testMeetPriv01_LockDuringCaptureReachesTheRowAndTheSave`
- `WatchtowerDesktop/Tests/MeetingRecorderPrivateTests.swift::testMeetPriv01_LockFlippedWhileStopFinalizesReachesTheJob`
- `WatchtowerDesktop/Tests/MeetingRecorderPrivateTests.swift::testMeetPriv01_LockFlippedWhileAFailingStopFinalizesReachesTheFailedJob`
- `WatchtowerDesktop/Tests/MeetingRecorderUpgradeTests.swift::testMeetPriv01_ALockFlippedBeforeTheRowLandsReachesTheRow`
- `WatchtowerDesktop/Tests/MeetingRecorderPrivateTests.swift::testMeetPriv01_CrashRecoveryKeepsTheFlag`
- `WatchtowerDesktop/Tests/MeetingRecorderPrivateTests.swift::testMeetPriv01_AudioOnlyRecoveryIsPrivateUntilTheOwnerOpensTheLock`
- `WatchtowerDesktop/Tests/MeetingRecorderPrivateTests.swift::testMeetPriv01_LegacyPendingPointerRecoversPrivate`
- `WatchtowerDesktop/Tests/MeetingRecorderPrivateTests.swift::testMeetPriv01_KeptTranscriptOfARowlessPrivateRecordingIsPrivate`
- `WatchtowerDesktop/Tests/MeetingRecorderPrivateTests.swift::testMeetPriv01_DismissedFailureStaysPrivate`
- `WatchtowerDesktop/Tests/MeetingChatSurfaceTests.swift::testMeetPriv01_TurnedPrivateDropsTheChatAndNoSpecIsBuiltAgain`
- `WatchtowerDesktop/Tests/MeetingChatSurfaceTests.swift::testMeetPriv01_NoSpecForAPrivateRecording`
- `WatchtowerDesktop/Tests/MeetingChaptersTests.swift::testMeetPriv01_ConvertActionItemOfAPrivateRecordingThrowsAndInsertsNoTarget`

**Locked since:** 2026-10-28

---

## MEETPRIV-02 — no prompt-feeding reader sees a private recording or the recap it owns

**Status:** Enforced (Go and Desktop).

**Observable:** A private recording, and the `meeting_recaps` row it owns (`transcript_id` = a private id; a recap with no recording is kept), is absent from: the knowledge index sources `transcript` and `recap` (`Build` renders nil, `Keys` leaves it out; migration 00164's trigger marks both in `kb_dirty` when the flag flips, so a recording turned private is deleted from the index on the next pass and one turned public comes back); the knowledge source `chat_artifact` for artifacts kept from the recording's meeting chat (`context_type` `meeting`, `context_id` = the recording id; `db.ChatNotPrivateMeeting`, marked by the same trigger); ideas mining of chat turns (`ListChatTurnsForIdeas` skips that meeting chat, in its media hold sub-select too); `meeting-prep recap --event-id E` refuses (exit 1, no generator call, nothing written: `event E's recap belongs to private recording N`) when E's recap is owned by a private recording, and the recap upsert never clears an existing `transcript_id` (a writer passing none keeps the owner); deleting a private recording deletes the recaps it owns (00164's `BEFORE DELETE` trigger) instead of letting the `ON DELETE SET NULL` foreign key turn them into readable recaps with no recording — a public recording's recap still outlives it; `SearchTranscripts` and so `list_transcripts` with a query and both `get_task_context` meetings paths (Jira and Linear); `list_transcripts` without a query (`ListMeetingTranscripts` skips private rows by default; only the owner's CLI `transcript list` sets `IncludePrivate`); `get_transcript` (answers `recording <id> is private`); a transcript's event recap in the transcript tools, the memory calendar episode and the notes prompt (`GetMeetingRecapForAI`); ideas mining (`ListTranscriptsForIdeasAfter`, including the recap join); catch-up (`ListCatchupMeetings`, both sub-queries); the automation reads `list_meeting_recaps` / `get_meeting_recap` (`ListMeetingRecaps`, `GetMeetingRecapByID`, `GetMeetingRecapByEventID`). Desktop: a meeting chat's prompt takes its recap from `MeetingRecapQueries.fetchForRecordingForAI` (Swift twin of `GetMeetingRecapForAI`), so a public recording on the same event as a private one never carries the private one's recap (a pasted recap with no recording still does); the calendar event page shows a recap a private recording owns but offers no AI action on it (`EventRecapGate`: no Re-generate, no `source_text` prefilled into the recap sheet, no "Recap from text", no "+ to notes").

**Why locked:** Each of these readers ends in a prompt. A reader that forgets the filter sends the recording to a provider without any visible sign.

**Test guards:**
- `internal/db/meeting_private_test.go::TestMeetPriv02_SearchTranscriptsSkipsPrivate`
- `internal/db/meeting_private_test.go::TestMeetPriv02_ListMeetingTranscriptsSkipsPrivateByDefault`
- `internal/db/meeting_private_test.go::TestMeetPriv02_IdeasReaderSkipsPrivate`
- `internal/db/meeting_private_test.go::TestMeetPriv02_CatchupSkipsPrivate`
- `internal/db/meeting_private_test.go::TestMeetPriv02_AutomationRecapReadsSkipPrivate`
- `internal/db/meeting_private_test.go::TestMeetPriv02_GetMeetingRecapForAISkipsPrivate`
- `internal/db/meeting_private_test.go::TestMeetPriv02_DeletingPrivateRecordingDeletesItsRecap`
- `internal/db/meeting_private_test.go::TestMeetPriv02_UpsertKeepsRecapOwnership`
- `internal/db/meeting_private_test.go::TestMeetPriv02_IdeasChatTurnsSkipPrivateMeetingChat`
- `cmd/meeting_transcript_private_test.go::TestMeetPriv02_EventRecapOfPrivateRecordingNotRegenerated`
- `internal/kb/meeting_private_test.go::TestMeetPriv02_PrivateMeetingChatArtifactsLeaveIndex`
- `internal/kb/meeting_private_test.go::TestMeetPriv02_PrivateRecordingNeverIndexed`
- `internal/kb/meeting_private_test.go::TestMeetPriv02_TurnedPrivateLeavesIndexNextPass` (also checks incremental = rebuild, KB-01)
- `internal/tools/transcripts_private_test.go::TestMeetPriv02_ListTranscriptsSkipsPrivate`
- `internal/tools/transcripts_private_test.go::TestMeetPriv02_GetTranscriptRefusesPrivate`
- `internal/tools/transcripts_private_test.go::TestMeetPriv02_TaskContextMeetingsSkipPrivate`
- `internal/memory/calendar_private_test.go::TestMeetPriv02_CalendarIngestSkipsPrivateRecap`
- `internal/meeting/meeting_private_test.go::TestMeetPriv02_NotesPromptSkipsPrivateRecap`
- `WatchtowerDesktop/Tests/MeetingChatSurfaceTests.swift::testMeetPriv02_ChatPromptSkipsTheEventRecapAPrivateRecordingOwns`
- `WatchtowerDesktop/Tests/Core/MeetingRecapTests.swift::testMeetPriv02_EventPageOffersNoAIActionOnARecapAPrivateRecordingOwns`

**Known limits:** the plain `GetMeetingRecap` does not filter (writers and the owner's CLI need the row) and must never feed a prompt; the same holds for Swift's `MeetingRecapQueries.fetch`/`fetchForRecording` (the owner's Recap tab and event page). A workbench agent with a shell can read the database or the recordings folder directly; the chat system prompt carries `schema.sql` as reference only (no raw-SQL tool is exposed).

**Locked since:** 2026-10-28

---

## MEETPRIV-03 — linking a private recording copies no text into `meeting_recaps`

**Status:** Enforced (Desktop: `MeetingTranscriptQueries.linkToEvent`).

**Observable:** Linking a private recording to a calendar event leaves `meeting_recaps` as it was.

**Why locked:** A copied recap would be a second, unmarked copy of the recording's content. (Go readers already skip a recap whose `transcript_id` is private.)

**Test guards:**
- `WatchtowerDesktop/Tests/MeetingTranscriptQueriesTests.swift::testMeetPriv03_LinkToEventPrivateRecordingCopiesNothingIntoRecaps`

**Locked since:** 2026-10-28

---

## MEETPRIV-04 — turning private on later hides, turning it off generates nothing

**Status:** Enforced (Go).

**Observable:** `transcript private <id> on|off` sets the flag and prints `{"id":N,"private":true|false}`; `show` reports `private`; `transcript list` (the owner's own) still lists the row. Turning private on also deletes the recording's transcript document, the recap documents it owns and the documents of the artifacts kept from its meeting chat from the knowledge index in the same process (`kb.DropPrivateRecording`), so `search_knowledge` and `get_knowledge_document` stop serving them at once; a failure there exits 1 after the flag is set, and the next index pass removes them anyway. Already generated recap, notes and chapters stay on the row, and every MEETPRIV-02 reader skips them from then on. Turning private off re-enables the AI commands and generates nothing by itself. Deleting a recording while it is private deletes its recap with it (MEETPRIV-02); turn private off first to keep the recap. Ideas and memory already mined are not unmined.

**Test guards:**
- `cmd/meeting_transcript_private_test.go::TestMeetPriv04_PrivateCommandTogglesAndShowReports`
- `internal/db/meeting_private_test.go::TestMeetPriv04_FlagRoundTripAndKBDirtyMarks`
- `internal/kb/meeting_private_test.go::TestMeetPriv04_DropPrivateRecordingLeavesSearchNow`

**Locked since:** 2026-10-28

---

## MEETPRIV-05 — export is local and always allowed

**Status:** Enforced (Go).

**Observable:** `transcript export <id> --format txt|md|srt|json [--output <file>]` works for private and public recordings alike, renders through `meeting.RenderTranscriptExport` (deleted utterances never exported; srt without segments exits 1 `transcript <id>: no timed segments`; a failed calendar-event lookup only leaves the md `Event:` line out, with a stderr warning), writes to stdout or to a file created 0600, and calls no model.

**Test guards:**
- `cmd/meeting_transcript_private_test.go::TestMeetPriv05_ExportPrivateToFile0600`
- `cmd/meeting_transcript_private_test.go::TestTranscriptExport_MarkdownEventTitle`
- `internal/meeting/export_test.go::TestMeetPriv05_RenderTranscriptExport`
- `internal/meeting/export_test.go::TestMeetPriv05_RenderTranscriptExportSRTNeedsSegments`
- `internal/meeting/export_test.go::TestMeetPriv05_RenderTranscriptExportJSON`

**Locked since:** 2026-10-28

---

## Changelog

- 2026-10-28 (board #906, private meetings Go lane): file created with MEETPRIV-01..05. Migration 00164 adds the `kb_dirty` trigger on `meeting_transcripts.private`. `TestMigration147_UpgradeKeepsLegacyAndMarksPending` reads its pre-upgrade hits with SearchTranscripts' query minus the private filter (the v146 database has no `private` column); its assertions are unchanged.
- 2026-10-28 (board #906, private meetings Desktop lane): MEETPRIV-01's Desktop half and MEETPRIV-03 Enforced, with their Swift guards; the Desktop's action item → Target refusal and fail-closed recovery join MEETPRIV-01. No guard relaxed.
- 2026-10-28 (board #906, final review fixes, Go): guards added, none relaxed. MEETPRIV-02 gains the `chat_artifact` knowledge source and the ideas chat-turn reader (00164's trigger, not yet in main, edited in place to mark kept meeting-chat artifacts), the `meeting-prep recap` refusal and the recap upsert that keeps its owner. MEETPRIV-04 drops the knowledge documents at once on `private on`. MEETPRIV-05's srt message names the transcript id, and a failed event lookup no longer fails an export.
- 2026-10-28 (board #906, final review Desktop fixes): MEETPRIV-02 Enforced on the Desktop too — the meeting chat's recap lookup and the calendar event page, with two Swift guards; MEETPRIV-01 gains three Swift guards (the kept transcript's pending row carries the job's flag, a dismissed failure stays private, the chat engine drop on the private flip). Guards only added; none relaxed.
