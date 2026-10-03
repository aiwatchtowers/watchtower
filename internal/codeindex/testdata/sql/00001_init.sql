-- +goose Up
-- +goose StatementBegin

-- Stores hold entries by key.
CREATE TABLE IF NOT EXISTS stores (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE entries (
    store_id INTEGER NOT NULL REFERENCES stores(id),
    key TEXT NOT NULL,
    value TEXT
);

CREATE UNIQUE INDEX idx_entries_key ON entries(store_id, key);

-- The stores with at least one entry.
CREATE VIEW busy_stores AS
SELECT s.id, s.name FROM stores s
WHERE EXISTS (SELECT 1 FROM entries e WHERE e.store_id = s.id);

CREATE TRIGGER entries_touch AFTER INSERT ON entries
BEGIN
    UPDATE stores SET name = name WHERE id = NEW.store_id;
END;

-- Audit rows, one per change.
CREATE TABLE audit (
    entry_id INTEGER,
    changed_at TEXT
);

CREATE TRIGGER audit_touch AFTER INSERT ON audit FOR EACH ROW EXECUTE FUNCTION touch_audit();

-- How a store feels.
CREATE TYPE mood AS ENUM ('calm', 'busy');

-- Adds one to a number.
CREATE FUNCTION add_one(x integer) RETURNS integer AS $$ SELECT x + 1 $$ LANGUAGE sql;

CREATE MATERIALIZED VIEW store_names AS SELECT name FROM stores;

INSERT INTO stores (name) VALUES ('default');
-- +goose StatementEnd

-- +goose Down
DROP TABLE entries;
DROP TABLE stores;
