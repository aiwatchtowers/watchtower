-- +goose Up
-- Session placement (board #229, spec 2026-10-14-session-worktrees-design.md §7).
-- worktree_branch non-NULL = Watchtower created the worktree this row's
-- folder_path is in, on this wt/<slug> branch; #535's cleanup owns that
-- worktree and branch by record. NULL = every other row.
ALTER TABLE terminal_sessions ADD COLUMN worktree_branch TEXT;
-- The commit the branch was cut from; NULL with worktree_branch.
ALTER TABLE terminal_sessions ADD COLUMN worktree_base TEXT;
-- The command run in a new session worktree before the agent's first launch; '' = none.
ALTER TABLE projects ADD COLUMN worktree_setup TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE projects DROP COLUMN worktree_setup;
ALTER TABLE terminal_sessions DROP COLUMN worktree_base;
ALTER TABLE terminal_sessions DROP COLUMN worktree_branch;
