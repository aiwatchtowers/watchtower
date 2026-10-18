-- +goose Up
-- The agent analytics tables as watchtower.db's 00116 + 00125 left them,
-- without the foreign keys into watchtower.db (projects, terminal_sessions):
-- they cannot reach across files. agentlogdb resolves both columns in Go.

CREATE TABLE agent_log_files (
  path           TEXT PRIMARY KEY,
  agent          TEXT NOT NULL CHECK (agent IN ('claude')),
  size           INTEGER NOT NULL DEFAULT 0,
  mtime          TEXT NOT NULL DEFAULT '',
  read_offset    INTEGER NOT NULL DEFAULT 0,
  parser_version INTEGER NOT NULL DEFAULT 0,
  missing_at     TEXT,
  scanned_at     TEXT NOT NULL DEFAULT ''
);

CREATE TABLE agent_log_sessions (
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
CREATE INDEX idx_agent_log_sessions_project ON agent_log_sessions(project_id, started_at);

CREATE TABLE agent_log_events (
  id             INTEGER PRIMARY KEY,
  session_uuid   TEXT NOT NULL REFERENCES agent_log_sessions(session_uuid) ON DELETE CASCADE,
  key            TEXT NOT NULL UNIQUE,
  kind           TEXT NOT NULL CHECK (kind IN
                   ('api_call','owner_turn','tool','skill','compaction','api_error','pr_link')),
  ts             TEXT NOT NULL,
  uuid           TEXT NOT NULL DEFAULT '',
  parent_uuid    TEXT NOT NULL DEFAULT '',
  prompt_id      TEXT NOT NULL DEFAULT '',
  agent_id       TEXT NOT NULL DEFAULT '',
  is_sidechain   INTEGER NOT NULL DEFAULT 0,
  name           TEXT NOT NULL DEFAULT '',
  target         TEXT NOT NULL DEFAULT '',
  trigger        TEXT NOT NULL DEFAULT '',
  outcome        TEXT NOT NULL DEFAULT '' CHECK (outcome IN
                   ('','ok','error','denied','interrupted','pending')),
  error_class    TEXT NOT NULL DEFAULT '',
  duration_ms    INTEGER,
  skill          TEXT NOT NULL DEFAULT '',
  input_tokens          INTEGER NOT NULL DEFAULT 0,
  output_tokens         INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
  cache_write_5m_tokens INTEGER NOT NULL DEFAULT 0,
  cache_write_1h_tokens INTEGER NOT NULL DEFAULT 0,
  speed          TEXT NOT NULL DEFAULT '',
  service_tier   TEXT NOT NULL DEFAULT '',
  cost_usd       REAL NOT NULL DEFAULT 0,
  price_version  INTEGER NOT NULL DEFAULT 0,
  cost_estimated INTEGER NOT NULL DEFAULT 0,
  lines_added    INTEGER NOT NULL DEFAULT 0,
  lines_removed  INTEGER NOT NULL DEFAULT 0,
  src_path       TEXT NOT NULL,
  src_offset     INTEGER NOT NULL,
  spawned_agent_id TEXT NOT NULL DEFAULT '',
  background     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_agent_log_events_session ON agent_log_events(session_uuid, ts);
CREATE INDEX idx_agent_log_events_kind ON agent_log_events(kind, name);

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

-- moved_from_main: RFC 3339 UTC time the one-time move from watchtower.db completed.
CREATE TABLE agent_log_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- One row per workbench: whether its last scan finished its listing.
CREATE TABLE agent_log_import (
  project_id   INTEGER PRIMARY KEY,
  complete     INTEGER NOT NULL,
  files_stored INTEGER NOT NULL,
  updated_at   TEXT NOT NULL
);

-- +goose Down
DROP TABLE agent_log_import;
DROP TABLE agent_log_meta;
DROP VIEW agent_log_session_totals;
DROP TABLE agent_log_events;
DROP TABLE agent_log_sessions;
DROP TABLE agent_log_files;
