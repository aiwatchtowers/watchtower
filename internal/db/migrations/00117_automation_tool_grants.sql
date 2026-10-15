-- +goose Up
-- Automations P2 (design spec 2026-10-14 §6.4, §9.4): the owner's per-(automation,
-- tool) auto grant. Written only by `watchtower automations auto <id> <tool> on
-- --hash <sha>` (the Desktop's form); removed by `... off`. A grant applies only
-- while grant_hash equals both automations.approval_hash and the run's
-- automation_runs.recipe_hash; otherwise it is inactive and kept for display.
CREATE TABLE automation_tool_grants (
    automation_id INTEGER NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
    tool          TEXT NOT NULL,
    grant_hash    TEXT NOT NULL,                             -- approval_hash the owner granted
    granted_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    PRIMARY KEY (automation_id, tool)
);

-- +goose Down
DROP TABLE IF EXISTS automation_tool_grants;
