package ai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/claude"
	"watchtower/internal/digest"
)

// Usage holds token metrics from an AI call.
type Usage struct {
	InputTokens    int
	OutputTokens   int
	TotalAPITokens int
}

// cliUsage is the nested usage object in the Claude CLI JSON response.
type cliUsage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
}

// cliResponse is the JSON structure returned by `claude --output-format json`.
type cliResponse struct {
	Type       string   `json:"type"`
	Subtype    string   `json:"subtype"`
	Result     string   `json:"result"`
	CostUSD    float64  `json:"total_cost_usd"`
	DurationMS int      `json:"duration_ms"`
	NumTurns   int      `json:"num_turns"`
	IsError    bool     `json:"is_error"`
	SessionID  string   `json:"session_id"`
	Usage      cliUsage `json:"usage"`
}

// parseCLIOutput handles both output formats from the Claude CLI:
//   - Single JSON object: {"result": "...", ...}
//   - Streaming JSON array: [{"type":"system",...}, ..., {"type":"result","result":"...",...}]
func parseCLIOutput(output []byte) (*cliResponse, error) {
	trimmed := bytes.TrimSpace(output)

	// Try single JSON object first (legacy format)
	if len(trimmed) > 0 && trimmed[0] == '{' {
		var resp cliResponse
		if err := json.Unmarshal(trimmed, &resp); err == nil {
			return &resp, nil
		}
	}

	// Try JSON array (streaming format) — find the "result" event
	if len(trimmed) > 0 && trimmed[0] == '[' {
		var events []cliResponse
		if err := json.Unmarshal(trimmed, &events); err != nil {
			return nil, fmt.Errorf("parsing claude CLI output array: %w", err)
		}
		for i := len(events) - 1; i >= 0; i-- {
			if events[i].Type == "result" {
				return &events[i], nil
			}
		}
		return nil, fmt.Errorf("no result event found in claude CLI streaming output (%d events)", len(events))
	}

	return nil, fmt.Errorf("unexpected claude CLI output format: %s", claude.DescribeOutput(trimmed))
}

// envelopeMessage returns the CLI's own diagnostic message for a failed run,
// bounded and rune-safe — the digest generator's errorEnvelopeMessage
// precedent (internal/digest/generator.go), reused here so a failed chat
// query surfaces the CLI's own reason (e.g. "Invalid API key · Please run
// /login") instead of a bare exit code. The cap keeps a subtype=error_max_turns
// envelope (whose "result" carries the model's own partial output rather than
// a short diagnostic) from writing an unbounded amount of that content into
// logs or the UI.
func envelopeMessage(result string) string {
	msg := strings.TrimSpace(result)
	if msg == "" {
		return "no message in the CLI result envelope"
	}
	const maxEnvelopeMessage = 4096
	if len(msg) <= maxEnvelopeMessage {
		return msg
	}
	// Back off to a rune boundary: this text is model output and routinely
	// Cyrillic, so a byte cut lands mid-rune and writes a broken one into logs.
	cut := maxEnvelopeMessage
	for cut > 0 && !utf8.RuneStart(msg[cut]) {
		cut--
	}
	return msg[:cut] + fmt.Sprintf("… (%d bytes truncated)", len(msg)-cut)
}

// ExternalMCPServer is a plain DTO describing an owner-added external MCP
// server to merge into the chat config and tool allowlist. It mirrors the
// shape of db.ExternalConnection without importing internal/db, keeping
// internal/ai free of a DB dependency.
type ExternalMCPServer struct {
	Name    string // becomes the mcpServers key and the mcp__<Name> allow token
	Kind    string // "stdio" | "http"
	Command string
	Args    []string
	URL     string
	Env     map[string]string
	Headers map[string]string
}

