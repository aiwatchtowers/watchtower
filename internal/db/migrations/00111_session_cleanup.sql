-- +goose Up
-- Session cleanup (board #535). Written by Go only; the Desktop reads
-- cleanup_result/cleanup_at for the session report and writes none of these.
--
-- terminal_session_worktrees: every (worktree root, branch) any agent of a
-- workbench session worked in, recorded by the session-state hook when the
-- pair is new for the session (at most 64 rows per session). root is the
-- worktree root (the dir holding .git), symlink-resolved and absolute;
-- branch is the short branch name at the time, '' = detached HEAD or
-- unreadable; first_at is in agent_state_at format.
CREATE TABLE terminal_session_worktrees (
    session_id INTEGER NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
    root       TEXT NOT NULL,
    branch     TEXT NOT NULL DEFAULT '',
    first_at   TEXT NOT NULL,
    PRIMARY KEY (session_id, root, branch)
);

-- cleanup_result: JSON of the last `workbench cleanup --apply` of the
-- session; NULL = never. cleanup_at: its time, agent_state_at format; NULL
-- with it.
ALTER TABLE terminal_sessions ADD COLUMN cleanup_result TEXT;
ALTER TABLE terminal_sessions ADD COLUMN cleanup_at TEXT;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN cleanup_at;
ALTER TABLE terminal_sessions DROP COLUMN cleanup_result;
DROP TABLE IF EXISTS terminal_session_worktrees;
