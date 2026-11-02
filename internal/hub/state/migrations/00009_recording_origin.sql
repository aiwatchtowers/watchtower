-- +goose Up
-- Where a phone recording came from (Go hub plan 3 Task 17): the calendar
-- event the phone recorded it for (an opaque calendar id, as the Mac's own
-- calendar_events.id) and when it started, so Desktop saves the transcript
-- against the event and gives it the phone's title from the Mac's calendar
-- (the event's title, or "Voice note — <start>"), as the Swift hub did with
-- the upload's title_hint. Ids and a time only: the title itself is content
-- and is never stored (ask #843: no file name, no text).
ALTER TABLE recording_jobs ADD COLUMN event_id TEXT;
ALTER TABLE recording_jobs ADD COLUMN started_at REAL;

-- +goose Down
ALTER TABLE recording_jobs DROP COLUMN started_at;
ALTER TABLE recording_jobs DROP COLUMN event_id;
