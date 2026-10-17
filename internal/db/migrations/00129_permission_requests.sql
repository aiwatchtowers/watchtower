-- +goose Up
CREATE TABLE permission_requests (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  terminal_session_id INTEGER NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
  workbench_id        INTEGER NOT NULL,
  tool_name           TEXT NOT NULL DEFAULT '',
  summary             TEXT NOT NULL DEFAULT '',
  status              TEXT NOT NULL CHECK (status IN ('pending','allowed','denied','answered_on_mac','expired')),
  created_at          TEXT NOT NULL,
  decided_at          TEXT,
  decided_by          TEXT
);
CREATE INDEX idx_permission_requests_session ON permission_requests(terminal_session_id, status);

-- +goose Down
DROP INDEX idx_permission_requests_session;
DROP TABLE permission_requests;
