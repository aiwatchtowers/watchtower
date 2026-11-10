-- +goose Up
-- Inbox builder A (AGENT-05): create_target creates at most one task per
-- action id, and an Inbox button has at most one open proposal. Duplicate
-- `action:<id>` sources (a --force retry after a dead apply had already
-- inserted) are renamed, never deleted: every one but the oldest gets
-- `:dup<row id>`, so the unique index builds on any database.
-- A later rebuild of targets or agent_actions must recreate both partial
-- unique indexes with exactly these WHERE clauses
-- (TestAgent05_ButtonIndexesPresent).
UPDATE targets SET source_id = source_id || ':dup' || id
WHERE source_type = 'chat' AND source_id LIKE 'action:%' AND source_id != 'action:0'
  AND id NOT IN (
    SELECT MIN(id) FROM targets
    WHERE source_type = 'chat' AND source_id LIKE 'action:%' AND source_id != 'action:0'
    GROUP BY source_id
  );
CREATE UNIQUE INDEX IF NOT EXISTS idx_targets_action_source ON targets(source_id) WHERE source_type = 'chat' AND source_id LIKE 'action:%' AND source_id != 'action:0';
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_actions_open_context ON agent_actions(context_type, context_id) WHERE context_type = 'automation_output' AND status IN ('pending','approved','executing');

-- +goose Down
DROP INDEX IF EXISTS idx_agent_actions_open_context;
DROP INDEX IF EXISTS idx_targets_action_source;
