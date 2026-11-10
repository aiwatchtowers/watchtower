package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/instructions"
	"watchtower/internal/llmusage"
	"watchtower/internal/logredact"
	"watchtower/internal/ollama"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
	"watchtower/internal/providers/transport"
	"watchtower/internal/specreview"
	"watchtower/internal/tools"

	"github.com/spf13/cobra"
)

var (
	aiFlagModel        string
	aiFlagSessionID    string
	aiFlagSystemPrompt string
	// aiFlagSystemPromptStdin reads the system prompt from stdin instead of
	// argv (the Desktop's chats: their prompt carries private context).
	aiFlagSystemPromptStdin bool
	// aiFlagPromptStdin reads the whole query — prompt and system prompt —
	// as one JSON object from stdin (the Desktop's chats: the owner's typed
	// message must not sit on this process's argv either).
	aiFlagPromptStdin bool
	// aiFlagOwnerInstructions appends the owner's chat instructions to the
	// resolved system prompt. A bare flag: the text is read from the
	// database, never carried on argv (CHAT-04, PROJ-22).
	aiFlagOwnerInstructions bool
	aiFlagDBPath            string
	aiFlagTools             string
	aiFlagSurface           string
	aiFlagConversation      int64
	aiFlagTurn              string
	aiFlagContextType       string
	aiFlagContextID         string
	aiFlagEvents            string
	aiFlagReadFolder        string
	// aiFlagReadFolderAsk names a spec/plan review ask whose reviewer's
	// folder (specreview.ReadFolder) the run reads: a Discuss thread.
	aiFlagReadFolderAsk int64
	// aiFlagReadFolderRound names a diff review round whose folder
	// (review_rounds.folder_root) the run reads: the branch-review reviewer.
	aiFlagReadFolderRound int64
	// aiFlagPurpose records this query's LLM calls under its own purpose
	// in the usage ledger (one of queryPurposes; "" keeps the default).
	aiFlagPurpose string
)

// queryPurposes are the --purpose values ai query accepts: embedded chats
// whose turns the usage ledger shows apart from the plain chat.
var queryPurposes = map[string]bool{"spec_review.discuss": true, "review.reviewer": true, "tuning.chat": true}

var aiCmd = &cobra.Command{
	Use:   "ai",
	Short: "AI provider interface (used by desktop app)",
}

var aiQueryCmd = &cobra.Command{
	Use:   "query",
	Short: "Stream an AI query through the configured provider",
	Long:  "Sends a prompt to the configured AI provider (Claude or Codex) and streams the response as JSON lines. Intended for programmatic use by the desktop app.",
	Args:  cobra.MaximumNArgs(1),
	RunE:  runAIQuery,
}

var aiModelsFlagJSON bool
var aiTestCLIPath string

// Catalog reads must not inherit the database/config schema upgrade hook:
// Settings uses saved file identity to confirm daemon application.
var aiModelsCmd = &cobra.Command{
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	Use:               "models",
	Short:             "List AI providers and their models",
	Long:              "Prints the provider registry: default per-tier models, the resolved light/strong models per provider under the current config, and — for OpenAI-compatible providers — the live model list. The Desktop app consumes this via --json.",
	RunE:              runAIModels,
}

var aiTestCmd = &cobra.Command{
	Use:               "test",
	PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
	Short:             "Test AI provider connectivity",
	Long:              "Verifies that the configured AI provider is available and responds. Outputs JSON with status.",
	RunE:              runAITest,
}

// aiStreamEvent is a JSON line emitted by `watchtower ai query`.
// Maps 1:1 to Swift StreamEvent enum.
type aiStreamEvent struct {
	Type              string `json:"type"`
	Text              string `json:"text,omitempty"`
	SessionID         string `json:"session_id,omitempty"`
	Error             string `json:"error,omitempty"`
	Code              string `json:"code,omitempty"`
	Reason            string `json:"reason,omitempty"`
	Retryable         bool   `json:"retryable,omitempty"`
	Provider          string `json:"provider,omitempty"`
	Model             string `json:"model,omitempty"`
	PreferredProvider string `json:"preferred_provider,omitempty"`
	RoutingMode       string `json:"routing_mode,omitempty"`
}

