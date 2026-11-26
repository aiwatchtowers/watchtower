// Package sessioncleanup plans and applies the removal of
// what a workbench session left behind: the linked worktrees and local
// branches it created once their work is merged or pushed, its orphan
// processes and the LaunchServices entries of builds inside those worktrees.
// It never removes uncommitted, unpushed, in-use or someone else's work
// (PROJ-18, docs/inventory/workbench.md). git runs only through
// internal/gitbin's binary, never in a folder outside a repository, never
// with --force and never to fetch.
package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
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
// The folder's .git/config is the agent's to write (security review #155):
// a read runs none of the commands it names (gitbin.ReadArgsIn — no
// fsmonitor, hook or signature program, and no filter driver on a status),
// and the owner-confirmed writes run no fsmonitor (gitbin.OwnerArgs).
type SystemGit struct{}

// GitBinary is gitbin.Locate.
func (SystemGit) GitBinary() (string, bool) { return gitbin.Locate() }

// GitInputRunner is a GitRunner that can also feed git a stdin (the drift
// check's `git patch-id`, unlock.go); SystemGit is one.
type GitInputRunner interface {
	RunGitInput(ctx context.Context, dir, bin string, stdin []byte, args ...string) (stdout []byte, code int, err error)
}

// RunGit runs bin with args in dir.
func (s SystemGit) RunGit(ctx context.Context, dir, bin string, args ...string) ([]byte, int, error) {
	return s.RunGitInput(ctx, dir, bin, nil, args...)
}