// Client wraps the Claude Code CLI for AI queries.
type Client struct {
	model     string
	dbPath    string // path to SQLite database for MCP server
	claudeCmd string // path to claude binary, default "claude"
	// mcpArgs are appended to `watchtower mcp --db-path <db>` — the chat
	// mode flags (--chat --surface … --conversation … --turn …) the Desktop
	// passes through `ai query --tools chat`. Empty = the read-only dev server.
	mcpArgs []string
	// externalServers are owner-added external MCP servers (Quick Connections)
	// merged into the mcp-config JSON and the --allowedTools allowlist
	// alongside the built-in watchtower server. Empty = today's behavior.
	externalServers []ExternalMCPServer
	// mcpConfigTempPath is set by buildArgs when hasSecret() is true — the
	// mcp-config JSON (which then contains a secret Env/Header value) is
	// written to this 0600 temp file instead of argv, and the caller (Query/
	// QuerySync) removes it once the subprocess has been reaped.
	mcpConfigTempPath string
}

// SetMCPArgs appends extra flags to the MCP server command (chat mode).
func (c *Client) SetMCPArgs(extra []string) { c.mcpArgs = extra }

// SetExternalMCPServers registers owner-added external MCP servers to merge
// into the chat's mcp-config and tool allowlist alongside the built-in
// watchtower server.
func (c *Client) SetExternalMCPServers(s []ExternalMCPServer) { c.externalServers = s }

// ExternalServersForTest exposes the registered external MCP servers for
// tests outside this package (e.g. cmd's chat-wiring tests) — the field
// itself stays unexported since nothing else needs to read it back.
func (c *Client) ExternalServersForTest() []ExternalMCPServer { return c.externalServers }

// NewClient creates a new AI client that invokes the Claude Code CLI.
// dbPath is the path to the SQLite database; when non-empty, an MCP SQLite
// server is attached so the AI can query the database directly.
// claudePath is an optional explicit path to the claude binary; pass "" for default PATH lookup.
func NewClient(model, dbPath, claudePath string) *Client {
	return &Client{
		model:     model,
		dbPath:    dbPath,
		claudeCmd: claude.FindBinary(claudePath),
	}
}

// promptFlagAndStdin builds the "-p" flag (and its inline value, when safe)
// for buildArgs, plus the same message again as stdin content when it must
// travel that way instead of via argv: either it exceeds
// digest.StdinThreshold (ARG_MAX safety — the digest.generateArgs precedent,
// hour-long meeting transcripts run to hundreds of KB) or it begins with
// '-', which a bare positional right after "-p" would then be parsed as a
// new flag rather than consumed as -p's value — claude's --print takes an
// OPTIONAL value, so a following dash-led token is never taken as it. A bare
// "-p" with no following value makes claude read the prompt from stdin.
func promptFlagAndStdin(userMessage string) (flagArgs []string, stdin string) {
	if len(userMessage) > digest.StdinThreshold || strings.HasPrefix(userMessage, "-") {
		return []string{"-p"}, userMessage
	}
	return []string{"-p", userMessage}, ""
}

