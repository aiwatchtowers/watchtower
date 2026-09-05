// Package repl provides an interactive REPL for Claude interaction with workspace data.
package repl

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
	"watchtower/internal/sync"

	"github.com/dustin/go-humanize"
	"golang.org/x/term"
)

func (r *REPL) handleSlashCommand(input string) {
	parts := strings.Fields(input)
	cmd := strings.ToLower(parts[0])

	switch cmd {
	case "/quit", "/exit":
		fmt.Println()
		r.cancel() // cancel REPL context for clean shutdown
		return

	case "/help":
		fmt.Print(helpText())

	case "/status":
		fmt.Println(runStatus(r.deps))

	case "/sync":
		fmt.Println(runSyncCommand(r.ctx, r.deps))

	case "/catchup":
		r.runCatchup()

	default:
		fmt.Println(errorStyle.Render(fmt.Sprintf("Unknown command: %s", cmd)))
		fmt.Println(dimStyle.Render("Type /help for available commands."))
	}
}

func helpText() string {
	var b strings.Builder
	b.WriteString("Available commands:\n")
	b.WriteString("  /sync      Trigger an incremental sync\n")
	b.WriteString("  /status    Show workspace stats\n")
	b.WriteString("  /catchup   Get a summary of recent activity\n")
	b.WriteString("  /help      Show this help message\n")
	b.WriteString("  /quit      Exit the REPL (also Ctrl+C)\n")
	b.WriteString("\n")
	b.WriteString("Or just type a question to ask about your Slack workspace.\n")
	return b.String()
}

func runStatus(deps Deps) string {
	database := deps.DB
	cfg := deps.Config

	accounts, err := database.ListSlackAccounts()
	if err != nil {
		return errorStyle.Render("Error: " + err.Error())
	}

	stats, err := database.GetStats()
	if err != nil {
		return errorStyle.Render("Error: " + err.Error())
	}

	lastSync, err := database.LastSyncTime()
	if err != nil {
		return errorStyle.Render("Error: " + err.Error())
	}

	var b strings.Builder

	if len(accounts) == 0 {
		b.WriteString(fmt.Sprintf("Workspace: %s (not yet synced)\n", cfg.ActiveWorkspace))
	} else {
		for _, a := range accounts {
			name := a.Label
			if name == "" {
				name = a.TeamName
			}
			b.WriteString(fmt.Sprintf("Slack: %s (%s) [%s]\n", name, a.TeamDomain, a.Status))
		}
	}

	dbPath := cfg.DBPath()
	info, statErr := os.Stat(dbPath)
	var dbSize int64
	if statErr == nil {
		dbSize = info.Size()
	}
	b.WriteString(fmt.Sprintf("Database:  %s (%s)\n", dbPath, humanize.IBytes(uint64(dbSize))))

	if lastSync != "" {
		t, err := time.Parse(time.RFC3339, lastSync)
		if err == nil {
			b.WriteString(fmt.Sprintf("Last sync: %s (%s)\n", lastSync, humanize.Time(t)))
		} else {
			b.WriteString(fmt.Sprintf("Last sync: %s\n", lastSync))
		}
	} else {
		b.WriteString("Last sync: never\n")
	}

	watchedStr := ""
	if stats.WatchedCount > 0 {
		watchedStr = fmt.Sprintf(" (%s watched)", humanize.Comma(int64(stats.WatchedCount)))
	}
	b.WriteString(fmt.Sprintf("Channels: %s%s | Users: %s | Messages: %s | Threads: %s\n",
		humanize.Comma(int64(stats.ChannelCount)),
		watchedStr,
		humanize.Comma(int64(stats.UserCount)),
		humanize.Comma(int64(stats.MessageCount)),
		humanize.Comma(int64(stats.ThreadCount)),
	))

	return b.String()
}

