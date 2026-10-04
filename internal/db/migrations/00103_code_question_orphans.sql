-- +goose Up
-- A workbench delete left its code questions behind (spec 2026-10-02 §9.4):
-- `chat_conversations` rows of context type `code_question` whose
-- `context_id` (`<workbench id>:<path>:<line>`) names a workbench that no
-- longer exists. They quote the deleted folder's code and no surface lists
-- them any more, so they go; their messages, steps and search rows follow by
-- cascade and the FTS triggers. `db.DeleteWorkbench` removes them with the
-- workbench from now on (PROJ-02). Workbench ids are never reused
-- (AUTOINCREMENT, 00081), so a missing id is a deleted workbench.
DELETE FROM chat_conversations
WHERE context_type = 'code_question'
  AND instr(context_id, ':') > 1
  AND CAST(substr(context_id, 1, instr(context_id, ':') - 1) AS INTEGER) NOT IN (SELECT id FROM projects);

-- +goose Down
-- Deleted rows cannot come back; nothing to undo.
