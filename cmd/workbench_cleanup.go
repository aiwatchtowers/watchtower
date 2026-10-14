package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/db"
	"watchtower/internal/sessioncleanup"
)

var workbenchCleanupCmd = &cobra.Command{
	Use:   "cleanup",
	Short: "Plan or remove what a workbench session left behind: merged or pushed worktrees and branches, orphans",
	Long: "Without --apply it only plans: it lists what it would remove and what it keeps and why,\n" +
		"and writes nothing. --session S (default $" + terminalSessionEnv + ") plans that session's\n" +
		"cleanup: the linked worktrees and local branches it created whose work is merged or\n" +
		"pushed, their orphan processes and LaunchServices entries; never uncommitted, unpushed,\n" +
		"in-use or someone else's work (PROJ-18). --apply evaluates afresh and removes what is\n" +
		"eligible now — only the --item keys named, when any — and saves the result on the\n" +
		"session (result_saved / result_error). --workbench N --sweep lists every worktree and\n" +
		"branch of the workbench repository with an owner hint; a sweep applies only named\n" +
		"--item keys and never signals a process. git is never fetched: fetch first.\n" +
		"Exit codes: 0 done (kept items are not a failure), 1 could not plan, 2 usage.",
	Args: cobra.NoArgs,
	RunE: runWorkbenchCleanup,
}

// cleanupFlags are the command's flags (spec §4).
type cleanupFlags struct {
	session, workbench         int64
	sweep, apply, noSize, json bool
	items, worktrees, branches []string
	liveSessions               []int64
}

var workbenchCleanupFlags cleanupFlags

func init() {
	c := workbenchCleanupCmd
	f := &workbenchCleanupFlags
	addWorkbenchIDFlag(c, &f.workbench, "workbench id: required with --sweep; the session must belong to it")
	fs := c.Flags()
	fs.Int64Var(&f.session, "session", 0, "terminal session id (default $"+terminalSessionEnv+")")
	fs.BoolVar(&f.sweep, "sweep", false, "list every worktree and branch of the workbench repository")
	fs.BoolVar(&f.apply, "apply", false, "remove what is eligible now (default: plan only, nothing written)")
	fs.StringArrayVar(&f.items, "item", nil, "item key to apply (repeatable; a sweep needs at least one)")
	fs.StringArrayVar(&f.worktrees, "worktree", nil, "a worktree root the session created (repeatable)")
	fs.StringArrayVar(&f.branches, "branch", nil, "a local branch the session created (repeatable)")
	fs.Int64SliceVar(&f.liveSessions, "live-session", nil, "a terminal session that is live in the Desktop (repeatable)")
	fs.BoolVar(&f.noSize, "no-size", false, "do not measure worktree sizes")
	fs.BoolVar(&f.json, "json", false, "output JSON")
	workbenchCmd.AddCommand(c)
}

// cleanupDeps are a cleanup's collaborators over database; tests replace
// it to fake the process scan.
var cleanupDeps = func(database *db.DB) sessioncleanup.Deps {
	return sessioncleanup.Deps{
		Git:     sessioncleanup.SystemGit{},
		DB:      sessioncleanup.DBStore{DB: database},
		Procs:   sessioncleanup.SystemProcs{},
		Sizer:   sessioncleanup.DiskSizer{},
		LS:      sessioncleanup.SystemLaunchServices{},
		Results: database,
	}
}

func runWorkbenchCleanup(cmd *cobra.Command, _ []string) error {
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return usageError("%v", err)
	}
	f := workbenchCleanupFlags
	req, err := cleanupRequest(f, cmd.Flags().Changed("session"), os.LookupEnv)
	if err != nil {
		return err
	}
	database, err := openCleanupDB(f.apply)
	if err != nil {
		return err
	}
	defer database.Close()
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	res, err := runCleanup(ctx, cleanupDeps(database), req, f)
	if err != nil {
		return err
	}
	if f.json {
		return writeJSON(cmd.OutOrStdout(), res)
	}
	printCleanupResult(cmd.OutOrStdout(), res)
	return nil
}

// cleanupBusyTimeout is how long a statement waits out another process's
// write lock.
const cleanupBusyTimeout = 5 * time.Second

