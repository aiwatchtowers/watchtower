package cmd

import (
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentlog"
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
	_ = report.MarkFlagRequired("workbench")
	agentsCmd.AddCommand(report)
	rootCmd.AddCommand(agentsCmd)
}

func runAgentsEnable(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	// FEAT-03 exception (ask #153): enabling loads history at once.
	if err := database.SetWorkbenchAgentAnalytics(flagAgentsWorkbench, true); err != nil {
		return err
	}
	return printAgentsScan(cmd, database)
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
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	on, err := database.WorkbenchAgentAnalytics(flagAgentsWorkbench)
	if err != nil {
		return err
	}
	if !on {
		return errors.New("agent analytics is off for this workbench (watchtower agents enable --workbench N)")
	}
	return printAgentsScan(cmd, database)
}

func printAgentsScan(cmd *cobra.Command, database *db.DB) error {
	res, err := agentlog.Scan(cmd.Context(), database, flagAgentsWorkbench, agentlog.Options{ClaudeDir: agentsClaudeDir()})
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
	*db.AgentLogStats
}

func runAgentsStats(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	on, err := database.WorkbenchAgentAnalytics(flagAgentsWorkbench)
	if err != nil {
		return err
	}
	st, err := database.AgentLogStats(flagAgentsWorkbench)
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
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()
	if flagAgentsSession != "" {
		det, err := agentreport.BuildSession(database, flagAgentsWorkbench, flagAgentsSession)
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
	ov, err := agentreport.BuildOverview(database, flagAgentsWorkbench, since, now)
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
		reportDur(t.ModelMS), reportDur(t.Tools.BuildTest+t.Tools.Git+t.Tools.ReadSearch+t.Tools.Edit+t.Tools.MCP+t.Tools.SubagentsFG+t.Tools.Other),
		reportDur(t.BackgroundMS), reportDur(t.OwnerMS), reportDur(t.AwayMS))
}

func printReportHints(w io.Writer, hints []agentreport.Hint) {
	for _, h := range hints[:min(3, len(hints))] {
		fmt.Fprintf(w, "- %s\n", h.Finding)
	}
}
