package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os/exec"
	"slices"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/watchman"
	"watchtower/internal/watchmanact"
)

// Arming is the delegation (spec 2026-11-16-watchman-design §2, D47): an
// armed session, or every session under an armed target, is decided by the
// twin until the owner takes it back. The Desktop arms only through these
// verbs, so arming, the sidecar and the git hooks have one implementation.

var (
	watchmanArmFlagSession    int64
	watchmanArmFlagTarget     int64
	watchmanArmFlagAllRunning bool
	watchmanArmFlagCheck      bool
	watchmanArmFlagJSON       bool

	watchmanDisarmFlagSession int64
	watchmanDisarmFlagTarget  int64
	watchmanDisarmFlagAll     bool
	watchmanDisarmFlagJSON    bool
)

func init() {
	arm := &cobra.Command{
		Use:   "arm",
		Short: "Hand a session, a target's sessions or every running session to Watchman",
		Long: "Hands --session N, --target N (every session under it) or --all-running to Watchman: it decides for them " +
			"until you take them back with `watchman disarm`. The first time on a workbench it turns Watchman and Agent " +
			"analytics on there and the daemon learns the workbench. --check writes nothing and says whether this is the " +
			"first time, with the learning estimate.",
		Args: cobra.NoArgs,
		RunE: runWatchmanArm,
	}
	arm.Flags().Int64Var(&watchmanArmFlagSession, "session", 0, "terminal session id")
	arm.Flags().Int64Var(&watchmanArmFlagTarget, "target", 0, "target id (every session under it)")
	arm.Flags().BoolVar(&watchmanArmFlagAllRunning, "all-running", false, "every running workbench agent session")
	arm.Flags().BoolVar(&watchmanArmFlagCheck, "check", false, "write nothing; report first_time and the learning estimate")
	arm.Flags().BoolVar(&watchmanArmFlagJSON, "json", false, "print JSON")
	disarm := &cobra.Command{
		Use:   "disarm",
		Short: "Take a session, a target or everything back from Watchman",
		Args:  cobra.NoArgs,
		RunE:  runWatchmanDisarm,
	}
	disarm.Flags().Int64Var(&watchmanDisarmFlagSession, "session", 0, "terminal session id")
	disarm.Flags().Int64Var(&watchmanDisarmFlagTarget, "target", 0, "target id")
	disarm.Flags().BoolVar(&watchmanDisarmFlagAll, "all", false, "everything handed to Watchman")
	disarm.Flags().BoolVar(&watchmanDisarmFlagJSON, "json", false, "print JSON")
	watchmanCmd.AddCommand(arm, disarm)
}

// watchmanArmJSON is `watchman arm --json` (keys pinned by
// TestWatchmanArm_JSONKeysPinned; the Desktop's arm sheet reads it).
// ProtectionWarning is the branch-protection check's warning ("" = none).
type watchmanArmJSON struct {
	OK                bool                     `json:"ok"`
	Armed             []watchman.ArmedEntry    `json:"armed"`
	ProtectionWarning string                   `json:"protection_warning"`
	FirstTime         bool                     `json:"first_time"`
	AnalyticsTurnedOn bool                     `json:"analytics_turned_on"`
	LearningStarted   bool                     `json:"learning_started"`
	Estimate          *watchman.EstimateStatus `json:"estimate"`
	Error             string                   `json:"error"`
	// SidecarError: the rows were written (ok stays true) but the sidecar
	// rewrite failed; the daemon's upkeep rewrites it next cycle.
	SidecarError string `json:"sidecar_error"`
	// HooksWarning: one line per repository whose layout (a shared
	// core.worktree or core.bare) the git guard cannot be installed in.
	HooksWarning string `json:"hooks_warning"`
}

// watchmanDisarmJSON is `watchman disarm --json`.
type watchmanDisarmJSON struct {
	OK           bool                  `json:"ok"`
	Armed        []watchman.ArmedEntry `json:"armed"`
	Error        string                `json:"error"`
	SidecarError string                `json:"sidecar_error"` // as on arm
}

