package cmd

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/instructions"
	"watchtower/internal/prompts"
	"watchtower/internal/watchman"
)

var watchmanCmd = &cobra.Command{Use: "watchman", Short: "Watchman: learns how the owner decides in a workbench"}

var (
	watchmanFlagWorkbench int64
	watchmanFlagStart     bool
	watchmanFlagJSON      bool

	watchmanStatusFlagWorkbench int64
	watchmanStatusFlagJSON      bool
)

// watchmanLearnBudget caps the first learning pass `watchman learn --start`
// runs; the daemon's learner continues from the cursors to the end.
const watchmanLearnBudget = 5 * time.Minute

// Seams tests replace.
var (
	// watchmanGeneratorFactory builds the labeller's generator (light tier
	// through digest.TierForSource(watchman.label)); the owner's text goes on
	// stdin, never argv (CHAT-04).
	watchmanGeneratorFactory = func(cfg *config.Config) digest.Generator {
		return digest.WithCallTimeout(cliGenerator(cfg), digest.DaemonAICallTimeout)
	}
	watchmanGit watchman.GitRunner = watchman.ExecGit
	// watchmanDaemonRunning reads, without touching it, whether the daemon's
	// pid file names a live daemon (a live process whose identity could not
	// be read counts as running).
	watchmanDaemonRunning = func(cfg *config.Config) bool {
		_, state, err := daemon.PeekProcess(pidFilePath(cfg))
		return err == nil && (state == daemon.PeekRunning || state == daemon.PeekUnknown)
	}
	// watchmanFeedReader reads a session's chat for the owner-turn source.
	watchmanFeedReader = func(ctx context.Context, d *db.DB) instructions.FeedReader {
		return instructions.NewFeedReader(ctx, d, coachSessionDirs())
	}
	// watchmanLearnerWake wakes a running daemon's Watchman (its learner
	// and twin) when learning starts — `learn --start` and the first
	// hand-over — so the learner runs now, not at the next cycle. No
	// daemon is fine; a failure is one stderr line. Tests count it.
	watchmanLearnerWake = func(cmd *cobra.Command, cfg *config.Config) {
		if err := wakeWatchman(cfg); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "warning: the daemon was not woken to learn now (it does at its next cycle): %v\n", err)
		}
	}
)

func init() {
	learn := &cobra.Command{
		Use:   "learn",
		Short: "Show how much Watchman would learn from a workbench; --start turns it on and learns",
		Long: "Without --start it only prints the estimate: the decisions found, how many need an AI label and the tokens that costs (~). " +
			"With --start it turns Watchman on for the workbench, turns Agent analytics on there (Watchman learns from your sessions), " +
			"runs one learning pass of up to five minutes and wakes the daemon, which learns the rest in one go.",
		Args: cobra.NoArgs,
		RunE: runWatchmanLearn,
	}
	learn.Flags().Int64Var(&watchmanFlagWorkbench, "workbench", 0, "workbench id")
	learn.Flags().BoolVar(&watchmanFlagStart, "start", false, "turn Watchman on and run the first learning pass")
	learn.Flags().BoolVar(&watchmanFlagJSON, "json", false, "print JSON")
	_ = learn.MarkFlagRequired("workbench")
	status := &cobra.Command{
		Use:   "status",
		Short: "Show Watchman's state per workbench: learning, precedents, sleep window and backtest",
		Long: "Lists every workbench (or --workbench N): for one Watchman is on for, the learning progress and what it learned; " +
			"for one it is not on for, the learning estimate. A backtest that was running when its process died shows as interrupted.",
		Args: cobra.NoArgs,
		RunE: runWatchmanStatus,
	}
	status.Flags().Int64Var(&watchmanStatusFlagWorkbench, "workbench", 0, "workbench id (default: every workbench)")
	status.Flags().BoolVar(&watchmanStatusFlagJSON, "json", false, "print JSON")
	watchmanCmd.AddCommand(learn, status)
	rootCmd.AddCommand(watchmanCmd)
}

// watchmanEstimateJSON is `watchman learn --json` without --start (keys
// pinned by TestWatchmanLearn_EstimateKeysPinned).
type watchmanEstimateJSON struct {
	OK         bool  `json:"ok"`
	Workbench  int64 `json:"workbench"`
	Decisions  int   `json:"decisions"`
	NeedLabels int   `json:"need_labels"`
	Tokens     int   `json:"tokens"`
}

// watchmanLearnJSON is `watchman learn --start --json` (keys pinned by
// TestWatchmanLearn_JSONKeysPinned).
type watchmanLearnJSON struct {
	OK                bool           `json:"ok"`
	Workbench         int64          `json:"workbench"`
	Written           int            `json:"written"`
	BySource          map[string]int `json:"by_source"`
	Incomplete        bool           `json:"incomplete"`
	Unlabelled        int            `json:"unlabelled"`
	AnalyticsTurnedOn bool           `json:"analytics_turned_on"`
}

