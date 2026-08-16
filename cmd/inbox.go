package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/feed"
	"watchtower/internal/inbox"
	"watchtower/internal/prompts"

	"github.com/spf13/cobra"
)

const syncStalenessThreshold = 10 * time.Minute

var (
	inboxFlagPriority               string
	inboxFlagType                   string
	inboxFlagAll                    bool
	inboxFlagJSON                   bool
	inboxGenFlagProgressJSON        bool
	inboxFeedbackRating             string
	inboxFeedbackComment            string
	inboxBackfillMentionsFlagSince  string
	inboxBackfillMentionsFlagDryRun bool
	inboxBackfillMentionsFlagForce  bool
)

// backfillMentionsMaxLookbackDays is the safety floor on --since: a date
// further back than this is rejected unless --force is passed, so a
// mistyped year (or an unintentionally distant date) does not silently
// sweep the entire messages table.
const backfillMentionsMaxLookbackDays = 90

var inboxCmd = &cobra.Command{
	Use:   "inbox",
	Short: "Show messages awaiting your response",
	Long:  "Displays inbox items — @mentions and DMs where you haven't replied yet.",
	RunE:  runInbox,
}

var inboxShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show inbox item details",
	Args:  cobra.ExactArgs(1),
	RunE:  runInboxShow,
}

var inboxResolveCmd = &cobra.Command{
	Use:   "resolve <id>",
	Short: "Mark an inbox item as resolved",
	Args:  cobra.ExactArgs(1),
	RunE:  runInboxResolve,
}

var inboxDismissCmd = &cobra.Command{
	Use:   "dismiss <id>",
	Short: "Dismiss an inbox item",
	Args:  cobra.ExactArgs(1),
	RunE:  runInboxDismiss,
}

var inboxSnoozeCmd = &cobra.Command{
	Use:   "snooze <id> <duration>",
	Short: "Snooze an inbox item (e.g. 1d, 3d, 1w)",
	Args:  cobra.ExactArgs(2),
	RunE:  runInboxSnooze,
}

var inboxGenerateCmd = &cobra.Command{
	Use:   "generate",
	Short: "Run inbox detection pipeline",
	RunE:  runInboxGenerate,
}

var inboxTaskCmd = &cobra.Command{
	Use:   "task <id>",
	Short: "Create a task from an inbox item",
	Args:  cobra.ExactArgs(1),
	RunE:  runInboxTask,
}

var inboxFeedbackCmd = &cobra.Command{
	Use:   "feedback <situation-id>",
	Short: "Record feedback on a dashboard situation (--rating up|down [--comment])",
	Args:  cobra.ExactArgs(1),
	RunE:  runInboxFeedback,
}

var inboxStyleSampleCmd = &cobra.Command{
	Use:   "style-sample",
	Short: "Distill a communication style profile from your own Slack messages",
	Args:  cobra.NoArgs,
	RunE:  runInboxStyleSample,
}

var inboxBackfillMentionsCmd = &cobra.Command{
	Use:   "backfill-mentions",
	Short: "Recover @mentions a broken or newly-connected detector missed, without moving the inbox watermark",
	Args:  cobra.NoArgs,
	RunE:  runInboxBackfillMentions,
}

func init() {
	rootCmd.AddCommand(inboxCmd)
	inboxCmd.AddCommand(inboxShowCmd, inboxResolveCmd, inboxDismissCmd, inboxSnoozeCmd, inboxGenerateCmd, inboxTaskCmd, inboxFeedbackCmd, inboxStyleSampleCmd, inboxBackfillMentionsCmd)

	inboxCmd.Flags().StringVar(&inboxFlagPriority, "priority", "", "filter by priority (high, medium, low)")
	inboxCmd.Flags().StringVar(&inboxFlagType, "type", "", "filter by trigger type (mention, dm)")
	inboxCmd.Flags().BoolVar(&inboxFlagAll, "all", false, "include resolved and dismissed items")
	inboxCmd.Flags().BoolVar(&inboxFlagJSON, "json", false, "output as JSON")
	inboxGenerateCmd.Flags().BoolVar(&inboxGenFlagProgressJSON, "progress-json", false, "output progress as JSON lines")
	inboxFeedbackCmd.Flags().StringVar(&inboxFeedbackRating, "rating", "", "up or down")
	inboxFeedbackCmd.Flags().StringVar(&inboxFeedbackComment, "comment", "", "free-text comment; derives learned rules via the AI interpreter")
	inboxBackfillMentionsCmd.Flags().StringVar(&inboxBackfillMentionsFlagSince, "since", "", "recover mentions after this date (YYYY-MM-DD, parsed as UTC midnight; that instant itself is excluded); required")
	inboxBackfillMentionsCmd.Flags().BoolVar(&inboxBackfillMentionsFlagDryRun, "dry-run", false, "report what would be recovered without creating any inbox items")
	inboxBackfillMentionsCmd.Flags().BoolVar(&inboxBackfillMentionsFlagForce, "force", false, fmt.Sprintf("allow --since further back than %d days", backfillMentionsMaxLookbackDays))
	_ = inboxBackfillMentionsCmd.MarkFlagRequired("since")
}

