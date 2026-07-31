-- +goose Up
-- Per-utterance transcript segments for a recording. NULL = legacy row (or a
-- save whose segments file was missing/malformed) — the flat transcript_text
-- stays the only representation. When non-NULL it is a JSON array of
-- RoleAssigner merge units: {"idx", "start_sec", "end_sec", "speaker",
-- "text", "deleted"}, and the load-bearing invariant holds:
-- transcript_text = render(segments where !deleted). One canonical renderer
-- per side keeps that true (Go internal/meeting.RenderTranscriptSegments for
-- CLI writes, Swift TranscriptSegments.render for UI edits — a deliberate
-- dual-path like notes_md). The column is heavy and must NEVER be selected by
-- the Desktop recordings list projection.
ALTER TABLE meeting_transcripts ADD COLUMN segments_json TEXT;

-- +goose Down
ALTER TABLE meeting_transcripts DROP COLUMN segments_json;
