package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"strconv"

	"github.com/spf13/cobra"

	"watchtower/internal/agentkind"
	"watchtower/internal/automations"
	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	internalmcp "watchtower/internal/mcp"
	"watchtower/internal/skills"
	"watchtower/internal/tools"
)

var mcpCmd = &cobra.Command{
	Use:   "mcp",
	Short: "Run a read-only MCP server exposing Watchtower data over stdio",
	Long: `Run a Model Context Protocol (MCP) server over stdio.

The server exposes Watchtower's product data (targets, briefings, digests,
people, tracks, calendar, Jira) as read-only tools so any MCP client
(Claude Code, Cursor, Codex, ...) can use it for work context.

Add it to Claude Code with:
  claude mcp add watchtower -- watchtower mcp

With --workbench N the server is bound to one Watchtower workbench: its
workbench tools (board, documents, comments) apply directly to that workbench
only, and nothing else becomes writable. 'watchtower integrate claude-code
--workbench N' registers this mode in the workbench folder; never register it
by hand for an unrelated client.`,
	RunE: runMCP,
}

var (
	mcpFlagDBPath       string
	mcpFlagChat         bool
	mcpFlagSurface      string
	mcpFlagConversation int64
	mcpFlagTurn         string
	mcpFlagTurnFile     string
	mcpFlagContextType  string
	mcpFlagContextID    string
	mcpFlagChatProject  int64
	mcpFlagWorkbench    int64
	mcpFlagAgent        string
	// mcpFlagAutomationRun / mcpFlagAutomationTools bind `--chat --surface
	// automation` to one automation run's agent() call and the tools it asked
	// for (mcpAutomationOptions).
	mcpFlagAutomationRun   int64
	mcpFlagAutomationTools []string
	// mcpFlagAutomationReadyFile is touched once the automation server
	// accepted its binding and serves (the agent() runner's startup record).
	mcpFlagAutomationReadyFile string
	// mcpFlagWorkbenchLegacy reports an `mcp --project N` invocation: the
	// registration a pre-rename install wrote, whose session lists the
	// renamed workbench tools under their old names (spec 2026-10-02 §5.2).
	mcpFlagWorkbenchLegacy func() bool
)

func init() {
	rootCmd.AddCommand(mcpCmd)
	mcpCmd.Flags().StringVar(&mcpFlagDBPath, "db-path", "", "SQLite database path (overrides the workspace default)")
	mcpCmd.Flags().BoolVar(&mcpFlagChat, "chat", false, "assistant chat mode: mount write tools as proposals (never for external clients)")
	mcpCmd.Flags().StringVar(&mcpFlagSurface, "surface", "main", "chat surface for --chat: main|target|automation")
	mcpCmd.Flags().Int64Var(&mcpFlagConversation, "conversation", 0, "chat conversation id for --chat")
	mcpCmd.Flags().StringVar(&mcpFlagTurn, "turn", "", "turn id for --chat (proposals attach to it)")
	mcpCmd.Flags().StringVar(&mcpFlagTurnFile, "turn-file", "", "file holding the running turn id for --chat (a warm ai session); mutually exclusive with --turn")
	mcpCmd.Flags().StringVar(&mcpFlagContextType, "context-type", "", "chat context type for --chat (e.g. target)")
	mcpCmd.Flags().StringVar(&mcpFlagContextID, "context-id", "", "chat context id for --chat")
	mcpCmd.Flags().Int64Var(&mcpFlagChatProject, "chat-project", 0, "chat project for --chat: search_knowledge prefers its pinned sources")
	mcpCmd.Flags().Int64Var(&mcpFlagAutomationRun, "automation-run", 0, "--surface automation: the running automation run whose agent() child this server serves")
	mcpCmd.Flags().StringVar(&mcpFlagAutomationReadyFile, "automation-ready-file", "", "--surface automation: a file created once the server accepted the run's binding and serves")
	mcpCmd.Flags().StringSliceVar(&mcpFlagAutomationTools, "automation-tools", nil, "--surface automation: the tools the agent() call asked for (comma-separated)")
	mcpCmd.Flags().StringVar(&mcpFlagAgent, "agent", "", "workbench mode: the coding agent of the session (claude|codex); labels its comments when no terminal session names it")
	mcpFlagWorkbenchLegacy = addWorkbenchIDFlag(mcpCmd, &mcpFlagWorkbench, "workbench mode: bind to workbench N and apply its workbench tools directly (installed by 'integrate claude-code --workbench N')")
}