func runInbox(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()

	out := cmd.OutOrStdout()

	f := db.InboxFilter{
		Priority:        inboxFlagPriority,
		TriggerType:     inboxFlagType,
		IncludeResolved: inboxFlagAll,
	}

	items, err := database.GetInboxItems(f)
	if err != nil {
		return fmt.Errorf("querying inbox: %w", err)
	}

	if inboxFlagJSON {
		data, err := json.MarshalIndent(items, "", "  ")
		if err != nil {
			return fmt.Errorf("marshaling JSON: %w", err)
		}
		fmt.Fprintln(out, string(data))
		return nil
	}

	pending, unread, err := database.GetInboxCounts()
	if err != nil {
		return fmt.Errorf("getting inbox counts: %w", err)
	}

	if len(items) == 0 {
		fmt.Fprintln(out, "No inbox items found.")
		return nil
	}

	header := fmt.Sprintf("Inbox (%d pending", pending)
	if unread > 0 {
		header += fmt.Sprintf(", %d unread", unread)
	}
	header += ")\n"
	fmt.Fprintln(out, header)

	for _, item := range items {
		pLabel := strings.ToUpper(item.Priority)
		switch item.Priority {
		case "high":
			pLabel = "HIGH"
		case "medium":
			pLabel = "MED "
		case "low":
			pLabel = "LOW "
		}

		typeLabel := "@"
		if item.TriggerType == "dm" {
			typeLabel = "DM"
		}

		snippet := item.Snippet
		if len(snippet) > 80 {
			snippet = snippet[:80] + "..."
		}

		line := fmt.Sprintf(" %s  %s  [#%d] %s", pLabel, typeLabel, item.ID, snippet)

		if item.Status != "pending" {
			line += fmt.Sprintf("  (%s)", item.Status)
		}

		fmt.Fprintln(out, line)
	}

	return nil
}

func runInboxShow(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid inbox item ID %q: must be a positive integer", args[0])
	}

	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()

	item, err := database.GetInboxItemByID(id)
	if err != nil {
		return fmt.Errorf("inbox item #%d not found: %w", id, err)
	}

	out := cmd.OutOrStdout()
	fmt.Fprintf(out, "Inbox Item #%d\n", item.ID)
	fmt.Fprintf(out, "Status: %s | Priority: %s | Type: %s\n", item.Status, item.Priority, item.TriggerType)
	fmt.Fprintf(out, "Channel: %s | Sender: %s\n", item.ChannelID, item.SenderUserID)

	if item.Snippet != "" {
		fmt.Fprintf(out, "\n%s\n", item.Snippet)
	}
	if item.Context != "" {
		fmt.Fprintf(out, "\n--- Context ---\n%s\n", item.Context)
	}
	if item.AIReason != "" {
		fmt.Fprintf(out, "\nAI Reason: %s\n", item.AIReason)
	}
	if item.ResolvedReason != "" {
		fmt.Fprintf(out, "Resolved: %s\n", item.ResolvedReason)
	}
	if item.Permalink != "" {
		fmt.Fprintf(out, "Link: %s\n", item.Permalink)
	}
	if item.SnoozeUntil != "" {
		fmt.Fprintf(out, "Snoozed until: %s\n", item.SnoozeUntil)
	}
	if item.TargetID != nil {
		fmt.Fprintf(out, "Target: #%d\n", *item.TargetID)
	}

	fmt.Fprintf(out, "Created: %s | Updated: %s\n", item.CreatedAt, item.UpdatedAt)

	return nil
}

