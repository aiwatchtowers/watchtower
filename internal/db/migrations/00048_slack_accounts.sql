-- +goose Up

-- 1. Account table.
CREATE TABLE IF NOT EXISTS slack_accounts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    team_id           TEXT NOT NULL DEFAULT '',
    team_name         TEXT NOT NULL DEFAULT '',
    team_domain       TEXT NOT NULL DEFAULT '',
    label             TEXT NOT NULL DEFAULT '',
    current_user_id   TEXT NOT NULL DEFAULT '',  -- namespaced, e.g. "1:U0123"
    status            TEXT NOT NULL DEFAULT 'ok',  -- ok | error | revoked | removed
    error             TEXT NOT NULL DEFAULT '',
    enabled           INTEGER NOT NULL DEFAULT 1,
    search_last_date  TEXT NOT NULL DEFAULT '',
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 2. Seed account #1 from the legacy workspace singleton whenever legacy
--    Slack data exists (token-only installs are seeded in Go by
--    ensureLegacySlackAccount — SQL can't see the config-embedded token).
INSERT INTO slack_accounts (team_id, team_name, team_domain, current_user_id, search_last_date)
SELECT COALESCE(id, ''), COALESCE(name, ''), COALESCE(domain, ''),
       CASE WHEN COALESCE(current_user_id, '') = '' THEN '' ELSE '1:' || current_user_id END,
       COALESCE(search_last_date, '')
FROM workspace
WHERE EXISTS (SELECT 1 FROM workspace WHERE COALESCE(current_user_id, '') != '' OR id != '');

-- 3. Namespace every existing Slack-derived id with the "1:" prefix
--    (all current data belongs to the single pre-migration account).
--    Empty-string sentinels stay empty; NULLs pass through '||' as NULL.
UPDATE channels SET id = '1:' || id WHERE id != '';
UPDATE channels SET dm_user_id = '1:' || dm_user_id WHERE dm_user_id IS NOT NULL AND dm_user_id != '';
UPDATE users SET id = '1:' || id WHERE id != '';
UPDATE messages SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE messages SET user_id = '1:' || user_id WHERE user_id != '';
-- messages.thread_ts is a raw Slack timestamp, not an id — intentionally untouched.
UPDATE reactions SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE reactions SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE files SET message_channel_id = '1:' || message_channel_id WHERE message_channel_id != '';
UPDATE sync_state SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE channel_settings SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE digests SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE digest_participants SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE user_analyses SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE tracks SET assignee_user_id = '1:' || assignee_user_id WHERE assignee_user_id != '';
UPDATE tracks SET ball_on = '1:' || ball_on WHERE ball_on != '';
UPDATE tracks SET owner_user_id = '1:' || owner_user_id WHERE owner_user_id != '';
UPDATE tracks SET requester_user_id = '1:' || requester_user_id WHERE requester_user_id != '';
UPDATE track_states SET ball_on = '1:' || ball_on WHERE ball_on != '';
UPDATE track_states SET owner_user_id = '1:' || owner_user_id WHERE owner_user_id != '';
UPDATE track_states SET requester_user_id = '1:' || requester_user_id WHERE requester_user_id != '';
UPDATE targets SET ball_on = '1:' || ball_on WHERE ball_on != '';
UPDATE pipeline_steps SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE memory_digest_shadow SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE inbox_items SET channel_id = '1:' || channel_id
  WHERE channel_id != '' AND channel_id NOT LIKE 'gmail:%' AND channel_id NOT LIKE 'imap:%';
UPDATE inbox_items SET sender_user_id = '1:' || sender_user_id
  WHERE sender_user_id != '' AND channel_id LIKE '1:%';
UPDATE inbox_learned_rules SET scope_key = 'channel:1:' || substr(scope_key, 9)
  WHERE scope_key LIKE 'channel:%' AND scope_key NOT LIKE 'channel:gmail:%' AND scope_key NOT LIKE 'channel:imap:%';
UPDATE inbox_learned_rules SET scope_key = 'sender:1:' || substr(scope_key, 8)
  WHERE scope_key LIKE 'sender:%';
UPDATE user_profile SET slack_user_id = '1:' || slack_user_id WHERE slack_user_id != '';
UPDATE user_profile SET manager = '1:' || manager WHERE manager != '';
UPDATE communication_guides SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE people_cards SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE briefings SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE day_plans SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE calendar_attendee_map SET slack_user_id = '1:' || slack_user_id WHERE slack_user_id != '';
UPDATE jira_user_map SET slack_user_id = '1:' || slack_user_id WHERE slack_user_id != '';
UPDATE jira_slack_links SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE memory_provenance SET channel_id = '1:' || channel_id
  WHERE channel_id != '' AND scheme = '';
UPDATE memory_provenance SET sender_id = '1:' || sender_id
  WHERE sender_id != '' AND scheme = '';

-- 4. Retire the workspace-singleton Slack fields (moved to slack_accounts).
--    id/name/domain/synced_at stay as a frozen legacy snapshot of account #1
--    — nothing reads them by key (every workspace read is `LIMIT 1`).
ALTER TABLE workspace DROP COLUMN current_user_id;
ALTER TABLE workspace DROP COLUMN search_last_date;

-- +goose Down
ALTER TABLE workspace ADD COLUMN current_user_id TEXT NOT NULL DEFAULT '';
ALTER TABLE workspace ADD COLUMN search_last_date TEXT NOT NULL DEFAULT '';
UPDATE workspace SET
    current_user_id = COALESCE((SELECT substr(current_user_id, 3) FROM slack_accounts WHERE id = 1), ''),
    search_last_date = COALESCE((SELECT search_last_date FROM slack_accounts WHERE id = 1), '');
UPDATE memory_provenance SET sender_id = substr(sender_id, 3) WHERE sender_id LIKE '1:%' AND scheme = '';
UPDATE memory_provenance SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%' AND scheme = '';
UPDATE jira_slack_links SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE jira_user_map SET slack_user_id = substr(slack_user_id, 3) WHERE slack_user_id LIKE '1:%';
UPDATE calendar_attendee_map SET slack_user_id = substr(slack_user_id, 3) WHERE slack_user_id LIKE '1:%';
UPDATE day_plans SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE briefings SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE people_cards SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE communication_guides SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE user_profile SET manager = substr(manager, 3) WHERE manager LIKE '1:%';
UPDATE user_profile SET slack_user_id = substr(slack_user_id, 3) WHERE slack_user_id LIKE '1:%';
UPDATE inbox_learned_rules SET scope_key = 'sender:' || substr(scope_key, 10) WHERE scope_key LIKE 'sender:1:%';
UPDATE inbox_learned_rules SET scope_key = 'channel:' || substr(scope_key, 11) WHERE scope_key LIKE 'channel:1:%';
UPDATE inbox_items SET sender_user_id = substr(sender_user_id, 3) WHERE sender_user_id LIKE '1:%';
UPDATE inbox_items SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE memory_digest_shadow SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE pipeline_steps SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE targets SET ball_on = substr(ball_on, 3) WHERE ball_on LIKE '1:%';
UPDATE track_states SET requester_user_id = substr(requester_user_id, 3) WHERE requester_user_id LIKE '1:%';
UPDATE track_states SET owner_user_id = substr(owner_user_id, 3) WHERE owner_user_id LIKE '1:%';
UPDATE track_states SET ball_on = substr(ball_on, 3) WHERE ball_on LIKE '1:%';
UPDATE tracks SET requester_user_id = substr(requester_user_id, 3) WHERE requester_user_id LIKE '1:%';
UPDATE tracks SET owner_user_id = substr(owner_user_id, 3) WHERE owner_user_id LIKE '1:%';
UPDATE tracks SET ball_on = substr(ball_on, 3) WHERE ball_on LIKE '1:%';
UPDATE tracks SET assignee_user_id = substr(assignee_user_id, 3) WHERE assignee_user_id LIKE '1:%';
UPDATE user_analyses SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE digest_participants SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE digests SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE channel_settings SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE sync_state SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE files SET message_channel_id = substr(message_channel_id, 3) WHERE message_channel_id LIKE '1:%';
UPDATE reactions SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE reactions SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE messages SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE messages SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE users SET id = substr(id, 3) WHERE id LIKE '1:%';
UPDATE channels SET dm_user_id = substr(dm_user_id, 3) WHERE dm_user_id LIKE '1:%';
UPDATE channels SET id = substr(id, 3) WHERE id LIKE '1:%';
DROP TABLE IF EXISTS slack_accounts;
