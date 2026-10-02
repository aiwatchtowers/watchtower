package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/agentloop"
	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/claude"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/providers"
	"watchtower/internal/skills"
	"watchtower/internal/tools"
)

var (
	aiSessionFlagConversation int64
	aiSessionFlagModel        string
	aiSessionFlagSurface      string
	aiSessionFlagProjectID    int64
	aiSessionFlagResume       string
	aiSessionFlagDBPath       string
)

var aiSessionCmd = &cobra.Command{
	Use:   "session",
	Short: "Run a long-lived chat session (protocol v2 over stdin/stdout; used by the desktop app)",
	Long: `Runs one chat conversation as a long-lived process. Commands arrive on stdin
as JSON lines ({"type":"turn"|"cancel"|"close", ...}); protocol-v2 events go
to stdout as NDJSON. With the claude provider one warm claude process serves
every turn. The system prompt is built here and passed by file; message text
and attachment paths travel on stdin, never on argv.`,
	Args: cobra.NoArgs,
	RunE: runAISession,
}

func init() {
	aiCmd.AddCommand(aiSessionCmd)
	f := aiSessionCmd.Flags()
	f.Int64Var(&aiSessionFlagConversation, "conversation", 0, "chat conversation id (required)")
	f.StringVar(&aiSessionFlagModel, "model", "", "override the AI model (default: the provider's strong tier)")
	f.StringVar(&aiSessionFlagSurface, "surface", "main", "chat surface: main|target")
	f.Int64Var(&aiSessionFlagProjectID, "project-id", 0, "chat project whose instructions and files join the prompt")
	f.StringVar(&aiSessionFlagResume, "resume", "", "Claude session id to resume")
	f.StringVar(&aiSessionFlagDBPath, "db-path", "", "SQLite database path (overrides the workspace default)")
}

func runAISession(cmd *cobra.Command, _ []string) error {
	out := chat.NewEventWriter(cmd.OutOrStdout())
	fail := func(code, msg string) error {
		_ = out.Emit(chat.Event{Type: chat.EventError, Code: code, Message: msg})
		return errors.New(msg)
	}
	if aiSessionFlagConversation <= 0 {
		return fail(chat.CodeInternal, "--conversation is required")
	}
	if aiSessionFlagSurface != "main" && aiSessionFlagSurface != "target" {
		return fail(chat.CodeInternal, "--surface must be main or target")
	}

	cfg, database, dbPath, conv, err := openAISessionConversation(aiSessionFlagConversation, aiSessionFlagDBPath)
	if err != nil {
		return fail(chat.CodeInternal, err.Error())
	}
	defer database.Close()

	ctx := cmd.Context()
	if ctx == nil { // RunE called directly (tests)
		ctx = context.Background()
	}
	ctx, cancel := notifyShutdownContext(ctx, stderrLogf)
	defer cancel()

	model := aiSessionFlagModel
	if model == "" {
		_, model = providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	}
	prompt, err := chat.BuildSystemPrompt(ctx, database, cfg,
		sessionPromptOptions(cfg, aiSessionFlagSurface, aiSessionFlagProjectID, time.Now()))
	if err != nil {
		return fail(chat.CodeInternal, fmt.Sprintf("building the system prompt: %v", err))
	}

	turnFile, err := newTurnFile()
	if err != nil {
		return fail(chat.CodeInternal, fmt.Sprintf("creating the turn file: %v", err))
	}
	defer os.Remove(turnFile)

	project, chatProjectID, err := loadSessionProject(database, aiSessionFlagProjectID)
	if err != nil {
		return fail(chat.CodeInternal, err.Error())
	}
	mcpArgs := sessionMCPArgs(aiSessionFlagSurface, conv, turnFile, chatProjectID)

	backend, err := newSessionBackend(sessionWiring{
		cfg: cfg, database: database, dbPath: dbPath, conv: conv,
		model: model, prompt: prompt, mcpArgs: mcpArgs, turnFile: turnFile,
		project: project, chatProjectID: chatProjectID, warn: cmd.ErrOrStderr(),
	})
	if err != nil {
		return fail(chat.CodeProviderUnavailable, err.Error())
	}

	s := chat.NewSession(backend, out)
	s.Provider = providers.ByID(cfg.AI.Provider).ID
	s.Model = model
	s.TurnFile = turnFile
	return s.Run(ctx, cmd.InOrStdin())
}

// openAISessionConversation loads the config, opens the database and reads
// the conversation the session serves. The caller closes the database.
func openAISessionConversation(convID int64, dbPathFlag string) (*config.Config, *db.DB, string, *db.ChatConversation, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, "", nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, "", nil, fmt.Errorf("invalid config: %w", err)
	}
	dbPath := dbPathFlag
	if dbPath == "" {
		dbPath = cfg.DBPath()
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return nil, nil, "", nil, fmt.Errorf("opening database: %w", err)
	}
	conv, err := database.GetChatConversation(convID)
	if err == nil && conv == nil {
		err = fmt.Errorf("conversation %d not found", convID)
	}
	if err != nil {
		_ = database.Close()
		return nil, nil, "", nil, err
	}
	return cfg, database, dbPath, conv, nil
}

// loadSessionProject reads the --project-id chat project. The id comes back
// only when the project exists — a deleted one leaves the prompt without its
// block, and the tools must not be bound to it either.
func loadSessionProject(database *db.DB, projectID int64) (*db.ChatProjectContext, int64, error) {
	if projectID <= 0 {
		return nil, 0, nil
	}
	project, err := database.GetChatProjectContext(projectID)
	if err != nil {
		return nil, 0, fmt.Errorf("loading chat project %d: %w", projectID, err)
	}
	if project == nil {
		return nil, 0, nil
	}
	return project, projectID, nil
}

