package cmd

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/memory"
	"watchtower/internal/prompts"

	"github.com/spf13/cobra"
)

var memoryCmd = &cobra.Command{
	Use:   "memory",
	Short: "Inspect and manage the secretary memory vault",
}

var memoryStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show node counts, watermark, extraction debt, and the last run",
	RunE:  runMemoryStatus,
}

var memoryReindexCmd = &cobra.Command{
	Use:   "reindex",
	Short: "Drop the SQLite index and rebuild it from the vault",
	RunE:  runMemoryReindex,
}

var memoryOpenCmd = &cobra.Command{
	Use:   "open <ref>",
	Short: "Resolve a node ID or alias and print the node",
	Args:  cobra.ExactArgs(1),
	RunE:  runMemoryOpen,
}

var memoryRecallCmd = &cobra.Command{
	Use:   "recall <query>",
	Short: "Full-text search over memory node titles and bodies",
	Args:  cobra.MinimumNArgs(1),
	RunE:  runMemoryRecall,
}

var memoryConsolidateCmd = &cobra.Command{
	Use:   "consolidate",
	Short: "Run one memory consolidation pass",
	RunE:  runMemoryConsolidate,
}

var memorySeedCmd = &cobra.Command{
	Use:   "seed",
	Short: "Seed skeleton entity pages from natural keys",
	RunE:  runMemorySeed,
}

// newMemoryPipelineFactory is the seam tests override to inject a fake
// pipeline (same pattern as newDayPlanPipelineFactory). The default wires
// the standard CLI generator, the prompt store, the digest language for
// the extractor's directive, and the caller's logf (the daemon passes its
// logger, the CLI a stderr printf — never nil, or per-window failures and
// quarantine warnings would be dropped silently); NewPipeline labels the run
// source "cli" (the daemon re-labels via SetMemoryPipeline).
var newMemoryPipelineFactory = func(database *db.DB, vault *memory.Vault, cfg *config.Config, logf func(string, ...any)) *memory.Pipeline {
	p := memory.NewPipeline(database, vault, cliGenerator(cfg), cfg.Memory, logf)
	p.Language = cfg.Digest.Language
	p.SetPromptStore(prompts.New(database, nil))
	return p
}

// memoryStderrLogf returns a pipeline logf that writes one line per call to
// the command's stderr.
func memoryStderrLogf(cmd *cobra.Command) func(string, ...any) {
	return func(format string, args ...any) {
		fmt.Fprintf(cmd.ErrOrStderr(), format+"\n", args...)
	}
}

func init() {
	rootCmd.AddCommand(memoryCmd)
	memoryCmd.AddCommand(memoryStatusCmd, memoryReindexCmd, memoryOpenCmd,
		memoryRecallCmd, memoryConsolidateCmd, memorySeedCmd)

	memoryRecallCmd.Flags().Int("limit", 10, "max results to print")
	memoryConsolidateCmd.Flags().Bool("once", false, "run a single consolidation pass and exit")
	memorySeedCmd.Flags().Bool("dry-run", false, "print what would be created without writing")
}

// ── helpers ───────────────────────────────────────────────────────────────────

