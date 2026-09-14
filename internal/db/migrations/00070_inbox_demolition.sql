-- +goose Up
-- Inbox demolition (docs/superpowers/specs/2026-09-14-inbox-demolition-design.md):
-- the situations composer, situation cards, per-item feedback and the
-- dashboard feed publisher are removed. Situations are frozen as read-only
-- history; the tables only the dead Dashboard read are dropped; the retired
-- AI prompts are deregistered (the 00012 precedent).

-- No writer remains, so an "open" situation is a lie: freeze them as stale.
UPDATE situations SET status = 'stale', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE status = 'open';

-- decision_made trigger items were rendered only by the Dashboard.
UPDATE inbox_items SET status = 'resolved', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE trigger_type = 'decision_made' AND status = 'pending';

DROP TABLE IF EXISTS inbox_feedback;
DROP TABLE IF EXISTS feed_items;
DROP TABLE IF EXISTS feed_state;

DELETE FROM prompts WHERE id IN ('inbox.triage', 'inbox.compose', 'inbox.situation_card', 'inbox.situation_learn');

-- +goose Down
-- Irreversible by design: the dropped tables held derived/empty data and the
-- prompts re-seed from defaults on downgrade builds.
