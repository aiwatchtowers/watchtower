package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitcmdparse"
	"watchtower/internal/gitdir"
	"watchtower/internal/terminal"
)

// recordSessionLedger records, on the session of row rowID, the worktree
// root and branch the event's cwd resolves to (terminal_session_worktrees,
// board #535; spec 2026-10-12-session-cleanup §3.2) — for any agent of the
// session, the main one, a subagent or a teammate. Nothing for a cwd that is
// missing, invalid or outside a repository; a pair the session already holds
// and has seen in this run, or a session already full, costs one read and no
// write (a pair last seen in an earlier run has its last sighting moved to
// this run, board #1018; concurrent hooks may both write it).
// It runs after the event's state write, in its own transaction, so it never
// changes that write: a failure is one stderr line, and nothing reaches
// stdout (PROJ-11). The "session full" line is printed at most once per run
// (one hook process).
// Its write waits for the lock as the event's state write did (lock: the
// async hook's budget, board #988).
func recordSessionLedger(database *db.DB, stderr io.Writer, rowID, workbenchID int64, sessionID, cwd string, at time.Time,
	lock hookLockWait) {
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
	err := writeSessionLedger(database, rowID, workbenchID, sessionID, root, branch, at, lock)
	if errors.Is(err, errSessionLedgerFull) && sessionLedgerFullReported.Swap(true) {
		return
	}
	var touch sightingNotMoved
	switch {
	case errors.As(err, &touch):
		fmt.Fprintf(stderr, "watchtower: session worktree sighting not moved: %v\n", touch.err)
	case err != nil:
		fmt.Fprintf(stderr, "watchtower: session worktree not recorded: %v\n", err)
	}
}

// sightingNotMoved is a failed move of a recorded pair's last sighting
// (board #1018): the pair is recorded, so it has its own stderr label.
type sightingNotMoved struct{ err error }

func (e sightingNotMoved) Error() string { return "sighting not moved: " + e.err.Error() }
func (e sightingNotMoved) Unwrap() error { return e.err }

// errSessionLedgerFull is a new pair past db.MaxSessionWorktrees.
var errSessionLedgerFull = fmt.Errorf("the session already records %d worktrees", db.MaxSessionWorktrees)

// sessionLedgerFullReported keeps the "session full" stderr line to one per
// run.
var sessionLedgerFullReported atomic.Bool