// buildArgs constructs the common CLI arguments, plus stdin content when
// userMessage must travel that way instead of inline (see
// promptFlagAndStdin). When sessionID is non-empty, --resume is used instead
// of --system-prompt (the system prompt is already baked into the existing
// session).
func (c *Client) buildArgs(systemPrompt, userMessage, outputFormat, sessionID string) ([]string, string) {
	promptArgs, stdin := promptFlagAndStdin(userMessage)
	// slices.Concat always allocates a fresh backing array, so the append
	// calls below can never alias (and corrupt) promptFlagAndStdin's slice —
	// unlike a plain append(promptArgs, tail...), which happens to be safe
	// today only because promptFlagAndStdin returns full-capacity literals.
	args := slices.Concat(promptArgs, []string{
		"--output-format", outputFormat,
		"--model", c.model,
		// Allowlist: the watchtower MCP server — read-only in dev mode; in
		// chat mode its write tools only record proposals (see internal/tools) —
		// plus one mcp__<Name> token per owner-added external server (Quick
		// Connections). Bash and any other built-in tools are deliberately
		// excluded — a prompt-injection payload in synced Slack/Jira content
		// must not be able to run shell commands. The task-chat agent still
		// changes targets ONLY via watchtower-action approval cards, never by
		// writing to the DB directly.
		"--allowedTools", c.allowedToolsFlag(),
		// Hide every built-in tool from the model outright, not just deny it:
		// a tool that is merely denied still shows up in the model's tool list,
		// so it tries the call, gets a silent headless rejection, and then asks
		// the user to "approve tool permissions" — a dead-end UX in the app's
		// chats. Three groups, all deliberate:
		//  - file editing + Claude Code task tooling (Edit/Write/TodoWrite/Task):
		//    targets change ONLY via watchtower-action approval cards;
		//  - shell + web (Bash/WebSearch/WebFetch): the assistant must never
		//    reach live Slack/Jira/Calendar or the open web — the local DB
		//    mirrors the sources, and web fetches are an exfiltration channel
		//    for prompt-injection payloads in synced content;
		//  - filesystem reads (Read/Grep/Glob/LS): local files are out of scope,
		//    and probing user folders can trigger TCC prompts (a project P0).
		"--disallowedTools", DisallowedTools,
		// Skip user-level ~/.claude/settings.json so its plugins/hooks/CLAUDE.md
		// auto-discovery don't probe ~/Desktop or ~/Documents at startup —
		// those probes trigger macOS TCC prompts attributed to Watchtower.app.
		// Keychain-backed OAuth still works because we don't override CLAUDE_CONFIG_DIR.
		"--setting-sources", "project,local",
		// Only the MCP servers named in --mcp-config (watchtower + the owner's
		// Quick Connections): never the owner's claude.ai connectors or any
		// other server the CLI would load on its own.
		"--strict-mcp-config",
	})
	// Claude CLI requires --verbose for stream-json output format.
	if outputFormat == "stream-json" {
		args = append(args, "--verbose")
	}
	if c.dbPath != "" {
		mcpConfig := c.buildMCPConfig()
		if c.hasSecret() {
			// A secret (Env/Headers) must never sit in argv — it's visible to
			// every other process on the box via `ps`. Write the config to a
			// 0600 temp file instead and pass its path; the caller removes the
			// file once the subprocess no longer needs it (after cmd.Wait()).
			if path, err := writeMCPConfigTempFile(mcpConfig); err == nil {
				c.mcpConfigTempPath = path
				args = append(args, "--mcp-config", path)
			} else {
				// On a temp-file write failure, --mcp-config is omitted rather
				// than falling back to inline JSON: the whole point of this path
				// is that the secret must never reach argv, so a degraded chat
				// (no external MCP servers, and no built-in watchtower read
				// tools either, this call) beats a leaked secret. Logged so the
				// degradation isn't silent.
				log.Printf("warning: failed to write mcp-config temp file, omitting --mcp-config (built-in tools unavailable this call): %v", err)
			}
		} else {
			args = append(args, "--mcp-config", mcpConfig)
		}
	}
	if sessionID != "" {
		args = append(args, "--resume", sessionID)
	} else {
		args = append(args, "--system-prompt", systemPrompt)
	}
	return args, stdin
}

// hasSecret reports whether any external server carries a non-empty Env or
// Headers map — the signal that the mcp-config JSON must not be passed
// inline on argv (visible to every other process on the box via `ps`).
func (c *Client) hasSecret() bool {
	for _, s := range c.externalServers {
		if len(s.Env) > 0 || len(s.Headers) > 0 {
			return true
		}
	}
	return false
}

