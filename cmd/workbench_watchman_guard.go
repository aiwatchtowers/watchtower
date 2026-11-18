package cmd

import (
	"context"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/watchman"
	"watchtower/internal/watchmanact"
)

// The guard hook's budgets (spec 2026-11-16-watchman-design §5 item 3): the
// database reads together (the arm read and, armed, the session's worktrees
// and the owner's limits) — past it the database counts as unreadable and
// the arm sidecar decides; each statement's wait for a lock; the live
// branch read. With the input wait the hook ends well inside its 5 s.
const (
	watchmanGuardReadBudget = 500 * time.Millisecond
	watchmanGuardBusy       = 500 * time.Millisecond
	watchmanGuardGitWait    = 500 * time.Millisecond
	// watchmanGuardLineRunes caps one denial's line in the journal, so a
	// few fit the item's question.
	watchmanGuardLineRunes = 400
)

var (
	workbenchWatchmanGuardFlagWorkbench string
	workbenchWatchmanGuardFlagAgent     string
)

var workbenchWatchmanGuardCmd = &cobra.Command{
	Use:   "watchman-guard",
	Short: "The Watchman guard: a PreToolUse hook denying hard-limit actions in a session handed to Watchman",
	Long: "Installed by `integrate claude-code|codex` with the other workbench hooks (PreToolUse, every tool); it\n" +
		"always exits 0. In the Desktop session named by " + terminalSessionEnv + ", while that session is\n" +
		"handed to Watchman, a tool call that hits a hard limit (a push to main, a force push, a release, a\n" +
		"tag, a message others see, a delete outside the worktree, ... or a limit the owner added with\n" +
		"`watchman limits add`) is denied: the agent is told it is parked for the owner and to continue with\n" +
		"other work, and the denial waits for the owner in Watchman's journal. A session not handed to\n" +
		"Watchman costs one row read. When the database cannot be read in time, the arm sidecar decides.",
	PersistentPreRunE:  func(*cobra.Command, []string) error { return nil },
	Args:               cobra.ArbitraryArgs,
	FParseErrWhitelist: cobra.FParseErrWhitelist{UnknownFlags: true},
	RunE: func(cmd *cobra.Command, _ []string) error {
		agent, err := hookAgentFor(cmd, workbenchWatchmanGuardFlagAgent)
		if err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "watchtower: watchman guard skipped: %v\n", err)
			return nil
		}
		runWatchmanGuard(cmd.InOrStdin(), cmd.OutOrStdout(), cmd.ErrOrStderr(), agent, defaultWatchmanGuardDeps())
		return nil
	},
}

func init() {
	workbenchWatchmanGuardCmd.Flags().StringVar(&workbenchWatchmanGuardFlagWorkbench, workbenchFlag, "", "workbench id")
	addHookAgentFlag(workbenchWatchmanGuardCmd, &workbenchWatchmanGuardFlagAgent)
	workbenchCmd.AddCommand(workbenchWatchmanGuardCmd)
}

// watchmanGuardStore is what the guard reads and writes; *db.DB in the hook.
type watchmanGuardStore interface {
	WatchmanArmedSession(sessionID int64) (db.ArmedSession, bool, error)
	SessionWorktrees(ctx context.Context, sessionID int64) ([]db.SessionWorktree, error)
	WatchmanExtraLimits() ([]db.WatchmanExtraLimit, error)
	ParkWatchmanGuard(it db.WatchmanItem, at time.Time) error
	Close() error
}

// watchmanGuardDeps are the guard's outside world; tests replace them.
type watchmanGuardDeps struct {
	open    func() (watchmanGuardStore, error)
	sidecar func() (watchmanact.Sidecar, error)
	// branch is the checked-out branch in dir, "" when it cannot be read.
	branch func(ctx context.Context, dir string) string
	after  func(time.Duration) <-chan time.Time
	now    func() time.Time
}

func defaultWatchmanGuardDeps() watchmanGuardDeps {
	return watchmanGuardDeps{
		open: func() (watchmanGuardStore, error) {
			cfg, err := loadWorkbenchCLIConfig()
			if err != nil {
				return nil, err
			}
			return db.OpenExistingRW(cfg.DBPath(), watchmanGuardBusy)
		},
		sidecar: func() (watchmanact.Sidecar, error) {
			cfg, err := loadWorkbenchCLIConfig()
			if err != nil {
				return watchmanact.Sidecar{}, err
			}
			return watchmanact.ReadSidecar(watchmanact.SidecarPath(cfg.WorkspaceDir()))
		},
		branch: gitCurrentBranch,
		after:  time.After,
		now:    time.Now,
	}
}

