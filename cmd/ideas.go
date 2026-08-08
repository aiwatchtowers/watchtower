package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"slices"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/daemon"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/ideas"
	"watchtower/internal/prompts"

	"github.com/spf13/cobra"
)

var ideasCmd = &cobra.Command{
	Use:   "ideas",
	Short: "Inspect and mine the ideas & decisions registry",
}

var ideasMineCmd = &cobra.Command{
	Use:   "mine",
	Short: "Run one ideas registry pass (Gmail/Jira pre-digests, then consolidation), or backfill a historical window with --from",
	RunE:  runIdeasMine,
}

var ideasListCmd = &cobra.Command{
	Use:   "list",
	Short: "List ideas in the registry",
	RunE:  runIdeasList,
}

func init() {
	rootCmd.AddCommand(ideasCmd)
	ideasCmd.AddCommand(ideasMineCmd, ideasListCmd)

	ideasListCmd.Flags().String("kind", "", "filter by kind ("+strings.Join(ideaKinds, ", ")+")")
	ideasListCmd.Flags().String("status", "", "filter by status ("+strings.Join(ideaStatuses, ", ")+")")

	ideasMineCmd.Flags().String("from", "", "backfill start date (YYYY-MM-DD); enables range mining over [from, to]")
	ideasMineCmd.Flags().String("to", "", "backfill end date (YYYY-MM-DD), defaults to now; requires --from")
}

// ideaKinds and ideaStatuses mirror the ideas table's CHECK constraints
// (migration 00050). An unknown filter value would otherwise be accepted
// silently and return an empty list, which reads as "you have no ideas"
// rather than "you typoed the flag".
var (
	ideaKinds    = []string{"idea", "decision", "note"}
	ideaStatuses = []string{"proposed", "active", "rejected", "not_now", "converted", "dropped", "merged", "superseded", "reversed"}
)

// validateEnumFlag returns an error naming the valid values when value is set
// but not among them. An empty value means "unfiltered" and always passes.
func validateEnumFlag(flag, value string, allowed []string) error {
	if value == "" || slices.Contains(allowed, value) {
		return nil
	}
	return fmt.Errorf("invalid --%s %q (valid: %s)", flag, value, strings.Join(allowed, ", "))
}

// wireIdeasPipeline attaches the ideas registry phase to the daemon when
// enabled (the wireMemoryPipeline precedent — it also keeps runSync under the
// cyclomatic-complexity gate).
func wireIdeasPipeline(d *daemon.Daemon, database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) {
	if !cfg.Ideas.Enabled {
		return
	}
	ideasPipe := ideas.New(database, cfg, gen, logger)
	ideasPipe.SetPromptStore(prompts.New(database, nil))
	d.SetIdeasPipeline(ideasPipe)
}

// ideasConfigAndDB loads the config (with the usual workspace/provider flag
// overrides) and opens the workspace database — the memoryConfigAndDB
// pattern.
func ideasConfigAndDB() (*config.Config, *db.DB, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, fmt.Errorf("invalid config: %w", err)
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	return cfg, database, nil
}

// ideasMineDateLayout is the CLI's --from/--to date format.
const ideasMineDateLayout = "2006-01-02"

// backfillEnvelope is `ideas mine --from`'s final one-line JSON summary
// (spec §3 step 5) — machine-readable so the Desktop "Find ideas" sheet can
// parse it straight off the CLI child's stdout.
type backfillEnvelope struct {
	Proposed        int  `json:"proposed"`
	Cycles          int  `json:"cycles"`
	MentionsDeduped int  `json:"mentions_deduped"`
	Capped          bool `json:"capped"`
}

func runIdeasMine(cmd *cobra.Command, _ []string) error {
	cfg, database, err := ideasConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	fromStr, _ := cmd.Flags().GetString("from")

	if !cfg.Ideas.Enabled {
		return reportIdeasDisabled(cmd, fromStr, out)
	}

	toStr, _ := cmd.Flags().GetString("to")
	if fromStr == "" && toStr != "" {
		return fmt.Errorf("--to requires --from")
	}

	logger := log.New(cmd.ErrOrStderr(), "[ideas] ", log.LstdFlags)
	pipe := ideas.New(database, cfg, cliGenerator(cfg), logger)
	pipe.SetPromptStore(prompts.New(database, nil))

	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	// A Ctrl-C/SIGTERM mid-run must still hit runIdeasBackfill's deferred
	// lock-release-and-floor-restore (and, for the incremental path, let an
	// in-flight AI call unwind cleanly) instead of the process dying with
	// the lock or a lowered floor left behind (cmd/sync.go:271 precedent,
	// GB8). Covers both paths below, since they share this same ctx.
	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if fromStr == "" {
		return runIdeasMineIncremental(ctx, pipe, out)
	}
	return runIdeasBackfill(ctx, cmd, cfg, pipe, fromStr, toStr)
}

// ideasDisabledEnvelope is the backfill path's machine-readable body when
// ideas.enabled=false (GB9) — the Desktop "Find ideas" sheet parses the
// CLI child's stdout for exactly this shape, so a disabled registry must
// still produce a stable, parseable line rather than prose.
type ideasDisabledEnvelope struct {
	Disabled bool `json:"disabled"`
}