// writeMCPConfigTempFile writes the mcp-config JSON to a 0600 temp file and
// returns its path. Called only when hasSecret() is true.
func writeMCPConfigTempFile(config string) (string, error) {
	f, err := os.CreateTemp("", "wt-mcp-*.json")
	if err != nil {
		return "", err
	}
	path := f.Name()
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		os.Remove(path)
		return "", err
	}
	if _, err := f.WriteString(config); err != nil {
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

// DisallowedTools hides every built-in Claude Code tool from the chat model
// (see buildArgs for why each group is hidden). Shared by the one-shot client
// and the warm `ai session` backend. The last two lines are the newer CLI
// built-ins (scheduling/remote triggers, workflows, agent/task plumbing, MCP
// resource readers that would bypass the Quick Connections allowlist) — an
// unknown name is ignored by older CLIs. ToolSearch stays allowed: it loads
// the deferred watchtower tool schemas.
const DisallowedTools = sessionDisallowedTools + "," + WebSearchTool

// SessionDisallowedTools is DisallowedTools minus WebSearch: the main chat's
// warm `ai session` (Claude backend) may search the public web. WebFetch stays
// hidden there too — fetching an arbitrary URL is the exfiltration channel a
// prompt-injection payload in synced content would use, while a search query
// only reaches the provider's own search backend.
const SessionDisallowedTools = sessionDisallowedTools

// WebSearchTool is Claude Code's built-in web search tool.
const WebSearchTool = "WebSearch"

const sessionDisallowedTools = "Edit,Write,NotebookEdit,TodoWrite,Task,TodoRead," +
	"Bash,BashOutput,KillShell,WebFetch,Read,Grep,Glob,LS," +
	"ExitPlanMode,SlashCommand,Skill," +
	"CronCreate,CronDelete,CronList,RemoteTrigger,ScheduleWakeup,PushNotification,Workflow,Monitor," +
	"EnterWorktree,ExitWorktree,ListAgents,SendMessage,TaskCreate,TaskGet,TaskList,TaskStop,TaskUpdate," +
	"ListMcpResourcesTool,ReadMcpResourceTool,ReadMcpResourceDirTool"

// AllowedTools builds the --allowedTools value: the built-in watchtower
// server plus one mcp__<Name> token per external server, in slice order.
func AllowedTools(ext []ExternalMCPServer) string {
	tools := "mcp__watchtower"
	for _, s := range ext {
		tools += ",mcp__" + s.Name
	}
	return tools
}

// ChatMCPConfig renders the chat's mcp-config JSON: the watchtower server
// (this binary as `mcp --db-path <db>` plus mcpArgs) and every external
// server. Shared by the one-shot client and the warm `ai session` backend.
func ChatMCPConfig(dbPath string, mcpArgs []string, ext []ExternalMCPServer) string {
	args := append([]string{"mcp", "--db-path", dbPath}, mcpArgs...)
	servers := map[string]any{
		"watchtower": map[string]any{
			"command": watchtowerBinary(),
			"args":    args,
		},
	}
	for _, s := range ext {
		servers[s.Name] = externalServerConfig(s)
	}
	data, err := json.Marshal(map[string]any{"mcpServers": servers})
	if err != nil {
		return "{}"
	}
	return string(data)
}

// allowedToolsFlag builds the --allowedTools value: the built-in watchtower
// server plus one mcp__<Name> token per external server, in slice order
// (deterministic — no external servers means byte-identical to today).
func (c *Client) allowedToolsFlag() string {
	return AllowedTools(c.externalServers)
}

// buildMCPConfig generates a JSON string for the chat's MCP server config.
// The watchtower server is the watchtower binary itself
// (`watchtower mcp --db-path <db>`), exposing curated read-only tools
// (people, targets, tracks, digests, jira, and raw message search) over
// stdio — no third-party npx package, no network. Owner-added external
// servers (Quick Connections) are merged in alongside it, one entry per
// server: stdio servers run a local command, http servers point at a URL.
func (c *Client) buildMCPConfig() string {
	return ChatMCPConfig(c.dbPath, c.mcpArgs, c.externalServers)
}

// externalServerConfig renders one owner-added external MCP server into its
// mcp-config entry shape. Empty env/headers maps are omitted from the JSON.
func externalServerConfig(s ExternalMCPServer) map[string]any {
	if s.Kind == "http" {
		entry := map[string]any{
			"type": "http",
			"url":  s.URL,
		}
		if len(s.Headers) > 0 {
			entry["headers"] = s.Headers
		}
		return entry
	}
	entry := map[string]any{
		"command": s.Command,
		"args":    s.Args,
	}
	if len(s.Env) > 0 {
		entry["env"] = s.Env
	}
	return entry
}

// watchtowerBinary is the path used to relaunch this binary as an MCP server.
// In the desktop flow the running process IS the watchtower CLI (`ai query`),
// so os.Executable() is the correct self-path; fall back to a bare "watchtower"
// on the caller's PATH if it cannot be determined.
func watchtowerBinary() string {
	if exe, err := os.Executable(); err == nil && exe != "" {
		return exe
	}
	return "watchtower"
}

// Query sends a streaming request via the Claude Code CLI and returns channels
// for text chunks, errors, and the session ID. The sessionIDCh receives at most
// one value — the session ID from the "result" event — enabling multi-turn
// conversations via --resume. Pass a non-empty sessionID to resume an existing session.
func (c *Client) Query(ctx context.Context, systemPrompt, userMessage, sessionID string) (<-chan StreamChunk, <-chan error, <-chan string) {
	textCh := make(chan StreamChunk, 64)
	errCh := make(chan error, 1)
	sidCh := make(chan string, 1)

	go func() {
		defer close(textCh)
		defer close(errCh)
		defer close(sidCh)

		args, promptStdin := c.buildArgs(systemPrompt, userMessage, "stream-json", sessionID)
		// buildArgs may have written the mcp-config to a 0600 temp file
		// (secret present) and recorded its path — clean it up once this
		// goroutine returns. Every path below reaches its return only after
		// the subprocess has been started and reaped via cmd.Wait(), or never
		// started at all, so the file is never removed while the subprocess
		// could still be reading it.
		if c.mcpConfigTempPath != "" {
			defer os.Remove(c.mcpConfigTempPath)
		}
		cmd := exec.CommandContext(ctx, c.claudeCmd, args...)
		if promptStdin != "" {
			cmd.Stdin = strings.NewReader(promptStdin)
		}
		// Send SIGINT first for graceful shutdown; SIGKILL after 5s.
		cmd.Cancel = func() error {
			return cmd.Process.Signal(os.Interrupt)
		}
		cmd.WaitDelay = 5 * time.Second
		// Pin CWD to a TCC-neutral directory so the Node-based Claude CLI never
		// inherits a parent CWD inside ~/Documents or ~/Desktop, which would
		// trigger macOS Files & Folders prompts attributed to Watchtower.
		cmd.Dir = os.TempDir()
		cmd.Env = append(os.Environ(),
			"PATH="+claude.RichPATH(),
		)

		stdout, err := cmd.StdoutPipe()
		if err != nil {
			errCh <- fmt.Errorf("creating stdout pipe: %w", err)
			return
		}

		// Cap stderr to 64KB to prevent unbounded memory growth.
		var stderrBuf strings.Builder
		cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

		if err := cmd.Start(); err != nil {
			errCh <- classifyError(err, "")
			return
		}

		scanner := bufio.NewScanner(stdout)
		// Allow up to 1MB lines for large context responses
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

		// lastResult remembers the most recent "result" event's is_error/result
		// fields — the CLI's own diagnostic (e.g. "Invalid API key · Please run
		// /login") for an API/usage failure, which otherwise arrives on stdout
		// as an ordinary envelope (classifyError only ever sees stderr, which
		// is empty in this case; see internal/digest/generator.go's
		// errorEnvelopeMessage for the same pattern on the batch path).
		var lastResult *streamEvent

		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				continue
			}

			var event streamEvent
			if err := json.Unmarshal([]byte(line), &event); err != nil {
				continue
			}

			if event.Type == "result" {
				captured := event
				lastResult = &captured
				if event.SessionID != "" {
					sidCh <- event.SessionID
				}
			}

			// A tool call interrupts the turn: signal a boundary so the consumer
			// drops the pre-tool preamble (including any text in this very event)
			// and starts the visible answer fresh from what follows the tool.
			if event.hasToolUse() {
				select {
				case textCh <- StreamChunk{ToolBoundary: true}:
				case <-ctx.Done():
					_ = cmd.Wait()
					errCh <- ctx.Err()
					return
				}
				continue
			}

			text := event.extractText()
			if text == "" {
				continue
			}

			select {
			case textCh <- StreamChunk{Text: text}:
			case <-ctx.Done():
				// CommandContext handles killing the process; just reap it.
				_ = cmd.Wait()
				errCh <- ctx.Err()
				return
			}
		}

		if err := scanner.Err(); err != nil {
			_ = cmd.Wait()
			errCh <- fmt.Errorf("reading claude output: %w", err)
			return
		}

		waitErr := cmd.Wait()

		// The CLI can flag is_error in its own envelope regardless of exit
		// code (a failure surfaced this way, or one that exits 0 anyway) —
		// its own message is always more actionable than a bare exit code or
		// empty stderr, so it takes priority over classifyError below.
		if lastResult != nil && lastResult.IsError {
			errCh <- fmt.Errorf("claude returned error (subtype=%s): %s", lastResult.Subtype, envelopeMessage(lastResult.Result))
			return
		}

		if waitErr != nil {
			errCh <- classifyError(waitErr, stderrBuf.String())
		}
	}()

	return textCh, errCh, sidCh
}

