package cmd

import (
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentlog"
	"watchtower/internal/agentlogdb"
	"watchtower/internal/agentreport"
	"watchtower/internal/db"
)

var agentsCmd = &cobra.Command{Use: "agents", Short: "Analytics of the coding-agent sessions run in a workbench"}

var (
	flagAgentsSince     string
	flagAgentsDays      int
	flagAgentsSession   string
	flagAgentsWorkbench int64
	flagAgentsJSON      bool
	// agentsClaudeDir is a test seam; ~/.claude, never CLAUDE_CONFIG_DIR.
	agentsClaudeDir = agentlog.DefaultClaudeDir
)

func init() {
	for _, c := range []*cobra.Command{
		{Use: "enable", Short: "Turn analytics on for a workbench and load its history now", RunE: runAgentsEnable},
		{Use: "disable", Short: "Turn analytics off (stored metrics stay)", RunE: runAgentsDisable},
		{Use: "scan", Short: "Read new transcript lines into the analytics tables", RunE: runAgentsScan},
		{Use: "stats", Short: "Totals for a workbench's agent sessions", RunE: runAgentsStats},
	} {
		c.Flags().Int64Var(&flagAgentsWorkbench, "workbench", 0, "workbench id")
		c.Flags().BoolVar(&flagAgentsJSON, "json", false, "print JSON")
		_ = c.MarkFlagRequired("workbench")
		agentsCmd.AddCommand(c)
	}
	report := &cobra.Command{Use: "report", Short: "Time, cost and hints for a workbench's agent sessions", RunE: runAgentsReport}
	report.Flags().Int64Var(&flagAgentsWorkbench, "workbench", 0, "workbench id")
	report.Flags().BoolVar(&flagAgentsJSON, "json", false, "print JSON")
	report.Flags().StringVar(&flagAgentsSince, "since", "", "first day of the period (YYYY-MM-DD, UTC)")
	report.Flags().IntVar(&flagAgentsDays, "days", 7, "period length in days (0 = all)")
	report.Flags().StringVar(&flagAgentsSession, "session", "", "one session's drill-down")
	report.MarkFlagsMutuallyExclusive("since", "days")
	_ = report.MarkFlagRequired("workbench")
	agentsCmd.AddCommand(report)
	rootCmd.AddCommand(agentsCmd)
}

// openAgentsDBs opens watchtower.db and the agentlog.db beside it, and
// returns agentlog.db's path. An agentlog.db that fails to open is the
// command's error: analytics never fall back to watchtower.db.
func openAgentsDBs() (*db.DB, *agentlogdb.DB, string, error) {
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return nil, nil, "", err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, "", fmt.Errorf("opening database: %w", err)
	}
	path := agentlogdb.PathFor(cfg.DBPath())
	al, err := agentlogdb.Open(path)
	if err != nil {
		database.Close()
		return nil, nil, "", err
	}
	return database, al, path, nil
}

// moveAgentLogRows runs the one-time move of the analytics rows out of
// watchtower.db (#849) for the writing agents commands, so a CLI-only
// install moves too. report and stats never call it: the Desktop polls
// report, which must neither start a copy nor write watchtower.db.
func moveAgentLogRows(cmd *cobra.Command, database *db.DB, al *agentlogdb.DB, path string) error {
	if err := agentlogdb.MoveFromMain(cmd.Context(), database, al, agentlogdb.MoveLockPath(path)); err != nil {
		return fmt.Errorf("moving agent analytics out of watchtower.db: %w", err)
	}
	return nil
}

func runAgentsEnable(cmd *cobra.Command, _ []string) error {
	database, al, path, err := openAgentsDBs()
	if err != nil {
		return err
	}
	defer database.Close()
	defer al.Close()
	// FEAT-03 exception (ask #153): enabling loads history at once.
	if err := database.SetWorkbenchAgentAnalytics(flagAgentsWorkbench, true); err != nil {
		return err
	}
	if err := moveAgentLogRows(cmd, database, al, path); err != nil {
		return err
	}
	return printAgentsScan(cmd, database, al)
}

func runAgentsDisable(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	if err := database.SetWorkbenchAgentAnalytics(flagAgentsWorkbench, false); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Agent analytics is off for workbench %d; stored metrics stay.\n", flagAgentsWorkbench)
	return nil
}

func runAgentsScan(cmd *cobra.Command, _ []string) error {
	database, al, path, err := openAgentsDBs()
	if err != nil {
		return err
	}
	defer database.Close()
	defer al.Close()
	on, err := database.WorkbenchAgentAnalytics(flagAgentsWorkbench)
	if err != nil {
		return err
	}
	if !on {
		return errors.New("agent analytics is off for this workbench (watchtower agents enable --workbench N)")
	}
	if err := moveAgentLogRows(cmd, database, al, path); err != nil {
		return err
	}
	return printAgentsScan(cmd, database, al)
}