// watchmanLearnFailureJSON is `watchman learn --start --json` when the
// learning pass failed after Watchman was turned on.
type watchmanLearnFailureJSON struct {
	OK                bool   `json:"ok"`
	Workbench         int64  `json:"workbench"`
	Error             string `json:"error"`
	WatchmanOn        bool   `json:"watchman_on"`
	AnalyticsOn       bool   `json:"analytics_on"`
	AnalyticsTurnedOn bool   `json:"analytics_turned_on"`
}

func runWatchmanLearn(cmd *cobra.Command, _ []string) error {
	// Starting is the owner's verb (spec §8.2: he sees count and cost first);
	// the estimate only reads.
	if watchmanFlagStart {
		if err := refuseUnderAgent("start Watchman learning"); err != nil {
			return err
		}
	}
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	if !watchmanFlagStart {
		return watchmanPrintEstimate(cmd, cfg)
	}
	return watchmanStart(cmd, cfg)
}

func watchmanPrintEstimate(cmd *cobra.Command, cfg *config.Config) error {
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()
	est, err := watchman.Estimate(cmd.Context(), database, watchmanGit, watchmanFlagWorkbench)
	if err != nil {
		return err
	}
	if watchmanFlagJSON {
		return writeJSON(cmd.OutOrStdout(), watchmanEstimateJSON{OK: true, Workbench: watchmanFlagWorkbench,
			Decisions: est.Decisions, NeedLabels: est.NeedLabels, Tokens: est.Tokens})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Workbench %d: ~%d decisions to learn from; ~%d need an AI label (~%d tokens on the light model).\n"+
		"Run again with --start to turn Watchman on and learn.\n", watchmanFlagWorkbench, est.Decisions, est.NeedLabels, est.Tokens)
	return nil
}