// gitCurrentBranch is `git rev-parse --abbrev-ref HEAD` in dir, "" on any
// failure (the hard-limit table then treats the branch as shared).
func gitCurrentBranch(ctx context.Context, dir string) string {
	if dir == "" {
		return ""
	}
	out, err := exec.CommandContext(ctx, "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// watchmanGuardRead is the guard's database read: whether the session is
// armed and, armed, the places it may touch and the owner's limits. warn
// collects failures of the reads after the arm read.
type watchmanGuardRead struct {
	store     watchmanGuardStore
	armed     bool
	session   db.ArmedSession
	worktrees []string
	extra     []db.WatchmanExtraLimit
	err       error
	warn      []string
}

// readWatchmanGuard reads session rowID's arming on the store, and only
// when it is armed anything more. err is an open or arm-read failure.
func readWatchmanGuard(deps watchmanGuardDeps, rowID int64) (r watchmanGuardRead) {
	defer func() {
		if p := recover(); p != nil {
			r.err = fmt.Errorf("panic: %v", p)
		}
	}()
	store, err := deps.open()
	if err != nil {
		return watchmanGuardRead{err: err}
	}
	r.store = store
	if r.session, r.armed, r.err = store.WatchmanArmedSession(rowID); r.err != nil || !r.armed {
		return r
	}
	wts, err := store.SessionWorktrees(context.Background(), rowID)
	if err != nil {
		r.warn = append(r.warn, err.Error())
	}
	for _, w := range wts {
		r.worktrees = append(r.worktrees, w.Root)
	}
	if r.extra, err = store.WatchmanExtraLimits(); err != nil {
		r.warn = append(r.warn, err.Error())
	}
	return r
}

// runWatchmanGuard is the PreToolUse hook. Its stdout is the agent's
// decision: nothing lets the tool run, the denial JSON stops it. No
// Desktop session (no terminal row), an unreadable input or a session not
// armed prints nothing. Armed, a tool call the hard-limit table or the
// owner's limits cover (watchman.CheckLimits) is denied and journalled for
// Waiting for you; a journal failure still denies. The database not read
// within watchmanGuardReadBudget → the arm sidecar decides, and nothing is
// journalled.
func runWatchmanGuard(stdin io.Reader, stdout, stderr io.Writer, agent agentkind.Kind, deps watchmanGuardDeps) {
	defer func() { _ = recover() }()
	ctx, cancel := context.WithTimeout(context.Background(), askGuardInputWait)
	in, err := readHookEvent(ctx, stdin, hookStdinLimit, agent)
	cancel()
	if err != nil || in.ToolName == "" {
		return
	}
	rowID, ok, err := terminalSessionRowID()
	if !ok || err != nil {
		return
	}
	ask := watchman.PermissionAsk{Tool: in.ToolName, Summary: permissionSummaryText(in.ToolName, in.ToolInput)}

	reads := make(chan watchmanGuardRead, 1)
	go func() { reads <- readWatchmanGuard(deps, rowID) }()
	var read watchmanGuardRead
	select {
	case read = <-reads:
	case <-deps.after(watchmanGuardReadBudget):
		read.err = fmt.Errorf("the database was not read within %s", watchmanGuardReadBudget)
		go func() { // close the late handle, should the read still end
			if late := <-reads; late.store != nil {
				_ = late.store.Close()
			}
		}()
	}
	if read.store != nil {
		defer func() { _ = read.store.Close() }()
	}
	for _, w := range read.warn {
		fmt.Fprintf(stderr, "watchtower: watchman guard: %s\n", w)
	}

	armed := read.armed
	dir := in.Cwd
	if read.err != nil {
		fmt.Fprintf(stderr, "watchtower: watchman guard: %v; the arm sidecar decides\n", read.err)
		sc, err := deps.sidecar()
		if err != nil {
			fmt.Fprintf(stderr, "watchtower: watchman guard: %v\n", err)
		}
		armed = slices.Contains(sc.Sessions, rowID) || sc.TargetsArmed
		ask.Worktrees = sidecarWorktreesOf(sc, in.Cwd)
	} else {
		ask.WorkbenchFolder = read.session.WorkbenchFolder
		ask.Worktrees = append([]string{read.session.Folder}, read.worktrees...)
		if dir == "" {
			dir = read.session.Folder
		}
	}
	if !armed {
		return
	}
	if ask.Tool == "Bash" { // only shell commands read the branch
		gctx, gcancel := context.WithTimeout(context.Background(), watchmanGuardGitWait)
		ask.Branch = &watchman.BranchInfo{Current: deps.branch(gctx, dir)}
		gcancel()
	}
	deny, limit := watchmanGuardDecision(in, armed, ask, read.extra)
	if !deny {
		return
	}
	writeToolDenial(stdout, watchmanGuardReason(limit))
	if read.err != nil {
		return
	}
	line := fmt.Sprintf("%s — %s: %s", limit, ask.Tool, strings.Join(strings.Fields(watchman.Redact(ask.Summary)), " "))
	err = read.store.ParkWatchmanGuard(db.WatchmanItem{
		WorkbenchID: read.session.WorkbenchID, SessionID: rowID, TargetID: read.session.TargetID,
		Question: watchman.Clip(line, watchmanGuardLineRunes), ParkReason: string(limit),
	}, deps.now())
	if err != nil {
		fmt.Fprintf(stderr, "watchtower: watchman guard: the denial was not journalled: %v\n", err)
	}
}

// watchmanGuardDecision is the guard's verdict on one tool call: deny while
// armed when the hard-limit table or the owner's limits cover it.
func watchmanGuardDecision(in hookEvent, armed bool, r watchman.PermissionAsk, extra []db.WatchmanExtraLimit) (deny bool, limit watchman.HardLimit) {
	if !armed || in.ToolName == "" {
		return false, ""
	}
	limit, deny = watchman.CheckLimits(r, extra)
	return deny, limit
}

// watchmanGuardReason is what the agent is told instead of its tool call.
func watchmanGuardReason(limit watchman.HardLimit) string {
	return "Parked for the owner: " + string(limit) + " — continue with other work"
}

// sidecarWorktreesOf is the armed worktree the hook runs in, by its working
// directory, for the hard-limit table's placement; none (every
// path-dependent row parks) when cwd lies in no listed worktree.
func sidecarWorktreesOf(sc watchmanact.Sidecar, cwd string) []string {
	if cwd == "" {
		return nil
	}
	cwd = filepath.Clean(cwd)
	for _, w := range sc.Worktrees {
		if cwd == w || strings.HasPrefix(cwd, strings.TrimSuffix(w, "/")+"/") {
			return []string{w}
		}
	}
	return nil
}
