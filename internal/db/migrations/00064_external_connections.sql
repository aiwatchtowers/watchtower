-- +goose Up
-- Owner-managed external MCP servers ("Quick Connections"). Read-only tools
-- surfaced in the chat on demand; nothing is synced. Secrets live in 0600
-- files (mcp_secret_<id>.json), never in this table.
CREATE TABLE IF NOT EXISTS external_connections (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL UNIQUE,
    kind       TEXT    NOT NULL DEFAULT 'stdio'
               CHECK(kind IN ('stdio','http')),
    command    TEXT    NOT NULL DEFAULT '',
    args_json  TEXT    NOT NULL DEFAULT '[]',
    url        TEXT    NOT NULL DEFAULT '',
    enabled    INTEGER NOT NULL DEFAULT 0,
    status     TEXT    NOT NULL DEFAULT 'ok',
    error      TEXT    NOT NULL DEFAULT '',
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- +goose Down
DROP TABLE IF EXISTS external_connections;
