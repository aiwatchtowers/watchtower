-- +goose Up
ALTER TABLE agent_log_events ADD COLUMN spawned_agent_id TEXT NOT NULL DEFAULT '';
ALTER TABLE agent_log_events ADD COLUMN background INTEGER NOT NULL DEFAULT 0;

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
  SUM(CASE WHEN kind = 'owner_turn' AND trigger NOT IN ('notification','hook') THEN 1 ELSE 0 END) AS owner_turns,
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
CREATE VIEW agent_log_session_totals AS
SELECT session_uuid,
  SUM(CASE WHEN kind = 'api_call' THEN 1 ELSE 0 END)   AS api_calls,
  SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
  SUM(cache_read_tokens) AS cache_read_tokens,
  SUM(cache_write_5m_tokens) AS cache_write_5m_tokens,
  SUM(cache_write_1h_tokens) AS cache_write_1h_tokens,
  SUM(cost_usd) AS cost_usd,
  SUM(cost_estimated) AS cost_estimated_calls,
  SUM(CASE WHEN kind = 'owner_turn' THEN 1 ELSE 0 END) AS owner_turns,
  SUM(CASE WHEN kind = 'tool' THEN 1 ELSE 0 END)       AS tool_calls,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'error' THEN 1 ELSE 0 END)       AS tool_errors,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'denied' THEN 1 ELSE 0 END)      AS tool_denials,
  SUM(CASE WHEN kind = 'tool' AND outcome = 'interrupted' THEN 1 ELSE 0 END) AS tool_interrupts,
  SUM(CASE WHEN kind = 'skill' THEN 1 ELSE 0 END)      AS skill_activations,
  SUM(CASE WHEN kind = 'compaction' THEN 1 ELSE 0 END) AS compactions,
  SUM(lines_added) AS lines_added, SUM(lines_removed) AS lines_removed
FROM agent_log_events GROUP BY session_uuid;
ALTER TABLE agent_log_events DROP COLUMN background;
ALTER TABLE agent_log_events DROP COLUMN spawned_agent_id;
