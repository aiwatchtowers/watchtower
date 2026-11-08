-- +goose NO TRANSACTION
-- +goose Up
-- Codex rollouts join agent analytics (ask #507, decision D; AGENTLOG-04
-- amended): agent_log_files.agent and agent_log_sessions.agent accept
-- 'codex' beside 'claude'.
--
-- SQLite cannot change a CHECK in place, so both tables are rebuilt with
-- every row. agent_log_sessions is the parent of ON DELETE CASCADE children
-- (events, context parts, skill listing, subagents), so foreign keys are OFF
-- around the dance: the DROPs must fire no cascade. The totals view reads
-- agent_log_events only but is dropped and recreated verbatim (00002) so no
-- rename re-parses it half-way. The pragma cannot change inside a
-- transaction, so it stays outside the explicit BEGIN … COMMIT that makes the
-- rebuild one unit; the transaction is one goose statement because the
-- driver discards a connection left inside a transaction between execs.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

DROP VIEW agent_log_session_totals;

CREATE TABLE agent_log_files_new (
  path           TEXT PRIMARY KEY,
  agent          TEXT NOT NULL CHECK (agent IN ('claude','codex')),
  size           INTEGER NOT NULL DEFAULT 0,
  mtime          TEXT NOT NULL DEFAULT '',
  read_offset    INTEGER NOT NULL DEFAULT 0,
  parser_version INTEGER NOT NULL DEFAULT 0,
  missing_at     TEXT,
  scanned_at     TEXT NOT NULL DEFAULT ''
);
INSERT INTO agent_log_files_new (path, agent, size, mtime, read_offset, parser_version, missing_at, scanned_at)
  SELECT path, agent, size, mtime, read_offset, parser_version, missing_at, scanned_at FROM agent_log_files;
DROP TABLE agent_log_files;
ALTER TABLE agent_log_files_new RENAME TO agent_log_files;

CREATE TABLE agent_log_sessions_new (
  session_uuid        TEXT PRIMARY KEY,
  agent               TEXT NOT NULL CHECK (agent IN ('claude','codex')),
  project_id          INTEGER,
  folder_path         TEXT NOT NULL,
  home_cwd            TEXT NOT NULL,
  terminal_session_id INTEGER,
  source_path         TEXT NOT NULL,
  git_branch          TEXT NOT NULL DEFAULT '',
  model               TEXT NOT NULL DEFAULT '',
  started_at          TEXT NOT NULL,
  ended_at            TEXT NOT NULL,
  reported_cost_usd   REAL
);
INSERT INTO agent_log_sessions_new (session_uuid, agent, project_id, folder_path, home_cwd, terminal_session_id,
    source_path, git_branch, model, started_at, ended_at, reported_cost_usd)
  SELECT session_uuid, agent, project_id, folder_path, home_cwd, terminal_session_id,
    source_path, git_branch, model, started_at, ended_at, reported_cost_usd FROM agent_log_sessions;
DROP TABLE agent_log_sessions;
ALTER TABLE agent_log_sessions_new RENAME TO agent_log_sessions;
CREATE INDEX idx_agent_log_sessions_project ON agent_log_sessions(project_id, started_at);

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

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;

-- +goose Down
-- Codex rows cannot satisfy the old CHECK: they are dropped (with their
-- events through the cascade, foreign keys on) before the rebuild back.
DELETE FROM agent_log_sessions WHERE agent = 'codex';
DELETE FROM agent_log_files WHERE agent = 'codex';
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

DROP VIEW agent_log_session_totals;

CREATE TABLE agent_log_files_old (
  path           TEXT PRIMARY KEY,
  agent          TEXT NOT NULL CHECK (agent IN ('claude')),
  size           INTEGER NOT NULL DEFAULT 0,
  mtime          TEXT NOT NULL DEFAULT '',
  read_offset    INTEGER NOT NULL DEFAULT 0,
  parser_version INTEGER NOT NULL DEFAULT 0,
  missing_at     TEXT,
  scanned_at     TEXT NOT NULL DEFAULT ''
);
INSERT INTO agent_log_files_old (path, agent, size, mtime, read_offset, parser_version, missing_at, scanned_at)
  SELECT path, agent, size, mtime, read_offset, parser_version, missing_at, scanned_at FROM agent_log_files;
DROP TABLE agent_log_files;
ALTER TABLE agent_log_files_old RENAME TO agent_log_files;

CREATE TABLE agent_log_sessions_old (
  session_uuid        TEXT PRIMARY KEY,
  agent               TEXT NOT NULL CHECK (agent IN ('claude')),
  project_id          INTEGER,
  folder_path         TEXT NOT NULL,
  home_cwd            TEXT NOT NULL,
  terminal_session_id INTEGER,
  source_path         TEXT NOT NULL,
  git_branch          TEXT NOT NULL DEFAULT '',
  model               TEXT NOT NULL DEFAULT '',
  started_at          TEXT NOT NULL,
  ended_at            TEXT NOT NULL,
  reported_cost_usd   REAL
);
INSERT INTO agent_log_sessions_old (session_uuid, agent, project_id, folder_path, home_cwd, terminal_session_id,
    source_path, git_branch, model, started_at, ended_at, reported_cost_usd)
  SELECT session_uuid, agent, project_id, folder_path, home_cwd, terminal_session_id,
    source_path, git_branch, model, started_at, ended_at, reported_cost_usd FROM agent_log_sessions;
DROP TABLE agent_log_sessions;
ALTER TABLE agent_log_sessions_old RENAME TO agent_log_sessions;
CREATE INDEX idx_agent_log_sessions_project ON agent_log_sessions(project_id, started_at);

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

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;