func printAgentsScan(cmd *cobra.Command, database *db.DB, al *agentlogdb.DB) error {
	res, err := agentlog.Scan(cmd.Context(), database, al, flagAgentsWorkbench, agentlog.Options{ClaudeDir: agentsClaudeDir()})
	if err != nil {
		return err
	}
	if flagAgentsJSON {
		return writeJSON(cmd.OutOrStdout(), res)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "%d sessions, %d files read, %d unchanged, %d events written",
		res.Sessions, res.FilesScanned, res.FilesSkipped, res.EventsWritten)
	if n := len(res.UnknownRecords); n > 0 {
		fmt.Fprintf(cmd.OutOrStdout(), ", %d unknown record types", n)
	}
	if res.FailedFiles > 0 {
		fmt.Fprintf(cmd.OutOrStdout(), ", %d files failed (retried next scan)", res.FailedFiles)
	}
	fmt.Fprintln(cmd.OutOrStdout())
	return nil
}

type agentsStatsJSON struct {
	WorkbenchID int64 `json:"workbench_id"`
	Enabled     bool  `json:"enabled"`
	*agentlogdb.AgentLogStats
}

func runAgentsStats(cmd *cobra.Command, _ []string) error {
	database, al, _, err := openAgentsDBs()
	if err != nil {
		return err
	}
	defer database.Close()
	defer al.Close()
	on, err := database.WorkbenchAgentAnalytics(flagAgentsWorkbench)
	if err != nil {
		return err
	}
	st, err := al.AgentLogStats(flagAgentsWorkbench)
	if err != nil {
		return err
	}
	if flagAgentsJSON {
		return writeJSON(cmd.OutOrStdout(), agentsStatsJSON{WorkbenchID: flagAgentsWorkbench, Enabled: on, AgentLogStats: st})
	}
	fmt.Fprintf(cmd.OutOrStdout(), "%d sessions · $%.2f (Claude Code reports $%.2f) · %d owner turns\n",
		st.Sessions, st.CostUSD, st.ReportedCostUSD, st.OwnerTurns)
	return nil
}

func runAgentsReport(cmd *cobra.Command, _ []string) error {
	now := time.Now().UTC()
	var since time.Time
	switch {
	case flagAgentsSince != "":
		d, err := time.Parse("2006-01-02", flagAgentsSince)
		if err != nil {
			return fmt.Errorf("--since must be YYYY-MM-DD: %w", err)
		}
		since = d
	case flagAgentsDays < 0:
		return errors.New("--days must not be negative")
	case flagAgentsDays > 0:
		since = now.AddDate(0, 0, -flagAgentsDays)
	}
	database, al, _, err := openAgentsDBs()
	if err != nil {
		return err
	}
	defer database.Close()
	defer al.Close()
	out := cmd.OutOrStdout()
	if flagAgentsSession != "" {
		det, err := agentreport.BuildSession(database, al, flagAgentsWorkbench, flagAgentsSession, now)
		if err != nil {
			return err
		}
		if flagAgentsJSON {
			return writeJSON(out, det)
		}
		fmt.Fprintf(out, "%s · $%.2f · active %s\n", det.Session.UUID, det.Session.CostUSD, reportDur(det.Time.ActiveMS))
		printReportTime(out, det.Time)
		printReportHints(out, det.Hints)
		return nil
	}
	ov, err := agentreport.BuildOverview(database, al, flagAgentsWorkbench, since, now)
	if err != nil {
		return err
	}
	if flagAgentsJSON {
		return writeJSON(out, ov)
	}
	fmt.Fprintf(out, "%d sessions · $%.2f · active %s · away %s\n", ov.Totals.Sessions, ov.Totals.CostUSD,
		reportDur(ov.Totals.ActiveMS), reportDur(ov.Totals.AwayMS))
	printReportTime(out, ov.Time)
	printReportHints(out, ov.Hints)
	return nil
}

func reportDur(ms int64) string {
	return (time.Duration(ms) * time.Millisecond).Round(time.Second).String()
}

func printReportTime(w io.Writer, t agentreport.TimeSplit) {
	fmt.Fprintf(w, "model %s · tools %s · background %s · owner %s · away %s\n",
		reportDur(t.ModelMS), reportDur(t.Tools.Total()),
		reportDur(t.BackgroundMS), reportDur(t.OwnerMS), reportDur(t.AwayMS))
}

func printReportHints(w io.Writer, hints []agentreport.Hint) {
	for _, h := range hints[:min(3, len(hints))] {
		fmt.Fprintf(w, "- %s\n", h.Finding)
	}
}
