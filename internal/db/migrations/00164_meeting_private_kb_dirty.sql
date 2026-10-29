-- +goose Up
-- Private meeting recordings (docs/features/private-meetings.md, MEETPRIV-02):
-- flipping meeting_transcripts.private moves no knowledge-index cursor the
-- recap source can see, and the Desktop writes the flag directly. Mark the
-- recording's document, every recap it owns and every artifact kept from its
-- meeting chat (context_type 'meeting', context_id = the recording id) in
-- kb_dirty, so the indexer re-renders them on its next pass — a private one
-- renders as nil and leaves the index, one made public again comes back.
--
-- Deleting a private recording deletes the recaps it owns: the foreign key
-- would otherwise null their transcript_id (ON DELETE SET NULL), and a recap
-- with no recording — source_text = the full transcript — is one every
-- MEETPRIV-02 reader serves. A public recording's recap still outlives it.
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS meeting_transcripts_private_kb_dirty AFTER UPDATE OF private ON meeting_transcripts
WHEN OLD.private != NEW.private
BEGIN
    INSERT INTO kb_dirty (source, key) VALUES ('transcript', 'transcript:' || NEW.id)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
    INSERT INTO kb_dirty (source, key) SELECT 'recap', 'recap:' || id FROM meeting_recaps WHERE transcript_id = NEW.id
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
    INSERT INTO kb_dirty (source, key)
        SELECT 'chat_artifact', 'chat_artifact:' || k.conversation_id || ':' || k.artifact_key
        FROM chat_knowledge_artifacts k JOIN chat_conversations c ON c.id = k.conversation_id
        WHERE c.context_type = 'meeting' AND c.context_id = CAST(NEW.id AS TEXT)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS meeting_transcripts_private_delete_recaps BEFORE DELETE ON meeting_transcripts
WHEN OLD.private = 1
BEGIN
    DELETE FROM meeting_recaps WHERE transcript_id = OLD.id;
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER IF EXISTS meeting_transcripts_private_delete_recaps;
DROP TRIGGER IF EXISTS meeting_transcripts_private_kb_dirty;