// writeSessionLedger is recordSessionLedger's database part: one read
// first, so the common cases — a pair already seen in this run, or a full
// session — never take the write lock; then the row's guards (the hook's
// conversation, workbench and kind); then the insert, or for a pair last
// seen before the session's run mark the move of its last sighting to this
// event (board #1018: a lane worktree a later run reuses is this run's).
func writeSessionLedger(database *db.DB, rowID, workbenchID int64, sessionID, root, branch string, at time.Time,
	lock hookLockWait) error {
	ctx := context.Background()
	has, stale, full, err := database.HasSessionWorktree(ctx, rowID, root, branch)
	if err != nil || (has && !stale) {
		return err
	}
	if !has && full {
		return errSessionLedgerFull
	}
	row, err := hookSessionRow(database, rowID, workbenchID, sessionID)
	if row == nil || err != nil {
		return err
	}
	stamp := db.AgentStateStamp(at)
	if has {
		if err := lock.write(database, func() error {
			_, err := database.TouchSessionWorktree(ctx, rowID, root, branch, stamp)
			return err
		}); err != nil {
			return sightingNotMoved{err}
		}
		return nil
	}
	var recorded bool
	err = lock.write(database, func() error {
		var err error
		recorded, err = database.RecordSessionWorktree(ctx, nil, rowID, root, branch, stamp)
		return err
	})
	if err != nil || recorded {
		return err
	}
	// Not recorded: a racing hook inserted the pair, or filled the session.
	has, _, _, err = database.HasSessionWorktree(ctx, rowID, root, branch)
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

// recordCommandLedger records, on the session of row rowID, the worktrees
// and branches a successful Bash call of the event asked git to create
// (board #1716, spec 2026-11-10-auto-cleanup §2a) as source='command' rows —
// for any agent of the session: a subagent's PostToolUse reaches the hook
// like the main agent's. Claude Code sends a failed call as
// PostToolUseFailure, which records nothing; Codex names its shell tool Bash
// and has no failure event, so its worktrees rest on the stat below alone.
// The command text is parsed (gitcmdparse) and a worktree kept only when
// <path>/.git is a regular file after the call; git is never run. Like
// recordSessionLedger it runs after the event's state write and never
// changes it: a failure is one stderr line, and the "session full" line is
// printed at most once per run.
func recordCommandLedger(database *db.DB, stderr io.Writer, rowID, workbenchID int64, ev hookEvent, at time.Time,
	lock hookLockWait) {
	rows := commandLedgerRows(ev)
	if len(rows) == 0 {
		return
	}
	err := writeCommandLedger(database, rowID, workbenchID, ev.SessionID, rows, at, lock)
	switch {
	case errors.Is(err, errCommandLedgerFull):
		if !commandLedgerFullReported.Swap(true) {
			fmt.Fprintf(stderr, "watchtower: session command row not recorded: %v\n", err)
		}
	case err != nil:
		fmt.Fprintf(stderr, "watchtower: session command row not recorded: %v\n", err)
	}
}

// errCommandLedgerFull is a new command row past db.MaxSessionCommandRows.
var errCommandLedgerFull = fmt.Errorf("the session already records %d command rows", db.MaxSessionCommandRows)

// commandLedgerFullReported keeps the command rows' "session full" stderr
// line to one per run.
var commandLedgerFullReported atomic.Bool

// commandRow is one terminal_session_worktrees row a command names.
type commandRow struct{ root, branch, kind string }

// commandLedgerRows is what ev's command created, deduplicated: nothing
// unless ev is a PostToolUse of Bash run in an absolute cwd. A worktree's
// root is its path symlink-resolved, kept only when <path>/.git is a
// regular file (a linked worktree's pointer; a typo or a failed add leaves
// none); a branch's root is the work tree holding the directory git ran in,
// found from files (sessionWorktreeAt), nothing outside one. Stats only.
func commandLedgerRows(ev hookEvent) []commandRow {
	if ev.Event != "PostToolUse" || ev.ToolName != "Bash" {
		return nil
	}
	cwd := hookPath(ev.Cwd)
	var input struct {
		Command string `json:"command"`
	}
	if cwd == "" || json.Unmarshal(ev.ToolInput, &input) != nil || input.Command == "" {
		return nil
	}
	var out []commandRow
	seen := map[commandRow]bool{}
	for _, c := range gitcmdparse.Parse(input.Command, cwd) {
		var r commandRow
		switch c.Kind {
		case gitcmdparse.KindWorktree:
			path := hookPath(c.Path)
			if path == "" {
				continue
			}
			if fi, err := os.Lstat(filepath.Join(path, ".git")); err != nil || !fi.Mode().IsRegular() {
				continue
			}
			r = commandRow{resolvedDir(path), c.Branch, gitcmdparse.KindWorktree}
		case gitcmdparse.KindBranch:
			root, _, ok := sessionWorktreeAt(hookPath(c.Dir))
			if !ok || c.Branch == "" {
				continue
			}
			r = commandRow{root, c.Branch, gitcmdparse.KindBranch}
		default:
			continue
		}
		if !seen[r] {
			seen[r] = true
			out = append(out, r)
		}
	}
	return out
}

// writeCommandLedger is recordCommandLedger's database part: the row's
// guards (the hook's conversation, workbench and kind) once, then one short
// write transaction per row. It stops at the first error; a row past the
// cap is errCommandLedgerFull after the rest are tried (a pair already held
// still moves its last sighting).
func writeCommandLedger(database *db.DB, rowID, workbenchID int64, sessionID string, rows []commandRow, at time.Time,
	lock hookLockWait) error {
	row, err := hookSessionRow(database, rowID, workbenchID, sessionID)
	if row == nil || err != nil {
		return err
	}
	stamp := db.AgentStateStamp(at)
	full := false
	for _, r := range rows {
		var rowFull bool
		if err := lock.write(database, func() error {
			var err error
			_, rowFull, err = database.RecordSessionCommandRow(context.Background(), rowID, r.root, r.branch, r.kind, stamp)
			return err
		}); err != nil {
			return err
		}
		full = full || rowFull
	}
	if full {
		return errCommandLedgerFull
	}
	return nil
}
