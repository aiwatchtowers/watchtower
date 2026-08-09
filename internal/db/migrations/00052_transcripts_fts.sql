-- +goose Up
-- Full-text index over meeting transcripts. Meetings are the highest-signal
-- material Watchtower holds and were the only source with no keyword search:
-- the dev surface's task dossier and decision archaeology both read it.
CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
    text,
    transcript_id UNINDEXED,
    title UNINDEXED,
    tokenize='porter unicode61'
);

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS meeting_transcripts_ai AFTER INSERT ON meeting_transcripts
WHEN NEW.transcript_text != ''
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = NEW.id;
    INSERT INTO transcripts_fts(text, transcript_id, title)
    VALUES (NEW.transcript_text, NEW.id, NEW.title);
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS meeting_transcripts_ad AFTER DELETE ON meeting_transcripts
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = OLD.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS meeting_transcripts_au AFTER UPDATE OF transcript_text, title ON meeting_transcripts
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = OLD.id;
    INSERT INTO transcripts_fts(text, transcript_id, title)
    SELECT NEW.transcript_text, NEW.id, NEW.title
    WHERE NEW.transcript_text != '';
END;
-- +goose StatementEnd

-- Backfill transcripts recorded before this index existed.
INSERT INTO transcripts_fts(text, transcript_id, title)
SELECT transcript_text, id, title FROM meeting_transcripts WHERE transcript_text != '';

-- +goose Down
DROP TRIGGER IF EXISTS meeting_transcripts_au;
DROP TRIGGER IF EXISTS meeting_transcripts_ad;
DROP TRIGGER IF EXISTS meeting_transcripts_ai;
DROP TABLE IF EXISTS transcripts_fts;
