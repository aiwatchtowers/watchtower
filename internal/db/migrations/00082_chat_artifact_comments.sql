-- +goose Up
-- Owner comments on AI Chat artifacts (projects POC phase 6). A comment is
-- anchored on the rendered text of one (conversation, artifact key) and
-- follows the key across versions: every newer version re-anchors it
-- (artifact_version = the version it was last found on), and a quote that is
-- gone makes it 'outdated'. 'open' = written, not sent yet; 'sent' = went out
-- in an owner chat message. The Desktop is the only writer (the chat-tables
-- precedent). The assistant never reads this table: it learns about comments
-- only from the owner's own message ("Send N comments").
CREATE TABLE chat_artifact_comments (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id  INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    artifact_key     TEXT NOT NULL,
    artifact_version INTEGER NOT NULL,
    body             TEXT NOT NULL,
    anchor_quote     TEXT NOT NULL,
    anchor_prefix    TEXT NOT NULL DEFAULT '',
    anchor_suffix    TEXT NOT NULL DEFAULT '',
    anchor_heading   TEXT NOT NULL DEFAULT '',
    status           TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','sent','resolved','outdated')),
    created_at       REAL NOT NULL,
    sent_at          REAL,
    CHECK (anchor_quote != '' AND body != ''),
    CHECK (status != 'sent' OR sent_at IS NOT NULL)
);
CREATE INDEX idx_chat_artifact_comments_key ON chat_artifact_comments(conversation_id, artifact_key);

-- +goose Down
DROP INDEX IF EXISTS idx_chat_artifact_comments_key;
DROP TABLE IF EXISTS chat_artifact_comments;
