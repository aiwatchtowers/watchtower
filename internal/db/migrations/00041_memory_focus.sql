-- +goose Up
-- Memory focus salience (docs/superpowers/specs/2026-07-26-memory-focus-salience-design.md):
-- memory_focus_fingerprint is the hash of the last APPLIED parsed focus.md
-- directive set — runtime state like the extraction watermarks, MEM-02-exempt.
-- memory_focus_matches is the mechanically-matched node set (state 'now' or
-- 'cooled'), rewritten wholesale on every fingerprint change so
-- computeNodeImportance reads a node's focus with one SELECT instead of
-- threading sets through its ~17 call sites. Runtime state: rebuilt from
-- focus.md + the index, cleared and rewritten by the pipeline, no FK (a match
-- may outlive its node briefly between runs; reads join against live nodes).
ALTER TABLE workspace ADD COLUMN memory_focus_fingerprint TEXT NOT NULL DEFAULT '';
CREATE TABLE IF NOT EXISTS memory_focus_matches (
    node_id TEXT PRIMARY KEY,
    state   TEXT NOT NULL CHECK (state IN ('now','cooled'))
);

-- +goose Down
DROP TABLE IF EXISTS memory_focus_matches;
ALTER TABLE workspace DROP COLUMN memory_focus_fingerprint;