func init() {
	rootCmd.AddCommand(aiCmd)
	aiCmd.AddCommand(aiQueryCmd)
	aiCmd.AddCommand(aiTestCmd)
	aiCmd.AddCommand(aiModelsCmd)

	aiModelsCmd.Flags().BoolVar(&aiModelsFlagJSON, "json", false, "output JSON")
	aiTestCmd.Flags().StringVar(&aiFlagModel, "model", "", "override AI model")
	aiTestCmd.Flags().StringVar(&aiTestCLIPath, "cli-path", "", "test this CLI path without saving it")

	aiQueryCmd.Flags().StringVar(&aiFlagModel, "model", "", "override AI model")
	// Ignored since #604 G11 (no Claude session is stored); kept so an
	// older caller's flag still parses.
	aiQueryCmd.Flags().StringVar(&aiFlagSessionID, "session-id", "", "ignored: no session is stored")
	_ = aiQueryCmd.Flags().MarkHidden("session-id")
	aiQueryCmd.Flags().StringVar(&aiFlagSystemPrompt, "system-prompt", "", "system prompt")
	aiQueryCmd.Flags().BoolVar(&aiFlagSystemPromptStdin, "system-prompt-stdin", false,
		"read the system prompt from stdin (keeps it off argv: visible in ps, bounded by ARG_MAX)")
	aiQueryCmd.MarkFlagsMutuallyExclusive("system-prompt", "system-prompt-stdin")
	aiQueryCmd.Flags().BoolVar(&aiFlagPromptStdin, "prompt-stdin", false,
		`read the query from stdin as JSON {"prompt": "...", "system_prompt": "..."} instead of a positional prompt (keeps both off argv)`)
	aiQueryCmd.Flags().BoolVar(&aiFlagOwnerInstructions, "owner-instructions", false,
		"append the owner's instructions to the system prompt (a resumed turn, with no system prompt, gets none)")
	aiQueryCmd.MarkFlagsMutuallyExclusive("prompt-stdin", "system-prompt")
	aiQueryCmd.MarkFlagsMutuallyExclusive("prompt-stdin", "system-prompt-stdin")
	aiQueryCmd.Flags().StringVar(&aiFlagDBPath, "db-path", "", "SQLite database path for MCP (overrides default)")
	aiQueryCmd.Flags().StringVar(&aiFlagTools, "tools", "", "tool mode: chat = mount the assistant's write tools as proposals")
	aiQueryCmd.Flags().StringVar(&aiFlagSurface, "surface", "main", "chat surface for --tools chat: main|target|automation_editor|tuning")
	aiQueryCmd.Flags().Int64Var(&aiFlagConversation, "conversation", 0, "chat conversation id for --tools chat")
	aiQueryCmd.Flags().StringVar(&aiFlagTurn, "turn", "", "turn id for --tools chat")
	aiQueryCmd.Flags().StringVar(&aiFlagContextType, "context-type", "", "chat context type (e.g. target)")
	aiQueryCmd.Flags().StringVar(&aiFlagContextID, "context-id", "", "chat context id")
	aiQueryCmd.Flags().StringVar(&aiFlagEvents, "events", "v1", "output protocol: v1 (text/reset/session_id/done) or v2 (chat events)")
	aiQueryCmd.Flags().StringVar(&aiFlagReadFolder, "read-folder", "",
		"run in this workbench folder with the provider's own read-only file tools (claude, codex); exit 2 if it is not a workbench folder")
	aiQueryCmd.Flags().Int64Var(&aiFlagReadFolderAsk, "read-folder-ask", 0,
		"run, like --read-folder, in the folder the reviewer of spec/plan review ask N read; exit 2 if it is no such ask")
	aiQueryCmd.Flags().Int64Var(&aiFlagReadFolderRound, "read-folder-round", 0,
		"run, like --read-folder, in the folder diff review round N was taken from; exit 2 if it is no such round")
	aiQueryCmd.Flags().StringVar(&aiFlagPurpose, "purpose", "",
		"record this query's LLM calls under this usage purpose (spec_review.discuss, review.reviewer, tuning.chat); exit 2 on any other value")
}

