-- +goose Up
-- Store.Seed's auto-upgrade compares only existing.Version < defaultVer, so a
-- prompt the tuner (or a user edit) bumped off the default lineage survives
-- exactly one later default-version bump before being silently overwritten
-- (digest.channel went 3->4->5 across releases this way). This column lets
-- the seeder tell "still on the default lineage" apart from "a human/tuner
-- touched this" so auto-upgrade can skip customized rows.
ALTER TABLE prompts ADD COLUMN customized INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE prompts DROP COLUMN customized;