func runInboxResolve(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid inbox item ID %q: must be a positive integer", args[0])
	}

	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()

	if err := database.ResolveInboxItem(id, "Manually resolved"); err != nil {
		return fmt.Errorf("resolving inbox item: %w", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Inbox item #%d resolved\n", id)
	return nil
}

func runInboxDismiss(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid inbox item ID %q: must be a positive integer", args[0])
	}

	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()

	if err := database.DismissInboxItem(id); err != nil {
		return fmt.Errorf("dismissing inbox item: %w", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Inbox item #%d dismissed\n", id)
	return nil
}

func runInboxSnooze(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid inbox item ID %q: must be a positive integer", args[0])
	}

	until, err := parseDuration(args[1])
	if err != nil {
		return fmt.Errorf("invalid duration %q: %w", args[1], err)
	}

	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()

	if err := database.SnoozeInboxItem(id, until); err != nil {
		return fmt.Errorf("snoozing inbox item: %w", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Inbox item #%d snoozed until %s\n", id, until)
	return nil
}

// parseDuration converts a human-readable duration to a YYYY-MM-DD date.
// Supported formats: 1d, 3d, 1w, 2w.
func parseDuration(s string) (string, error) {
	s = strings.TrimSpace(strings.ToLower(s))
	if len(s) < 2 {
		return "", fmt.Errorf("duration too short")
	}

	unit := s[len(s)-1]
	num, err := strconv.Atoi(s[:len(s)-1])
	if err != nil || num <= 0 {
		return "", fmt.Errorf("invalid number in duration")
	}

	now := time.Now()
	switch unit {
	case 'd':
		return now.AddDate(0, 0, num).Format("2006-01-02"), nil
	case 'w':
		return now.AddDate(0, 0, num*7).Format("2006-01-02"), nil
	default:
		return "", fmt.Errorf("unknown unit %q (use d or w)", string(unit))
	}
}

func runInboxGenerate(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	if err := validateModel(cfg); err != nil {
		return err
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	logger := log.New(cmd.ErrOrStderr(), "[inbox] ", log.LstdFlags)
	out := cmd.OutOrStdout()

	// Ensure messages are fresh — run sync if last sync was >10 min ago.
	if needsSync(database, logger) {
		var onProgress func(string)
		if inboxGenFlagProgressJSON {
			onProgress = func(line string) {
				// Parse sync progress JSON and relay as inbox pipeline status
				var sp struct {
					Phase               string `json:"phase"`
					DiscoveryPages      int    `json:"discovery_pages"`
					DiscoveryTotalPages int    `json:"discovery_total_pages"`
					MessagesFetched     int    `json:"messages_fetched"`
					SearchAfter         string `json:"search_after"`
				}
				if json.Unmarshal([]byte(line), &sp) != nil {
					return
				}

				status := "Syncing messages..."
				if sp.SearchAfter != "" {
					status = fmt.Sprintf("Sync: from %s", sp.SearchAfter)
				}
				if sp.DiscoveryPages > 0 {
					pages := fmt.Sprintf("p. %d", sp.DiscoveryPages)
					if sp.DiscoveryTotalPages > 0 {
						pages = fmt.Sprintf("p. %d/%d", sp.DiscoveryPages, sp.DiscoveryTotalPages)
					}
					msgs := fmt.Sprintf("%d msgs", sp.MessagesFetched)
					if sp.SearchAfter != "" {
						status = fmt.Sprintf("Sync: from %s (%s, %s)", sp.SearchAfter, pages, msgs)
					} else {
						status = fmt.Sprintf("Sync: %s, %s", pages, msgs)
					}
				}

				data, _ := json.Marshal(map[string]any{
					"pipeline": "inbox", "done": 0, "total": 0,
					"status": status, "finished": false,
					"input_tokens": 0, "output_tokens": 0,
				})
				fmt.Fprintln(out, string(data))
			}
		}
		database.Close() // release DB lock for sync subprocess
		if err := runQuickSync(cmd, logger, onProgress); err != nil {
			logger.Printf("inbox: pre-sync failed (continuing with stale data): %v", err)
		}
		database, err = db.Open(cfg.DBPath())
		if err != nil {
			return fmt.Errorf("reopening database after sync: %w", err)
		}
		defer database.Close()
	}

	gen, cleanupPool := cliPooledGenerator(cfg, logger)
	defer cleanupPool()
	pipe := inbox.New(database, cfg, gen, logger)
	pipe.SetPromptStore(prompts.New(database, nil))

	if inboxGenFlagProgressJSON {
		type pj struct {
			Pipeline         string  `json:"pipeline"`
			Done             int     `json:"done"`
			Total            int     `json:"total"`
			Status           string  `json:"status,omitempty"`
			InputTokens      int     `json:"input_tokens"`
			OutputTokens     int     `json:"output_tokens"`
			Error            string  `json:"error,omitempty"`
			Finished         bool    `json:"finished"`
			ItemsFound       int     `json:"items_found"`
			StepDurationSec  float64 `json:"step_duration_seconds,omitempty"`
			StepInputTokens  int     `json:"step_input_tokens,omitempty"`
			StepOutputTokens int     `json:"step_output_tokens,omitempty"`
			TotalAPITokens   int     `json:"total_api_tokens,omitempty"`
		}
		emit := func(p pj) { data, _ := json.Marshal(p); fmt.Fprintln(out, string(data)) }

		runID, _ := database.CreatePipelineRun("inbox", "cli", "auto")
		lastTotal := 4 // default, updated dynamically

		pipe.OnProgress = func(done, total int, status string) {
			lastTotal = total
			inTok, outTok, _, totalAPI := pipe.AccumulatedUsage()
			p := pj{
				Pipeline:       "inbox",
				Done:           done,
				Total:          total,
				Status:         status,
				InputTokens:    inTok,
				OutputTokens:   outTok,
				TotalAPITokens: totalAPI,
			}
			if pipe.LastStepDurationSeconds > 0 {
				p.StepDurationSec = pipe.LastStepDurationSeconds
				p.StepInputTokens = pipe.LastStepInputTokens
				p.StepOutputTokens = pipe.LastStepOutputTokens
			}
			emit(p)

			// Log step to DB.
			if runID > 0 && p.StepDurationSec > 0 {
				_ = database.InsertPipelineStep(db.PipelineStep{
					RunID: runID, Step: done, Total: total, Status: status,
					InputTokens:     p.StepInputTokens,
					OutputTokens:    p.StepOutputTokens,
					TotalAPITokens:  totalAPI,
					DurationSeconds: p.StepDurationSec,
				})
			}
		}

		created, resolved, err := pipe.Run(cmd.Context())
		errMsg := ""
		if err != nil {
			errMsg = err.Error()
		}

		inTok, outTok, cost, totalAPI := pipe.AccumulatedUsage()
		emit(pj{
			Pipeline:       "inbox",
			Done:           lastTotal,
			Total:          lastTotal,
			Finished:       true,
			ItemsFound:     created + resolved,
			InputTokens:    inTok,
			OutputTokens:   outTok,
			TotalAPITokens: totalAPI,
			Error:          errMsg,
		})

		if runID > 0 {
			_ = database.CompletePipelineRun(runID, created+resolved, inTok, outTok, cost, totalAPI, nil, nil, errMsg)
		}

		if err != nil {
			return fmt.Errorf("inbox pipeline: %w", err)
		}

		if cfg.Feed.Enabled {
			if _, err := feed.New(database, cfg, logger).Publish(time.Now()); err != nil {
				logger.Printf("feed publish after generate: %v", err) // non-fatal, mirrors daemon phaseFeed
			}
		}
		return nil
	}

	runID, _ := database.CreatePipelineRun("inbox", "cli", "auto")

	created, resolved, err := pipe.Run(cmd.Context())
	inTok, outTok, cost, totalAPI := pipe.AccumulatedUsage()
	errMsg := ""
	if err != nil {
		errMsg = err.Error()
	}
	if runID > 0 {
		_ = database.CompletePipelineRun(runID, created+resolved, inTok, outTok, cost, totalAPI, nil, nil, errMsg)
	}
	if err != nil {
		return fmt.Errorf("inbox pipeline: %w", err)
	}

	if cfg.Feed.Enabled {
		if _, err := feed.New(database, cfg, logger).Publish(time.Now()); err != nil {
			logger.Printf("feed publish after generate: %v", err) // non-fatal, mirrors daemon phaseFeed
		}
	}

	fmt.Fprintf(out, "Inbox: %d new items detected, %d resolved\n", created, resolved)
	return nil
}

func runInboxTask(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid inbox item ID %q: must be a positive integer", args[0])
	}

	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()

	item, err := database.GetInboxItemByID(id)
	if err != nil {
		return fmt.Errorf("inbox item #%d not found: %w", id, err)
	}

	target := db.Target{
		Text:       item.Snippet,
		Status:     "todo",
		Priority:   item.Priority,
		Ownership:  "mine",
		SourceType: "inbox",
		SourceID:   strconv.Itoa(item.ID),
	}

	targetID, err := database.CreateTarget(target)
	if err != nil {
		return fmt.Errorf("creating target: %w", err)
	}

	if err := database.LinkInboxTarget(id, int(targetID)); err != nil {
		return fmt.Errorf("linking target: %w", err)
	}

	fmt.Fprintf(cmd.OutOrStdout(), "Created target #%d from inbox item #%d\n", targetID, id)
	return nil
}

func runInboxFeedback(cmd *cobra.Command, args []string) error {
	situationID, err := strconv.Atoi(args[0])
	if err != nil || situationID <= 0 {
		return fmt.Errorf("invalid situation id %q", args[0])
	}
	rating, err := parseRating(inboxFeedbackRating)
	if err != nil {
		return err
	}

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	logger := log.New(cmd.ErrOrStderr(), "[inbox] ", log.LstdFlags)
	gen, closeGen := cliPooledGenerator(cfg, logger)
	defer closeGen()

	pipe := inbox.New(database, cfg, gen, logger)
	if err := pipe.SubmitSituationFeedback(cmd.Context(), situationID, rating, inboxFeedbackComment); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Recorded feedback on situation %d.\n", situationID)
	return nil
}

func runInboxStyleSample(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	logger := log.New(cmd.ErrOrStderr(), "[inbox] ", log.LstdFlags)
	gen, closeGen := cliPooledGenerator(cfg, logger)
	defer closeGen()

	pipe := inbox.New(database, cfg, gen, logger)
	if err := pipe.GenerateStyleProfile(cmd.Context()); err != nil {
		return err
	}
	fmt.Fprintln(cmd.OutOrStdout(), "Style profile regenerated.")
	return nil
}

// backfillMentionsAccountEnvelope is one connected account's contribution to
// a `inbox backfill-mentions` run's JSON envelope. Every candidate
// FindPendingMentions found for this account lands in exactly one of
// Created/AlreadyAnswered/EmptySnippet/CreateErrors on a completed run (see
// inbox.BackfillAccountResult), so CandidatesFound always equals their sum —
// a --dry-run envelope is fully readable without re-checking the database.
type backfillMentionsAccountEnvelope struct {
	AccountID       int64 `json:"account_id"`
	CandidatesFound int   `json:"candidates_found"`
	Created         int   `json:"created"`
	AlreadyAnswered int   `json:"already_answered"`
	EmptySnippet    int   `json:"empty_snippet"`
	CreateErrors    int   `json:"create_errors"`
}

// backfillMentionsEnvelope is `inbox backfill-mentions`'s one-line JSON
// summary on stdout — the `ideas mine --from` backfillEnvelope precedent
// (cmd/ideas.go): built and printed only on success, with errors returned
// directly as a Go error rather than carried as a field on the envelope, so
// a non-zero exit always means no envelope was printed at all. Per-account
// counts, the accounts skipped for having no resolved identity, and the
// totals are all included so a --dry-run's output is fully readable without
// re-checking the database.
type backfillMentionsEnvelope struct {
	Since                string                            `json:"since"`
	DryRun               bool                              `json:"dry_run"`
	Accounts             []backfillMentionsAccountEnvelope `json:"accounts"`
	SkippedAccountIDs    []int64                           `json:"skipped_account_ids"`
	TotalCandidates      int                               `json:"total_candidates"`
	TotalCreated         int                               `json:"total_created"`
	TotalAlreadyAnswered int                               `json:"total_already_answered"`
	TotalEmptySnippet    int                               `json:"total_empty_snippet"`
	TotalCreateErrors    int                               `json:"total_create_errors"`
}

// parseBackfillMentionsSince validates and parses --since for
// backfill-mentions: required (no default, so a direct RunE call — as in
// this package's tests — surfaces the same clear error a real invocation
// would, the targets `ai-update --instruction` precedent, cmd/targets_ai.go,
// rather than relying on cobra's MarkFlagRequired alone), must be
// YYYY-MM-DD, and — unless force is set — no further back than
// backfillMentionsMaxLookbackDays, so a mistyped year cannot silently sweep
// the whole messages table. time.Parse's "2006-01-02" layout carries no
// zone, so Go parses it as UTC midnight; combined with the pipeline's strict
// `>` comparison against that instant, that boundary itself is excluded — a
// UTC+3 owner passing today's date loses today's early-morning mentions,
// which is why the flag help spells this out too.
func parseBackfillMentionsSince(sinceFlag string, force bool) (time.Time, error) {
	if sinceFlag == "" {
		return time.Time{}, fmt.Errorf("--since is required (format YYYY-MM-DD)")
	}
	since, err := time.Parse("2006-01-02", sinceFlag)
	if err != nil {
		return time.Time{}, fmt.Errorf("invalid --since date %q: %w", sinceFlag, err)
	}
	if floor := time.Now().AddDate(0, 0, -backfillMentionsMaxLookbackDays); since.Before(floor) && !force {
		return time.Time{}, fmt.Errorf("--since %s is more than %d days ago; pass --force to sweep a window this large", sinceFlag, backfillMentionsMaxLookbackDays)
	}
	return since, nil
}

// newBackfillMentionsPipeline loads config, opens the DB, and builds the
// inbox pipeline backfill-mentions runs against — the ordinary
// config-load/workspace-override/provider-override/validate/db-open
// sequence every inbox subcommand repeats, isolated here so
// runInboxBackfillMentions' own body reads as validate → build → run →
// report instead of interleaving this setup with that flow. The returned
// closeFn must be called (via defer) to close the DB handle; it is nil
// whenever err is non-nil, since nothing was opened yet at any failure
// point below.
func newBackfillMentionsPipeline(cmd *cobra.Command) (pipe *inbox.Pipeline, closeFn func(), err error) {
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

	logger := log.New(cmd.ErrOrStderr(), "[inbox] ", log.LstdFlags)
	return inbox.New(database, cfg, nil, logger), func() { database.Close() }, nil
}

// buildBackfillMentionsEnvelope converts one BackfillMentions result into
// the CLI's JSON envelope shape (per-account counts plus totals, and
// SkippedAccountIDs normalized to `[]` rather than `null` for a stable
// stdout contract), isolated here so runInboxBackfillMentions' own body
// doesn't carry this loop.
func buildBackfillMentionsEnvelope(result inbox.BackfillMentionsResult, sinceFlag string, dryRun bool) backfillMentionsEnvelope {
	envelope := backfillMentionsEnvelope{
		Since:                sinceFlag,
		DryRun:               dryRun,
		Accounts:             make([]backfillMentionsAccountEnvelope, 0, len(result.Accounts)),
		SkippedAccountIDs:    result.SkippedAccountIDs,
		TotalCandidates:      result.TotalCandidates,
		TotalCreated:         result.TotalCreated,
		TotalAlreadyAnswered: result.TotalAlreadyAnswered,
		TotalEmptySnippet:    result.TotalEmptySnippet,
		TotalCreateErrors:    result.TotalCreateErrors,
	}
	for _, acct := range result.Accounts {
		envelope.Accounts = append(envelope.Accounts, backfillMentionsAccountEnvelope{
			AccountID:       acct.AccountID,
			CandidatesFound: acct.CandidatesFound,
			Created:         acct.Created,
			AlreadyAnswered: acct.AlreadyAnswered,
			EmptySnippet:    acct.EmptySnippet,
			CreateErrors:    acct.CreateErrors,
		})
	}
	if envelope.SkippedAccountIDs == nil {
		envelope.SkippedAccountIDs = []int64{}
	}
	return envelope
}

// runInboxBackfillMentions implements `watchtower inbox backfill-mentions
// --since <YYYY-MM-DD> [--dry-run] [--force]`: a thin CLI wrapper over
// inbox.Pipeline.BackfillMentions (internal/inbox/backfill.go), which scans
// only @mentions from the explicit --since timestamp, per connected Slack
// account, and never touches inbox_last_processed_ts (INBOX-09 — see
// docs/inventory/inbox-pulse.md). The command makes no AI call, so no
// generator is wired into the pipeline. A Ctrl-C/SIGTERM mid-sweep still
// prints the envelope for whatever was recovered before the interrupt
// rather than dying with no output — see the ctx wrapping below.
func runInboxBackfillMentions(cmd *cobra.Command, _ []string) error {
	since, err := parseBackfillMentionsSince(inboxBackfillMentionsFlagSince, inboxBackfillMentionsFlagForce)
	if err != nil {
		return err
	}

	pipe, closeDB, err := newBackfillMentionsPipeline(cmd)
	if err != nil {
		return err
	}
	defer closeDB()

	ctx := cmd.Context()
	if ctx == nil { // RunE invoked directly (tests) — cobra sets ctx only via Execute
		ctx = context.Background()
	}
	// cmd/root.go runs plain Execute(), so without this wrapping ctx is an
	// uncancellable Background in production and BackfillMentions' ctx.Err()
	// checks (between accounts and between candidates) are dead code — the
	// cmd/ideas.go backfill precedent. With it, a Ctrl-C/SIGTERM mid-sweep
	// stops promptly instead of the process dying mid-run with no output;
	// each CreateInboxItem already commits independently and re-running is
	// idempotent, so an interrupted sweep loses nothing by stopping early.
	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer cancel()

	result, runErr := pipe.BackfillMentions(ctx, since, inboxBackfillMentionsFlagDryRun)
	if runErr != nil && ctx.Err() == nil {
		// A genuine failure unrelated to cancellation (e.g. a per-account
		// DB error) — no envelope, matching the pre-existing hard-failure
		// contract for validation errors above.
		return fmt.Errorf("backfilling mentions: %w", runErr)
	}

	envelope := buildBackfillMentionsEnvelope(result, inboxBackfillMentionsFlagSince, inboxBackfillMentionsFlagDryRun)
	data, err := json.Marshal(envelope)
	if err != nil {
		return fmt.Errorf("marshaling envelope: %w", err)
	}
	fmt.Fprintln(cmd.OutOrStdout(), string(data))

	if runErr != nil {
		// ctx was cancelled mid-run: the envelope above is the partial
		// report of what got recovered before the interrupt; still return
		// the error so the exit code reflects that the sweep did not finish.
		return fmt.Errorf("backfilling mentions: %w", runErr)
	}
	return nil
}

// needsSync checks if workspace.synced_at is older than syncStalenessThreshold.
func needsSync(database *db.DB, logger *log.Logger) bool {
	var syncedAt string
	err := database.QueryRow(`SELECT COALESCE(synced_at, '') FROM workspace LIMIT 1`).Scan(&syncedAt)
	if err != nil || syncedAt == "" {
		return true
	}
	t, err := time.Parse(time.RFC3339, syncedAt)
	if err != nil {
		// Try alternate format
		t, err = time.Parse("2006-01-02T15:04:05Z", syncedAt)
		if err != nil {
			logger.Printf("inbox: cannot parse synced_at %q: %v", syncedAt, err)
			return true
		}
	}
	return time.Since(t) > syncStalenessThreshold
}

// runQuickSync runs `watchtower sync` as a subprocess to refresh messages.
// If onProgress is non-nil, --progress-json is added and each stdout line
// is forwarded to the callback for real-time progress relay.
func runQuickSync(cmd *cobra.Command, logger *log.Logger, onProgress func(string)) error {
	logger.Println("inbox: messages stale, running quick sync...")
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("finding executable: %w", err)
	}
	args := []string{"sync"}
	if flagConfig != "" {
		args = append(args, "--config", flagConfig)
	}
	if flagWorkspace != "" {
		args = append(args, "--workspace", flagWorkspace)
	}
	if onProgress != nil {
		args = append(args, "--progress-json")
	}
	syncProc := exec.CommandContext(cmd.Context(), exe, args...)
	syncProc.Stderr = cmd.ErrOrStderr()

	if onProgress == nil {
		return syncProc.Run()
	}

	stdout, err := syncProc.StdoutPipe()
	if err != nil {
		return fmt.Errorf("creating stdout pipe: %w", err)
	}
	if err := syncProc.Start(); err != nil {
		return fmt.Errorf("starting sync: %w", err)
	}

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		onProgress(scanner.Text())
	}

	return syncProc.Wait()
}