// queryContext tags ctx with the --purpose value for the LLM usage ledger.
// "" returns ctx unchanged; a value outside queryPurposes is a usage error
// (exit 2).
func queryContext(ctx context.Context, purpose string) (context.Context, error) {
	if purpose == "" {
		return ctx, nil
	}
	if !queryPurposes[purpose] {
		return nil, usageError("unknown --purpose %q", purpose)
	}
	return llmusage.WithPurpose(ctx, purpose), nil
}

// withOwnerInstructions appends the owner's chat slot to a non-empty system
// prompt. An empty prompt (a resumed turn) and an empty slot leave it as is.
func withOwnerInstructions(d *db.DB, system string) (string, error) {
	if system == "" {
		return system, nil
	}
	g, err := d.GetOwnerInstructions()
	if err != nil {
		return "", err
	}
	slot := instructions.ChatSlot(g)
	if slot == "" {
		return system, nil
	}
	return system + "\n\n" + slot, nil
}

// maxStdinSystemPrompt bounds --system-prompt-stdin and --prompt-stdin; a chat prompt is tens of
// KB, so anything near this is a caller bug, not a prompt.
const maxStdinSystemPrompt = 16 << 20

// querySystemPrompt returns the system prompt from --system-prompt, or, with
// --system-prompt-stdin, everything on stdin.
func querySystemPrompt(stdin io.Reader) (string, error) {
	if !aiFlagSystemPromptStdin {
		return aiFlagSystemPrompt, nil
	}
	data, err := io.ReadAll(io.LimitReader(stdin, maxStdinSystemPrompt+1))
	if err != nil {
		return "", fmt.Errorf("reading the system prompt from stdin: %w", err)
	}
	if len(data) > maxStdinSystemPrompt {
		return "", fmt.Errorf("system prompt on stdin exceeds %d bytes", maxStdinSystemPrompt)
	}
	if len(data) == 0 {
		// The flag is passed only with a prompt to send: empty stdin means
		// the delivery failed, and a chat without its prompt must not run.
		return "", errors.New("--system-prompt-stdin: stdin was empty")
	}
	return string(data), nil
}

// stdinQuery is the --prompt-stdin payload.
type stdinQuery struct {
	Prompt       string `json:"prompt"`
	SystemPrompt string `json:"system_prompt"`
}

// queryInput returns the prompt and system prompt: with --prompt-stdin both
// from the JSON object on stdin (no positional prompt allowed), otherwise
// the positional prompt and querySystemPrompt.
func queryInput(args []string, stdin io.Reader) (prompt, systemPrompt string, err error) {
	if !aiFlagPromptStdin {
		if len(args) != 1 {
			return "", "", errors.New("a prompt is required: pass it as the argument or use --prompt-stdin")
		}
		systemPrompt, err = querySystemPrompt(stdin)
		return args[0], systemPrompt, err
	}
	if len(args) != 0 {
		return "", "", errors.New("--prompt-stdin reads the prompt from stdin: pass no prompt argument")
	}
	data, err := io.ReadAll(io.LimitReader(stdin, maxStdinSystemPrompt+1))
	if err != nil {
		return "", "", fmt.Errorf("reading the query from stdin: %w", err)
	}
	if len(data) > maxStdinSystemPrompt {
		return "", "", fmt.Errorf("query on stdin exceeds %d bytes", maxStdinSystemPrompt)
	}
	var q stdinQuery
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		return "", "", fmt.Errorf("--prompt-stdin: stdin is not a query object: %w", err)
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		// A second object or stray bytes: the writer is not the one we expect.
		return "", "", errors.New("--prompt-stdin: unexpected data after the query object")
	}
	if q.Prompt == "" {
		// An empty prompt means the delivery failed: never run without it.
		return "", "", errors.New("--prompt-stdin: the query has no prompt")
	}
	return q.Prompt, q.SystemPrompt, nil
}

