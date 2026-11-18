package cmd

import (
	"database/sql"
	"errors"
	"fmt"
	"slices"
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
// verbs, so arming, the sidecar and (Task 6) the hooks have one
// implementation.

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
// ProtectionWarning is filled by the branch-protection check (Task 6).
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
	// "Sleep since".
	existing, err := database.ListWatchmanArming()
	if err != nil {
		return err
	}
	now := time.Now()
	changed := false
	for _, r := range rows {
		if slices.ContainsFunc(existing, func(a db.WatchmanArming) bool { return a.Scope == r.Scope && a.RefID == r.RefID }) {
			continue
		}
		r.ArmedAt, r.ArmedBy = now, "cli"
		if err := database.UpsertWatchmanArming(r); err != nil {
			return err
		}
		changed = true
	}
	arming, err := watchmanact.RefreshSidecar(cmd.Context(), cfg.WorkspaceDir(), database)
	out.Armed = watchman.ArmedEntries(arming)
	if err != nil {
		if arming == nil {
			if arming, err = database.ListWatchmanArming(); err != nil {
				return err
			}
			out.Armed = watchman.ArmedEntries(arming)
		}
		out.SidecarError = err.Error()
	}
	// The daemon's upkeep takes the hold and its learning phase does the
	// backfill; arm never runs either.
	if changed || out.LearningStarted {
		watchmanArmingNudge(cmd, cfg)
	}
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
// then rewrites the sidecar.
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
	if changed > 0 {
		watchmanArmingNudge(cmd, cfg)
	}
	return nil
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