func runSyncCommand(ctx context.Context, deps Deps) string {
	cfg := deps.Config
	database := deps.DB

	accounts, err := database.ListEnabledSlackAccounts()
	if err != nil {
		return errorStyle.Render("Error: " + err.Error())
	}
	if len(accounts) == 0 {
		return errorStyle.Render("Error: no Slack account connected. Run: watchtower slack login")
	}

	opts := sync.SyncOptions{
		Workers: cfg.Sync.Workers,
	}
	discard := log.New(io.Discard, "", 0)

	// Fan out over every connected account; one account's failure is reported
	// but does not block the others (the daemon fan-out pattern).
	var totalMessages int
	var earliest time.Time
	var firstErr error
	ran := 0
	skipped := 0
	for _, acct := range accounts {
		token, err := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), acct.ID).Load()
		if err != nil || token == nil {
			skipped++
			continue
		}
		client := watchtowerslack.NewClient(token.AccessToken)
		client.SetLogger(discard)
		orch := sync.NewOrchestrator(database, client, cfg, acct.ID)
		orch.SetLogger(discard)

		syncErr := orch.Run(ctx, opts)
		snap := orch.Progress().Snapshot()
		ran++
		totalMessages += snap.MessagesFetched
		if !snap.StartTime.IsZero() && (earliest.IsZero() || snap.StartTime.Before(earliest)) {
			earliest = snap.StartTime
		}
		if syncErr != nil && firstErr == nil {
			firstErr = syncErr
		}
	}

	if ran == 0 {
		return errorStyle.Render("Error: no Slack account has a stored token. Run: watchtower slack login")
	}
	if firstErr != nil {
		msg := errorStyle.Render("Sync failed: " + firstErr.Error())
		if skipped > 0 {
			msg += fmt.Sprintf(" (%d account(s) also skipped — no stored token, run: watchtower slack login)", skipped)
		}
		return msg
	}

	elapsed := time.Since(earliest).Round(time.Second)
	msg := fmt.Sprintf("Sync complete in %s: %d messages synced.", elapsed, totalMessages)
	if skipped > 0 {
		msg += fmt.Sprintf(" (%d account(s) skipped — no stored token, run: watchtower slack login)", skipped)
	}
	return msg
}

// runCatchup streams a catchup summary to stdout.
func (r *REPL) runCatchup() {
	cfg := r.deps.Config
	database := r.deps.DB

	sinceTime, err := database.DetermineSinceTime(0)
	if err != nil {
		fmt.Println(errorStyle.Render("Error determining catchup window: " + err.Error()))
		return
	}

	now := time.Now()
	fromUnix := float64(sinceTime.Unix())
	toUnix := float64(now.Unix())

	msgCount, err := database.CountMessagesByTimeRange(fromUnix, toUnix)
	if err != nil {
		fmt.Println(errorStyle.Render("Error counting messages: " + err.Error()))
		return
	}
	if msgCount == 0 {
		if err := database.UpdateCheckpoint(now); err != nil {
			fmt.Printf("Warning: failed to update checkpoint: %v\n", err)
		}
		fmt.Println("No new activity found since your last catchup.")
		return
	}

	fmt.Println(dimStyle.Render(fmt.Sprintf("Catching up since %s...", sinceTime.Format("2006-01-02 15:04 MST"))))
	fmt.Println()

	pq := ai.ParsedQuery{
		TimeRange: &ai.TimeRange{
			From: sinceTime,
			To:   now,
		},
	}

	systemPrompt := ai.BuildSystemPrompt(r.deps.Workspace, r.deps.Domain, r.deps.TeamID, db.Schema, cfg.Digest.Language)

	// Inject Jira context if enabled
	if cfg.Jira.Enabled {
		systemPrompt += ai.JiraPromptSection()
	}

	timeHints := ai.FormatTimeHints(pq)
	question := "What happened since I was last here? Give me a structured catchup summary."
	if lang := cfg.Digest.Language; lang != "" && !strings.EqualFold(lang, "English") {
		question = fmt.Sprintf("What happened since I was last here? Give me a structured catchup summary. Respond in %s.", lang)
	}
	userMessage := ai.AssembleUserMessage(question, timeHints)

	streamCtx, streamCancel := context.WithCancel(r.ctx)
	defer streamCancel()
	r.setStreamCancel(streamCancel)
	r.streaming.Store(true)
	defer func() {
		r.streaming.Store(false)
		r.setStreamCancel(nil)
	}()

	isTTY := term.IsTerminal(int(os.Stdout.Fd()))
	if isTTY {
		fmt.Print(dimStyle.Render("Thinking..."))
	}

	aiClient := r.aiProvider()
	textCh, errCh, _ := aiClient.Query(streamCtx, systemPrompt, userMessage, "")

	var fullResponse strings.Builder
	for chunk := range textCh {
		if chunk.ToolBoundary {
			// Drop the pre-tool preamble; keep only the post-tool answer.
			fullResponse.Reset()
			continue
		}
		fullResponse.WriteString(chunk.Text)
	}

	// Clear "Thinking..." line.
	if isTTY {
		fmt.Print("\r\033[K")
	}

	if err := <-errCh; err != nil {
		fmt.Println(errorStyle.Render("Error: " + err.Error()))
		return
	}

	// Render markdown + resolve sources, print formatted output.
	renderer := ai.NewResponseRenderer(database, r.deps.Domain, r.deps.TeamID)
	rendered, renderErr := renderer.Render(fullResponse.String())
	if renderErr != nil {
		rendered = fullResponse.String()
	}
	fmt.Print(rendered)

	if err := database.UpdateCheckpoint(now); err != nil {
		fmt.Printf("Warning: failed to update checkpoint: %v\n", err)
	}
}