// openCleanupDB opens the active workspace's database without creating the
// file or migrating it: read-only for a plan (db.OpenExisting), read-write
// only for --apply, which saves the result (db.OpenExistingRW). A schema
// without the 00111 cleanup columns is refused, so an older database fails
// clearly instead of on the first query.
func openCleanupDB(apply bool) (*db.DB, error) {
	cfg, err := loadWorkbenchCLIConfig()
	if err != nil {
		return nil, fmt.Errorf("loading config: %w", err)
	}
	open := db.OpenExisting
	if apply {
		open = db.OpenExistingRW
	}
	database, err := open(cfg.DBPath(), cleanupBusyTimeout)
	if err != nil {
		return nil, err
	}
	ok, err := database.HasColumns("terminal_sessions", "cleanup_result", "cleanup_at")
	if err == nil && ok {
		ok, err = database.HasColumns("terminal_session_worktrees", "session_id", "root", "branch", "first_at")
	}
	if err == nil && !ok {
		err = errors.New("the database predates session cleanup (migration 00111): open the Watchtower app to upgrade it")
	}
	if err != nil {
		database.Close()
		return nil, err
	}
	return database, nil
}

// cleanupRequest checks the flags and builds the request. The calling
// agent's session comes from the environment; a value there that is not a
// session id (empty and whitespace included) is a usage error, never read as
// "no caller".
func cleanupRequest(f cleanupFlags, sessionGiven bool, lookupEnv func(string) (string, bool)) (sessioncleanup.Request, error) {
	caller, err := envTerminalSession(lookupEnv)
	if err != nil {
		return sessioncleanup.Request{}, err
	}
	if err := checkCleanupFlags(f, sessionGiven); err != nil {
		return sessioncleanup.Request{}, err
	}
	if err := checkCallerScope(f, sessionGiven, caller); err != nil {
		return sessioncleanup.Request{}, err
	}
	req := sessioncleanup.Request{
		WorkbenchID: f.workbench, Sweep: f.sweep, CallerSessionID: caller, LiveSessions: f.liveSessions,
		DeclaredWorktrees: f.worktrees, DeclaredBranches: f.branches, NoSize: f.noSize,
	}
	if f.sweep {
		return req, nil
	}
	req.SessionID = caller
	if sessionGiven {
		req.SessionID = f.session
	}
	if req.SessionID <= 0 {
		return req, usageError("cleanup needs a session or --workbench with --sweep")
	}
	return req, nil
}

// envTerminalSession is $WATCHTOWER_TERMINAL_SESSION_ID; 0 only when the
// variable is absent. Present but empty, whitespace or not a positive id, it
// fails closed (a usage error): a caller session is set but unreadable, and
// reading it as "no caller" would lift the caller-scope guard (PROJ-18).
func envTerminalSession(lookupEnv func(string) (string, bool)) (int64, error) {
	raw, present := lookupEnv(terminalSessionEnv)
	if !present {
		return 0, nil
	}
	id, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || id <= 0 {
		return 0, usageError("%s=%q is set but is not a terminal session id", terminalSessionEnv, raw)
	}
	return id, nil
}

// checkCallerScope confines a caller inside an agent's terminal session
// ($WATCHTOWER_TERMINAL_SESSION_ID set — where the auto-approved allow rule
// applies, spec §4) to that same session: another --session and a sweep are
// refused; a --workbench other than the session's is refused by the plan
// (sessioncleanup.ErrWrongWorkbench). Sweeps and other sessions are the
// Desktop's, which runs the command without that variable.
func checkCallerScope(f cleanupFlags, sessionGiven bool, caller int64) error {
	switch {
	case caller == 0:
		return nil
	case f.sweep:
		return usageError("inside terminal session %d a sweep is refused: sweeps run from the Watchtower app", caller)
	case sessionGiven && f.session != caller:
		return usageError("inside terminal session %d only that session can be cleaned up, not session %d", caller, f.session)
	}
	return nil
}

// checkCleanupFlags refuses the flag combinations spec §4 does not have.
func checkCleanupFlags(f cleanupFlags, sessionGiven bool) error {
	switch {
	case f.workbench < 0 || (sessionGiven && f.session <= 0):
		return usageError("--session and --workbench take a positive id")
	case len(f.items) > 0 && !f.apply:
		return usageError("--item names what to apply: it needs --apply")
	case f.sweep:
		return checkSweepFlags(f, sessionGiven)
	}
	return nil
}