// QuerySync sends a non-streaming request via the Claude Code CLI and returns
// the full response text and token usage. Pass a non-empty sessionID to resume
// an existing session.
func (c *Client) QuerySync(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, error) {
	args, promptStdin := c.buildArgs(systemPrompt, userMessage, "json", sessionID)
	// buildArgs may have written the mcp-config to a 0600 temp file (secret
	// present) and recorded its path — clean it up on every return path.
	// cmd.Output() below blocks until the subprocess exits, so by the time
	// this defer runs the subprocess can no longer be reading the file.
	if c.mcpConfigTempPath != "" {
		defer os.Remove(c.mcpConfigTempPath)
	}
	cmd := exec.CommandContext(ctx, c.claudeCmd, args...)
	if promptStdin != "" {
		cmd.Stdin = strings.NewReader(promptStdin)
	}
	cmd.Cancel = func() error {
		return cmd.Process.Signal(os.Interrupt)
	}
	cmd.WaitDelay = 5 * time.Second
	// See Query() for rationale on cmd.Dir.
	cmd.Dir = os.TempDir()
	cmd.Env = append(os.Environ(),
		"PATH="+claude.RichPATH(),
	)

	var stderrBuf strings.Builder
	cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

	output, err := cmd.Output()
	if err != nil {
		// The CLI reports an API or usage failure as an ordinary result
		// envelope on stdout and exits 1, with the actionable reason (e.g.
		// "Invalid API key · Please run /login") behind kilobytes of usage
		// telemetry — and with stderr empty. Parse it first so that message
		// survives instead of a bare "exit code 1" (the digest generator's
		// errorEnvelopeMessage precedent, internal/digest/generator.go).
		if exitErr, ok := err.(*exec.ExitError); ok {
			if resp, perr := parseCLIOutput(output); perr == nil && resp.IsError {
				return "", nil, fmt.Errorf("claude CLI failed (exit %d, subtype=%s): %s",
					exitErr.ExitCode(), resp.Subtype, envelopeMessage(resp.Result))
			}
		}
		return "", nil, classifyError(err, stderrBuf.String())
	}

	resp, err := parseCLIOutput(output)
	if err != nil {
		// Fallback: treat as plain text if JSON parsing fails (e.g. old CLI version)
		return strings.TrimRight(string(output), "\n"), nil, nil //nolint:nilerr // intentional fallback to plain text
	}

	if resp.IsError {
		return "", nil, fmt.Errorf("claude returned error (subtype=%s): %s", resp.Subtype, envelopeMessage(resp.Result))
	}

	totalAPI := resp.Usage.InputTokens + resp.Usage.CacheReadInputTokens + resp.Usage.CacheCreationInputTokens
	usage := &Usage{
		InputTokens:    resp.Usage.InputTokens,
		OutputTokens:   resp.Usage.OutputTokens,
		TotalAPITokens: totalAPI,
	}

	return strings.TrimRight(resp.Result, "\n"), usage, nil
}

