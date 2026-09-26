# Recordings Tab + Recording Single-View — Design

**Date:** 2026-07-15
**Branch:** `feature/pluggable-transcription-engines` (worktree)
**Feature area:** Meeting Transcriber (v74+), Desktop Calendar

## Problem

Meeting recordings today have no home of their own. Event-linked transcripts are
buried inside `MeetingPrepDetailView` → `MeetingNotesView` → `TranscriptSectionView`
as inline `DisclosureGroup`s; ad-hoc recordings appear only as a row at the bottom of
the Calendar events list. There is:

- **No dedicated screen** for a recording.
- **No way to delete** a recording — neither Go DB layer, CLI, nor Swift has any
  delete path (only the daemon audio-retention sweep, which keeps the row + text
  forever).
- **No "publish" concept** — the recap renders as plain `Text`; there is no editable,
  shareable meeting-notes output.
- **Slow opening**, because the Swift list queries (`fetchForEvent`, `fetchAdHoc`)
  eagerly `fetchAll` full rows including `transcript_text` and `summary_json`,
  re-decode `summary_json` with a fresh `JSONDecoder` inside row builders, and the
  phase-change reload cascade fires multiple full-row reads at once.

## Goals

1. A **"Записи" (Recordings) tab** inside the Calendar screen (segmented control
   `События | Записи`), listing all recordings (ad-hoc + event-linked) in one place.
2. A **single-view detail screen** per recording with four tabs: **Рекап**,
   **Meeting notes**, **Расшифровка**, **Чат с секретарём**.
3. **Fast opening** via a lightweight list projection + lazy tab loading + decode-once.
4. **Publishable meeting notes**: AI-generated markdown, editable in-app, Copy,
   persisted.
5. **Delete a recording with all its content** (row + audio file + meeting chat),
   with confirmation.
6. UI consistent with the app's existing style (Dashboard `SituationReviewPane`,
   segmented controls, language badges).

## Non-goals

- Slack/Confluence auto-posting of notes. "Publish" = generate + edit + Copy;
  the user pastes wherever they want.
- Deleting the event's `meeting_recaps` row on transcript delete (a recap can exist
  independently of a recording — leave it untouched).
- Changing live/batch transcription, provider registry, or the recording pipeline.
- Markdown-rendering the structured recap (keep the existing plain structured render).

## Navigation & Tab

- `CalendarEventsView` gains `@State private var mode: CalendarMode` (`.events` /
  `.recordings`) driven by a segmented `Picker` at the top of the screen.
  - `.events` — the current view, unchanged.
  - `.recordings` — new master-detail: `RecordingsListView` (left) + `RecordingDetailView`
    (right, shown when a recording is selected).
- The old ad-hoc `recordingsSection` / `adHocRow` at the bottom of the events list is
  **removed** — recordings now live only in the Recordings tab. `LinkTranscriptSheet`
  ("Link to event…") moves into the recording detail/row.
- Recordings list is unified: ad-hoc and event-linked recordings both appear. Rows show
  title, date, duration, language badges, and a source hint (event-linked vs ad-hoc).

## Performance

- **`RecordingListItem`** — a new GRDB projection struct: `id`, `title`, `eventID`,
  `durationSec`, `createdAt`, `langStats`, `hasSummary`, `hasNotes`, `snippet` (first
  ~200 chars of `transcript_text`). The list query selects only these columns —
  **never** `transcript_text` or full `summary_json` — mirroring the Go `list` command.
- The full `MeetingTranscript` row is fetched **only on selection**, asynchronously
  (`.task(id:)`), off the synchronous main-render path.
- `parsedSummary` is decoded **once** when the detail loads (cached on the detail
  view-model), not inside SwiftUI row builders.
- **Lazy tabs**: `transcript_text` and the chat conversation load only when their tab is
  first opened, not on detail appearance.

## Detail Screen (4 tabs, layout variant A)

`RecordingDetailView`:

- **Header** — title, date, duration, language badges (`TranscriptLangBadges`), and a
  **🗑 Удалить** button (trailing).
- **Segmented control** — `Рекап | Meeting notes | Расшифровка | Чат`.

Tabs:

1. **Рекап** — structured recap (summary / key decisions / action items / open
   questions), rendered with the existing plain-`Text` `recapSection` style. Recap
   actions ("Re-generate", "Recap from text") move here from `MeetingNotesView`.
2. **Meeting notes** — publishable notes:
   - **Сгенерировать** button → AI produces markdown notes from the transcript.
   - Editable `TextEditor` bound to the notes markdown.
   - **Copy** button (to clipboard) + autosave-on-edit to the DB.
   - Optional markdown preview via the existing `MarkdownText` component.
3. **Расшифровка** — full `transcript_text` in a `ScrollView` (lazy-loaded).
4. **Чат** — `MeetingDiscussSection` (secretary chat about this meeting), lazy-loaded,
   with the input bar docked outside the ScrollView (mirroring `SituationDiscussSection`).

## Data & Layers

### Migration `00017_meeting_transcript_notes.sql`

- `ALTER TABLE meeting_transcripts ADD COLUMN notes_md TEXT;` (nullable; null = not yet
  generated).
- Mirror the column into `internal/db/schema.sql`; regenerate the golden snapshot
  (`go test ./internal/db/ -run TestSchemaGolden -update`).
