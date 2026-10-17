-- +goose Up
-- Data minimisation (board #597): the full Slack payload in messages.raw_json
-- was never read by anything, and the Slack API terms ask for the minimum
-- necessary retention. The column stays (NOT NULL DEFAULT '{}', no table
-- recreation) and is now always written empty; clear what is stored.
-- This UPDATE clears the payloads logically only: the old bytes stay on disk
-- in freed pages (and in the WAL until a checkpoint) until they are
-- overwritten or a later VACUUM. Physical scrubbing is a follow-up under
-- board #595 (encryption, #602/#603). One-time cost: a single UPDATE over all
-- rows holds the write lock for a few seconds on a large database at first
-- start.
UPDATE messages SET raw_json = '{}' WHERE raw_json != '{}';

-- +goose Down
-- No-op: the cleared payloads cannot come back.
SELECT 1;
