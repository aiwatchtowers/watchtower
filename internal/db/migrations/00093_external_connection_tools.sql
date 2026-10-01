-- +goose Up
-- QC-02 per-tool allowlist, one row per Quick Connection that has a tool
-- list or an owner allow list (no row = never listed and no allow list: the
-- chat allows none of its tools, fail closed). tools_json caches the server's
-- tools/list, one {"name","read_only_hint","annotated"} object per tool;
-- listed_at is when it was taken ('' = never). allow_json is the owner's
-- explicit allow list of tool names (NULL = the default policy: only tools
-- known to be read-only, see internal/externalmcp/toolpolicy.go).
-- list_failed_at is the last failed listing ('' = none since the last
-- success): a chat launch does not retry it for an hour.
CREATE TABLE IF NOT EXISTS external_connection_tools (
    connection_id INTEGER PRIMARY KEY REFERENCES external_connections(id) ON DELETE CASCADE,
    tools_json    TEXT NOT NULL DEFAULT '',
    listed_at     TEXT NOT NULL DEFAULT '',
    allow_json    TEXT,
    list_failed_at TEXT NOT NULL DEFAULT ''
);

-- +goose Down
DROP TABLE IF EXISTS external_connection_tools;
