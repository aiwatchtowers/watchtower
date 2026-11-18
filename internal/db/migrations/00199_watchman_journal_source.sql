-- +goose NO TRANSACTION
-- +goose Up
-- Watchman phase 2 (Task 14): the journal source stores precedents of source
-- 'journal', so watchman_precedents' source CHECK gains it. SQLite cannot
-- change a CHECK in place: the table is rebuilt with every row, its id and
-- the learner's flags (00197), the index, and the FTS5 sync triggers (dropped
-- with the old table, re-created after the rename); the external-content FTS
-- index is rebuilt from the new table. One transaction as one goose statement
-- (see 00150); foreign keys are OFF around it, nothing references the table.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;
CREATE TABLE watchman_precedents_new (
    id           INTEGER PRIMARY KEY,
    workbench_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    source       TEXT NOT NULL CHECK (source IN ('ask','review','spec','permission','journal','turn','git')),
    source_key   TEXT NOT NULL,
    category     TEXT NOT NULL CHECK (category IN ('design','scope','ux_text','tests','review_code','review_doc','permission','finish')),
    situation    TEXT NOT NULL DEFAULT '',
    choice       TEXT NOT NULL DEFAULT '',
    owner_words  TEXT NOT NULL DEFAULT '',
    decided_at   TEXT NOT NULL,
    weight       REAL NOT NULL DEFAULT 1,
    is_decision  INTEGER,  -- §9.1: NULL = not flagged yet (a candidate), 0/1 set by the learner's relabel pass
    parked       INTEGER,  -- §9.1: NULL/0 = usable, 1 = parked out of the backtest
    flags_at     TEXT,     -- §9.1: when the relabel pass tried the row (even if both flags stayed NULL)
    UNIQUE (workbench_id, source, source_key)
);
INSERT INTO watchman_precedents_new (id, workbench_id, source, source_key, category, situation, choice, owner_words, decided_at, weight, is_decision, parked, flags_at)
    SELECT id, workbench_id, source, source_key, category, situation, choice, owner_words, decided_at, weight, is_decision, parked, flags_at FROM watchman_precedents;
DROP TABLE watchman_precedents;
ALTER TABLE watchman_precedents_new RENAME TO watchman_precedents;
CREATE INDEX IF NOT EXISTS idx_watchman_precedents_wb ON watchman_precedents(workbench_id, category, decided_at);
CREATE TRIGGER IF NOT EXISTS watchman_precedents_ai AFTER INSERT ON watchman_precedents BEGIN
    INSERT INTO watchman_fts(rowid, situation, choice, owner_words) VALUES (NEW.id, NEW.situation, NEW.choice, NEW.owner_words);
END;
CREATE TRIGGER IF NOT EXISTS watchman_precedents_ad AFTER DELETE ON watchman_precedents BEGIN
    INSERT INTO watchman_fts(watchman_fts, rowid, situation, choice, owner_words) VALUES ('delete', OLD.id, OLD.situation, OLD.choice, OLD.owner_words);
END;
CREATE TRIGGER IF NOT EXISTS watchman_precedents_au AFTER UPDATE ON watchman_precedents BEGIN
    INSERT INTO watchman_fts(watchman_fts, rowid, situation, choice, owner_words) VALUES ('delete', OLD.id, OLD.situation, OLD.choice, OLD.owner_words);
    INSERT INTO watchman_fts(rowid, situation, choice, owner_words) VALUES (NEW.id, NEW.situation, NEW.choice, NEW.owner_words);
END;
INSERT INTO watchman_fts(watchman_fts) VALUES ('rebuild');

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;
DELETE FROM watchman_precedents WHERE source = 'journal';
CREATE TABLE watchman_precedents_new (
    id           INTEGER PRIMARY KEY,
    workbench_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    source       TEXT NOT NULL CHECK (source IN ('ask','review','spec','permission','turn','git')),
    source_key   TEXT NOT NULL,
    category     TEXT NOT NULL CHECK (category IN ('design','scope','ux_text','tests','review_code','review_doc','permission','finish')),
    situation    TEXT NOT NULL DEFAULT '',
    choice       TEXT NOT NULL DEFAULT '',
    owner_words  TEXT NOT NULL DEFAULT '',
    decided_at   TEXT NOT NULL,
    weight       REAL NOT NULL DEFAULT 1,
    is_decision  INTEGER,  -- §9.1: NULL = not flagged yet (a candidate), 0/1 set by the learner's relabel pass
    parked       INTEGER,  -- §9.1: NULL/0 = usable, 1 = parked out of the backtest
    flags_at     TEXT,     -- §9.1: when the relabel pass tried the row (even if both flags stayed NULL)
    UNIQUE (workbench_id, source, source_key)
);
INSERT INTO watchman_precedents_new (id, workbench_id, source, source_key, category, situation, choice, owner_words, decided_at, weight, is_decision, parked, flags_at)
    SELECT id, workbench_id, source, source_key, category, situation, choice, owner_words, decided_at, weight, is_decision, parked, flags_at FROM watchman_precedents;
DROP TABLE watchman_precedents;
ALTER TABLE watchman_precedents_new RENAME TO watchman_precedents;
CREATE INDEX IF NOT EXISTS idx_watchman_precedents_wb ON watchman_precedents(workbench_id, category, decided_at);
CREATE TRIGGER IF NOT EXISTS watchman_precedents_ai AFTER INSERT ON watchman_precedents BEGIN
    INSERT INTO watchman_fts(rowid, situation, choice, owner_words) VALUES (NEW.id, NEW.situation, NEW.choice, NEW.owner_words);
END;
CREATE TRIGGER IF NOT EXISTS watchman_precedents_ad AFTER DELETE ON watchman_precedents BEGIN
    INSERT INTO watchman_fts(watchman_fts, rowid, situation, choice, owner_words) VALUES ('delete', OLD.id, OLD.situation, OLD.choice, OLD.owner_words);
END;
CREATE TRIGGER IF NOT EXISTS watchman_precedents_au AFTER UPDATE ON watchman_precedents BEGIN
    INSERT INTO watchman_fts(watchman_fts, rowid, situation, choice, owner_words) VALUES ('delete', OLD.id, OLD.situation, OLD.choice, OLD.owner_words);
    INSERT INTO watchman_fts(rowid, situation, choice, owner_words) VALUES (NEW.id, NEW.situation, NEW.choice, NEW.owner_words);
END;
INSERT INTO watchman_fts(watchman_fts) VALUES ('rebuild');

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;