// watchmanArmingNudge asks a running daemon for a cycle after an arming
// change, so its upkeep takes or releases the keep-awake hold and rewrites
// the sidecar now rather than at the next poll (accepted cost: a cycle
// already fetching restarts its fetches). No daemon is fine. Tests count it.
var watchmanArmingNudge = func(cmd *cobra.Command, cfg *config.Config) {
	if _, err := signalSyncNow(cfg); err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: the daemon was not asked to pick the change up now (it does at its next cycle): %v\n", err)
	}
}

// watchmanProtectionRun runs gh for the branch-protection check: stdout,
// also on a failure (where gh puts an API error's body). cmd tests stub it
// (TestMain); a test that wants a fake gh on PATH puts execCommandOutput back.
var watchmanProtectionRun = execCommandOutput

// execCommandOutput runs name args… in dir and returns its stdout.
func execCommandOutput(ctx context.Context, dir, name string, args ...string) ([]byte, error) {
	c := exec.CommandContext(ctx, name, args...) // #nosec G204 -- fixed binary (gh), explicit args
	c.Dir = dir
	return c.Output()
}

// watchmanProtectionBudget bounds the branch-protection check's gh calls.
const watchmanProtectionBudget = 15 * time.Second

// watchmanProtectionWarning checks each workbench repository's default
// branch protection (spec §5 item 2) and returns the first warning; ""
// when every one needs an approving review to merge.
func watchmanProtectionWarning(ctx context.Context, database *db.DB, workbenches []int64) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, watchmanProtectionBudget)
	defer cancel()
	for _, id := range workbenches {
		wb, err := database.GetWorkbench(id)
		if err != nil {
			return "", fmt.Errorf("reading workbench %d: %w", id, err)
		}
		if w := watchmanact.CheckProtection(ctx, watchmanProtectionRun, wb.FolderPath).Warning; w != "" {
			return w, nil
		}
	}
	return "", nil
}

// addLine appends line to the newline-joined text unless it is there.
func addLine(text *string, line string) {
	if slices.Contains(strings.Split(*text, "\n"), line) {
		return
	}
	if *text != "" {
		*text += "\n"
	}
	*text += line
}

// watchmanGuardWarnings adds to text the repositories of the workbenches
// whose layout the git guard cannot be installed in; a folder that is no
// git repository has nothing to warn about here.
func watchmanGuardWarnings(ctx context.Context, database *db.DB, workbenches []int64, text *string) error {
	for _, id := range workbenches {
		wb, err := database.GetWorkbench(id)
		if err != nil {
			return fmt.Errorf("reading workbench %d: %w", id, err)
		}
		var unsupported *watchmanact.GuardUnsupportedError
		if err := watchmanact.CheckGuardLayout(ctx, wb.FolderPath); errors.As(err, &unsupported) {
			addLine(text, unsupported.Error())
		}
	}
	return nil
}

// watchmanEnsureHooks gives every armed session's worktree Watchman's git
// hooks (spec §5 item 1). A repository the guard cannot be installed in
// goes to text; any other failure is a warning on stderr: the daemon's
// upkeep installs the hooks again each cycle.
func watchmanEnsureHooks(cmd *cobra.Command, workspace string, database *db.DB, text *string) {
	sessions, err := database.WatchmanArmedSessions()
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: the git hooks were not installed (the daemon installs them at its next cycle): %v\n", err)
		return
	}
	done := map[string]bool{}
	for _, s := range sessions {
		if done[s.Folder] {
			continue
		}
		done[s.Folder] = true
		err := watchmanact.EnsureHooks(cmd.Context(), s.Folder, workspace)
		var unsupported *watchmanact.GuardUnsupportedError
		switch {
		case errors.As(err, &unsupported):
			addLine(text, unsupported.Error())
		case err != nil:
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: the git hooks for session %d were not installed (the daemon installs them at its next cycle): %v\n", s.SessionID, err)
		}
	}
}

// watchmanArmedRoots is the canonical worktree roots of the armed sessions
// (watchmanact.WorktreeRoot, the key the hooks are installed under), so two
// sessions on one worktree by different paths count as one. A folder that
// is no git worktree has no hooks and is left out.
func watchmanArmedRoots(ctx context.Context, database *db.DB) (map[string]bool, error) {
	sessions, err := database.WatchmanArmedSessions()
	if err != nil {
		return nil, err
	}
	roots := map[string]bool{}
	for _, s := range sessions {
		if root, err := watchmanact.WorktreeRoot(ctx, s.Folder); err == nil {
			roots[root] = true
		}
	}
	return roots, nil
}