// memoryConfigAndDB loads the config (with the usual workspace/provider flag
// overrides) and opens the workspace database.
func memoryConfigAndDB() (*config.Config, *db.DB, error) {
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

// memoryVaultPath is the fixed vault location — WorkspaceDir()/memory, not
// configurable in v1 per the design spec.
func memoryVaultPath(cfg *config.Config) string {
	return filepath.Join(cfg.WorkspaceDir(), "memory")
}

// ── handlers ──────────────────────────────────────────────────────────────────

func runMemoryStatus(cmd *cobra.Command, _ []string) error {
	cfg, database, err := memoryConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	// Node counts by type/tier. Tombstones are redirects, not knowledge —
	// excluded from the buckets (matching map.md and memory_map) and reported
	// on their own line.
	rows, err := database.ListMemoryNodes()
	if err != nil {
		return fmt.Errorf("listing memory nodes: %w", err)
	}
	counts := make(map[string]int)
	tombstones := 0
	for _, row := range rows {
		if row.Status == "tombstone" {
			tombstones++
			continue
		}
		counts[row.Type+"/"+row.Tier]++
	}
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	fmt.Fprintf(out, "Nodes: %d\n", len(rows)-tombstones)
	for _, k := range keys {
		fmt.Fprintf(out, "  %s: %d\n", k, counts[k])
	}
	fmt.Fprintf(out, "Tombstones: %d\n", tombstones)

	// Extraction watermark.
	wm, err := database.MemoryWatermark()
	if err != nil {
		return err
	}
	if wm == 0 {
		fmt.Fprintln(out, "Watermark: none (no messages extracted yet)")
	} else {
		fmt.Fprintf(out, "Watermark: %.6f (%s)\n", wm, time.Unix(int64(wm), 0).UTC().Format(time.RFC3339))
	}

	// Debt estimate: extractable messages above the watermark, capped at one
	// chunk — at the cap the real debt may be larger, hence the "+".
	msgs, err := database.ListMemoryExtractMessages(wm, cfg.Memory.MaxChunkMessages)
	if err != nil {
		return err
	}
	suffix := ""
	if cfg.Memory.MaxChunkMessages > 0 && len(msgs) >= cfg.Memory.MaxChunkMessages {
		suffix = "+"
	}
	fmt.Fprintf(out, "Extraction debt: %d%s messages\n", len(msgs), suffix)

	// Last memory pipeline run.
	var (
		runID             int64
		items             int
		source, status    string
		errMsg, startedAt string
	)
	err = database.QueryRow(`SELECT id, source, status, COALESCE(error_msg, ''), items_found, started_at
		FROM pipeline_runs WHERE pipeline = 'memory' ORDER BY id DESC LIMIT 1`).
		Scan(&runID, &source, &status, &errMsg, &items, &startedAt)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		fmt.Fprintln(out, "Last run: none")
	case err != nil:
		return fmt.Errorf("reading last memory run: %w", err)
	default:
		fmt.Fprintf(out, "Last run: #%d %s (%s) started %s — %d items", runID, status, source, startedAt, items)
		if errMsg != "" {
			fmt.Fprintf(out, " — error: %s", errMsg)
		}
		fmt.Fprintln(out)
	}
	return nil
}

func runMemoryReindex(cmd *cobra.Command, _ []string) error {
	cfg, database, err := memoryConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	vault, err := memory.OpenExistingVault(memoryVaultPath(cfg))
	if errors.Is(err, memory.ErrVaultNotInitialized) {
		fmt.Fprintln(out, "Memory vault not initialized; nothing to reindex.")
		return nil
	}
	if err != nil {
		return err
	}
	// Reindex rewrites the whole index from the vault files, so it must not
	// interleave with a consolidation run writing them.
	unlock, err := vault.Lock()
	if err != nil {
		return err
	}
	defer unlock()

	stats, err := memory.Rebuild(vault, database, memoryStderrLogf(cmd))
	if err != nil {
		return err
	}
	rows, err := database.ListMemoryNodes()
	if err != nil {
		return fmt.Errorf("listing memory nodes: %w", err)
	}
	fmt.Fprintf(out, "Reindexed %d nodes from the vault.\n", len(rows))
	if stats.Quarantined > 0 {
		fmt.Fprintf(out, "%d file(s) quarantined (parse/index failure — see warnings above).\n", stats.Quarantined)
	}
	return nil
}

