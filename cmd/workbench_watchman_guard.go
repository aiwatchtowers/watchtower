package cmd

import (
	"cmp"
	"context"
	"encoding/json"
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
// armed and, armed, the places it may touch and the owner's limits. err is
// an open or arm-read failure (the sidecar then decides); extraErr a failed
// read of the owner's limits (an armed session then denies every call);
// warn collects the other failures.
type watchmanGuardRead struct {
	store     watchmanGuardStore
	armed     bool
	session   db.ArmedSession
	worktrees []string
	extra     []db.WatchmanExtraLimit
	err       error
	extraErr  error
	warn      []string
}

// readWatchmanGuard reads session rowID's arming on the store, and only
// when it is armed anything more.
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
	r.extra, r.extraErr = store.WatchmanExtraLimits()
	return r
}

// watchmanGuardRun is one run's output state: whether the session is known
// armed and whether the denial was printed, for the panic path.
type watchmanGuardRun struct {
	stdout        io.Writer
	armed, denied bool
}

func (g *watchmanGuardRun) deny(limit watchman.HardLimit) {
	if !g.denied {
		g.denied = true
		writeToolDenial(g.stdout, watchmanGuardReason(limit))
	}
}

// runWatchmanGuard is the PreToolUse hook. Its stdout is the agent's
// decision: nothing lets the tool run, the denial JSON stops it. No Desktop
// session (no terminal row) or a session not armed prints nothing, after one
// row read. Armed, a tool call the hard-limit table or the owner's limits
// cover (watchman.CheckLimits) is denied and journalled for Waiting for you;
// a journal failure still denies. Armed, it fails closed with `unreadable`:
// a hook input it cannot read, owner's limits it cannot read (from the
// database, or a sidecar marked limits-unavailable), a sidecar that exists
// but cannot be read, a panic. The database not read within
// watchmanGuardReadBudget → the arm sidecar decides (with the owner's
// limits it carries), and nothing is journalled.
func runWatchmanGuard(stdin io.Reader, stdout, stderr io.Writer, agent agentkind.Kind, deps watchmanGuardDeps) {
	rowID, ok, err := terminalSessionRowID()
	if !ok || err != nil {
		return
	}
	g := &watchmanGuardRun{stdout: stdout}
	defer func() {
		if p := recover(); p != nil && g.armed {
			g.deny(watchman.LimitUnreadable)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), askGuardInputWait)
	in, inErr := readHookEvent(ctx, stdin, hookStdinLimit, agent)
	cancel()
	inputOK := inErr == nil && in.ToolName != ""

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

	var ask watchman.PermissionAsk
	extra, unreadable := read.extra, read.extraErr != nil
	if read.extraErr != nil {
		fmt.Fprintf(stderr, "watchtower: watchman guard: the owner's limits: %v\n", read.extraErr)
	}
	dir := in.Cwd
	if read.err != nil {
		fmt.Fprintf(stderr, "watchtower: watchman guard: %v; the arm sidecar decides\n", read.err)
		sc, err := deps.sidecar()
		if err != nil { // a sidecar that is there but cannot be read: armed, unreadable
			fmt.Fprintf(stderr, "watchtower: watchman guard: %v\n", err)
			g.armed, unreadable = true, true
		} else {
			g.armed = slices.Contains(sc.Sessions, rowID) || sc.TargetsArmed
			unreadable = unreadable || sc.LimitsUnavailable // not all the owner's limits are in it
		}
		ask.Worktrees, extra = sidecarWorktreesOf(sc, in.Cwd), sc.Limits
	} else {
		g.armed = read.armed
		ask.WorkbenchFolder = read.session.WorkbenchFolder
		ask.Worktrees = append([]string{read.session.Folder}, read.worktrees...)
		if dir == "" {
			dir = read.session.Folder
		}
	}
	if !g.armed {
		return
	}
	var deny bool
	var limit watchman.HardLimit
	if !inputOK || unreadable {
		if inErr != nil {
			fmt.Fprintf(stderr, "watchtower: watchman guard: the hook input: %v\n", inErr)
		}
		deny, limit = true, watchman.LimitUnreadable
		ask.Tool, ask.Summary = cmp.Or(in.ToolName, "(unknown tool)"), "the hook input or the owner's limits could not be read"
	} else {
		ask.Tool, ask.Summary = in.ToolName, watchmanGuardSummary(in)
		if filepath.IsAbs(in.Cwd) {
			ask.Cwd = filepath.Clean(in.Cwd)
		}
		if ask.Tool == "Bash" { // only shell commands read the branch
			gctx, gcancel := context.WithTimeout(context.Background(), watchmanGuardGitWait)
			ask.Branch = &watchman.BranchInfo{Current: deps.branch(gctx, dir)}
			gcancel()
		}
		deny, limit = watchmanGuardDecision(in, true, ask, extra)
	}
	if !deny {
		return
	}
	g.deny(limit)
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

// watchmanGuardSummary is the tool call as the hard-limit table reads it:
// a file tool's relative path is made absolute against the call's working
// directory cwd. A shell command keeps its text; its start directory goes
// to the table as PermissionAsk.Cwd.
func watchmanGuardSummary(in hookEvent) string {
	if in.ToolName == "Bash" || in.Cwd == "" || !filepath.IsAbs(in.Cwd) {
		return permissionSummaryText(in.ToolName, in.ToolInput)
	}
	return permissionSummaryText(in.ToolName, absToolPaths(in.ToolInput, in.Cwd))
}

// absToolPaths rewrites a tool input's relative file_path, notebook_path
// and path against cwd; anything else is kept as it was.
func absToolPaths(input json.RawMessage, cwd string) json.RawMessage {
	var fields map[string]json.RawMessage
	if json.Unmarshal(input, &fields) != nil {
		return input
	}
	changed := false
	for _, key := range []string{"file_path", "notebook_path", "path"} {
		var p string
		if json.Unmarshal(fields[key], &p) != nil || p == "" || filepath.IsAbs(p) || strings.HasPrefix(p, "~") {
			continue
		}
		raw, err := json.Marshal(filepath.Join(cwd, p))
		if err != nil {
			continue
		}
		fields[key], changed = raw, true
	}
	if !changed {
		return input
	}
	out, err := json.Marshal(fields)
	if err != nil {
		return input
	}
	return out
}

// pathWithin reports whether p is root or lies under it.
func pathWithin(p, root string) bool {
	p, root = filepath.Clean(p), filepath.Clean(root)
	return p == root || strings.HasPrefix(p, strings.TrimSuffix(root, "/")+"/")
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
	for _, w := range sc.Worktrees {
		if pathWithin(cwd, w) {
			return []string{w}
		}
	}
	return nil
}