// reportIdeasDisabled handles cfg.Ideas.Enabled=false for both `ideas mine`
// paths (GB9), exiting 0 either way: the backfill path (--from set) is
// machine-driven, so it emits {"disabled":true} on stdout — the ONLY line
// on stdout, matching runIdeasBackfill's own envelope-is-the-only-stdout-line
// contract — plus a human-readable line on stderr for a terminal watcher.
// The flagless incremental path has no machine reader and keeps its
// existing prose line on stdout.
func reportIdeasDisabled(cmd *cobra.Command, fromStr string, out io.Writer) error {
	const humanLine = "Ideas registry is disabled (ideas.enabled = false in config); nothing to do."
	if fromStr == "" {
		fmt.Fprintln(out, humanLine)
		return nil
	}
	fmt.Fprintln(cmd.ErrOrStderr(), humanLine)
	envelope, err := json.Marshal(ideasDisabledEnvelope{Disabled: true})
	if err != nil {
		return fmt.Errorf("marshaling disabled envelope: %w", err)
	}
	fmt.Fprintln(out, string(envelope))
	return nil
}

// runIdeasMineIncremental is flagless `ideas mine`'s body: one ordinary
// (unbounded) pipeline pass.
func runIdeasMineIncremental(ctx context.Context, pipe *ideas.Pipeline, out io.Writer) error {
	proposed, err := pipe.Run(ctx)
	if err != nil {
		return fmt.Errorf("mining ideas: %w", err)
	}
	inTok, outTok, _, totalAPI := pipe.AccumulatedUsage()
	fmt.Fprintf(out, "proposed=%d (input tokens: %d, output tokens: %d, API calls: %d)\n", proposed, inTok, outTok, totalAPI)
	return nil
}

// runIdeasBackfill implements `ideas mine --from [--to]` (spec §3): parses
// and validates the window, acquires the cross-process backfill lock (spec
// §5 — released via defer even on error), runs Pipeline.Backfill with a
// per-cycle progress line, and prints the final envelope.
func runIdeasBackfill(ctx context.Context, cmd *cobra.Command, cfg *config.Config, pipe *ideas.Pipeline, fromStr, toStr string) error {
	from, to, err := parseBackfillWindow(fromStr, toStr)
	if err != nil {
		return err
	}

	release, err := ideas.AcquireBackfillLock(cfg.WorkspaceDir(), "CLI backfill")
	if err != nil {
		return err
	}
	defer release()

	errOut := cmd.ErrOrStderr()
	result, err := pipe.Backfill(ctx, from, to, func(cycle int) {
		fmt.Fprintf(errOut, "cycle=%d\n", cycle)
	})
	if err != nil {
		return fmt.Errorf("backfilling ideas: %w", err)
	}

	envelope, err := json.Marshal(backfillEnvelope{
		Proposed:        result.Proposed,
		Cycles:          result.Cycles,
		MentionsDeduped: result.MentionsDeduped,
		Capped:          result.Capped,
	})
	if err != nil {
		return fmt.Errorf("marshaling backfill envelope: %w", err)
	}
	fmt.Fprintln(cmd.OutOrStdout(), string(envelope))
	return nil
}

// parseBackfillWindow parses and validates ideas mine --from/--to (spec §3):
// --to defaults to now when empty, and --from must be strictly before the
// effective --to.
func parseBackfillWindow(fromStr, toStr string) (from, to time.Time, err error) {
	from, err = time.Parse(ideasMineDateLayout, fromStr)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("invalid --from date: %w", err)
	}
	if toStr != "" {
		to, err = time.Parse(ideasMineDateLayout, toStr)
		if err != nil {
			return time.Time{}, time.Time{}, fmt.Errorf("invalid --to date: %w", err)
		}
	}
	effectiveTo := to
	if effectiveTo.IsZero() {
		effectiveTo = time.Now()
	}
	if !from.Before(effectiveTo) {
		return time.Time{}, time.Time{}, fmt.Errorf("--from must be before --to (or now)")
	}
	return from, to, nil
}

func runIdeasList(cmd *cobra.Command, _ []string) error {
	kind, _ := cmd.Flags().GetString("kind")
	status, _ := cmd.Flags().GetString("status")
	if err := validateEnumFlag("kind", kind, ideaKinds); err != nil {
		return err
	}
	if err := validateEnumFlag("status", status, ideaStatuses); err != nil {
		return err
	}

	_, database, err := ideasConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	rows, err := database.ListIdeas(db.IdeaFilter{Kind: kind, Status: status})
	if err != nil {
		return fmt.Errorf("listing ideas: %w", err)
	}
	if len(rows) == 0 {
		fmt.Fprintln(out, "No ideas found.")
		return nil
	}

	w := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tKIND\tSTATUS\tTITLE\tLAST MENTION")
	for _, idea := range rows {
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\n", idea.ID, idea.Kind, idea.Status, idea.Title, idea.LastMentionAt)
	}
	return w.Flush()
}