func runAIQuery(cmd *cobra.Command, args []string) error {
	enc := json.NewEncoder(os.Stdout)
	if aiFlagEvents != "v1" && aiFlagEvents != "v2" {
		emitError(enc, fmt.Sprintf("--events must be v1 or v2, got %q", aiFlagEvents))
		return nil
	}
	// Before any config or provider work: an unknown surface never starts a
	// model call or an MCP child.
	if !tools.KnownChatSurface(aiFlagSurface) {
		emitError(enc, fmt.Sprintf("unknown chat surface %q", aiFlagSurface))
		return nil
	}
	if aiFlagTools == "chat" && aiFlagSurface == tools.SurfaceTuning {
		if err := checkTuningBinding(aiFlagConversation, aiFlagContextType); err != nil {
			emitError(enc, err.Error())
			return nil
		}
	}
	// Before the config/DB work below, so a writer feeding a large prompt on
	// stdin is not kept waiting (the Desktop tolerates a CLI that exits
	// before reading — see WatchtowerAIService.feedStdin).
	prompt, systemPrompt, err := queryInput(args, os.Stdin)
	if err != nil {
		emitError(enc, err.Error())
		return nil
	}

	cfg, err := config.Load(flagConfig)
	if err != nil {
		emitError(enc, fmt.Sprintf("loading config: %v", err))
		return nil
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		emitError(enc, fmt.Sprintf("invalid config: %v", err))
		return nil
	}

	// Determine database path
	dbPath := aiFlagDBPath
	if dbPath == "" {
		dbPath = cfg.DBPath()
	}

	readFolder, err := resolveReadFolder(cmd, dbPath)
	if err != nil {
		return err
	}

	if aiFlagOwnerInstructions && systemPrompt != "" {
		database, err := db.Open(dbPath)
		if err != nil {
			emitError(enc, fmt.Sprintf("--owner-instructions: opening the database: %v", err))
			return nil
		}
		systemPrompt, err = withOwnerInstructions(database, systemPrompt)
		_ = database.Close()
		if err != nil {
			emitError(enc, fmt.Sprintf("--owner-instructions: %v", err))
			return nil
		}
	}

	aiClient, cleanup, err := newQueryClient(cfg, dbPath, transport.Options{ReadFolder: readFolder, ToolEvents: aiFlagEvents == "v2"})
	if err != nil {
		emitError(enc, fmt.Sprintf("preparing tools: %v", err))
		return nil
	}
	defer cleanup()
	if readFolder != "" && !toolRoutingEnabled(cfg, aiFlagModel) && !providers.ByID(cfg.AI.Provider).Caps.ReadsFolder() {
		// A provider with no file tools (ollama) would answer from the
		// prompt alone: refused before any model call, never a silent
		// answer (spec 2026-11-05 §3.3, read_folder none). A routed query
		// checks the provider it selects (toolRouteProvider).
		return refuseQuery(enc, providers.CapabilityError(cfg.AI.Provider, providers.ReviewReadonly,
			fmt.Errorf("--read-folder: the %s provider has no file tools, so it cannot read the folder; use Claude or Codex for questions about code", cfg.AI.Provider)))
	}

	ctx, cancel := notifyShutdownContext(context.Background(), stderrLogf)
	defer cancel()
	ctx, err = queryContext(ctx, aiFlagPurpose)
	if err != nil {
		return err
	}

	textCh, errCh, sidCh := aiClient.Query(ctx, systemPrompt, prompt, aiFlagSessionID)

	if aiFlagEvents == "v2" {
		streamQueryV2(os.Stdout, v2TurnID(), textCh, errCh, sidCh)
		return nil
	}
	streamQueryV1(enc, textCh, errCh, sidCh)
	return nil
}

