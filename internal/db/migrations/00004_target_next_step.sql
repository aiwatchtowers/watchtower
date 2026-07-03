-- +goose Up
-- AI-suggested "next step" for a target: a JSON suggestion blob plus the
-- timestamp it was generated at. next_step_at is compared against updated_at to
-- detect staleness (a user edit bumps updated_at past next_step_at), so the
-- generator must NOT touch updated_at when it writes these columns.
ALTER TABLE targets ADD COLUMN next_step TEXT NOT NULL DEFAULT '';
ALTER TABLE targets ADD COLUMN next_step_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE targets DROP COLUMN next_step_at;
ALTER TABLE targets DROP COLUMN next_step;
