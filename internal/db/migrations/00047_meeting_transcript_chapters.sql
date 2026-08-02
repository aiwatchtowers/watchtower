-- +goose Up
-- AI-generated meeting chapters for a recording. NULL until the
-- meeting.chapters prompt has run (automatically after `transcript save` when
-- segments exist, or on demand via `watchtower meeting-prep transcript
-- chapters <id>`). When non-NULL it is a JSON object:
-- {"overall_summary": "...", "chapters": [{"title", "start_sec", "end_sec",
-- "participants", "summary", "decisions", "action_items", "open_questions"}]}
-- where each action item is {"text", "converted_target_id"} —
-- converted_target_id records the Target created from the item (a link, not a
-- delete, DASH-03 spirit; Swift writes it via
-- MeetingTranscriptQueries.setActionItemConverted). The column is heavy and
-- must NEVER be selected by the Desktop recordings list projection.
ALTER TABLE meeting_transcripts ADD COLUMN chapters_json TEXT;

-- +goose Down
ALTER TABLE meeting_transcripts DROP COLUMN chapters_json;