// sidecarWarning is the text form of a failed sidecar rewrite.
func sidecarWarning(cmd *cobra.Command, sidecarErr string) {
	if sidecarErr != "" {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: the arm sidecar was not rewritten (the daemon rewrites it at its next cycle): %s\n", sidecarErr)
	}
}

// exactlyOne is whether exactly one of the choices is set.
func exactlyOne(set ...bool) bool {
	n := 0
	for _, s := range set {
		if s {
			n++
		}
	}
	return n == 1
}

func runWatchmanArm(cmd *cobra.Command, _ []string) error {
	out := watchmanArmJSON{Armed: []watchman.ArmedEntry{}}
	err := watchmanArm(cmd, &out)
	out.OK = err == nil
	if err != nil {
		out.Error = err.Error()
	}
	if watchmanArmFlagJSON {
		if werr := writeJSON(cmd.OutOrStdout(), out); werr != nil && err == nil {
			err = werr
		}
		return err
	}
	if err != nil {
		return err
	}
	sidecarWarning(cmd, out.SidecarError)
	w := cmd.OutOrStdout()
	for _, warning := range []string{out.ProtectionWarning, out.HooksWarning} {
		if warning != "" {
			defer fmt.Fprintln(w, warning)
		}
	}
	if watchmanArmFlagCheck {
		if out.Estimate != nil {
			fmt.Fprintf(w, "The first time on this workbench: Watchman learns ~%d decisions first (~%d tokens on the light model).\n",
				out.Estimate.Decisions, out.Estimate.Tokens)
		} else {
			fmt.Fprintln(w, "Ready to hand to Watchman.")
		}
		return nil
	}
	fmt.Fprintf(w, "Handed to Watchman: %s.\n", armedText(out.Armed))
	if out.LearningStarted {
		fmt.Fprintln(w, "Watchman is learning this workbench; the daemon continues in its cycles.")
	}
	return nil
}

// armedText is "session 7, target 3".
func armedText(armed []watchman.ArmedEntry) string {
	s := ""
	for i, a := range armed {
		if i > 0 {
			s += ", "
		}
		s += fmt.Sprintf("%s %d", a.Scope, a.ID)
	}
	return s
}

