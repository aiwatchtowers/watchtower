-- +goose Up
-- Desktop's progress of a claimed phone recording (Go hub plan 3 Task 5,
-- spec §8 p. 4a): the phase the transcriber is in and, while it transcribes,
-- its percent, so the recording_job slice shows what the Swift hub showed.
-- A fixed vocabulary and a counter only: no file name (ask #843), no text.
ALTER TABLE recording_jobs ADD COLUMN phase TEXT CHECK (phase IN ('transcribing', 'diarizing', 'summarizing'));
ALTER TABLE recording_jobs ADD COLUMN percent INTEGER CHECK (percent BETWEEN 0 AND 100);

-- +goose Down
ALTER TABLE recording_jobs DROP COLUMN percent;
ALTER TABLE recording_jobs DROP COLUMN phase;
