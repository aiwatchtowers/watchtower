-- +goose Up
-- Private meeting recordings (docs/features/private-meetings.md, MEETPRIV-02):
-- flipping meeting_transcripts.private moves no knowledge-index cursor the
-- recap source can see, and the Desktop writes the flag directly. Mark the
-- recording's document and every recap it owns in kb_dirty, so the indexer
-- re-renders them on its next pass — a private one renders as nil and leaves
-- the index, one made public again comes back.
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS meeting_transcripts_private_kb_dirty AFTER UPDATE OF private ON meeting_transcripts
WHEN OLD.private != NEW.private
BEGIN
    INSERT INTO kb_dirty (source, key) VALUES ('transcript', 'transcript:' || NEW.id)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
    INSERT INTO kb_dirty (source, key) SELECT 'recap', 'recap:' || id FROM meeting_recaps WHERE transcript_id = NEW.id
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER IF EXISTS meeting_transcripts_private_kb_dirty;