func runMemoryOpen(cmd *cobra.Command, args []string) error {
	cfg, database, err := memoryConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	vault, err := memory.OpenExistingVault(memoryVaultPath(cfg))
	if errors.Is(err, memory.ErrVaultNotInitialized) {
		fmt.Fprintln(out, "Memory vault not initialized (memory may be disabled, or consolidation has not run yet).")
		return nil
	}
	if err != nil {
		return err
	}
	n, err := memory.Resolve(vault, database, args[0])
	if errors.Is(err, memory.ErrNotFound) {
		fmt.Fprintf(out, "No memory node for %q.\n", args[0])
		return nil
	}
	if err != nil {
		return err
	}

	fmt.Fprintf(out, "%s  %s/%s  %s", n.ID, n.Type, n.Tier, n.Status)
	if len(n.Aliases) > 0 {
		fmt.Fprintf(out, "  aliases: %s", strings.Join(n.Aliases, ", "))
	}
	fmt.Fprintf(out, "\n\n%s", n.Body)
	return nil
}

func runMemoryRecall(cmd *cobra.Command, args []string) error {
	limit, _ := cmd.Flags().GetInt("limit")
	_, database, err := memoryConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	hits, err := database.SearchMemoryFTS(strings.Join(args, " "), limit)
	if err != nil {
		return err
	}
	if len(hits) == 0 {
		fmt.Fprintln(out, "No matches.")
		return nil
	}
	for _, h := range hits {
		fmt.Fprintf(out, "%s  [%s]  %s — %s\n", h.ID, h.Type, h.Title, h.Snippet)
	}
	return nil
}

func runMemoryConsolidate(cmd *cobra.Command, _ []string) error {
	once, _ := cmd.Flags().GetBool("once")
	if !once {
		return fmt.Errorf("memory consolidate requires --once (the daemon owns the recurring schedule)")
	}

	cfg, database, err := memoryConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	if !cfg.Memory.Enabled {
		fmt.Fprintln(out, "Memory is disabled (memory.enabled = false in config); nothing to do.")
		return nil
	}

	vault, err := memory.OpenVault(memoryVaultPath(cfg))
	if err != nil {
		return err
	}
	pipe := newMemoryPipelineFactory(database, vault, cfg, memoryStderrLogf(cmd))

	ctx := cmd.Context()
	if ctx == nil {
		ctx = context.Background()
	}
	stats, err := pipe.Run(ctx)
	if err != nil {
		return fmt.Errorf("memory consolidation: %w", err)
	}

	if stats.OwnerEditsCommitted {
		fmt.Fprintln(out, "Owner edits committed first (memory(owner-edit)).")
	}
	fmt.Fprintf(out, "Consolidation done: %d entities seeded, situations %d created / %d updated / %d finalized, %d episodes from %d windows (%d failed, %d messages, %d refs rejected).\n",
		stats.Seeded, stats.Ingested.Created, stats.Ingested.Updated, stats.Ingested.Finalized,
		stats.Episodes, stats.Windows, stats.WindowsFailed, stats.Messages, stats.RefsRejected)
	if q := stats.Reconciled.Quarantined; q > 0 {
		fmt.Fprintf(out, "Warning: %d vault file(s) quarantined during reconcile (parse/index failure — see warnings above).\n", q)
	}
	return nil
}

func runMemorySeed(cmd *cobra.Command, _ []string) error {
	dryRun, _ := cmd.Flags().GetBool("dry-run")
	cfg, database, err := memoryConfigAndDB()
	if err != nil {
		return err
	}
	defer database.Close()
	out := cmd.OutOrStdout()

	if !dryRun {
		vault, err := memory.OpenVault(memoryVaultPath(cfg))
		if err != nil {
			return err
		}
		// Seeding writes vault commits + index rows: exclude concurrent
		// consolidation/reindex runs.
		unlock, err := vault.Lock()
		if err != nil {
			return err
		}
		defer unlock()
		n, err := memory.SeedEntities(vault, database, memory.SeedConfig{
			MinMessages: cfg.Memory.SeedMinMessages, WindowDays: memorySeedWindowDays,
		})
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "Seeded %d entities.\n", n)
		return nil
	}

	candidates, err := listMemorySeedCandidates(database, cfg.Memory.SeedMinMessages)
	if err != nil {
		return err
	}
	printed := 0
	for _, c := range candidates {
		// Same idempotency filter as SeedEntities: the first alias is the key.
		_, err := database.LookupMemoryAlias(c.aliases[0])
		if err == nil {
			continue // already seeded (or manually created)
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("looking up alias %q: %w", c.aliases[0], err)
		}
		if printed == 0 {
			fmt.Fprintln(out, "Would create (dry run, nothing written):")
		}
		fmt.Fprintf(out, "  - %s (aliases: %s)\n", c.title, strings.Join(c.aliases, ", "))
		printed++
	}
	if printed == 0 {
		fmt.Fprintln(out, "Nothing to seed.")
	}
	return nil
}

