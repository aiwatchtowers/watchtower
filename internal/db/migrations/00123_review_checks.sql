-- +goose Up
CREATE TABLE review_checks (
  round_id    INTEGER NOT NULL REFERENCES review_rounds(id) ON DELETE CASCADE,
  chapter_key TEXT NOT NULL,
  lens        TEXT NOT NULL,
  item_key    TEXT NOT NULL,
  state       TEXT NOT NULL CHECK (state IN ('checked','commented','done','partial','not_done')),
  updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (round_id, chapter_key, lens, item_key)
);

-- +goose Down
DROP TABLE review_checks;
