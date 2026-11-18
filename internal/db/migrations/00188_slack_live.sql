-- +goose Up
-- Slack Live (#1709, plan A task 1): the probe's verdict per workspace and
-- provider, the first Live turn of a chat, and the Live flag of an automation run.
CREATE TABLE slack_live_status (
  team_id TEXT NOT NULL,            -- '' = workspace not identified
  provider TEXT NOT NULL CHECK (provider IN ('claude','codex')),
  status TEXT NOT NULL CHECK (status IN ('ok','not_connected','needs_admin','no_plan','unavailable')),
  error_class TEXT NOT NULL DEFAULT '',
  connector_id TEXT NOT NULL DEFAULT '',
  checked_at TEXT NOT NULL,
  PRIMARY KEY (team_id, provider)
);
ALTER TABLE chat_conversations ADD COLUMN live_slack_since INTEGER;
ALTER TABLE automation_runs ADD COLUMN live_slack INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE automation_runs DROP COLUMN live_slack;
ALTER TABLE chat_conversations DROP COLUMN live_slack_since;
DROP TABLE slack_live_status;