// streamQueryV1 writes the v1 protocol (text/reset/session_id/error/done).
func streamQueryV1(enc *json.Encoder, textCh <-chan ai.StreamChunk, errCh <-chan error, sidCh <-chan string) {
	// Drain text channel (main stream). A tool-boundary chunk becomes a "reset"
	// event so the desktop drops the pre-tool preamble and renders only the
	// answer that follows the tool call.
	for chunk := range textCh {
		if route := chunk.Routing; route != nil {
			_ = enc.Encode(aiStreamEvent{Type: "routing", Provider: route.Provider, Model: route.Model,
				PreferredProvider: route.PreferredProvider, RoutingMode: route.Mode, Reason: route.Reason})
			continue
		}
		if chunk.ToolBoundary {
			_ = enc.Encode(aiStreamEvent{Type: "reset"})
			continue
		}
		_ = enc.Encode(aiStreamEvent{Type: "text", Text: chunk.Text})
	}

	// Drain session ID (at most one value)
	for sid := range sidCh {
		if sid != "" {
			_ = enc.Encode(aiStreamEvent{Type: "session_id", SessionID: sid})
		}
	}

	// Check for errors
	for err := range errCh {
		if err != nil {
			code, reason, retry := queryErrorClass(err)
			_ = enc.Encode(aiStreamEvent{Type: "error", Error: logredact.Full(err), Code: code, Retryable: retry, Reason: reason})
		}
	}

	_ = enc.Encode(aiStreamEvent{Type: "done"})
}

func runAITest(_ *cobra.Command, _ []string) error {
	enc := json.NewEncoder(os.Stdout)

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return enc.Encode(map[string]any{
			"ok":    false,
			"error": "Could not read provider configuration",
		})
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	wireLLMUsage(cfg)

	_, model := providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	if aiFlagModel != "" {
		model = aiFlagModel
	}

	// Explicit single-provider probe: never enter the fallback router or mount
	// chat tools. The same canonical batch leaves enforce startup isolation.
	if _, known := providers.CapsFor(cfg.AI.Provider); !known {
		return enc.Encode(map[string]any{"ok": false, "error": "Unknown AI provider", "provider": cfg.AI.Provider, "model": model})
	}
	leafCfg := *cfg
	if aiTestCLIPath != "" {
		if !providers.RunsChild(cfg.AI.Provider) {
			return enc.Encode(map[string]any{"ok": false, "error": "CLI path is unavailable for HTTP providers", "provider": cfg.AI.Provider, "model": model})
		}
		leafCfg.ClaudePath, leafCfg.CodexPath = aiTestCLIPath, aiTestCLIPath
	}
	gen := transport.For(cfg.AI.Provider).NewGenerator(transport.Options{Config: &leafCfg, Model: model, IsolatedChild: true})
	ctx, shutdown := notifyShutdownContext(context.Background(), stderrLogf)
	defer shutdown()
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	err = providers.Allowed(cfg.AI.Provider)
	if err == nil {
		err = runConnectionProbe(ctx, cfg.AI.Provider, gen)
	}
	if err != nil {
		return enc.Encode(map[string]any{"ok": false, "error": connectionTestError(err), "error_code": connectionTestCode(err), "provider": cfg.AI.Provider, "model": model})
	}

	return enc.Encode(map[string]any{
		"ok":       true,
		"provider": cfg.AI.Provider,
		"model":    model,
	})
}

// The Desktop boundary contains classifications, never arbitrary child stderr,
// owner paths, tokens or managed-configuration contents.
func connectionTestCode(err error) providers.ErrorCategory {
	var failure *providers.Failure
	if errors.As(err, &failure) {
		return failure.Category
	}
	return providers.Unknown
}

func connectionTestError(err error) string {
	if errors.Is(err, errProbeNonceMissing) { // error_code stays invalid_output
		return "Codex answered but ignored Watchtower's instructions. Update the Codex CLI, or check its config, and test again."
	}
	var failure *providers.Failure
	if errors.As(err, &failure) {
		return "Provider request failed (" + string(failure.Category) + ")."
	}
	return "Provider request failed. Check the CLI installation and sign-in in Terminal."
}