// sessionMCPArgs are the chat-mode MCP server's arguments: the running turn
// is read from turnFile at propose time (spec §1.2); a project chat passes
// its chat project on so search_knowledge prefers the pinned sources.
func sessionMCPArgs(surface string, conv *db.ChatConversation, turnFile string, chatProjectID int64) []string {
	args := []string{"--chat", "--surface", surface,
		"--conversation", strconv.FormatInt(conv.ID, 10), "--turn-file", turnFile}
	if conv.ContextType != "" {
		args = append(args, "--context-type", conv.ContextType, "--context-id", conv.ContextID)
	}
	if chatProjectID > 0 {
		args = append(args, "--chat-project", strconv.FormatInt(chatProjectID, 10))
	}
	return args
}

// sessionPromptOptions selects the session's system-prompt blocks. The memory
// block follows the owner's memory.surfaces.chat gate (and memory.enabled).
func sessionPromptOptions(cfg *config.Config, surface string, projectID int64, now time.Time) chat.PromptOptions {
	return chat.PromptOptions{
		Surface: surface, ProjectID: projectID, ToolsAvailable: true,
		Provider: cfg.AI.Provider, SkillsDir: skills.Dir(cfg.WorkspaceDir()), VaultDir: memoryVaultPath(cfg),
		MemoryChat: cfg.Memory.Enabled && cfg.Memory.Surfaces.Chat, Now: now,
		// Only the Claude backend unhides WebSearch (newSessionBackend).
		WebSearch: cfg.AI.Provider != "codex" && cfg.AI.Provider != "ollama",
	}
}

// sessionWiring is what a provider backend needs from the command.
type sessionWiring struct {
	cfg           *config.Config
	database      *db.DB
	dbPath        string
	conv          *db.ChatConversation
	model         string
	prompt        string
	mcpArgs       []string
	turnFile      string
	project       *db.ChatProjectContext // nil = not a project chat
	chatProjectID int64                  // 0 = not a project chat; bound into the ollama registry
	warn          io.Writer              // skipped project files are named here
}

// newSessionBackend picks the provider backend for `ai session`.
func newSessionBackend(w sessionWiring) (chat.Backend, error) {
	switch w.cfg.AI.Provider {
	case "codex":
		// Stateless per turn: the backend replays the active path every turn.
		// The MCP server reads the running turn from the turn file.
		c := codex.NewClient(w.model, w.dbPath, w.cfg.CodexPath)
		c.SetMCPArgs(w.mcpArgs)
		// CHAT-04 (spec §9): the chat session's system prompt and replayed
		// history must never sit on this process's argv — route the whole
		// turn through stdin instead of -c developer_instructions=... and a
		// positional prompt.
		c.SetStdinOnly(true)
		return chat.NewTurnBackend(c, w.database, w.conv.ID, chat.WithSystemPrompt(w.prompt)), nil
	case "ollama":
		// Ollama ships no default model: without one every turn would fail
		// as a retryable internal error, so the session refuses to start
		// (provider_unavailable) with the fix in the message.
		if w.model == "" {
			return nil, errors.New("no Ollama model is configured: pick one in Settings → AI")
		}
		// Runtime B: the registry runs in-process; proposals bind to the
		// running turn through the same turn file.
		loop := agentloop.NewClient(w.model, w.cfg.AI.OllamaURL, buildToolRegistry(w.cfg, w.database), sessionToolBinding(w))
		return chat.NewTurnBackend(loop, w.database, w.conv.ID, chat.WithSystemPrompt(w.prompt)), nil
	default:
		return chat.NewClaudeBackend(claudeSessionOptions(w, loadExternalMCPServers(w.cfg, w.dbPath))), nil
	}
}

// sessionToolBinding is the in-process registry's binding (runtime B): the
// same conversation, context and chat project the MCP server gets on argv.
func sessionToolBinding(w sessionWiring) tools.Binding {
	return tools.Binding{
		Surface: aiSessionFlagSurface, ConversationID: w.conv.ID,
		ContextType: w.conv.ContextType, ContextID: w.conv.ContextID,
		TurnIDFunc: chat.TurnFileReader(w.turnFile), ChatProjectID: w.chatProjectID,
	}
}

// claudeSessionOptions is the warm claude session's wiring for the external
// servers ext: the same per-tool QC-02 allowlist as the one-shot client (plus
// web search), and every external tool QC-02 denies hidden outright.
func claudeSessionOptions(w sessionWiring, ext []ai.ExternalMCPServer) chat.ClaudeOptions {
	return chat.ClaudeOptions{
		Binary:          claude.FindBinary(w.cfg.ClaudePath),
		Model:           w.model,
		ResumeSessionID: aiSessionFlagResume,
		SystemPrompt:    w.prompt,
		MCPConfig:       ai.ChatMCPConfig(w.dbPath, w.mcpArgs, ext),
		AllowedTools:    ai.AllowedTools(ext) + "," + ai.WebSearchTool,
		DisallowedTools: ai.WithExternalDisallowed(ai.SessionDisallowedTools, ext),
		// Claude only: codex/ollama would reject an image/PDF as
		// attachment_unsupported; their prompt still lists the files.
		ProjectAttachments: chat.ProjectAttachments(w.project, w.warn),
		Warn:               w.warn,
		Replay: func(turnID string) (string, error) {
			return chat.ReplayFromDB(w.database, w.conv.ID, turnID)
		},
	}
}

// newTurnFile creates the empty 0600 file the session publishes turn ids in.
func newTurnFile() (string, error) {
	f, err := os.CreateTemp("", "wt-chat-turn-*.txt")
	if err != nil {
		return "", err
	}
	path := f.Name()
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		os.Remove(path)
		return "", err
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}
