package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/terminal"
)

// gitPointerMaxBytes caps what the ledger reads of a ".git" file or a HEAD
// file: both are one short line.
const gitPointerMaxBytes = 4096

// recordSessionLedger records, on the session of row rowID, the worktree
// root and branch the event's cwd resolves to (terminal_session_worktrees,
// board #535; spec 2026-10-12-session-cleanup §3.2) — for any agent of the
// session, the main one, a subagent or a teammate. Nothing for a cwd that is
// missing, invalid or outside a repository; a pair the session already holds
// costs one read and no write. It runs after the event's state write, in its
// own transaction, so it never changes that write: a failure is one stderr
// line, and nothing reaches stdout (PROJ-11).
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
	if err := writeSessionLedger(database, rowID, workbenchID, sessionID, root, branch, at); err != nil {
		fmt.Fprintf(stderr, "watchtower: session worktree not recorded: %v\n", err)
	}
}

// errSessionLedgerFull is a new pair past db.MaxSessionWorktrees.
var errSessionLedgerFull = fmt.Errorf("the session already records %d worktrees", db.MaxSessionWorktrees)

// writeSessionLedger is recordSessionLedger's database part: read first, so
// the common case (a pair already recorded) never takes the write lock; then
// the row's guards (the hook's conversation, workbench and kind); then the
// insert.
func writeSessionLedger(database *db.DB, rowID, workbenchID int64, sessionID, root, branch string, at time.Time) error {
	ctx := context.Background()
	has, err := database.HasSessionWorktree(ctx, rowID, root, branch)
	if err != nil || has {
		return err
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
	// Not recorded: a racing hook inserted the pair, or the session is full.
	has, err = database.HasSessionWorktree(ctx, rowID, root, branch)
	if err != nil || has {
		return err
	}
	return errSessionLedgerFull
}

// sessionWorktreeAt resolves an absolute, cleaned dir to the work tree
// holding it — the nearest dir up from it with a ".git" entry, symlink-
// resolved — and the branch that work tree's HEAD names ("" for a detached
// or unreadable HEAD). It reads files only and never runs git (spec §3.2).
// ok is false outside any work tree or when the ".git" entry found is not a
// git dir or a "gitdir:" file.
func sessionWorktreeAt(dir string) (root, branch string, ok bool) {
	for cur := dir; ; cur = filepath.Dir(cur) {
		gitDir, found, valid := gitDirIn(cur)
		if found {
			if !valid {
				return "", "", false
			}
			return resolvedRoot(cur), headBranch(gitDir), true
		}
		if filepath.Dir(cur) == cur {
			return "", "", false
		}
	}
}

// gitDirIn reads dir's ".git" entry: found says one exists, valid that it is
// a directory or a "gitdir: <path>" file, and gitDir is the git dir it names
// (a relative path is taken from dir).
func gitDirIn(dir string) (gitDir string, found, valid bool) {
	p := filepath.Join(dir, ".git")
	info, err := os.Stat(p)
	if err != nil {
		return "", !errors.Is(err, os.ErrNotExist), false
	}
	if info.IsDir() {
		return p, true, true
	}
	if !info.Mode().IsRegular() {
		return "", true, false
	}
	b, err := readSmallFile(p)
	if err != nil {
		return "", true, false
	}
	target, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir:")
	target = strings.TrimSpace(target)
	if !ok || target == "" {
		return "", true, false
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(dir, target)
	}
	return target, true, true
}

// headBranch is the short branch name gitDir's HEAD names, "" when HEAD is
// detached, names no branch, or cannot be read.
func headBranch(gitDir string) string {
	b, err := readSmallFile(filepath.Join(gitDir, "HEAD"))
	if err != nil {
		return ""
	}
	ref, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "ref:")
	if !ok {
		return ""
	}
	name, ok := strings.CutPrefix(strings.TrimSpace(ref), "refs/heads/")
	if !ok || strings.ContainsAny(name, "\x00\n\r") {
		return ""
	}
	return name
}

// resolvedRoot is root symlink-resolved, the form the cleanup compares
// against `git worktree list` (sessioncleanup's resolvePath); root itself
// when it cannot be resolved.
func resolvedRoot(root string) string {
	if r, err := filepath.EvalSymlinks(root); err == nil {
		return r
	}
	return root
}

// readSmallFile reads at most gitPointerMaxBytes of path; a longer file is
// an error (no git pointer file is that long).
func readSmallFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, gitPointerMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(b) > gitPointerMaxBytes {
		return nil, fmt.Errorf("%s is longer than %d bytes", path, gitPointerMaxBytes)
	}
	return b, nil
}