// aiModelsProvider is one provider entry in the `ai models` output.
type aiModelsProvider struct {
	providers.Provider
	ResolvedLight  string   `json:"resolved_light"`
	ResolvedStrong string   `json:"resolved_strong"`
	Models         []string `json:"models,omitempty"`
	Error          string   `json:"error,omitempty"`
}

// aiModelsOutput is the JSON envelope of `ai models --json`.
type aiModelsOutput struct {
	ActiveProvider string             `json:"active_provider"`
	Providers      []aiModelsProvider `json:"providers"`
}

func runAIModels(cmd *cobra.Command, _ []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)

	ctx, cancel := notifyShutdownContext(context.Background(), stderrLogf)
	defer cancel()

	out := aiModelsOutput{ActiveProvider: providers.ByID(cfg.AI.Provider).ID}
	for _, p := range providers.All() {
		entry := aiModelsProvider{Provider: p}
		entry.ResolvedLight, entry.ResolvedStrong = providers.ResolveModelsFor(cfg, p.ID)
		entry.Models = p.KnownModels
		if p.LiveModels {
			// Best-effort: an unreachable server yields an empty list plus an
			// error string, never a failing command.
			models, err := ollama.ListModels(ctx, cfg.AI.OllamaURL)
			if err != nil {
				entry.Error = logredact.Full(err)
			} else {
				entry.Models = models
			}
		}
		out.Providers = append(out.Providers, entry)
	}

	w := cmd.OutOrStdout()
	if aiModelsFlagJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(out)
	}

	for _, p := range out.Providers {
		active := " "
		if p.ID == out.ActiveProvider {
			active = "*"
		}
		fmt.Fprintf(w, "%s %s (%s)\n", active, p.DisplayName, p.ID)
		fmt.Fprintf(w, "    light:  %s\n", orPickHint(p.ResolvedLight))
		fmt.Fprintf(w, "    strong: %s\n", orPickHint(p.ResolvedStrong))
		if p.LiveModels {
			switch {
			case p.Error != "":
				fmt.Fprintf(w, "    models: unavailable (%s)\n", p.Error)
			case len(p.Models) == 0:
				fmt.Fprintf(w, "    models: none installed\n")
			default:
				fmt.Fprintf(w, "    models: %s\n", strings.Join(p.Models, ", "))
			}
		}
	}
	return nil
}

// orPickHint renders an unresolved (empty) model as an instruction instead
// of a blank — only ollama can resolve empty, since it ships no default.
func orPickHint(model string) string {
	if model == "" {
		return "(not set — pick a model, e.g. via ai.models.strong)"
	}
	return model
}

func emitError(enc *json.Encoder, msg string) {
	if aiFlagEvents == "v2" {
		_ = enc.Encode(chat.Event{Type: chat.EventError, TurnID: v2TurnID(), Code: chat.CodeInternal, Message: msg, Retryable: true})
		return
	}
	_ = enc.Encode(aiStreamEvent{Type: "error", Error: msg})
	_ = enc.Encode(aiStreamEvent{Type: "done"})
}

// v2TurnID is the turn id `ai query --events v2` stamps on its events: the
// --turn flag when given (tool-bearing chats pass one), else "query".
func v2TurnID() string {
	if aiFlagTurn != "" {
		return aiFlagTurn
	}
	return "query"
}

// streamQueryV2 renders a one-shot query as protocol-v2 events: turn_start,
// text_delta per chunk (a tool boundary never wipes text), tool_start/
// tool_end and usage from a provider with the chat events on
// (transport.Options.ToolEvents), then turn_done —
// or, on failure, one classified turn error in its place.
func streamQueryV2(w io.Writer, turnID string, textCh <-chan ai.StreamChunk, errCh <-chan error, sidCh <-chan string) {
	out := chat.NewEventWriter(w)
	_ = out.Emit(chat.Event{Type: chat.EventTurnStart, TurnID: turnID})
	for chunk := range textCh {
		for _, e := range chat.ChunkEvents(turnID, chunk) {
			_ = out.Emit(e)
		}
	}
	sid := ""
	for s := range sidCh {
		if s != "" {
			sid = s
		}
	}
	for err := range errCh {
		if err != nil {
			code, reason, retry := queryErrorClass(err)
			_ = out.Emit(chat.Event{Reason: reason, Type: chat.EventError, TurnID: turnID, Code: code, Message: logredact.Full(err), Retryable: retry})
			return
		}
	}
	_ = out.Emit(chat.Event{Type: chat.EventTurnDone, TurnID: turnID, Status: chat.StatusComplete, SessionID: sid})
}

