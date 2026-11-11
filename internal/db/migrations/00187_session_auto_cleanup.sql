-- +goose Up
-- Board #1716: every Desktop session delete cleans up in the background.
-- delete_requested_at marks a row whose delete the owner confirmed and whose
-- cleanup has not finished (the Desktop is its only writer; NULL = not
-- deleting). The ledger gains the rows the session-state hook parses out of
-- the agents' git commands: source 'cwd' (the rows recorded so far) or
-- 'command', and kind 'worktree' (a root with its branch) or 'branch' (a
-- branch-only row whose root is the repository's top level).
ALTER TABLE terminal_sessions ADD COLUMN delete_requested_at TEXT;
ALTER TABLE terminal_session_worktrees ADD COLUMN source TEXT NOT NULL DEFAULT 'cwd' CHECK (source IN ('cwd','command'));
ALTER TABLE terminal_session_worktrees ADD COLUMN kind TEXT NOT NULL DEFAULT 'worktree' CHECK (kind IN ('worktree','branch'));

-- +goose Down
ALTER TABLE terminal_session_worktrees DROP COLUMN kind;
ALTER TABLE terminal_session_worktrees DROP COLUMN source;
ALTER TABLE terminal_sessions DROP COLUMN delete_requested_at;
