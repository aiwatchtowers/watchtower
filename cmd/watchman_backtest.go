package cmd

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/prompts"
	"watchtower/internal/watchman"
)

var (
	watchmanBacktestFlagWorkbench int64
	watchmanBacktestFlagJSON      bool
)

// watchmanBacktestExe names the binary the daemon's weekly backtest child
// runs; tests replace it.
var watchmanBacktestExe = os.Executable

// LaunchWatchmanBacktest starts `<exe> watchman backtest --workbench N` as a
// detached child in its own session (the specreview launcher's pattern: no
// agent markers, output appended to <logDir>/watchman-backtest.log) and does
// not wait for it; it is reaped in the background.
func LaunchWatchmanBacktest(exe string, workbenchID int64, logDir string) error {
	if err := os.MkdirAll(logDir, 0o700); err != nil {
		return fmt.Errorf("creating log dir: %w", err)
	}
	logFile, err := os.OpenFile(filepath.Join(logDir, "watchman-backtest.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("opening watchman-backtest log: %w", err)
	}
	defer logFile.Close()
	c := exec.Command(exe, "watchman", "backtest", "--workbench", strconv.FormatInt(workbenchID, 10))
	c.Stdout, c.Stderr = logFile, logFile
	c.Env = envWithoutAgentMarkers(os.Environ())
	c.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := c.Start(); err != nil {
		return fmt.Errorf("starting the backtest: %w", err)
	}
	go func() { _ = c.Wait() }()
	return nil
}

func init() {
	backtest := &cobra.Command{
		Use:   "backtest",
		Short: "Measure how often Watchman decides like you: re-decide your newest 30 decisions per category, hidden from it",
		Long: "For each category Watchman hides your newest 30 decisions and decides them again from what came before. " +
			"A category is strong at 80 % agreement or more with at most 5 % wrong answers it was sure of; " +
			"fewer than 30 decisions is not measured (no AI call). The verdict is go when 3 categories are strong, " +
			"permission or review_code among them. Review approvals and hunk undos are not measured in phase 1. " +
			"Each decision is one strong-model call (plus a light-model judge for free answers), so a full run costs " +
			"real money (the cost shown is an estimate); the daemon reruns it weekly in the background.",
		Args: cobra.NoArgs,
		RunE: runWatchmanBacktest,
	}
	backtest.Flags().Int64Var(&watchmanBacktestFlagWorkbench, "workbench", 0, "workbench id")
	backtest.Flags().BoolVar(&watchmanBacktestFlagJSON, "json", false, "print JSON")
	_ = backtest.MarkFlagRequired("workbench")
	watchmanCmd.AddCommand(backtest)
}

// watchmanBacktestJSON is `watchman backtest --json` (keys pinned by
// TestWatchmanBacktest_JSONKeysPinned). A failed run prints the same object
// with ok false, status failed and its error; the finished categories are
// kept.
type watchmanBacktestJSON struct {
	OK         bool                      `json:"ok"`
	Workbench  int64                     `json:"workbench"`
	BacktestID int64                     `json:"backtest_id"`
	Status     string                    `json:"status"`
	Verdict    string                    `json:"verdict"`
	CostUSD    float64                   `json:"cost_usd"`
	Categories []watchmanBacktestRowJSON `json:"categories"`
	Error      string                    `json:"error,omitempty"`
}

type watchmanBacktestRowJSON struct {
	Category  string  `json:"category"`
	Total     int     `json:"total"`
	Agree     int     `json:"agree"`
	WrongHigh int     `json:"wrong_high"`
	CostUSD   float64 `json:"cost_usd"`
	Status    string  `json:"status"`
}

// watchmanBacktestNotMeasuredNote names what the phase-1 backtest leaves out
// (their situations give the answer away, or they are never anything else).
const watchmanBacktestNotMeasuredNote = "Review approvals and hunk undos are not measured in phase 1."

func runWatchmanBacktest(cmd *cobra.Command, _ []string) error {
	// Spending on strong-model calls is the owner's verb.
	if err := refuseUnderAgent("run a Watchman backtest"); err != nil {
		return err
	}
	cfg, err := workspaceConfigFromFlags()
	if err != nil {
		return err
	}
	database, err := openWatchmanDB()
	if err != nil {
		return err
	}
	defer database.Close()
	wb := watchmanBacktestFlagWorkbench
	if _, err := database.GetWorkbench(wb); err != nil {
		return err
	}
	gen := watchmanGeneratorFactory(cfg)
	store := prompts.New(database, nil)
	id, runErr := watchman.Backtest(cmd.Context(), database, gen, watchman.NewLLMJudge(gen, store), store, wb, time.Now())
	if errors.Is(runErr, watchman.ErrBusy) {
		if watchmanBacktestFlagJSON {
			_ = writeJSON(cmd.OutOrStdout(), map[string]any{"ok": false, "error": "busy"})
		}
		return fmt.Errorf("a Watchman backtest is already running (the daemon's weekly one or another): try again when it ends")
	}
	if id == 0 { // the run failed before its row was written
		return runErr
	}
	b, rows, err := database.WatchmanBacktestByID(wb, id)
	if err != nil || b == nil {
		return errors.Join(runErr, err)
	}
	res := watchmanBacktestJSON{OK: runErr == nil, Workbench: wb, BacktestID: b.ID, Status: b.Status, Verdict: b.Verdict,
		CostUSD: b.CostUSD, Categories: []watchmanBacktestRowJSON{}, Error: b.Error}
	for _, r := range rows {
		res.Categories = append(res.Categories, watchmanBacktestRowJSON{Category: r.Category, Total: r.Total, Agree: r.Agree,
			WrongHigh: r.WrongHigh, CostUSD: r.CostUSD, Status: r.Status})
	}
	if runErr == nil {
		// The daemon's weekly launch reads this stamp: a finished run, manual
		// or launched, counts as the week's.
		stamp := watchman.BacktestStampPath(cfg.WorkspaceDir(), wb)
		if err := os.WriteFile(stamp, []byte(strconv.FormatInt(time.Now().Unix(), 10)), 0o600); err != nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "watchman backtest: saving the weekly stamp: %v\n", err)
		}
	}
	if watchmanBacktestFlagJSON {
		if err := writeJSON(cmd.OutOrStdout(), res); err != nil {
			return errors.Join(runErr, err)
		}
		return runErr
	}
	out := cmd.OutOrStdout()
	for _, r := range rows {
		switch r.Status {
		case watchman.BacktestNotMeasured:
			fmt.Fprintf(out, "%-12s not measured (%d of %d decisions)\n", r.Category, r.Total, watchman.HiddenPerCategory)
		default:
			fmt.Fprintf(out, "%-12s %s: %d of %d agree, %d wrong while sure (~$%.2f)\n",
				r.Category, r.Status, r.Agree, r.Total, r.WrongHigh, r.CostUSD)
		}
	}
	fmt.Fprintln(out, watchmanBacktestNotMeasuredNote)
	if runErr != nil {
		fmt.Fprintf(out, "The backtest stopped (cost so far ~$%.2f, an estimate); the categories above are kept.\n", b.CostUSD)
		return runErr
	}
	fmt.Fprintf(out, "Verdict: %s (cost ~$%.2f, an estimate from the token counts where the provider reports none)\n", b.Verdict, b.CostUSD)
	return nil
}