// checkSweepFlags: a sweep is of one workbench, declares nothing and
// applies only named items.
func checkSweepFlags(f cleanupFlags, sessionGiven bool) error {
	switch {
	case f.workbench == 0:
		return usageError("--sweep needs --workbench")
	case sessionGiven:
		return usageError("--sweep covers the whole workbench: drop --session")
	case len(f.worktrees)+len(f.branches) > 0:
		return usageError("--worktree and --branch declare a session's work: they do not go with --sweep")
	case f.apply && len(f.items) == 0:
		return usageError("a sweep applies only named items: pass --item")
	}
	return nil
}

// runCleanup plans, or applies with --apply; Apply saves a session's
// result itself (Deps.Results).
func runCleanup(ctx context.Context, deps sessioncleanup.Deps, req sessioncleanup.Request, f cleanupFlags) (sessioncleanup.Result, error) {
	if f.apply {
		res, err := sessioncleanup.Apply(ctx, deps, req, f.items)
		return res, cleanupFailure(err)
	}
	res, err := sessioncleanup.PlanResult(ctx, deps, req)
	return res, cleanupFailure(err)
}

// cleanupFailure is exit 1 (could not plan), or 2 for a wrong id — an
// unknown or standalone session, an unknown workbench, a session of another
// workbench — or a sweep without items. The plan checks the ids itself
// before anything is done.
func cleanupFailure(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, sessioncleanup.ErrSweepNeedsItems), errors.Is(err, sessioncleanup.ErrWrongWorkbench),
		errors.Is(err, sessioncleanup.ErrStandaloneSession), errors.Is(err, db.ErrTerminalSessionNotFound),
		errors.Is(err, db.ErrWorkbenchNotFound):
		return usageError("%v", err)
	case errors.Is(err, sessioncleanup.ErrNoGit):
		return fmt.Errorf("cleanup: no git found, nothing was planned: %w", err)
	}
	return fmt.Errorf("cleanup: %w", err)
}

// printCleanupResult prints the result as lines: a header, one line per
// item with its reason, the summary and, after a session apply, whether
// the result was saved.
func printCleanupResult(w io.Writer, r sessioncleanup.Result) {
	fmt.Fprintln(w, cleanupHeader(r))
	for _, it := range r.Items {
		fmt.Fprintln(w, "  "+cleanupItemLine(it))
	}
	fmt.Fprintln(w, r.Summary)
	if r.Mode != sessioncleanup.ModeApply || r.Sweep {
		return
	}
	if r.ResultSaved {
		fmt.Fprintln(w, "result saved on the session")
	} else {
		fmt.Fprintln(w, "result not saved: "+r.ResultError)
	}
}

func cleanupHeader(r sessioncleanup.Result) string {
	what := "Cleanup plan"
	if r.Mode == sessioncleanup.ModeApply {
		what = "Cleanup"
	}
	if r.Sweep {
		return fmt.Sprintf("%s: sweep of workbench %d", what, r.WorkbenchID)
	}
	return fmt.Sprintf("%s: session %d, workbench %d", what, r.SessionID, r.WorkbenchID)
}

// cleanupItemLine is "remove  worktree  x [feat/x] ~12 GB — reason: detail".
func cleanupItemLine(it sessioncleanup.Item) string {
	status := it.Action
	switch {
	case it.Done:
		status = "removed"
	case it.Error != "":
		status = "failed"
	}
	line := fmt.Sprintf("%-7s %-8s %s", status, it.Kind, it.Name)
	if it.Kind == sessioncleanup.KindWorktree {
		line += cleanupWorktreeExtras(it)
	}
	if it.Reason != "" {
		line += " — " + sessioncleanup.ReasonPhrase(it.Reason)
	}
	if it.Detail != "" {
		line += ": " + it.Detail
	}
	if it.Error != "" {
		line += " (error: " + it.Error + ")"
	}
	return line + cleanupOwnerText(it.Owner)
}

func cleanupWorktreeExtras(it sessioncleanup.Item) string {
	s := ""
	if it.Branch != "" {
		s += " [" + it.Branch + "]"
	}
	if it.BytesKnown {
		return s + " ~" + sessioncleanup.SizeText(it.Bytes)
	}
	return s + " (size unknown)"
}

func cleanupOwnerText(o *sessioncleanup.OwnerHint) string {
	switch {
	case o == nil:
		return ""
	case o.Unknown:
		return " (owner unknown)"
	case o.Title != "":
		return fmt.Sprintf(" (owner: session %d %q)", o.SessionID, o.Title)
	}
	return fmt.Sprintf(" (owner: session %d)", o.SessionID)
}