func watchmanStart(cmd *cobra.Command, cfg *config.Config) error {
	ctx := cmd.Context()
	database, al, alPath, err := openAgentsDBs(cfg)
	if err != nil {
		return err
	}
	defer database.Close()
	defer al.Close()
	wb := watchmanFlagWorkbench
	turnedOn, err := watchmanTurnOn(cmd, database, al, alPath, wb, !watchmanFlagJSON)
	if err != nil {
		return err
	}
	// One learner per workbench: the daemon's learner holds the lock while
	// it learns, and then this pass is skipped. Either way the daemon is
	// woken after, so its learner goes on to the end at once.
	defer watchmanLearnerWake(cmd, cfg)
	unlock, ok, err := watchman.TryLearnLock(cfg.WorkspaceDir(), wb)
	if err != nil {
		return err
	}
	if !ok {
		nudgeDaemon(cmd, cfg)
		if watchmanFlagJSON {
			return writeJSON(cmd.OutOrStdout(), watchmanLearnJSON{OK: true, Workbench: wb, BySource: map[string]int{},
				Incomplete: true, AnalyticsTurnedOn: turnedOn})
		}
		fmt.Fprintf(cmd.OutOrStdout(), "Watchman is on for workbench %d; the daemon is learning it.\n", wb)
		return nil
	}
	sources := append(watchman.DBSources(), watchman.TurnSource(watchmanFeedReader(ctx, database)), watchman.GitSource(watchmanGit))
	st, err := watchman.Learn(ctx, database, wb, watchman.LearnOptions{
		Budget:  watchmanLearnBudget,
		Sources: sources,
		Labeler: watchman.NewLLMLabeler(watchmanGeneratorFactory(cfg), prompts.New(database, nil)),
	})
	unlock()
	nudgeDaemon(cmd, cfg)
	if err != nil {
		// Watchman and analytics stay on: the owner learns that, and the
		// daemon's cycles continue the learning from the cursors.
		if watchmanFlagJSON {
			_ = writeJSON(cmd.OutOrStdout(), watchmanLearnFailureJSON{Workbench: wb, Error: err.Error(), WatchmanOn: true,
				AnalyticsOn: true, AnalyticsTurnedOn: turnedOn})
		} else {
			fmt.Fprintf(cmd.OutOrStdout(), "Watchman and Agent analytics are on for workbench %d; the first learning pass failed "+
				"and the daemon learns it in one go.\n", wb)
		}
		return err
	}
	if watchmanFlagJSON {
		return writeJSON(cmd.OutOrStdout(), watchmanLearnJSON{OK: true, Workbench: wb, Written: st.Written, BySource: st.BySource,
			Incomplete: st.Incomplete, Unlabelled: st.Unlabelled, AnalyticsTurnedOn: turnedOn})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Watchman is on for workbench %d: learned %d decisions%s", wb, st.Written, bySourceText(st.BySource))
	if st.Unlabelled > 0 {
		fmt.Fprintf(cmd.OutOrStdout(), "; %d could not be placed in a category", st.Unlabelled)
	}
	fmt.Fprintln(cmd.OutOrStdout(), ".")
	if st.Incomplete {
		fmt.Fprintln(cmd.OutOrStdout(), "The daemon learns the rest now, in one go.")
	}
	return nil
}

// watchmanAnalyticsLine is the D21 line, said once when Watchman turns
// Agent analytics on.
const watchmanAnalyticsLine = "Agent analytics turned on — Watchman learns from your sessions"

// watchmanTurnOn turns Watchman on for workbench wb (no-op when it already
// is) and Agent analytics there; analyticsTurnedOn is whether analytics was
// off, and then the D21 line is printed when say is set. `learn --start` and
// the first arm share it; neither the estimate nor this runs a learning pass.
func watchmanTurnOn(cmd *cobra.Command, database *db.DB, al *agentlogdb.DB, alPath string, wb int64, say bool) (analyticsTurnedOn bool, err error) {
	est, err := watchman.Estimate(cmd.Context(), database, watchmanGit, wb)
	if err != nil {
		return false, err
	}
	if err := database.EnableWatchmanWorkbench(wb, time.Now(), est.Decisions); err != nil {
		return false, err
	}
	on, err := database.WorkbenchAgentAnalytics(wb)
	if err != nil || on {
		return false, err
	}
	if err := enableAgentAnalytics(cmd, database, al, alPath, wb); err != nil {
		return false, err
	}
	if say {
		fmt.Fprintln(cmd.OutOrStdout(), watchmanAnalyticsLine)
	}
	return true, nil
}

// bySourceText is " (ask 3, git 2)" sorted by source name, "" when nothing was written.
func bySourceText(m map[string]int) string {
	var parts []string
	for k, n := range m {
		if n > 0 {
			parts = append(parts, fmt.Sprintf("%s %d", k, n))
		}
	}
	if len(parts) == 0 {
		return ""
	}
	sort.Strings(parts)
	return " (" + strings.Join(parts, ", ") + ")"
}

// runWatchmanStatus is `watchman status`: it only reads (allowed under an
// agent). --json is watchman.StatusReport, the Desktop's Settings source.
func runWatchmanStatus(cmd *cobra.Command, _ []string) error {
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()
	rep, err := watchman.Status(cmd.Context(), database, watchmanStatusFlagWorkbench, watchman.StatusOptions{
		Running:       watchman.Locked(watchman.LockPath(cfg.WorkspaceDir())),
		DaemonRunning: watchmanDaemonRunning(cfg),
		Git:           watchmanGit,
	})
	if err != nil {
		return err
	}
	if watchmanStatusFlagJSON {
		return writeJSON(cmd.OutOrStdout(), rep)
	}
	out := cmd.OutOrStdout()
	if rep.Mode == watchman.ModeSleep && rep.ModeSince != nil {
		since, _ := time.Parse(time.RFC3339, *rep.ModeSince)
		fmt.Fprintf(out, "Watchman · Sleep since %s — %d handed to it\n", since.Local().Format("15:04"), len(rep.Armed))
		if !rep.DaemonRunning {
			fmt.Fprintln(out, "Watchman is not running — the daemon is stopped")
		}
	}
	for _, wb := range rep.Workbenches {
		fmt.Fprintf(out, "Workbench %d (%s): ", wb.Workbench, wb.Name)
		if wb.Learning == nil {
			if wb.Estimate == nil {
				fmt.Fprintln(out, "Watchman is off; counting its decisions took too long (a large repository).")
				continue
			}
			fmt.Fprintf(out, "Watchman is off; ~%d decisions to learn from.\n", wb.Estimate.Decisions)
			continue
		}
		if wb.Learning.Done {
			fmt.Fprintf(out, "learned %d decisions", wb.Learning.Written)
		} else {
			fmt.Fprintf(out, "learning… %d of ~%d", min(wb.Learning.Written, wb.Learning.Estimated), wb.Learning.Estimated)
		}
		fmt.Fprintln(out, bySourceText(sourceWritten(wb.Sources)))
		if wb.Learning.RelabelPending > 0 {
			fmt.Fprintf(out, "  relabelling earlier decisions: %d left\n", wb.Learning.RelabelPending)
		}
		if wb.SleepWindow != "" {
			fmt.Fprintf(out, "  Sleep window: %s\n", wb.SleepWindow)
		}
		if b := wb.Backtest; b != nil {
			fmt.Fprintf(out, "  Backtest #%d: %s", b.ID, b.Status)
			switch {
			case b.Verdict != "":
				fmt.Fprintf(out, ", verdict %s", b.Verdict)
			case b.Progress != "" && b.Status == "running":
				fmt.Fprintf(out, " (%s)", b.Progress)
			}
			fmt.Fprintln(out)
		}
	}
	return nil
}

func sourceWritten(m map[string]watchman.SourceStatus) map[string]int {
	out := make(map[string]int, len(m))
	for k, v := range m {
		out[k] = v.Written
	}
	return out
}