// mcpTurnBinding resolves the turn a chat-mode proposal attaches to: a fixed
// --turn (one-shot `ai query`) or a --turn-file read at propose time (a warm
// `ai session`). Exactly one may be given, and only in chat mode.
func mcpTurnBinding(chatMode bool, turn, turnFile string) (string, func() string, error) {
	if turnFile == "" {
		return turn, nil, nil
	}
	if !chatMode {
		return "", nil, errors.New("--turn-file requires --chat")
	}
	if turn != "" {
		return "", nil, errors.New("--turn and --turn-file are mutually exclusive")
	}
	return "", chat.TurnFileReader(turnFile), nil
}

// mcpModeOptions sets up project mode, chat mode (the write-tool registry) or
// dev mode (the read-only fence) on the opened database.
func mcpModeOptions(cfg *config.Config, database *db.DB, turn string, turnFunc func() string) ([]internalmcp.ServerOption, error) {
	if mcpFlagChatProject != 0 && !mcpFlagChat {
		return nil, errors.New("--chat-project requires --chat")
	}
	if mcpFlagWorkbench != 0 && (mcpFlagSurface == tools.AutomationSurface || mcpFlagAutomationRun != 0 || mcpFlagAutomationTools != nil || mcpFlagAutomationReadyFile != "") {
		// Never a workbench DirectApply server for an automation's agent.
		return nil, errors.New("--workbench and the automation flags (--surface automation, --automation-run, --automation-tools, --automation-ready-file) are mutually exclusive")
	}
	if mcpFlagAutomationReadyFile != "" && (!mcpFlagChat || mcpFlagSurface != tools.AutomationSurface) {
		return nil, errors.New("--automation-ready-file requires --chat --surface automation")
	}
	if (mcpFlagAutomationRun != 0 || mcpFlagAutomationTools != nil) && !mcpFlagChat {
		return nil, errors.New("--automation-run and --automation-tools require --chat --surface automation")
	}
	if mcpFlagAgent != "" && mcpFlagWorkbench == 0 {
		return nil, errors.New("--agent requires --workbench")
	}
	if mcpFlagChatProject < 0 {
		return nil, fmt.Errorf("--chat-project must be a chat project id, got %d", mcpFlagChatProject)
	}
	if mcpFlagWorkbench == 0 && !mcpFlagChat {
		// The MCP surface is read-only; enforce it at the connection level so even
		// a buggy handler cannot write. Must run after Open (migrations need writes).
		if err := database.SetReadOnly(); err != nil {
			return nil, fmt.Errorf("enforcing read-only: %w", err)
		}
		return nil, nil
	}
	// Both writable modes record owner-facing rows (a proposal, a board
	// write); give them the owner-click lock budget.
	if err := database.SetBusyTimeout(ownerWriteBusyTimeout); err != nil {
		return nil, err
	}
	if mcpFlagWorkbench != 0 {
		return mcpWorkbenchOptions(cfg, database, mcpFlagWorkbench, mcpFlagWorkbenchLegacy())
	}
	// Chat mode: the connection stays writable ONLY so the registry can
	// record proposals (agent_actions) — the tools themselves still never
	// write domain data on propose (AGENT-01). Dev mode above keeps the
	// query_only fence (AGENT-02 / DEV-01).
	return mcpChatOptions(cfg, database, turn, turnFunc)
}

