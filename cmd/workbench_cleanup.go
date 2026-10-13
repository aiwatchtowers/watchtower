package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

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
		"in-use or someone else's work (PROJ-16). --apply evaluates afresh and removes what is\n" +
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
	req, err := cleanupRequest(f, cmd.Flags().Changed("session"), os.Getenv)
	if err != nil {
		return err
	}
	_, database, err := openJiraCmdDB()
	if err != nil {
		return err
	}
	defer database.Close()
	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	deps := cleanupDeps(database)
	if err := resolveCleanupScope(ctx, deps.DB, &req); err != nil {
		return err
	}
	res, err := runCleanup(ctx, deps, req, f)
	if err != nil {
		return err
	}
	if f.json {
		return writeJSON(cmd.OutOrStdout(), res)
	}
	printCleanupResult(cmd.OutOrStdout(), res)
	return nil
}

// cleanupRequest checks the flags and builds the request. The calling
// agent's session comes from the environment; a value there that is not a
// session id is a usage error, never read as "no caller".
func cleanupRequest(f cleanupFlags, sessionGiven bool, getenv func(string) string) (sessioncleanup.Request, error) {
	caller, err := envTerminalSession(getenv)
	if err != nil {
		return sessioncleanup.Request{}, err
	}
	if err := checkCleanupFlags(f, sessionGiven); err != nil {
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

// envTerminalSession is $WATCHTOWER_TERMINAL_SESSION_ID; 0 when unset.
func envTerminalSession(getenv func(string) string) (int64, error) {
	raw := strings.TrimSpace(getenv(terminalSessionEnv))
	if raw == "" {
		return 0, nil
	}
	id, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || id <= 0 {
		return 0, usageError("%s=%q is not a terminal session id", terminalSessionEnv, raw)
	}
	return id, nil
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

// resolveCleanupScope checks the session (or the swept workbench) exists
// and, when both are given, that the session belongs to the workbench; it
// fills in the session's workbench. A wrong id is a usage error.
func resolveCleanupScope(ctx context.Context, store sessioncleanup.Store, req *sessioncleanup.Request) error {
	if req.Sweep {
		_, err := store.WorkbenchFolder(ctx, req.WorkbenchID)
		if errors.Is(err, db.ErrWorkbenchNotFound) {
			return usageError("%v", err)
		}
		return err
	}
	s, err := store.CleanupSession(ctx, req.SessionID)
	if errors.Is(err, db.ErrTerminalSessionNotFound) || errors.Is(err, sessioncleanup.ErrStandaloneSession) {
		return usageError("session %d: %v", req.SessionID, err)
	}
	if err != nil {
		return err
	}
	if req.WorkbenchID != 0 && s.WorkbenchID != req.WorkbenchID {
		return usageError("session %d belongs to workbench %d, not %d", req.SessionID, s.WorkbenchID, req.WorkbenchID)
	}
	req.WorkbenchID = s.WorkbenchID
	return nil
}

// runCleanup plans, or applies with --apply; Apply saves a session's
// result itself (Deps.Results).
func runCleanup(ctx context.Context, deps sessioncleanup.Deps, req sessioncleanup.Request, f cleanupFlags) (sessioncleanup.Result, error) {
	if f.apply {
		res, err := sessioncleanup.Apply(ctx, deps, req, f.items)
		return res, cleanupFailure(err)
	}
	p, err := sessioncleanup.Build(ctx, deps, req)
	if err != nil {
		return sessioncleanup.Result{}, cleanupFailure(err)
	}
	if p.Items == nil {
		p.Items = []sessioncleanup.Item{}
	}
	return sessioncleanup.Result{
		SessionID: req.SessionID, WorkbenchID: req.WorkbenchID, Mode: sessioncleanup.ModePlan, Sweep: req.Sweep,
		Plan: p, RemovedBytesKnown: true, Summary: sessioncleanup.Summarize(p.Items),
	}, nil
}

// cleanupFailure is exit 1 (could not plan), or 2 for a sweep without
// items.
func cleanupFailure(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, sessioncleanup.ErrSweepNeedsItems):
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
