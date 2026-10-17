-- +goose Up
-- Data minimisation (board #597): the full Slack payload in messages.raw_json
-- was never read by anything, and the Slack API terms ask for the minimum
-- necessary retention. The column stays (NOT NULL DEFAULT '{}', no table
-- recreation) and is now always written empty; clear what is stored. No
-- VACUUM here: the freed pages are reused by the file.
UPDATE messages SET raw_json = '{}' WHERE raw_json != '{}';

-- +goose Down
-- No-op: the cleared payloads cannot come back.
SELECT 1;