// mcpChatOptions is `watchtower mcp --chat`: the write-tool registry bound to
// the chat surface, conversation, turn and context the flags name.
func mcpChatOptions(cfg *config.Config, database *db.DB, turn string, turnFunc func() string) ([]internalmcp.ServerOption, error) {
	if mcpFlagSurface == tools.AutomationSurface || mcpFlagAutomationRun != 0 || mcpFlagAutomationTools != nil {
		return mcpAutomationOptions(cfg, database)
	}
	if mcpFlagSurface != "main" && mcpFlagSurface != "target" {
		return nil, fmt.Errorf("--surface must be main, target or automation")
	}
	if mcpFlagContextType == tools.AutomationContextType {
		// Only the automations executor binds a run (Binding.AutomationRunID);
		// a chat must not record rows that read as a run's proposals.
		return nil, fmt.Errorf("--context-type %s is reserved for automation runs", tools.AutomationContextType)
	}
	return []internalmcp.ServerOption{internalmcp.WithRegistry(buildToolRegistry(cfg, database), tools.Binding{
		Surface: mcpFlagSurface, ConversationID: mcpFlagConversation, TurnID: turn, TurnIDFunc: turnFunc,
		ContextType: mcpFlagContextType, ContextID: mcpFlagContextID, ChatProjectID: mcpFlagChatProject,
	})}, nil
}

// mcpAutomationOptions is `watchtower mcp --chat --surface automation
// --automation-run N --automation-tools a,b,c` (spec 2026-10-14 §6.5): the
// server an automation's agent() claude/codex child talks to. It starts only
// in that run's own child (RunEnvMarker = N, never a borrowed binding) while
// run N is running. It mounts EffectiveAgentTools — the flag's tools ∩ what
// the run's manifest admits ∩ the automation surface, no writes in a dry run
// — plus get_action, shows get_action only the run's own rows, and passes
// every call through GateAgentCall and every result through
// CheckAgentResult. A write is a proposal stamped with the run, always
// pending (AutomationAgent). The chat flags (--conversation, --turn,
// --context-*) do not apply here.
func mcpAutomationOptions(cfg *config.Config, database *db.DB) ([]internalmcp.ServerOption, error) {
	runID := mcpFlagAutomationRun
	switch {
	case mcpFlagSurface != tools.AutomationSurface:
		return nil, errors.New("--automation-run and --automation-tools require --surface automation")
	case runID <= 0:
		return nil, errors.New("--surface automation requires --automation-run N")
	case os.Getenv(automations.RunEnvMarker) != strconv.FormatInt(runID, 10):
		return nil, fmt.Errorf("--automation-run %d serves only that run's own agent (%s=%d)", runID, automations.RunEnvMarker, runID)
	}
	run, err := database.GetAutomationRun(runID)
	if err != nil {
		return nil, fmt.Errorf("automation run %d: %w", runID, err)
	}
	if run.Status != db.RunRunning {
		return nil, fmt.Errorf("automation run %d is %s, not running", runID, run.Status)
	}
	a, err := database.GetAutomation(run.AutomationID)
	if err != nil {
		return nil, fmt.Errorf("reading the automation of run %d: %w", runID, err)
	}
	r, err := automations.ParseRecipe(a.Slug, []byte(run.RecipeSnapshot), automations.Scope{Kind: automations.ScopeKind(a.Scope), WorkbenchID: a.ProjectID})
	if err != nil {
		return nil, fmt.Errorf("automation run %d: the recipe does not parse: %w", runID, err)
	}
	m, err := automations.ParseManifest(r.Permissions, r.Outputs, r.Scope)
	if err != nil {
		return nil, fmt.Errorf("automation run %d: the permission manifest does not parse: %w", runID, err)
	}
	requested := []string{}
	for _, name := range mcpFlagAutomationTools {
		if name != "" {
			requested = append(requested, name)
		}
	}
	dryRun := run.Trigger == db.TriggerDryRun
	reg := buildToolRegistry(cfg, database)
	return []internalmcp.ServerOption{
		internalmcp.WithRegistry(reg, tools.Binding{
			Surface: tools.AutomationSurface, ContextType: tools.AutomationContextType, ContextID: strconv.FormatInt(runID, 10),
			AutomationRunID: runID, WorkbenchID: a.ProjectID, AutomationAgent: true,
		}),
		// Computed per tool at mount time: the memory and skill tools join the
		// registry inside NewServer, after these options are built.
		internalmcp.WithToolFilter(func(t *tools.Tool) bool {
			return slices.Contains(automations.EffectiveAgentTools(reg, m, requested, dryRun), t.Name)
		}),
		internalmcp.WithCallGate(func(ctx context.Context, t *tools.Tool, args json.RawMessage) (json.RawMessage, error) {
			return automations.GateAgentCall(ctx, database, m, runID, t, args)
		}),
		internalmcp.WithResultCheck(automations.CheckAgentResult),
	}, nil
}

