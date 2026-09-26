package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/kb"
)

var kbCmd = &cobra.Command{Use: "kb", Short: "Local knowledge search index"}

var kbStatusCmd = &cobra.Command{Use: "status", Short: "Show per-source index state", RunE: runKBStatus}
var kbReindexCmd = &cobra.Command{Use: "reindex", Short: "Rebuild the index (all sources, or --source)", RunE: runKBReindex}
var kbSearchCmd = &cobra.Command{Use: "search <query>...", Short: "Search the index; each argument is one query", Args: cobra.MinimumNArgs(1), RunE: runKBSearch}

// One variable per command flag: no two commands share a flag variable, so
// a value set on one command can never leak into another.
var (
	kbStatusJSON     bool
	kbReindexSources []string
	kbReindexForce   bool
	kbSearchSources  []string
	kbSearchFrom     string
	kbSearchTo       string
	kbSearchLimit    int
	kbSearchJSON     bool
)

func init() {
	rootCmd.AddCommand(kbCmd)
	kbCmd.AddCommand(kbStatusCmd, kbReindexCmd, kbSearchCmd)
	kbStatusCmd.Flags().BoolVar(&kbStatusJSON, "json", false, "JSON output")
	kbReindexCmd.Flags().StringSliceVar(&kbReindexSources, "source", nil, "source to rebuild (repeatable); default all")
	kbReindexCmd.Flags().BoolVar(&kbReindexForce, "force", false, "rebuild even while the sync daemon is running")
	kbSearchCmd.Flags().StringSliceVar(&kbSearchSources, "source", nil, "restrict to source (repeatable)")
	kbSearchCmd.Flags().StringVar(&kbSearchFrom, "from", "", "YYYY-MM-DD")
	kbSearchCmd.Flags().StringVar(&kbSearchTo, "to", "", "YYYY-MM-DD (inclusive)")
	kbSearchCmd.Flags().IntVar(&kbSearchLimit, "limit", 0, "max documents (default 10, max 25)")
	kbSearchCmd.Flags().BoolVar(&kbSearchJSON, "json", false, "JSON output")
}

// kbDaemonPID returns the running sync daemon's PID, 0 when none runs. A
// package var so tests can substitute it.
var kbDaemonPID = func() (int, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return 0, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	return daemon.FindProcess(pidFilePath(cfg))
}

// checkReindexAllowed refuses a rebuild while the daemon runs: its
// knowledge-index phase would race the rebuild's cursor resets (a stale
// cursor written back over a fresh one), leaving the index silently partial.
func checkReindexAllowed(pid int, force bool) error {
	if pid == 0 || force {
		return nil
	}
	return fmt.Errorf("the sync daemon is running (PID %d) and indexes in the background; "+
		"quit Watchtower (or run 'watchtower sync stop') before rebuilding, or pass --force", pid)
}

func runKBStatus(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	statuses, err := kb.Status(cmd.Context(), database)
	if err != nil {
		return fmt.Errorf("reading knowledge index status: %w", err)
	}

	if kbStatusJSON {
		return json.NewEncoder(out).Encode(statuses)
	}

	w := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "SOURCE\tDOCS\tCHUNKS\tPROGRESS\tLAST\tRECONCILE")
	for _, s := range statuses {
		last := s.UpdatedAt
		if last == "" {
			last = "-"
		}
		reconcile := s.LastReconciledAt
		if reconcile == "" {
			reconcile = "-"
		}
		fmt.Fprintf(w, "%s\t%d\t%d\t%.0f%%\t%s\t%s\n", s.Source, s.Docs, s.Chunks, s.Progress*100, last, reconcile)
	}
	return w.Flush()
}

func runKBReindex(cmd *cobra.Command, _ []string) error {
	pid, err := kbDaemonPID()
	if err != nil {
		return fmt.Errorf("checking for a running daemon: %w", err)
	}
	if err := checkReindexAllowed(pid, kbReindexForce); err != nil {
		return err
	}
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	if len(kbReindexSources) == 0 {
		fmt.Fprintln(out, "Rebuilding all sources…")
	} else {
		fmt.Fprintf(out, "Rebuilding %s…\n", strings.Join(kbReindexSources, ", "))
	}

	start := time.Now()
	stats, err := kb.Reindex(cmd.Context(), database, kbReindexSources, time.Now())
	if err != nil {
		return fmt.Errorf("reindexing: %w", err)
	}
	fmt.Fprintf(out, "Done: %d written, %d deleted in %s\n", stats.Written, stats.Deleted, time.Since(start).Round(time.Millisecond))
	return nil
}

func runKBSearch(cmd *cobra.Command, args []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	from, err := parseKBDay(kbSearchFrom, false)
	if err != nil {
		return fmt.Errorf("--from must be YYYY-MM-DD: %w", err)
	}
	to, err := parseKBDay(kbSearchTo, true)
	if err != nil {
		return fmt.Errorf("--to must be YYYY-MM-DD: %w", err)
	}

	req := kb.Request{
		Queries: args,
		Sources: kbSearchSources,
		From:    from,
		To:      to,
		Limit:   kbSearchLimit,
		Now:     time.Now(),
	}
	res, err := kb.Search(cmd.Context(), database, req)
	var reqErr *kb.RequestError
	if errors.As(err, &reqErr) {
		return reqErr
	}
	if err != nil {
		return fmt.Errorf("searching knowledge: %w", err)
	}

	if kbSearchJSON {
		return json.NewEncoder(out).Encode(res)
	}

	if res.IndexNote != "" {
		fmt.Fprintln(out, res.IndexNote)
	}
	if len(res.Hits) == 0 {
		fmt.Fprintln(out, "No matches.")
		return nil
	}
	for i, h := range res.Hits {
		fmt.Fprintf(out, "%d. [%s] %s — %s\n", i+1, h.Source, h.Title, h.When)
		fmt.Fprintf(out, "   ref: %s\n", h.Ref)
		if h.Link != "" {
			fmt.Fprintf(out, "   link: %s\n", h.Link)
		}
		for _, snippet := range h.Snippets {
			fmt.Fprintf(out, "   %s\n", snippet)
		}
	}
	return nil
}

// parseKBDay parses a YYYY-MM-DD filter date in UTC; "" passes through as
// "no bound" (the internal/tools search_knowledge parseDay precedent — kept
// as its own copy since that one is unexported and this command has no
// other reason to import internal/tools). endOfDay widens the parsed day to
// the next midnight (an exclusive upper bound), matching kb.Request.To.
func parseKBDay(s string, endOfDay bool) (time.Time, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, nil
	}
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return time.Time{}, err
	}
	if endOfDay {
		t = t.AddDate(0, 0, 1)
	}
	return t, nil
}