// queryErrorClass is a failed query's code, reason and retry hint: the
// router's deferral is "quota_wait", anything else chat.ClassifyFailure (a
// typed failure first, the Claude text matcher only for an untyped error).
func queryErrorClass(err error) (code, reason string, retryable bool) {
	code, reason, retryable = chat.ClassifyFailure(err)
	if errors.Is(err, providerrouting.ErrDeferred) {
		return code, "quota_wait", false
	}
	return code, reason, retryable
}

// refuseQuery ends a query refused before any model call: the error as the
// requested protocol's event (v2: one classified error; v1: error + done),
// and a failed exit carrying err for stderr. Unlike emitError's setup
// errors (exit 0), a refused capability is a failed command: a caller that
// skipped its own capability check must not read the run as answered.
func refuseQuery(enc *json.Encoder, err error) error {
	code, reason, retry := queryErrorClass(err)
	if aiFlagEvents == "v2" {
		_ = enc.Encode(chat.Event{Type: chat.EventError, TurnID: v2TurnID(), Code: code, Reason: reason,
			Message: logredact.Full(err), Retryable: retry})
	} else {
		_ = enc.Encode(aiStreamEvent{Type: "error", Error: logredact.Full(err), Code: code, Reason: reason, Retryable: retry})
		_ = enc.Encode(aiStreamEvent{Type: "done"})
	}
	return &exitCodeError{code: 1, err: err}
}

// resolveReadFolder resolves --read-folder to the folder of a workbench in
// the database at dbPath: absolute, symlinks resolved, an existing directory
// bound to a workbench (a subfolder is not). "" without the flag. Any
// refusal is a usage error (exit 2), as is combining it with --tools: a
// read-folder run mounts no write tool. --read-folder-ask N instead names the
// folder by a spec/plan review ask (resolveReviewReadFolder), and
// --read-folder-round N by a diff review round (resolveRoundReadFolder);
// each excludes the other two and --tools the same way.
func resolveReadFolder(cmd *cobra.Command, dbPath string) (string, error) {
	// An explicit id flag is a request even at 0: refused, never ignored.
	roundGiven := cmd.Flags().Changed("read-folder-round")
	askGiven := cmd.Flags().Changed("read-folder-ask")
	if roundGiven {
		if aiFlagReadFolder != "" || askGiven {
			return "", usageError("give one of --read-folder, --read-folder-ask or --read-folder-round")
		}
		if aiFlagTools != "" {
			return "", usageError("--read-folder-round runs without --tools")
		}
		return resolveRoundReadFolder(dbPath, aiFlagReadFolderRound)
	}
	if askGiven {
		if aiFlagReadFolder != "" {
			return "", usageError("give --read-folder or --read-folder-ask, not both")
		}
		if aiFlagTools != "" {
			return "", usageError("--read-folder-ask runs without --tools")
		}
		return resolveReviewReadFolder(dbPath, aiFlagReadFolderAsk)
	}
	if aiFlagReadFolder == "" {
		return "", nil
	}
	if aiFlagTools != "" {
		return "", usageError("--read-folder runs without --tools")
	}
	abs, err := filepath.Abs(aiFlagReadFolder)
	if err != nil {
		return "", usageError("--read-folder %s: %v", aiFlagReadFolder, err)
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", usageError("--read-folder %s: %v", aiFlagReadFolder, err)
	}
	if info, err := os.Stat(resolved); err != nil || !info.IsDir() {
		return "", usageError("--read-folder %s: not a directory", aiFlagReadFolder)
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return "", usageError("--read-folder: opening the database: %v", err)
	}
	defer func() { _ = database.Close() }()
	wb, err := database.WorkbenchByFolder(resolved)
	if err != nil {
		if errors.Is(err, db.ErrWorkbenchNotFound) {
			return "", usageError("--read-folder %s: not a workbench folder", aiFlagReadFolder)
		}
		return "", usageError("--read-folder %s: %v", aiFlagReadFolder, err)
	}
	return wb.FolderPath, nil
}