// RunGitInput is RunGit feeding stdin (nil = none) to git, under the same
// read or owner arguments and environment.
func (SystemGit) RunGitInput(ctx context.Context, dir, bin string, stdin []byte, args ...string) ([]byte, int, error) {
	argv, err := gitArgv(ctx, dir, bin, args)
	if err != nil {
		return nil, -1, fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	stdout, stderr, err := gitbin.Exec(ctx, dir, stdin, bin, argv...)
	if err == nil {
		return stdout, 0, nil
	}
	var exitErr interface{ ExitCode() int }
	if errors.As(err, &exitErr) && ctx.Err() == nil {
		return stdout, exitErr.ExitCode(), &GitError{Args: args, Code: exitErr.ExitCode(), Stderr: string(stderr)}
	}
	return nil, -1, fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
}

// gitArgv is the argv SystemGit runs for args in dir: a read under
// gitbin's read guard; a write the owner's way (OwnerArgs) — or, under a
// ctx withBackgroundWrites marked, in gitbin's background mode, naming the
// repository the mark carries (or the one the args name already) with
// --git-dir.
func gitArgv(ctx context.Context, dir, bin string, args []string) ([]string, error) {
	gitDir, on := backgroundWrites(ctx)
	if !ownerWrite(args) {
		argv, err := gitbin.ReadArgsIn(ctx, bin, dir, args...)
		if err != nil || !on || !repositoryWideRead(args) {
			return argv, err //nolint:wrapcheck // the caller names the command
		}
		// The repository pass decides its deletes on these: they read the
		// repository whose lock is held, never one found from dir (#2402
		// fix rounds 3–4, R3-1, R4-2) — under the same read guard, the
		// filter drivers blanked for a diff included.
		guard := argv[:len(argv)-len(args)]
		return slices.Concat(guard, []string{"--git-dir=" + gitDir}, args), nil
	}
	if !on {
		return gitbin.OwnerArgs(args...), nil
	}
	if len(args) > 0 && strings.HasPrefix(args[0], "--git-dir=") {
		gitDir, args = strings.TrimPrefix(args[0], "--git-dir="), args[1:]
	}
	return gitbin.BackgroundWriteArgsIn(ctx, bin, dir, gitDir, args...) //nolint:wrapcheck // the caller names the command
}

// repositoryWideRead: args read the repository as a whole — its worktree
// list, refs and reflogs, ancestry, commits named by their id or ref —
// with no worktree's HEAD, index or files in play, so naming the common
// dir gives the same answer from any folder of it. The cleanup's own reads
// (readRepo, recheckBranch, notCheckedOutNow) and the merge check behind
// W3 (workbenchcheck's) are these; a probe of the folder itself
// (`rev-parse --show-toplevel`, `--is-inside-work-tree`, `--git-common-dir`)
// and anything naming HEAD or no revision at all are not.
func repositoryWideRead(args []string) bool {
	if len(args) == 0 || slices.ContainsFunc(args[1:], headRelative) {
		return false
	}
	switch args[0] {
	case "worktree":
		return len(args) > 1 && args[1] == "list"
	case "for-each-ref", "show-ref", "merge-base", "symbolic-ref", "cherry":
		return true
	case "rev-parse":
		return slices.Contains(args[1:], "--verify")
	case "reflog":
		return len(args) > 2 && args[1] == "show"
	case "rev-list", "log":
		return len(revisions(args[1:])) > 0
	case "diff":
		return len(revisions(args[1:])) >= 2
	}
	return false
}

// headRelative: a revision argument resolved against a worktree's HEAD.
func headRelative(a string) bool {
	return a == "HEAD" || a == "@" || strings.HasPrefix(a, "HEAD~") || strings.HasPrefix(a, "HEAD^") ||
		strings.HasPrefix(a, "HEAD:") || strings.HasPrefix(a, "HEAD.") || strings.HasSuffix(a, "..HEAD")
}

// revisions are the non-option arguments before "--".
func revisions(args []string) []string {
	var out []string
	for _, a := range args {
		if a == "--" {
			break
		}
		if !strings.HasPrefix(a, "-") {
			out = append(out, a)
		}
	}
	return out
}

type backgroundWritesKey struct{}

// withBackgroundWrites marks ctx: SystemGit runs every write under it in
// gitbin's background mode — no hook, no fsmonitor, and for `worktree
// remove` no filter driver the folder or the target worktree sees (#2402,
// fix rounds 1–2) — naming commonDir, the repository whose lock is held
// and that every evaluation was checked against, with --git-dir, so no
// write — nor a repository-wide read (repositoryWideRead) — discovers
// another repository from its folder. The repository pass
// sets it: it writes over trees no session of the owner's owns, so nothing
// it does may run the repository's commands. The mark travels with the ctx
// through any runner that wraps SystemGit.
func withBackgroundWrites(ctx context.Context, commonDir string) context.Context {
	return context.WithValue(ctx, backgroundWritesKey{}, commonDir)
}

// backgroundWrites is the mark's repository, and whether ctx carries one.
func backgroundWrites(ctx context.Context) (string, bool) {
	dir, on := ctx.Value(backgroundWritesKey{}).(string)
	return dir, on
}

// ownerWrite: args are one of the writes an apply runs on the owner's
// confirmation (worktree remove, its unlock and relock, update-ref -d,
// config --remove-section);
// everything else is a read.
func ownerWrite(args []string) bool {
	if len(args) > 0 && strings.HasPrefix(args[0], "--git-dir=") {
		args = args[1:] // the restore names the repository (unlock.go)
	}
	switch {
	case len(args) == 0:
		return false
	case args[0] == "update-ref":
		return true
	case args[0] == "worktree":
		return len(args) > 1 && slices.Contains([]string{"remove", "lock", "unlock"}, args[1])
	case args[0] == "config":
		return slices.Contains(args[1:], "--remove-section")
	}
	return false
}

// SessionInfo is the slice of a terminal_sessions row a session-mode plan
// needs. PlacedCwd and PlacedBranch are the row's folder_path and
// worktree_branch when Watchtower placed it in a worktree it created (board
// #229), both "" otherwise. Kind is the row's kind (claude, codex, shell).
// Ended is the row's delete_requested_at (board #1716): its terminal had
// ended by then; zero when the row is not being deleted (or the stamp does
// not parse), which bounds nothing. Folder is the workbench folder the
// session was started for (multi-folder workbench, #2003): its repository is
// the one planned; "" = the workbench's home folder (a row from before
// folders). FolderRemoved: that folder has left the bench, so only the
// worktrees the session's own ledger recorded can go (PROJ-18).
type SessionInfo struct {
	ID, WorkbenchID         int64
	CreatedAt               time.Time
	PlacedCwd, PlacedBranch string
	Kind                    string
	Ended                   time.Time
	Folder                  string
	FolderRemoved           bool
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
	// DeleteRequested: the row has delete_requested_at (board #1716).
	DeleteRequested bool
	// Kind is the row's kind ("shell" for a plain terminal) and Folder its
	// folder_path, where it was opened (#2402 fix round 4).
	Kind   string
	Folder string
}

// Store is what a plan reads from the database. It has no write method: a
// plan writes nothing (PROJ-18).
type Store interface {
	CleanupSession(ctx context.Context, sessionID int64) (SessionInfo, error)
	SessionWorktrees(ctx context.Context, sessionID int64) ([]db.SessionWorktree, error)
	// SessionTargetBranches is the non-empty `branch` of every target the
	// session linked (terminal_session_targets, PROJ-14).
	SessionTargetBranches(ctx context.Context, sessionID int64) ([]string, error)
	// AgentSessionIDs is every agent session id the row has had (history
	// plus the current claude_session_id), each with when the row acquired it.
	AgentSessionIDs(ctx context.Context, sessionID int64) ([]db.AgentSessionID, error)
	// AgentSessionIDOwners maps each uuid to every terminal session row
	// whose history or current id holds it.
	AgentSessionIDOwners(ctx context.Context, uuids []string) (map[string][]int64, error)
	// WorkbenchFolder is the workbench's home folder (folder_path).
	WorkbenchFolder(ctx context.Context, workbenchID int64) (string, error)
	// WorkbenchFolders is every folder of every workbench, the folders
	// that left their bench included: none is ever a candidate (W1).
	WorkbenchFolders(ctx context.Context) ([]string, error)
	// BenchFolders is the workbench's live folders, the home folder first
	// then the rest by position: the repositories the owner's sweep covers.
	BenchFolders(ctx context.Context, workbenchID int64) ([]string, error)
	WorkbenchSessionWorktrees(ctx context.Context, workbenchID int64) (map[string][]int64, error)
	// SessionWorktreeOwners maps each root any session of any workbench
	// recorded to those sessions: the repository pass's owners (#2402).
	SessionWorktreeOwners(ctx context.Context) (map[string][]int64, error)
	// AllSessionActivity is every terminal session of every workbench (and
	// standalone ones): an agent of another workbench over the same
	// repository can work inside a worktree too (W6).
	AllSessionActivity(ctx context.Context) ([]SessionActivity, error)
	// SessionActivityOf is one session's row of AllSessionActivity, read
	// by id; false when there is none. The last read before a quiet
	// session's destructive step (Request.Quiet).
	SessionActivityOf(ctx context.Context, id int64) (SessionActivity, bool, error)

	// WorktreeLastSeen is the newest sighting of a worktree root in any
	// session's ledger; false = none recorded.
	WorktreeLastSeen(ctx context.Context, root string) (time.Time, bool, error)
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
	// Register adds a bundle back (an apply whose worktree stayed after
	// its bundles were unregistered).
	Register(ctx context.Context, bundle string) error
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
	// ClaudeProjects is Claude Code's projects directory, where the
	// subagent records are read (auto cleanup spec 2026-11-10 §2a): the one
	// the session feed reads; nil = ~/.claude/projects. "" = unknown.
	ClaudeProjects func() string
	// Lock takes the cross-process cleanup lock of a repository, keyed by
	// its git common dir (LockPath), waiting until it is free or ctx is
	// done; an apply holds it from before its evaluation to its end. nil =
	// no lock.
	Lock func(ctx context.Context, repo string) (unlock func(), err error)
	// OrphanGrace is how long an apply waits for SIGTERMed orphans to exit
	// before it keeps the worktree; 0 = 5 s (spec §7).
	OrphanGrace time.Duration
	// markerWritten, when set (tests), runs right after an unlock marker
	// was written and synced, before the lock's last read.
	markerWritten func(admin string)
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
		if isLanguageServer(p) {
			continue // spec §5: neither keeps a worktree nor is signalled
		}
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

// languageServers are the native language servers (spec §5, W5): a process
// running one neither keeps a worktree nor is ever an orphan to signal. A
// fixed set on purpose: servers under node or python (tsserver, pyright)
// cannot be told from a build or a dev server by the executable, so they
// keep the worktree.
var languageServers = map[string]bool{
	"gopls": true, "sourcekit-lsp": true, "clangd": true, "rust-analyzer": true,
	"jdtls": true, "lua-language-server": true, "zls": true,
}

// isLanguageServer: p's executable (never its argv-based name) is one of
// languageServers; an unknown executable is not.
func isLanguageServer(p Proc) bool {
	return p.Exe != "" && languageServers[filepath.Base(p.Exe)]
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
