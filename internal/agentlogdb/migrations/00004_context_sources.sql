-- +goose Up
-- The start weight of each source in a lane's context before its first API
-- call (agent_id '' = the main lane): a listed skill's or agent's own line, a
-- tool's definition, an MCP server's instruction block. Names and byte
-- counts only (AGENTLOG-01). A session parsed before parser v5 has no rows:
-- not measured, never 0.
CREATE TABLE agent_log_context_sources (
  session_uuid TEXT NOT NULL REFERENCES agent_log_sessions(session_uuid) ON DELETE CASCADE,
  agent_id     TEXT NOT NULL DEFAULT '',
  kind         TEXT NOT NULL CHECK (kind IN ('skill','agent','tool','mcp_instructions')),
  name         TEXT NOT NULL,
  bytes        INTEGER NOT NULL,
  PRIMARY KEY (session_uuid, agent_id, kind, name)
);

-- +goose Down
DROP TABLE agent_log_context_sources;