// mcpWorkbenchOptions is `watchtower mcp --workbench N` (DEV-06): the connection
// stays writable, the registry is bound to workbench N on the "project" surface,
// and its tools apply directly (DirectApply) with an agent_actions audit row —
// never an External tool inline: the one propose-only External tool
// (send_slack_message) is recorded pending for the owner's Approve (DEV-06).
// The workbench must exist when the server starts; if it is deleted later,
// every tool answers "workbench N no longer exists".
// legacy is the pre-rename `--project N` spelling: the same session, listing
// the renamed tools under their old names (Binding.LegacyNames).
func mcpWorkbenchOptions(cfg *config.Config, database *db.DB, workbenchID int64, legacy bool) ([]internalmcp.ServerOption, error) {
	flag := workbenchFlagName(legacy)
	if mcpFlagChat {
		return nil, fmt.Errorf("%s and --chat are mutually exclusive", flag)
	}
	if workbenchID < 0 {
		return nil, fmt.Errorf("%s must be a workbench id, got %d", flag, workbenchID)
	}
	agent, err := mcpAgent(mcpFlagAgent)
	if err != nil {
		return nil, err
	}
	if _, err := database.GetWorkbench(workbenchID); err != nil {
		return nil, fmt.Errorf("workbench %d: %w", workbenchID, err)
	}
	return []internalmcp.ServerOption{internalmcp.WithRegistry(buildToolRegistry(cfg, database), tools.Binding{
		Surface: tools.WorkbenchSurface, WorkbenchID: workbenchID, DirectApply: true, LegacyNames: legacy,
		Agent: agent,
	})}, nil
}

// mcpAgent reads --agent: empty is "not given" (the comment label falls back
// to claude-code), anything but an agent kind is refused.
func mcpAgent(raw string) (agentkind.Kind, error) {
	if raw == "" {
		return "", nil
	}
	k, ok := agentkind.Parse(raw)
	if !ok {
		return "", fmt.Errorf("--agent must be claude or codex, got %q", raw)
	}
	return k, nil
}

func runMCP(cmd *cobra.Command, args []string) error {
	if err := checkWorkbenchIDFlags(cmd); err != nil {
		return err
	}
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	turn, turnFunc, err := mcpTurnBinding(mcpFlagChat, mcpFlagTurn, mcpFlagTurnFile)
	if err != nil {
		return err
	}

	dbPath := cfg.DBPath()
	if mcpFlagDBPath != "" {
		dbPath = mcpFlagDBPath
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	opts := []internalmcp.ServerOption{
		internalmcp.WithSkillsDir(skills.Dir(cfg.WorkspaceDir())),
	}
	modeOpts, err := mcpModeOptions(cfg, database, turn, turnFunc)
	if err != nil {
		return err
	}
	opts = append(opts, modeOpts...)
	if cfg.Memory.Enabled {
		opts = append(opts, internalmcp.WithMemoryVault(memoryVaultPath(cfg)))
		// An automation's reads write nothing: no recall shadow row (D23).
		if cfg.Memory.Retrieve.RecallCompare && mcpFlagAutomationRun == 0 {
			shadowDB, err := db.Open(dbPath)
			if err != nil {
				return fmt.Errorf("opening retrieve-compare shadow handle: %w", err)
			}
			defer shadowDB.Close()
			opts = append(opts, internalmcp.WithMemoryRetrieveCompare(shadowDB))
		}
	}
	srv := internalmcp.NewServer(database, opts...)
	if mcpFlagAutomationReadyFile != "" {
		// mcpAutomationOptions accepted the binding (the run's own marker,
		// the run running) and the server is built: record the start for the
		// agent() runner, which fails a child whose server never got here.
		if err := os.WriteFile(mcpFlagAutomationReadyFile, nil, 0o600); err != nil {
			return fmt.Errorf("writing the automation ready file: %w", err)
		}
	}
	return srv.ServeStdio(cmd.Context())
}
