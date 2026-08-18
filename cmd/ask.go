package cmd

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/providers"

	"github.com/spf13/cobra"
)

var (
	askFlagModel   string
	askFlagChannel string
	askFlagSince   time.Duration
)

var askCmd = &cobra.Command{
	Use:   `ask "<question>"`,
	Short: "Ask a question about your Slack workspace",
	Long:  "Uses AI to analyze synced Slack data and answer your question with context from messages, channels, and users.",
	Args:  cobra.MinimumNArgs(1),
	RunE:  runAsk,
}

func init() {
	rootCmd.AddCommand(askCmd)
	askCmd.Flags().StringVar(&askFlagModel, "model", "", "override AI model (e.g., claude-sonnet-4-6)")
	askCmd.Flags().StringVar(&askFlagChannel, "channel", "", "limit context to a specific channel")
	askCmd.Flags().DurationVar(&askFlagSince, "since", 0, "limit context to messages since this duration ago (e.g., 2h, 24h)")
}

func runAsk(cmd *cobra.Command, args []string) error {
	question := strings.Join(args, " ")

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

	accounts, err := database.ListSlackAccounts()
	if err != nil {
		return fmt.Errorf("listing slack accounts: %w", err)
	}
	if len(accounts) == 0 {
		return fmt.Errorf("no workspace data found — run 'watchtower sync' first")
	}
	// Connected-workspaces summary for the system prompt; the first account is
	// the representative for illustrative deep-link examples (per-message
	// permalinks are resolved per account by the context builder / renderer).
	wsSummary := db.FormatConnectedWorkspaces(accounts)
	domain, teamID := accounts[0].TeamDomain, accounts[0].TeamID

	// Parse the query for time hints
	pq := ai.Parse(question)

	// Apply CLI flag overrides
	if askFlagChannel != "" {
		pq.Channels = append(pq.Channels, askFlagChannel)
	}
	if askFlagSince > 0 {
		now := time.Now()
		pq.TimeRange = &ai.TimeRange{
			From: now.Add(-askFlagSince),
			To:   now,
		}
	}

	// Assemble prompt with DB access
	dbPath := cfg.DBPath()
	systemPrompt := ai.BuildSystemPrompt(wsSummary, domain, teamID, db.Schema, cfg.Digest.Language)

	// Inject Jira context if enabled
	if cfg.Jira.Enabled {
		systemPrompt += ai.JiraPromptSection()
	}

	// Inject digest context if available
	if digestCtx := buildDigestContext(database); digestCtx != "" {
		systemPrompt += "\n\n=== RECENT DIGEST SUMMARIES ===\n" +
			"Below are pre-analyzed summaries of recent activity. Use these as background knowledge. " +
			"For detailed questions, query the database for raw messages.\n\n" + digestCtx
	}

	timeHints := ai.FormatTimeHints(pq)
	userMessage := ai.AssembleUserMessage(question, timeHints)

	_, model := providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	if askFlagModel != "" {
		model = askFlagModel
	}
	aiClient := newAIClientWithModel(cfg, dbPath, model)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	out := cmd.OutOrStdout()
	renderer := ai.NewResponseRenderer(database, domain, teamID)

	runID, _ := database.CreatePipelineRun("ask", "cli", model)

	resp, usage, err := aiClient.QuerySync(ctx, systemPrompt, userMessage, "")

	// Complete pipeline run regardless of outcome.
	{
		errMsg := ""
		if err != nil {
			errMsg = err.Error()
		}
		inTok, outTok, cost, totalAPI := 0, 0, 0.0, 0
		if usage != nil {
			inTok, outTok, totalAPI = usage.InputTokens, usage.OutputTokens, usage.TotalAPITokens
		}
		if runID > 0 {
			_ = database.CompletePipelineRun(runID, 1, inTok, outTok, cost, totalAPI, nil, nil, errMsg)
		}
	}

	if err != nil {
		return fmt.Errorf("ai query failed: %w", err)
	}
	rendered, err := renderer.Render(resp)
	if err != nil {
		fmt.Fprint(out, resp)
	} else {
		fmt.Fprint(out, rendered)
	}

	return nil
}
