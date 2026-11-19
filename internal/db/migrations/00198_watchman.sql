-- +goose Up
-- Watchman phase 1 (spec 2026-11-16): precedents mined from the owner's decisions, their FTS index, per-source cursors, the profile and backtests. Situation text is redacted and capped before storage.
CREATE TABLE IF NOT EXISTS watchman_workbenches (
    workbench_id       INTEGER PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    enabled_at         TEXT NOT NULL,
    estimated_decisions INTEGER NOT NULL DEFAULT 0,  -- taken at start; the learning progress's denominator
    unlabelled         INTEGER NOT NULL DEFAULT 0,   -- decisions seen but not placed in a category
    learned_through    TEXT                          -- set when every source reports done on its backfill
);

CREATE TABLE IF NOT EXISTS watchman_precedents (
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
    UNIQUE (workbench_id, source, source_key)
);
CREATE INDEX IF NOT EXISTS idx_watchman_precedents_wb ON watchman_precedents(workbench_id, category, decided_at);

CREATE VIRTUAL TABLE IF NOT EXISTS watchman_fts USING fts5(
    situation, choice, owner_words,
    content='watchman_precedents', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS watchman_precedents_ai AFTER INSERT ON watchman_precedents BEGIN
    INSERT INTO watchman_fts(rowid, situation, choice, owner_words) VALUES (NEW.id, NEW.situation, NEW.choice, NEW.owner_words);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS watchman_precedents_ad AFTER DELETE ON watchman_precedents BEGIN
    INSERT INTO watchman_fts(watchman_fts, rowid, situation, choice, owner_words) VALUES ('delete', OLD.id, OLD.situation, OLD.choice, OLD.owner_words);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS watchman_precedents_au AFTER UPDATE ON watchman_precedents BEGIN
    INSERT INTO watchman_fts(watchman_fts, rowid, situation, choice, owner_words) VALUES ('delete', OLD.id, OLD.situation, OLD.choice, OLD.owner_words);
    INSERT INTO watchman_fts(rowid, situation, choice, owner_words) VALUES (NEW.id, NEW.situation, NEW.choice, NEW.owner_words);
END;
-- +goose StatementEnd

CREATE TABLE IF NOT EXISTS watchman_cursors (
    workbench_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    source       TEXT NOT NULL,
    cursor       TEXT NOT NULL DEFAULT '',
    updated_at   TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (workbench_id, source)
);

CREATE TABLE IF NOT EXISTS watchman_profile (
    workbench_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    key          TEXT NOT NULL,                      -- a category or 'sleep_window'
    text         TEXT NOT NULL DEFAULT '',
    pinned       INTEGER NOT NULL DEFAULT 0,
    version      INTEGER NOT NULL DEFAULT 1,
    updated_at   TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (workbench_id, key)
);

CREATE TABLE IF NOT EXISTS watchman_backtests (
    id           INTEGER PRIMARY KEY,
    workbench_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    started_at   TEXT NOT NULL,
    finished_at  TEXT,
    status       TEXT NOT NULL CHECK (status IN ('running','done','failed')),
    error        TEXT NOT NULL DEFAULT '',
    verdict      TEXT NOT NULL DEFAULT '' CHECK (verdict IN ('','go','stop')),
    cost_usd     REAL NOT NULL DEFAULT 0,
    progress     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_watchman_backtests_wb ON watchman_backtests(workbench_id, id);

CREATE TABLE IF NOT EXISTS watchman_backtest_rows (
    backtest_id INTEGER NOT NULL REFERENCES watchman_backtests(id) ON DELETE CASCADE,
    category    TEXT NOT NULL,
    total       INTEGER NOT NULL DEFAULT 0,
    agree       INTEGER NOT NULL DEFAULT 0,
    wrong_high  INTEGER NOT NULL DEFAULT 0,
    cost_usd    REAL NOT NULL DEFAULT 0,
    baseline    REAL NOT NULL DEFAULT 0,  -- share of the most common owner choice among the hidden items
    status      TEXT NOT NULL CHECK (status IN ('strong','weak','not_measured')),
    PRIMARY KEY (backtest_id, category)
);

-- +goose Down
DROP TABLE IF EXISTS watchman_backtest_rows;
DROP TABLE IF EXISTS watchman_backtests;
DROP TABLE IF EXISTS watchman_profile;
DROP TABLE IF EXISTS watchman_cursors;
DROP TRIGGER IF EXISTS watchman_precedents_au;
DROP TRIGGER IF EXISTS watchman_precedents_ad;
DROP TRIGGER IF EXISTS watchman_precedents_ai;
DROP TABLE IF EXISTS watchman_fts;
DROP TABLE IF EXISTS watchman_precedents;
DROP TABLE IF EXISTS watchman_workbenches;