// resolveReviewReadFolder is --read-folder-ask's folder: the one the reviewer
// of spec/plan review ask askID read, computed by the reviewer's own
// specreview.ReadFolder (the session's recorded working directory when it is
// still a directory, else the workbench folder), then symlink-resolved and
// checked to be a directory. The reviewer reads that same path, so a recorded
// folder that is now a symlink leads both to its target. Any failure is a
// usage error (exit 2).
func resolveReviewReadFolder(dbPath string, askID int64) (string, error) {
	if askID <= 0 {
		return "", usageError("--read-folder-ask %d: not an ask id", askID)
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return "", usageError("--read-folder-ask: opening the database: %v", err)
	}
	defer func() { _ = database.Close() }()
	ask, err := database.GetOwnerAskByID(askID)
	if err != nil {
		return "", usageError("--read-folder-ask %d: %v", askID, err)
	}
	if t := specreview.DocType(ask.DocType); ask.Kind != "review" || (t != specreview.Spec && t != specreview.Plan) {
		return "", usageError("--read-folder-ask %d: not a spec or plan review", askID)
	}
	dir, err := specreview.ReadFolder(database, ask)
	if err != nil {
		return "", usageError("--read-folder-ask %d: %v", askID, err)
	}
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", usageError("--read-folder-ask %d: %v", askID, err)
	}
	if info, err := os.Stat(resolved); err != nil || !info.IsDir() {
		return "", usageError("--read-folder-ask %d: not a directory", askID)
	}
	return resolved, nil
}

// resolveRoundReadFolder is --read-folder-round's folder: the one diff review
// round roundID was taken from (review_rounds.folder_root — the session's
// worktree, or the workbench's folder inside it for a workbench bound to a
// repository subfolder; a branch-tip round's folder too), symlink-resolved and
// checked to be a directory. Owner, ask #611: the branch-review reviewer names
// its folder by the round, so --read-folder stays workbench folders only. Any
// failure is a usage error (exit 2); there is no fallback to the workbench
// folder.
func resolveRoundReadFolder(dbPath string, roundID int64) (string, error) {
	if roundID <= 0 {
		return "", usageError("--read-folder-round %d: not a review round id", roundID)
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return "", usageError("--read-folder-round: opening the database: %v", err)
	}
	defer func() { _ = database.Close() }()
	round, err := database.ReviewRoundByID(roundID)
	if err != nil {
		return "", usageError("--read-folder-round %d: %v", roundID, err)
	}
	if round == nil {
		return "", usageError("--read-folder-round %d: no such review round", roundID)
	}
	// EvalSymlinks("") is ".", the CLI's own cwd: an empty or relative
	// recorded folder is refused, never read relative to the process.
	if !filepath.IsAbs(round.FolderRoot) {
		return "", usageError("--read-folder-round %d: the round records no absolute folder", roundID)
	}
	resolved, err := filepath.EvalSymlinks(round.FolderRoot)
	if err != nil {
		return "", usageError("--read-folder-round %d: %v", roundID, err)
	}
	if info, err := os.Stat(resolved); err != nil || !info.IsDir() {
		return "", usageError("--read-folder-round %d: not a directory", roundID)
	}
	return resolved, nil
}

func chatMCPArgs() []string {
	args := []string{"--chat", "--surface", aiFlagSurface, "--conversation", strconv.FormatInt(aiFlagConversation, 10), "--turn", aiFlagTurn}
	if aiFlagContextType != "" {
		args = append(args, "--context-type", aiFlagContextType, "--context-id", aiFlagContextID)
	}
	return args
}