// watchmanArm arms what the flags name, or with --check only reports.
// First the workbenches it is the first time on get Watchman and Agent
// analytics, then the arming rows are written, then the sidecar is
// rewritten from the database.
func watchmanArm(cmd *cobra.Command, out *watchmanArmJSON) error {
	if !watchmanArmFlagCheck {
		if err := refuseUnderAgent("hand a session to Watchman"); err != nil {
			return err
		}
	}
	if !exactlyOne(watchmanArmFlagSession != 0, watchmanArmFlagTarget != 0, watchmanArmFlagAllRunning) {
		return errors.New("name exactly one of --session N, --target N or --all-running")
	}
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	// --check only reads: it never creates or migrates the database.
	open := db.Open
	if watchmanArmFlagCheck {
		open = func(path string) (*db.DB, error) { return db.OpenExisting(path, watchmanCheckBusy) }
	}
	database, err := open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()
	rows, workbenches, err := watchmanArmRows(database)
	if err != nil {
		return err
	}
	var first []int64 // workbenches Watchman is not on for or has not learned
	var notOn []int64 // of those, the ones it is not on for
	for _, wb := range workbenches {
		state, err := database.WatchmanWorkbench(wb)
		if err != nil {
			return err
		}
		if state == nil || state.LearnedThrough == nil {
			first = append(first, wb)
		}
		if state == nil {
			notOn = append(notOn, wb)
		}
	}
	out.FirstTime = len(first) > 0
	if out.ProtectionWarning, err = watchmanProtectionWarning(cmd.Context(), database, workbenches); err != nil {
		return err
	}
	if err := watchmanGuardWarnings(cmd.Context(), database, workbenches, &out.HooksWarning); err != nil {
		return err
	}

	if watchmanArmFlagCheck {
		if out.FirstTime {
			est := &watchman.EstimateStatus{}
			for _, wb := range first {
				e, err := watchman.Estimate(cmd.Context(), database, watchmanGit, wb)
				if err != nil {
					return err
				}
				est.Decisions += e.Decisions
				est.NeedLabels += e.NeedLabels
				est.Tokens += e.Tokens
			}
			out.Estimate = est
		}
		arming, err := database.ListWatchmanArming()
		if err != nil {
			return err
		}
		out.Armed = watchman.ArmedEntries(arming)
		return nil
	}

	if out.FirstTime {
		turned, err := watchmanTurnOnAll(cmd, cfg, database, first)
		out.AnalyticsTurnedOn = turned
		if err != nil {
			return err
		}
		out.LearningStarted = len(notOn) > 0
	}
	// A row already there keeps its armed_at: re-arming does not move
	// "Sleep since" (one INSERT … DO NOTHING, so no check-then-write race).
	now := time.Now()
	changed := false
	for _, r := range rows {
		r.ArmedAt, r.ArmedBy = now, "cli"
		inserted, err := database.ArmWatchman(r)
		if err != nil {
			return err
		}
		changed = changed || inserted
	}
	// The daemon's upkeep takes the hold and its learning phase does the
	// backfill; arm never runs either.
	if changed || out.LearningStarted {
		defer watchmanArmingNudge(cmd, cfg)
	}
	arming, refreshErr := watchmanact.RefreshSidecar(cmd.Context(), cfg.WorkspaceDir(), database)
	if refreshErr != nil {
		out.SidecarError = refreshErr.Error()
		if arming == nil {
			if arming, err = database.ListWatchmanArming(); err != nil {
				return err
			}
		}
	}
	out.Armed = watchman.ArmedEntries(arming)
	watchmanEnsureHooks(cmd, cfg.WorkspaceDir(), database, &out.HooksWarning)
	return nil
}

// watchmanCheckBusy bounds how long `arm --check` waits for another
// process's lock on the read-only database.
const watchmanCheckBusy = 2 * time.Second

// watchmanArmRows resolves the flags to the arming rows to write and the
// workbenches they cover. Only a running workbench agent session (not a
// shell) or a workbench target can be armed.
func watchmanArmRows(database *db.DB) ([]db.WatchmanArming, []int64, error) {
	if watchmanArmFlagTarget != 0 {
		wb, err := database.WatchmanTargetWorkbench(watchmanArmFlagTarget)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil, fmt.Errorf("there is no target %d", watchmanArmFlagTarget)
		}
		if err != nil {
			return nil, nil, err
		}
		if wb == 0 {
			return nil, nil, fmt.Errorf("target %d is not on a workbench", watchmanArmFlagTarget)
		}
		return []db.WatchmanArming{{Scope: "target", RefID: watchmanArmFlagTarget}}, []int64{wb}, nil
	}
	live, err := database.WatchmanLiveSessions()
	if err != nil {
		return nil, nil, err
	}
	var rows []db.WatchmanArming
	var wbs []int64
	for _, s := range live {
		if !watchmanArmFlagAllRunning && s.SessionID != watchmanArmFlagSession {
			continue
		}
		rows = append(rows, db.WatchmanArming{Scope: "session", RefID: s.SessionID})
		if !slices.Contains(wbs, s.WorkbenchID) {
			wbs = append(wbs, s.WorkbenchID)
		}
	}
	switch {
	case len(rows) > 0:
		return rows, wbs, nil
	case watchmanArmFlagAllRunning:
		return nil, nil, errors.New("no running workbench agent session to hand to Watchman")
	default:
		return nil, nil, fmt.Errorf("session %d is not a running workbench agent session", watchmanArmFlagSession)
	}
}

// watchmanTurnOnAll turns Watchman and Agent analytics on for each
// workbench, through the code `learn --start` uses; turned is whether
// analytics was turned on anywhere (the D21 line is said once).
func watchmanTurnOnAll(cmd *cobra.Command, cfg *config.Config, database *db.DB, workbenches []int64) (turned bool, err error) {
	al, err := agentlogdb.Open(agentlogdb.PathFor(cfg.DBPath()))
	if err != nil {
		return false, err
	}
	defer al.Close()
	for _, wb := range workbenches {
		t, err := watchmanTurnOn(cmd, database, al, agentlogdb.PathFor(cfg.DBPath()), wb, !watchmanArmFlagJSON && !turned)
		turned = turned || t
		if err != nil {
			return turned, err
		}
	}
	return turned, nil
}

