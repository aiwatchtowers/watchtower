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
	ideasMineCmd.Flags().String("to", "", "backfill end date (YYYY-MM-DD, inclusive), defaults to now; requires --from")
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
	// SlackRefsDropped/RefsRejected surface the run's two IDEA-02 provenance
	// drops (pipe.AccumulatedDrops), which used to be visible only in the log:
	// without them a zero-yield backfill reads as "that window held nothing"
	// even when it actually held candidates whose Slack timestamps resolved to
	// no live message, or ops citing refs the run never rendered.
	SlackRefsDropped int `json:"slack_refs_dropped"`
	RefsRejected     int `json:"refs_rejected"`
	// InputTokens/OutputTokens/APICalls (GB15) mirror the flagless
	// incremental path's own "(input tokens: %d, output tokens: %d, API
	// calls: %d)" reporting — same pipe.AccumulatedUsage() values, just
	// structured for the machine reader instead of prose.
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
	APICalls     int `json:"api_calls"`
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
	slackDropped, refsRejected := pipe.AccumulatedDrops()
	fmt.Fprintf(out, "proposed=%d slack_refs_dropped=%d refs_rejected=%d (input tokens: %d, output tokens: %d, API calls: %d)\n",
		proposed, slackDropped, refsRejected, inTok, outTok, totalAPI)
	return nil
}

// runIdeasBackfill implements `ideas mine --from [--to]` (spec §3): parses
// and validates the window, acquires the cross-process backfill lock (spec
// §5 — released via defer even on error), runs Pipeline.Backfill with a
// per-cycle progress line, and prints the final envelope. GB14 (verified):
// the envelope is the ONLY line this ever writes to stdout — the per-cycle
// "cycle=N" progress lines go to stderr — so the Desktop "Find ideas" sheet
// can parse stdout as exactly one JSON object with no interleaved noise.
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

	inTok, outTok, _, totalAPI := pipe.AccumulatedUsage()
	slackDropped, refsRejected := pipe.AccumulatedDrops()
	envelope, err := json.Marshal(backfillEnvelope{
		Proposed:         result.Proposed,
		Cycles:           result.Cycles,
		MentionsDeduped:  result.MentionsDeduped,
		Capped:           result.Capped,
		SlackRefsDropped: slackDropped,
		RefsRejected:     refsRejected,
		InputTokens:      inTok,
		OutputTokens:     outTok,
		APICalls:         totalAPI,
	})
	if err != nil {
		return fmt.Errorf("marshaling backfill envelope: %w", err)
	}
	fmt.Fprintln(cmd.OutOrStdout(), string(envelope))
	return nil
}

// parseBackfillWindow parses and validates ideas mine --from/--to (spec §3):
// --to defaults to now when empty, and --from must be strictly before the
// effective --to. --to is inclusive of its whole calendar day (SB1): the
// returned to, when set, is midnight of the day AFTER the named date, so a
// window like --from 2026-08-01 --to 2026-08-01 covers all of August 1st
// rather than excluding it entirely.
func parseBackfillWindow(fromStr, toStr string) (from, to time.Time, err error) {
	from, err = time.Parse(ideasMineDateLayout, fromStr)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("invalid --from date: %w", err)
	}
	if toStr != "" {
		toDate, perr := time.Parse(ideasMineDateLayout, toStr)
		if perr != nil {
			return time.Time{}, time.Time{}, fmt.Errorf("invalid --to date: %w", perr)
		}
		to = toDate.AddDate(0, 0, 1)
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
