// Package sessioncleanup plans (and, from Task 6 on, applies) the removal of
// what a workbench session left behind: the linked worktrees and local
// branches it created once their work is merged or pushed, its orphan
// processes and the LaunchServices entries of builds inside those worktrees.
// It never removes uncommitted, unpushed, in-use or someone else's work
// (PROJ-16, docs/inventory/workbench.md). git runs only through
// internal/gitbin's binary, never in a folder outside a repository, never
// with --force and never to fetch.
package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
)

// ErrNoGit means no git binary was found outside the macOS shim; nothing
// was planned and no process ran.
var ErrNoGit = gitbin.ErrUnavailable

// GitRunner runs the located git binary. A non-zero exit returns its code
// and an error carrying git's stderr (a *GitError).
type GitRunner interface {
	GitBinary() (string, bool)
	RunGit(ctx context.Context, dir, bin string, args ...string) (stdout []byte, code int, err error)
}

// GitError is a git run that exited non-zero; Stderr is git's own words.
type GitError struct {
	Args   []string
	Code   int
	Stderr string
}

func (e *GitError) Error() string {
	return fmt.Sprintf("git %s: exit %d: %s", strings.Join(e.Args, " "), e.Code, e.Stderr)
}

// SystemGit is the real GitRunner: gitbin.Locate and gitbin.Exec
// (non-interactive, no optional locks, no inherited repository variables).
type SystemGit struct{}

// GitBinary is gitbin.Locate.
func (SystemGit) GitBinary() (string, bool) { return gitbin.Locate() }

// RunGit runs bin with args in dir.
func (SystemGit) RunGit(ctx context.Context, dir, bin string, args ...string) ([]byte, int, error) {
	stdout, stderr, err := gitbin.Exec(ctx, dir, nil, bin, args...)
	if err == nil {
		return stdout, 0, nil
	}
	var exitErr interface{ ExitCode() int }
	if errors.As(err, &exitErr) && ctx.Err() == nil {
		return stdout, exitErr.ExitCode(), &GitError{Args: args, Code: exitErr.ExitCode(), Stderr: string(stderr)}
	}
	return nil, -1, fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
}

// SessionInfo is the slice of a terminal_sessions row a session-mode plan
// needs.
type SessionInfo struct {
	ID, WorkbenchID int64
	CreatedAt       time.Time
}

// SessionActivity is one terminal session, of any workbench, as the in-use
// and recent-owner catches see it. AgentCwd is the main agent's latest place
// (board #565's column, read through the Store seam; "" = unknown).
type SessionActivity struct {
	ID          int64
	WorkbenchID int64 // 0 = a standalone terminal
	Title       string
	AgentCwd    string
	ReportedAt  time.Time // agent_state_at; zero = never reported
	LastActive  time.Time // last_active_at
	Finished    bool
}

// Store is what a plan reads from the database. It has no write method: a
// plan writes nothing (PROJ-16).
type Store interface {
	CleanupSession(ctx context.Context, sessionID int64) (SessionInfo, error)
	SessionWorktrees(ctx context.Context, sessionID int64) ([]db.SessionWorktree, error)
	// SessionTargetBranches is the non-empty `branch` of every target the
	// session linked (terminal_session_targets, PROJ-14).
	SessionTargetBranches(ctx context.Context, sessionID int64) ([]string, error)
	WorkbenchFolder(ctx context.Context, workbenchID int64) (string, error)
	// WorkbenchFolders is every workbench's folder_path.
	WorkbenchFolders(ctx context.Context) ([]string, error)
	WorkbenchSessionWorktrees(ctx context.Context, workbenchID int64) (map[string][]int64, error)
	// AllSessionActivity is every terminal session of every workbench (and
	// standalone ones): an agent of another workbench over the same
	// repository can work inside a worktree too (W6).
	AllSessionActivity(ctx context.Context) ([]SessionActivity, error)
}

// Proc is one process of the scan. Cwd "" = unknown.
type Proc struct {
	PID, PPID, UID  int
	Start, Exe, Cwd string
}

// ProcessScanner lists processes and signals orphans (Task 5 implements it).
type ProcessScanner interface {
	Scan(ctx context.Context) ([]Proc, error)
	Terminate(p Proc) error // SIGTERM, re-verifies the start time
}

// Sizer measures a worktree's allocated bytes within budget; known is
// false when it ran over or failed.
type Sizer interface {
	Size(ctx context.Context, root string, budget time.Duration) (bytes int64, known bool)
}

// LaunchServices finds and unregisters .app bundles (Task 5 implements it).
type LaunchServices interface {
	Bundles(root string) []string
	Unregister(ctx context.Context, bundle string) error
	Stale(ctx context.Context, under string) ([]string, error)
}

// Deps are a plan's collaborators. Git, DB and Procs are required; a nil
// Sizer leaves sizes unknown, a nil LS lists no lsreg items, a nil Clock is
// time.Now, a nil Home is os.UserHomeDir.
type Deps struct {
	Git   GitRunner
	DB    Store
	Procs ProcessScanner
	Sizer Sizer
	LS    LaunchServices
	Clock func() time.Time
	// Home is the owner's home directory: nothing under its .claude is
	// ever removed (spec §5 "never, by construction").
	Home func() (string, error)
}

// OrphansIn splits the processes whose cwd or executable is inside one of
// roots into orphans — ppid 1, the current user, not self and not
// Watchtower's, Claude Code's or Codex's executable — and blockers (every
// other one inside). Processes outside every root are in neither.
func OrphansIn(procs []Proc, roots []string, self int) (orphans, blockers []Proc) {
	uid := os.Getuid()
	for _, p := range procs {
		if !procInside(p, roots) {
			continue
		}
		if p.PPID == 1 && p.UID == uid && p.PID != self && !protectedExe(p.Exe) {
			orphans = append(orphans, p)
		} else {
			blockers = append(blockers, p)
		}
	}
	return orphans, blockers
}

func procInside(p Proc, roots []string) bool {
	for _, r := range roots {
		if pathWithin(p.Cwd, r) || pathWithin(p.Exe, r) {
			return true
		}
	}
	return false
}

// protectedExe: Watchtower's CLI, daemon or app, Claude Code and Codex are
// never orphans.
func protectedExe(exe string) bool {
	switch filepath.Base(exe) {
	case "watchtower", "claude", "codex":
		return true
	}
	return strings.Contains(exe, "/Watchtower") && strings.Contains(exe, ".app/")
}

// pathWithin reports whether p is root or inside it; "" is never inside.
func pathWithin(p, root string) bool {
	if p == "" || root == "" {
		return false
	}
	return p == root || strings.HasPrefix(p, strings.TrimSuffix(root, "/")+"/")
}