// streamEvent represents a JSON event from Claude Code CLI stream-json output.
type streamEvent struct {
	Type      string         `json:"type"`
	Subtype   string         `json:"subtype"`
	SessionID string         `json:"session_id"`
	Message   *streamMessage `json:"message"`
	Result    string         `json:"result"`
	IsError   bool           `json:"is_error"`
}

type streamMessage struct {
	Content []streamContent `json:"content"`
}

type streamContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// extractText returns the text content from a stream event, if any.
func (e *streamEvent) extractText() string {
	// Current format: {"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}
	if e.Type == "assistant" && e.Message != nil {
		var sb strings.Builder
		for _, c := range e.Message.Content {
			if c.Type == "text" {
				sb.WriteString(c.Text)
			}
		}
		return sb.String()
	}
	// Note: "result" events contain the full response but we skip them
	// to avoid duplicating text already streamed via "assistant" events.
	return ""
}

// hasToolUse reports whether an assistant event carries a tool_use content
// block — the marker that the model paused the turn to call a tool.
func (e *streamEvent) hasToolUse() bool {
	if e.Type != "assistant" || e.Message == nil {
		return false
	}
	for _, c := range e.Message.Content {
		if c.Type == "tool_use" {
			return true
		}
	}
	return false
}

// limitedWriter wraps an io.Writer and stops writing after limit bytes.
type limitedWriter struct {
	w       io.Writer
	limit   int
	written int
}

