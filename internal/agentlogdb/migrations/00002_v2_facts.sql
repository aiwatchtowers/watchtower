-- +goose Up
-- Agent analytics v2 facts. Byte and token counts and enum classes only
-- (AGENTLOG-01): no transcript text in any column. NULL result_bytes / pre /
-- post mean "not measured" (rows from parser v2).

ALTER TABLE agent_log_events ADD COLUMN result_bytes INTEGER;
ALTER TABLE agent_log_events ADD COLUMN thinking_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE agent_log_events ADD COLUMN pre_tokens INTEGER;
ALTER TABLE agent_log_events ADD COLUMN post_tokens INTEGER;

-- The baseline parts of a lane's first API call (agent_id '' = the main lane).
CREATE TABLE agent_log_context_parts (
  session_uuid TEXT NOT NULL REFERENCES agent_log_sessions(session_uuid) ON DELETE CASCADE,
  agent_id     TEXT NOT NULL DEFAULT '',
  part         TEXT NOT NULL,
  bytes        INTEGER NOT NULL,
  PRIMARY KEY (session_uuid, agent_id, part)
);

-- The skills listed in the session's context and the bytes each one costs.
CREATE TABLE agent_log_skill_listing (
  session_uuid TEXT NOT NULL REFERENCES agent_log_sessions(session_uuid) ON DELETE CASCADE,
  skill        TEXT NOT NULL,
  bytes        INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (session_uuid, skill)
);

CREATE TABLE agent_log_subagents (
  session_uuid TEXT NOT NULL REFERENCES agent_log_sessions(session_uuid) ON DELETE CASCADE,
  agent_id     TEXT NOT NULL,
  agent_type   TEXT NOT NULL DEFAULT '',
  depth        INTEGER NOT NULL DEFAULT 1,
  finished     INTEGER,
  PRIMARY KEY (session_uuid, agent_id)
);

DROP VIEW agent_log_session_totals;
CREATE VIEW agent_log_session_totals AS
SELECT session_uuid,
  SUM(CASE WHEN kind = 'api_call' THEN 1 ELSE 0 END)   AS api_calls,
  SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
  SUM(cache_read_tokens) AS cache_read_tokens,
  SUM(cache_write_5m_tokens) AS cache_write_5m_tokens,
  SUM(cache_write_1h_tokens) AS cache_write_1h_tokens,
  SUM(cost_usd) AS cost_usd,
  SUM(cost_estimated) AS cost_estimated_calls,
  SUM(CASE WHEN kind = 'owner_turn' AND trigger NOT IN ('notification','hook','interrupt') THEN 1 ELSE 0 END) AS owner_turns,
  SUM(CASE WHEN kind = 'owner_turn' AND trigger = 'interrupt' THEN 1 ELSE 0 END) AS owner_interrupts,
  SUM(CASE WHEN kind = 'tool' THEN 1 ELSE 0 END)       AS tool_calls,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'error' THEN 1 ELSE 0 END)       AS tool_errors,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'denied' THEN 1 ELSE 0 END)      AS tool_denials,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'interrupted' THEN 1 ELSE 0 END) AS tool_interrupts,
  SUM(CASE WHEN kind = 'skill' THEN 1 ELSE 0 END)      AS skill_activations,
  SUM(CASE WHEN kind = 'compaction' THEN 1 ELSE 0 END) AS compactions,
  SUM(lines_added) AS lines_added, SUM(lines_removed) AS lines_removed
FROM agent_log_events GROUP BY session_uuid;

-- +goose Down
DROP VIEW agent_log_session_totals;
DROP TABLE agent_log_subagents;
DROP TABLE agent_log_skill_listing;
DROP TABLE agent_log_context_parts;
ALTER TABLE agent_log_events DROP COLUMN post_tokens;
ALTER TABLE agent_log_events DROP COLUMN pre_tokens;
ALTER TABLE agent_log_events DROP COLUMN thinking_tokens;
ALTER TABLE agent_log_events DROP COLUMN result_bytes;
CREATE VIEW agent_log_session_totals AS
SELECT session_uuid,
  SUM(CASE WHEN kind = 'api_call' THEN 1 ELSE 0 END)   AS api_calls,
  SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
  SUM(cache_read_tokens) AS cache_read_tokens,
  SUM(cache_write_5m_tokens) AS cache_write_5m_tokens,
  SUM(cache_write_1h_tokens) AS cache_write_1h_tokens,
  SUM(cost_usd) AS cost_usd,
  SUM(cost_estimated) AS cost_estimated_calls,
  SUM(CASE WHEN kind = 'owner_turn' AND trigger NOT IN ('notification','hook') THEN 1 ELSE 0 END) AS owner_turns,
  SUM(CASE WHEN kind = 'tool' THEN 1 ELSE 0 END)       AS tool_calls,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'error' THEN 1 ELSE 0 END)       AS tool_errors,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'denied' THEN 1 ELSE 0 END)      AS tool_denials,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'interrupted' THEN 1 ELSE 0 END) AS tool_interrupts,
  SUM(CASE WHEN kind = 'skill' THEN 1 ELSE 0 END)      AS skill_activations,
  SUM(CASE WHEN kind = 'compaction' THEN 1 ELSE 0 END) AS compactions,
  SUM(lines_added) AS lines_added, SUM(lines_removed) AS lines_removed
FROM agent_log_events GROUP BY session_uuid;
