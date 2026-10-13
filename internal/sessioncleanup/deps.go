// Package sessioncleanup plans and applies the removal of
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

// Proc is one process of the scan. Cwd and Exe "" = unknown. Name is ps's
// comm (argv-based), for messages only — never a basis for a decision.
type Proc struct {
	PID, PPID, UID        int
	Start, Exe, Cwd, Name string
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
// time.Now, a nil Home is os.UserHomeDir, a nil WorktreeBirth is the
// platform's birth time (unknown off darwin).
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
	// WorktreeBirth is the birth time of a worktree's admin dir; false =
	// unknown, which keeps the worktree (created_unknown).
	WorktreeBirth func(adminDir string) (time.Time, bool)
	// Results stores a session-mode apply's result (cleanup_result); nil
	// leaves it unsaved and says so in Result.ResultError.
	Results ResultStore
	// OrphanGrace is how long an apply waits for SIGTERMed orphans to exit
	// before it keeps the worktree; 0 = 5 s (spec §7).
	OrphanGrace time.Duration
}

// OrphansIn splits the processes inside one of roots into orphans and
// blockers; processes outside every root are in neither. An orphan has ppid
// 1, runs as the current user, is not self, and its executable is inside
// one of roots and is not Watchtower's, Claude Code's or Codex's: only a
// build output, test stub or dev binary of the worktree itself is ever
// signalled. A process whose cwd is inside but whose executable is outside
// (a shell, a tmux server, a node-run CLI, an app) is a blocker. A process
// of the current user whose cwd is unknown is a blocker for every root
// (ProcUnknown): it could be working in any of them (fail closed).
func OrphansIn(procs []Proc, roots []string, self int) (orphans, blockers []Proc) {
	uid := os.Getuid()
	for _, p := range procs {
		if !procInside(p, roots) && (p.UID != uid || !ProcUnknown(p)) {
			continue
		}
		if isOrphan(p, roots, uid, self) {
			orphans = append(orphans, p)
		} else {
			blockers = append(blockers, p)
		}
	}
	return orphans, blockers
}

// ProcUnknown reports whether the scan could not see p's cwd.
func ProcUnknown(p Proc) bool { return p.Cwd == "" }

func isOrphan(p Proc, roots []string, uid, self int) bool {
	if p.PPID != 1 || p.UID != uid || p.PID == self || ProcUnknown(p) || protectedExe(p.Exe) {
		return false
	}
	for _, r := range roots {
		if pathWithin(p.Exe, r) {
			return true
		}
	}
	return false
}

func procInside(p Proc, roots []string) bool {
	for _, r := range roots {
		if pathWithin(p.Cwd, r) || pathWithin(p.Exe, r) {
			return true
		}
	}
	return false
}

// protectedExe: Watchtower's CLI, daemon or app, Claude Code (its native
// install runs from .../claude/versions/<version>) and Codex are never
// orphans; neither is a process whose executable is unknown (fail closed).
func protectedExe(exe string) bool {
	if exe == "" {
		return true
	}
	switch filepath.Base(exe) {
	case "watchtower", "claude", "codex":
		return true
	}
	if strings.Contains(exe, "/claude/versions/") {
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