// Write always reports len(p) on success, even when it keeps only a prefix:
// os/exec drains stderr through io.Copy, which turns a short count into
// io.ErrShortWrite and fails a run that exited 0.
func (lw *limitedWriter) Write(p []byte) (int, error) {
	remaining := lw.limit - lw.written
	if remaining <= 0 {
		return len(p), nil // silently discard
	}
	kept := p
	if len(kept) > remaining {
		kept = kept[:remaining]
	}
	n, err := lw.w.Write(kept)
	lw.written += n
	if err != nil {
		return n, err
	}
	return len(p), nil
}

// classifyError wraps CLI errors with user-friendly messages.
func classifyError(err error, stderr string) error {
	// Check if claude binary is not found
	if execErr, ok := err.(*exec.Error); ok {
		if execErr.Err == exec.ErrNotFound {
			return fmt.Errorf("claude CLI not found — install Claude Code first: https://docs.anthropic.com/en/docs/claude-code")
		}
	}

	// Check exit error for details
	if exitErr, ok := err.(*exec.ExitError); ok {
		code := exitErr.ExitCode()
		stderrMsg := strings.TrimSpace(stderr)
		if stderrMsg == "" {
			stderrMsg = strings.TrimSpace(string(exitErr.Stderr))
		}

		if stderrMsg != "" {
			return fmt.Errorf("claude CLI failed (exit %d): %s", code, stderrMsg)
		}
		return fmt.Errorf("claude CLI failed with exit code %d", code)
	}

	return fmt.Errorf("claude CLI error: %w", err)
}
