-- +goose Up
-- Workflow states and labels of the selected Linear teams, mirrored by the
-- sync so the chat and automations resolve names to ids without a live call.
CREATE TABLE IF NOT EXISTS linear_workflow_states (
    account_id INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    team_id    TEXT NOT NULL DEFAULT '',
    id         TEXT NOT NULL,
    name       TEXT NOT NULL DEFAULT '',
    type       TEXT NOT NULL DEFAULT '',
    position   REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_linear_states_team ON linear_workflow_states(account_id, team_id, position);

-- team_id '' = a workspace label (shared by every team).
CREATE TABLE IF NOT EXISTS linear_labels (
    account_id INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id         TEXT NOT NULL,
    team_id    TEXT NOT NULL DEFAULT '',
    name       TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_linear_labels_team ON linear_labels(account_id, team_id);

-- +goose Down
DROP INDEX IF EXISTS idx_linear_labels_team;
DROP TABLE IF EXISTS linear_labels;
DROP INDEX IF EXISTS idx_linear_states_team;
DROP TABLE IF EXISTS linear_workflow_states;
