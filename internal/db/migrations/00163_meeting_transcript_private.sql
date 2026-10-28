-- +goose Up
-- Private meeting recordings (docs/features/private-meetings.md): a private
-- recording's content never reaches an AI provider. No recap, chapters, notes,
-- follow-up or meeting chat is generated for it, and every reader that feeds a
-- prompt (knowledge index, transcript search and tools, ideas, catch-up,
-- memory, automation reads) skips it. Export stays available: it is local.
ALTER TABLE meeting_transcripts ADD COLUMN private INTEGER NOT NULL DEFAULT 0 CHECK (private IN (0, 1));
-- The Desktop recorder's not-yet-saved recording keeps the flag too, so a
-- recording recovered after a crash still saves private.
ALTER TABLE pending_transcripts ADD COLUMN private INTEGER NOT NULL DEFAULT 0 CHECK (private IN (0, 1));

-- +goose Down
ALTER TABLE pending_transcripts DROP COLUMN private;
ALTER TABLE meeting_transcripts DROP COLUMN private;