func runWatchmanDisarm(cmd *cobra.Command, _ []string) error {
	out := watchmanDisarmJSON{Armed: []watchman.ArmedEntry{}}
	err := watchmanDisarm(cmd, &out)
	out.OK = err == nil
	if err != nil {
		out.Error = err.Error()
	}
	if watchmanDisarmFlagJSON {
		if werr := writeJSON(cmd.OutOrStdout(), out); werr != nil && err == nil {
			err = werr
		}
		return err
	}
	if err != nil {
		return err
	}
	sidecarWarning(cmd, out.SidecarError)
	if len(out.Armed) == 0 {
		fmt.Fprintln(cmd.OutOrStdout(), "Taken back: Watchman has nothing now.")
	} else {
		fmt.Fprintf(cmd.OutOrStdout(), "Taken back. Watchman still has: %s.\n", armedText(out.Armed))
	}
	return nil
}

// watchmanDisarm removes the named arming row (or every row with --all),
// rewrites the sidecar, and gives the worktrees no longer armed their
// previous git hooks back (a failure is a warning: the hooks pass through
// while not armed).
func watchmanDisarm(cmd *cobra.Command, out *watchmanDisarmJSON) error {
	if err := refuseUnderAgent("take a session back from Watchman"); err != nil {
		return err
	}
	if !exactlyOne(watchmanDisarmFlagSession != 0, watchmanDisarmFlagTarget != 0, watchmanDisarmFlagAll) {
		return errors.New("name exactly one of --session N, --target N or --all")
	}
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()
	armedBefore, err := watchmanArmedRoots(cmd.Context(), database)
	if err != nil {
		return err
	}
	changed := int64(1) // disarmOne fails when there was no row
	switch {
	case watchmanDisarmFlagAll:
		changed, err = database.ClearWatchmanArming()
	case watchmanDisarmFlagSession != 0:
		err = disarmOne(database, "session", watchmanDisarmFlagSession)
	default:
		err = disarmOne(database, "target", watchmanDisarmFlagTarget)
	}
	if err != nil {
		return err
	}
	arming, err := watchmanact.RefreshSidecar(cmd.Context(), cfg.WorkspaceDir(), database)
	if err != nil {
		out.SidecarError = err.Error()
		if arming == nil {
			if arming, err = database.ListWatchmanArming(); err != nil {
				return err
			}
		}
	}
	out.Armed = watchman.ArmedEntries(arming)
	watchmanRestoreHooks(cmd, cfg.WorkspaceDir(), database, armedBefore)
	if changed > 0 {
		watchmanArmingNudge(cmd, cfg)
	}
	return nil
}

// watchmanRestoreHooks restores the git hooks of the worktree roots armed
// before the disarm and not after it (canonical roots, so a session still
// armed on the same worktree by another path keeps its guard).
func watchmanRestoreHooks(cmd *cobra.Command, workspace string, database *db.DB, armedBefore map[string]bool) {
	armedNow, err := watchmanArmedRoots(cmd.Context(), database)
	if err != nil {
		fmt.Fprintf(cmd.ErrOrStderr(), "warning: the git hooks were not restored (they pass through while not armed): %v\n", err)
		return
	}
	roots := make([]string, 0, len(armedBefore))
	for root := range armedBefore {
		if !armedNow[root] {
			roots = append(roots, root)
		}
	}
	slices.Sort(roots)
	for _, f := range roots {
		if err := watchmanact.RestoreHooks(cmd.Context(), f, workspace); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: the git hooks of %s were not restored (they pass through while not armed): %v\n", f, err)
		}
	}
}

func disarmOne(database *db.DB, scope string, id int64) error {
	ok, err := database.DeleteWatchmanArming(scope, id)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("%s %d was not handed to Watchman", scope, id)
	}
	return nil
}
