-- +goose Up
-- Publishable meeting notes (markdown) for a recording. NULL = never
-- generated. Written by `watchtower meeting-prep transcript notes <id>` (AI)
-- and edited directly by the Desktop app (GRDB) — unlike summary_json, which
-- only the CLI writes.
ALTER TABLE meeting_transcripts ADD COLUMN notes_md TEXT;

-- +goose Down
ALTER TABLE meeting_transcripts DROP COLUMN notes_md;