// ── seed dry-run listing ──────────────────────────────────────────────────────

// memorySeedWindowDays mirrors internal/memory's unexported seedWindowDays
// (the 30-day activity lookback from the design spec).
const memorySeedWindowDays = 30

// memorySeedCandidate is one would-be entity for the dry-run listing.
type memorySeedCandidate struct {
	title   string
	aliases []string
}

// listMemorySeedCandidates mirrors the read-only candidate queries of
// internal/memory's SeedEntities (people, channels, Jira project keys).
// internal/memory exports no dry-run listing, so the queries are duplicated
// here rather than adding a mode to the pipeline package.
func listMemorySeedCandidates(database *db.DB, minMessages int) ([]memorySeedCandidate, error) {
	since := float64(time.Now().AddDate(0, 0, -memorySeedWindowDays).Unix())
	var out []memorySeedCandidate

	// People: non-bot users with enough recent messages.
	rows, err := database.Query(`
		SELECT u.id, COALESCE(NULLIF(u.display_name, ''), NULLIF(u.real_name, ''), u.name), u.email
		FROM users u
		JOIN messages m ON m.user_id = u.id AND m.ts_unix >= ?
		WHERE u.is_bot = 0
		GROUP BY u.id
		HAVING COUNT(*) >= ?
		ORDER BY u.id`, since, minMessages)
	if err != nil {
		return nil, fmt.Errorf("listing seed people: %w", err)
	}
	out, err = scanSeedCandidates(rows, out, func(id, title, email string) memorySeedCandidate {
		c := memorySeedCandidate{title: title, aliases: []string{id}}
		if email != "" {
			c.aliases = append(c.aliases, email)
		}
		return c
	})
	if err != nil {
		return nil, err
	}

	// Channels: any channel with recent non-empty traffic.
	rows, err = database.Query(`
		SELECT c.id, c.name, ''
		FROM channels c
		WHERE EXISTS (
			SELECT 1 FROM messages m
			WHERE m.channel_id = c.id AND m.text != '' AND m.ts_unix >= ?)
		ORDER BY c.id`, since)
	if err != nil {
		return nil, fmt.Errorf("listing seed channels: %w", err)
	}
	out, err = scanSeedCandidates(rows, out, func(id, name, _ string) memorySeedCandidate {
		return memorySeedCandidate{title: "#" + name, aliases: []string{id}}
	})
	if err != nil {
		return nil, err
	}

	// Jira project keys (no activity window — few and stable).
	rows, err = database.Query(`SELECT project_key, '', '' FROM jira_issues GROUP BY project_key ORDER BY project_key`)
	if err != nil {
		return nil, fmt.Errorf("listing seed jira projects: %w", err)
	}
	return scanSeedCandidates(rows, out, func(key, _, _ string) memorySeedCandidate {
		return memorySeedCandidate{title: key, aliases: []string{key}}
	})
}

// scanSeedCandidates appends one candidate per three-column row.
func scanSeedCandidates(rows *sql.Rows, out []memorySeedCandidate, build func(a, b, c string) memorySeedCandidate) ([]memorySeedCandidate, error) {
	defer rows.Close()
	for rows.Next() {
		var a, b, c string
		if err := rows.Scan(&a, &b, &c); err != nil {
			return nil, fmt.Errorf("scanning seed candidate: %w", err)
		}
		out = append(out, build(a, b, c))
	}
	return out, rows.Err()
}