- Notes are stored on the transcript for both ad-hoc and event-linked recordings.

### Meeting notes generation (Go, AI)

- New CLI subcommand: `watchtower meeting-prep transcript notes <id>`.
- New AI prompt `meeting.notes` (**strong** tier, works on both claude and codex),
  registered per the `add-ai-prompt` skill. Input: `transcript_text` (passed via stdin
  when > `digest.StdinThreshold` (32 KB), like the recap path). Output: markdown notes
  intended for publication (title, participants, outcomes, decisions, next steps;
  neutral tone).
- Result is written to `meeting_transcripts.notes_md` and echoed back in the CLI JSON
  envelope. Go DB layer gains `SetMeetingTranscriptNotes(id, md)` and a `NotesMD` field
  on the `MeetingTranscript` struct.
- Swift wrapper: `TranscriptSaveService.generateNotes(transcriptID:)` runs the CLI and
  returns the markdown.

### Meeting notes editing (Swift, direct GRDB)

- `MeetingTranscriptQueries.saveNotes(_:id:markdown:)` writes `notes_md` directly via
  GRDB — fast, local, following the `linkToEvent` precedent. Autosaved as the user
  edits (debounced).

### Meeting chat

- New `MeetingChatViewModel` (`@MainActor @Observable`) mirroring `SituationChatViewModel`:
  `context_type = "meeting"`, `context_id = String(transcript.id)`.
- `loadOrCreateConversation()` via `ChatConversationQueries.fetchByContext` / `create`.
- System prompt built from `transcript_text` + parsed recap.
- New `MeetingDiscussSection` view mirroring `SituationDiscussSection` (collapsible
  messages + docked `MeetingDiscussInputBar`).
- No schema change — `context_type` is free-form TEXT; the `ensureContextColumns`
  one-time rewrite only touches `"action_item"→"track"`, so `"meeting"` is safe.

### Delete (Swift-only)

- `MeetingTranscriptQueries.delete(_:id:)` performs, in one GRDB transaction:
  1. Read the row (for `audio_path` and to resolve the chat conversation).
  2. Delete the chat conversation for `context_type="meeting"`, `context_id=id`
     (cascades its messages via `ChatConversationQueries.delete`).
  3. Delete the `meeting_transcripts` row.
- **After** the transaction commits, delete the audio file at `audio_path` via
  `FileManager` (best-effort; a missing/already-swept file is not an error).
- `meeting_recaps` for the linked event is **not** deleted.
- Triggered from the detail header via `.confirmationDialog`; on success the detail pane
  clears and the list reloads.

## File Scope (approximate)

**Go**
- `internal/db/migrations/00017_meeting_transcript_notes.sql`
- `internal/db/schema.sql` + regenerated golden snapshot
- `internal/db/meeting_transcripts.go` — `NotesMD` field, `SetMeetingTranscriptNotes`
- `cmd/meeting_transcript.go` — `notes <id>` subcommand
- `internal/meeting/` — notes generator (`GenerateTranscriptNotes`), reusing the
  provider/stdin plumbing of the recap path
- New prompt row `meeting.notes` (seed/migration per add-ai-prompt)

**Swift**
- `CalendarEventsView.swift` — segmented `События | Записи`; remove ad-hoc section
- `RecordingsListView.swift` (new) — master list using `RecordingListItem`
- `RecordingDetailView.swift` (new) — header + 4 tabs
- Tab subviews: recap, notes editor, transcript, chat (some reused/extracted from
  `MeetingNotesView` / `TranscriptSectionView`)
- `MeetingTranscript.swift` — `notesMD` field
- `MeetingTranscriptQueries.swift` — `RecordingListItem` projection + list query,
  `saveNotes`, `delete`
- `TranscriptSaveService.swift` — `generateNotes`
- `MeetingChatViewModel.swift` (new) + `MeetingDiscussSection.swift` (new)

**Docs**
- `CLAUDE.md` — Meeting Transcriber section (recordings tab, notes, delete)
- `docs/inventory/` — new guard contracts if any (e.g. delete scope, notes storage)
- `docs/app-guide.md` — UI change for the chat-bot system prompt

## Defaults (confirmed during brainstorming)

- Notes prompt: **strong** tier.
- Notes: free-form markdown document (title, participants, outcomes, decisions, next
  steps), publication style, neutral tone.
- Recap stays a plain structured render (not markdown).
- Delete scope: row + audio + meeting chat; recap left intact.
- Recordings tab lives inside Calendar (segmented control), not a new sidebar
  destination.

## Testing

- Go: notes generator + CLI `notes` subcommand (happy path + recap-style stdin
  threshold + AI-failure envelope). Migration golden snapshot. `TestAllTablesExist`
  unaffected (column add only).
- Swift: `RecordingListItem` projection excludes heavy columns; `delete` removes row +
  chat conversation and is a no-op-safe on a missing audio file (test the
  valid-but-degenerate "audio already swept, `audio_path` present but file gone" case);
  `saveNotes` round-trips; `MeetingChatViewModel` creates/loads the `"meeting"`
  conversation.
- Behavioral: opening a recording does not read `transcript_text` until the transcript
  tab is opened (perf guard).
