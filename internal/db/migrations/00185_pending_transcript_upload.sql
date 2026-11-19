-- +goose Up
-- The Go hub's phone recording an ingest reserved (go hub plan 3 Task 17):
-- the upload id the Desktop's recording queue claimed, written with the
-- reservation in the same row, so a Desktop that crashed between the
-- reservation and remembering the upload finds the recording again by its
-- upload id instead of ingesting (and transcribing) it a second time. An id
-- only; Desktop is the only writer, Go never reads it.
ALTER TABLE pending_transcripts ADD COLUMN upload_id TEXT;

-- +goose Down
ALTER TABLE pending_transcripts DROP COLUMN upload_id;
