-- +goose Up
-- Who put a document on the project (board item #79): 'agent' — Claude Code
-- attached or revised it (attach_document); 'import' — the mechanical scan at
-- project setup found it in the folder (`watchtower project import-docs`);
-- 'owner' — reserved for a Desktop "add document" action. The Desktop badge
-- counts only agent-revised documents, so an import never lights it up.
-- An agent re-attach of an imported document flips it to 'agent'.
ALTER TABLE project_documents ADD COLUMN origin TEXT NOT NULL DEFAULT 'agent'
    CHECK(origin IN ('agent','import','owner'));

-- +goose Down
ALTER TABLE project_documents DROP COLUMN origin;
