package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"sync/atomic"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitdir"
	"watchtower/internal/terminal"
)

// recordSessionLedger records, on the session of row rowID, the worktree
// root and branch the event's cwd resolves to (terminal_session_worktrees,
// board #535; spec 2026-10-12-session-cleanup §3.2) — for any agent of the
// session, the main one, a subagent or a teammate. Nothing for a cwd that is
// missing, invalid or outside a repository; a pair the session already holds,
// or a session already full, costs one read and no write. It runs after the
// event's state write, in its own transaction, so it never changes that
// write: a failure is one stderr line, and nothing reaches stdout (PROJ-11).
// The "session full" line is printed at most once per run (one hook process).
func recordSessionLedger(database *db.DB, stderr io.Writer, rowID, workbenchID int64, sessionID, cwd string, at time.Time) {
	if !terminal.IsSessionID(sessionID) {
		return // the state write already reported it
	}
	path := hookPath(cwd)
	if path == "" {
		return
	}
	root, branch, ok := sessionWorktreeAt(path)
	if !ok {
		return
	}
	err := writeSessionLedger(database, rowID, workbenchID, sessionID, root, branch, at)
	if errors.Is(err, errSessionLedgerFull) && sessionLedgerFullReported.Swap(true) {
		return
	}
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: session worktree not recorded: %v\n", err)
	}
}

// errSessionLedgerFull is a new pair past db.MaxSessionWorktrees.
var errSessionLedgerFull = fmt.Errorf("the session already records %d worktrees", db.MaxSessionWorktrees)

// sessionLedgerFullReported keeps the "session full" stderr line to one per
// run.
var sessionLedgerFullReported atomic.Bool

// writeSessionLedger is recordSessionLedger's database part: one read
// first, so the common cases — a pair already recorded, or a full session —
// never take the write lock; then the row's guards (the hook's conversation,
// workbench and kind); then the insert.
func writeSessionLedger(database *db.DB, rowID, workbenchID int64, sessionID, root, branch string, at time.Time) error {
	ctx := context.Background()
	has, full, err := database.HasSessionWorktree(ctx, rowID, root, branch)
	if err != nil || has {
		return err
	}
	if full {
		return errSessionLedgerFull
	}
	row, err := hookSessionRow(database, rowID, workbenchID, sessionID)
	if row == nil || err != nil {
		return err
	}
	if err := database.SetBusyTimeout(sessionRecordBusyTimeout); err != nil {
		return err
	}
	recorded, err := database.RecordSessionWorktree(ctx, nil, rowID, root, branch, db.AgentStateStamp(at))
	if err != nil || recorded {
		return err
	}
	// Not recorded: a racing hook inserted the pair, or filled the session.
	has, _, err = database.HasSessionWorktree(ctx, rowID, root, branch)
	if err != nil || has {
		return err
	}
	return errSessionLedgerFull
}

// sessionWorktreeAt resolves an absolute, cleaned dir to the work tree
// holding it and the branch that work tree's HEAD names. dir is first
// symlink-resolved (its nearest existing ancestor, when dir itself is gone),
// so a cwd reached through a symlink into a repository — even into one of
// its subdirectories — finds the repository's .git; the root is therefore
// symlink-resolved too, the form the cleanup compares against `git worktree
// list`. The branch is "" when unknown: a detached or unreadable HEAD, or a
// reftable repository (gitdir.HeadBranch); the pair is still recorded, with
// "" as its branch. It reads files only and never runs git (spec §3.2). ok
// is false outside any work tree and when the walk meets a ".git" it cannot
// use (gitdir.FindWorkTree fails closed).
func sessionWorktreeAt(dir string) (root, branch string, ok bool) {
	root, gitDir, found, err := gitdir.FindWorkTree(resolvedDir(dir))
	if err != nil || !found {
		return "", "", false
	}
	return root, gitdir.HeadBranch(gitDir), true
}

// resolvedDir is dir with symlinks resolved: the nearest existing ancestor
// is resolved and the missing rest appended. dir as is when nothing on its
// path resolves.
func resolvedDir(dir string) string {
	rest := ""
	for cur := dir; ; cur = filepath.Dir(cur) {
		if r, err := filepath.EvalSymlinks(cur); err == nil {
			return filepath.Join(r, rest)
		}
		if filepath.Dir(cur) == cur {
			return dir
		}
		rest = filepath.Join(filepath.Base(cur), rest)
	}
}
