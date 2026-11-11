package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/inbox"
	"watchtower/internal/logredact"
	"watchtower/internal/prompts"

	"github.com/spf13/cobra"
)

const syncStalenessThreshold = 10 * time.Minute

var (
	inboxFlagPriority               string
	inboxFlagType                   string
	inboxFlagAll                    bool
	inboxFlagIncludeArchived        bool
	inboxFlagJSON                   bool
	inboxGenFlagProgressJSON        bool
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
	Use:   "resolve <id> | --dry-run (--sender <addr> --trigger email_received | --older-than <n>d --people) | --ids <a,b,c>",
	Short: "Mark an inbox item, or items in bulk, as resolved",
	Long: `Marks one inbox item as resolved, or the owner marks items done in bulk:
a --dry-run names the open items a filter matches, and --ids resolves exactly
the ids it named that are still open. The bulk forms are refused under an AI
agent.`,
	Args: cobra.MaximumNArgs(1),
	RunE: runInboxResolve,
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

var inboxBackfillMentionsCmd = &cobra.Command{
	Use:   "backfill-mentions",
	Short: "Recover @mentions a broken or newly-connected detector missed, without moving the inbox watermark",
	Args:  cobra.NoArgs,
	RunE:  runInboxBackfillMentions,
}

func init() {
	rootCmd.AddCommand(inboxCmd)
	inboxCmd.AddCommand(inboxShowCmd, inboxResolveCmd, inboxDismissCmd, inboxSnoozeCmd, inboxGenerateCmd, inboxTaskCmd, inboxBackfillMentionsCmd)

	inboxCmd.Flags().StringVar(&inboxFlagPriority, "priority", "", "filter by priority (high, medium, low)")
	inboxCmd.Flags().StringVar(&inboxFlagType, "type", "", "filter by trigger type (mention, dm)")
	inboxCmd.Flags().BoolVar(&inboxFlagAll, "all", false, "include resolved and dismissed items")
	inboxCmd.Flags().BoolVar(&inboxFlagIncludeArchived, "include-archived", false, "include archived items (auto-archived pending items are hidden by default)")
	inboxCmd.Flags().BoolVar(&inboxFlagJSON, "json", false, "output as JSON")
	rf := inboxResolveCmd.Flags()
	rf.BoolVar(&inboxResolveFlags.dryRun, "dry-run", false, "name the open items a filter matches; write nothing")
	rf.StringVar(&inboxResolveFlags.sender, "sender", "", "with --dry-run: open mail from this address (any spelling)")
	rf.StringVar(&inboxResolveFlags.trigger, "trigger", "", "with --sender: email_received (the only value)")
	rf.StringVar(&inboxResolveFlags.olderThan, "older-than", "", "with --dry-run --people: items at least <n>d old (1-365)")
	rf.BoolVar(&inboxResolveFlags.people, "people", false, "with --older-than: open people items (every trigger but email_received)")
	rf.StringVar(&inboxResolveFlags.ids, "ids", "", "resolve these open items: comma-separated ids, at most 10000")
	rf.BoolVar(&inboxResolveFlags.json, "json", false, "print the result as one JSON line")
	inboxGenerateCmd.Flags().BoolVar(&inboxGenFlagProgressJSON, "progress-json", false, "output progress as JSON lines")
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
		IncludeArchived: inboxFlagIncludeArchived,
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
	if inboxResolveBulk(cmd) {
		return runInboxResolveBulk(cmd, args)
	}
	if len(args) == 0 {
		return fmt.Errorf("give an inbox item id, or --dry-run with a filter, or --ids")
	}
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

// inboxResolveFlags are the bulk flags of `inbox resolve`.
var inboxResolveFlags struct {
	dryRun, people, json       bool
	sender, trigger, olderThan string
	ids                        string
}

// inboxResolveMaxIDs caps the distinct ids one --ids press resolves.
const inboxResolveMaxIDs = 10000

// inboxResolveBulk reports whether any bulk flag was given.
func inboxResolveBulk(cmd *cobra.Command) bool {
	for _, name := range []string{"dry-run", "sender", "trigger", "older-than", "people", "ids", "json"} {
		if cmd.Flags().Changed(name) {
			return true
		}
	}
	return false
}

// runInboxResolveBulk runs a bulk form of `inbox resolve`: the owner's
// --dry-run names the open items a filter matches, and --ids resolves
// exactly those still open, so a press never closes more than its dry run
// named. Refused under an AI agent (AGENT-07). With --json the last stdout
// line is the result; on any failure it is {"resolved","of","error"}.
func runInboxResolveBulk(cmd *cobra.Command, args []string) error {
	resolved, of, err := inboxResolveBulkRun(cmd, args)
	if err == nil {
		return nil
	}
	if inboxResolveFlags.json {
		line, _ := json.Marshal(struct {
			Resolved int    `json:"resolved"`
			Of       int    `json:"of"`
			Error    string `json:"error"`
		}{resolved, of, err.Error()})
		fmt.Fprintln(cmd.OutOrStdout(), string(line))
		return err
	}
	if resolved > 0 {
		return fmt.Errorf("closed %d of %d: %w", resolved, of, err)
	}
	return err
}

// inboxResolveBulkRun returns how many items it resolved of how many
// distinct ids were asked (0/0 before any write) and the error, if any.
func inboxResolveBulkRun(cmd *cobra.Command, args []string) (int, int, error) {
	if err := refuseUnderAgent("resolve inbox items in bulk"); err != nil {
		return 0, 0, err
	}
	f := inboxResolveFlags
	changed := cmd.Flags().Changed
	if len(args) > 0 {
		return 0, 0, fmt.Errorf("an inbox item id takes no flags: resolve one id, or use --dry-run / --ids")
	}
	if changed("ids") {
		if f.dryRun || changed("sender") || changed("trigger") || changed("older-than") || f.people {
			return 0, 0, fmt.Errorf("--ids takes no --dry-run and no filter: it resolves the ids a dry run named")
		}
		ids, err := parseInboxResolveIDs(f.ids)
		if err != nil {
			return 0, 0, err
		}
		return inboxResolveIDs(cmd, ids)
	}
	if !f.dryRun {
		return 0, 0, fmt.Errorf("a filter needs --dry-run; resolve the ids it names with --ids")
	}
	query, err := inboxResolveFilter(cmd)
	if err != nil {
		return 0, 0, err
	}
	database, err := openDBFromConfig()
	if err != nil {
		return 0, 0, err
	}
	defer database.Close()
	ids, err := query(database)
	if err != nil {
		return 0, 0, err
	}
	out := cmd.OutOrStdout()
	if !f.json {
		fmt.Fprintf(out, "%d items match\n", len(ids))
		return 0, 0, nil
	}
	line, err := json.Marshal(struct {
		Count int      `json:"count"`
		IDs   []string `json:"ids"`
	}{len(ids), decimalIDs(ids)})
	if err != nil {
		return 0, 0, err
	}
	fmt.Fprintln(out, string(line))
	return 0, 0, nil
}

// inboxResolveFilter checks the dry run's one filter and returns its read:
// --sender X --trigger email_received, or --older-than Nd --people.
func inboxResolveFilter(cmd *cobra.Command) (func(*db.DB) ([]int64, error), error) {
	f := inboxResolveFlags
	changed := cmd.Flags().Changed
	mail := changed("sender") || changed("trigger")
	people := changed("older-than") || f.people
	switch {
	case mail && people:
		return nil, fmt.Errorf("give one filter: --sender with --trigger, or --older-than with --people")
	case mail:
		address := db.MailSenderKey(f.sender)
		if address == "" {
			return nil, fmt.Errorf("--sender needs an address")
		}
		if f.trigger != "email_received" {
			return nil, fmt.Errorf("--sender needs --trigger email_received (the only value)")
		}
		return func(d *db.DB) ([]int64, error) {
			return d.OpenMailItemIDsFrom(cmd.Context(), time.Now(), address)
		}, nil
	case people:
		days, err := parseOlderThanDays(f.olderThan)
		if err != nil {
			return nil, err
		}
		if !f.people {
			return nil, fmt.Errorf("--older-than needs --people")
		}
		return func(d *db.DB) ([]int64, error) {
			return d.OpenPeopleItemIDsOlderThan(cmd.Context(), time.Now(), time.Duration(days)*24*time.Hour)
		}, nil
	}
	return nil, fmt.Errorf("--dry-run needs a filter: --sender with --trigger, or --older-than with --people")
}

// parseOlderThanDays reads --older-than: <n>d with n from 1 to 365.
func parseOlderThanDays(s string) (int, error) {
	n, err := strconv.Atoi(strings.TrimSuffix(s, "d"))
	if !strings.HasSuffix(s, "d") || err != nil || n < 1 || n > 365 || strconv.Itoa(n)+"d" != s {
		return 0, fmt.Errorf("--older-than %q: want <n>d with n from 1 to 365", s)
	}
	return n, nil
}

// parseInboxResolveIDs reads --ids: positive integers, duplicates dropped,
// at most inboxResolveMaxIDs distinct.
func parseInboxResolveIDs(s string) ([]int64, error) {
	var ids []int64
	seen := map[int64]bool{}
	for part := range strings.SplitSeq(s, ",") {
		id, err := strconv.ParseInt(part, 10, 64)
		if err != nil || id <= 0 {
			return nil, fmt.Errorf("--ids %q: each id must be a positive integer", part)
		}
		if !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	if len(ids) > inboxResolveMaxIDs {
		return nil, fmt.Errorf("--ids names %d items: at most %d", len(ids), inboxResolveMaxIDs)
	}
	return ids, nil
}

// inboxResolveIDs resolves the items among ids that are still open now.
func inboxResolveIDs(cmd *cobra.Command, ids []int64) (int, int, error) {
	database, err := openDBFromConfig()
	if err != nil {
		return 0, len(ids), err
	}
	defer database.Close()
	resolved, err := database.ResolveOpenInboxItems(cmd.Context(), time.Now(), ids, db.BulkResolveReason)
	if err != nil {
		return len(resolved), len(ids), err
	}
	out := cmd.OutOrStdout()
	skipped := len(ids) - len(resolved)
	if !inboxResolveFlags.json {
		fmt.Fprintf(out, "Resolved %d, skipped %d\n", len(resolved), skipped)
		return len(resolved), len(ids), nil
	}
	line, err := json.Marshal(struct {
		Resolved int      `json:"resolved"`
		Skipped  int      `json:"skipped"`
		IDs      []string `json:"ids"`
	}{len(resolved), skipped, decimalIDs(resolved)})
	if err != nil {
		return len(resolved), len(ids), err
	}
	fmt.Fprintln(out, string(line))
	return len(resolved), len(ids), nil
}

// decimalIDs spells ids as decimal strings, never null.
func decimalIDs(ids []int64) []string {
	out := make([]string, len(ids))
	for i, id := range ids {
		out[i] = strconv.FormatInt(id, 10)
	}
	return out
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

	gen, cleanupPool := cliPooledGenerator(cfg)
	defer cleanupPool()
	pipe := inbox.New(database, cfg, gen, logger)
	pipe.SetPromptStore(prompts.New(database, nil))
	// A manual run detects but never moves the inbox watermark (INBOX-09):
	// it cannot tell whether the data it scans is complete — its pre-sync is
	// a subprocess whose rate-limit or revoked-account outcome it cannot
	// see, and it fails outright while the daemon holds the sync lock. The
	// daemon's cycle, which knows its own sync result, advances it.
	pipe.HoldWatermark()

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
			errMsg = logredact.Full(err)
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
		return nil
	}

	runID, _ := database.CreatePipelineRun("inbox", "cli", "auto")

	created, resolved, err := pipe.Run(cmd.Context())
	inTok, outTok, cost, totalAPI := pipe.AccumulatedUsage()
	errMsg := ""
	if err != nil {
		errMsg = logredact.Full(err)
	}
	if runID > 0 {
		_ = database.CompletePipelineRun(runID, created+resolved, inTok, outTok, cost, totalAPI, nil, nil, errMsg)
	}
	if err != nil {
		return fmt.Errorf("inbox pipeline: %w", err)
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
	pipe = inbox.New(database, cfg, nil, logger)
	pipe.SetPromptStore(prompts.New(database, nil))
	return pipe, func() { database.Close() }, nil
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
	ctx, cancel := notifyShutdownContext(ctx, stderrLogf)
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
