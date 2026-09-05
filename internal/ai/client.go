package ai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"watchtower/internal/claude"
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

// Client wraps the Claude Code CLI for AI queries.
type Client struct {
	model     string
	dbPath    string // path to SQLite database for MCP server
	claudeCmd string // path to claude binary, default "claude"
	// mcpArgs are appended to `watchtower mcp --db-path <db>` — the chat
	// mode flags (--chat --surface … --conversation … --turn …) the Desktop
	// passes through `ai query --tools chat`. Empty = the read-only dev server.
	mcpArgs []string
}

// SetMCPArgs appends extra flags to the MCP server command (chat mode).
func (c *Client) SetMCPArgs(extra []string) { c.mcpArgs = extra }

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

// buildArgs constructs the common CLI arguments.
// When sessionID is non-empty, --resume is used instead of --system-prompt
// (the system prompt is already baked into the existing session).
func (c *Client) buildArgs(systemPrompt, userMessage, outputFormat, sessionID string) []string {
	args := []string{
		"-p", userMessage,
		"--output-format", outputFormat,
		"--model", c.model,
		// Allowlist: only the watchtower MCP server — read-only in dev mode; in
		// chat mode its write tools only record proposals (see internal/tools),
		// so the allowlist stays one entry. Bash and any other tools are
		// deliberately excluded — a prompt-injection payload in synced
		// Slack/Jira content must not be able to run shell commands. The
		// task-chat agent still changes targets ONLY via watchtower-action
		// approval cards, never by writing to the DB directly.
		"--allowedTools", "mcp__watchtower",
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
		"--disallowedTools", "Edit,Write,NotebookEdit,TodoWrite,Task,TodoRead," +
			"Bash,BashOutput,KillShell,WebSearch,WebFetch,Read,Grep,Glob,LS," +
			"ExitPlanMode,SlashCommand,Skill",
		// Skip user-level ~/.claude/settings.json so its plugins/hooks/CLAUDE.md
		// auto-discovery don't probe ~/Desktop or ~/Documents at startup —
		// those probes trigger macOS TCC prompts attributed to Watchtower.app.
		// Keychain-backed OAuth still works because we don't override CLAUDE_CONFIG_DIR.
		"--setting-sources", "project,local",
	}
	// Claude CLI requires --verbose for stream-json output format.
	if outputFormat == "stream-json" {
		args = append(args, "--verbose")
	}
	if c.dbPath != "" {
		mcpConfig := c.buildMCPConfig()
		args = append(args, "--mcp-config", mcpConfig)
	}
	if sessionID != "" {
		args = append(args, "--resume", sessionID)
	} else {
		args = append(args, "--system-prompt", systemPrompt)
	}
	return args
}

// buildMCPConfig generates a JSON string for the watchtower MCP server config.
// The server is the watchtower binary itself (`watchtower mcp --db-path <db>`),
// exposing curated read-only tools (people, targets, tracks, digests, jira, and
// raw message search) over stdio — no third-party npx package, no network.
func (c *Client) buildMCPConfig() string {
	args := append([]string{"mcp", "--db-path", c.dbPath}, c.mcpArgs...)
	cfg := map[string]any{
		"mcpServers": map[string]any{
			"watchtower": map[string]any{
				"command": watchtowerBinary(),
				"args":    args,
			},
		},
	}
	data, err := json.Marshal(cfg)
	if err != nil {
		return "{}"
	}
	return string(data)
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

		args := c.buildArgs(systemPrompt, userMessage, "stream-json", sessionID)
		cmd := exec.CommandContext(ctx, c.claudeCmd, args...)
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

		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				continue
			}

			var event streamEvent
			if err := json.Unmarshal([]byte(line), &event); err != nil {
				continue
			}

			// Capture session ID from result event
			if event.Type == "result" && event.SessionID != "" {
				sidCh <- event.SessionID
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

		if err := cmd.Wait(); err != nil {
			errCh <- classifyError(err, stderrBuf.String())
		}
	}()

	return textCh, errCh, sidCh
}

// QuerySync sends a non-streaming request via the Claude Code CLI and returns
// the full response text and token usage. Pass a non-empty sessionID to resume
// an existing session.
func (c *Client) QuerySync(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, error) {
	args := c.buildArgs(systemPrompt, userMessage, "json", sessionID)
	cmd := exec.CommandContext(ctx, c.claudeCmd, args...)
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
		return "", nil, classifyError(err, stderrBuf.String())
	}

	resp, err := parseCLIOutput(output)
	if err != nil {
		// Fallback: treat as plain text if JSON parsing fails (e.g. old CLI version)
		return strings.TrimRight(string(output), "\n"), nil, nil //nolint:nilerr // intentional fallback to plain text
	}

	if resp.IsError {
		return "", nil, fmt.Errorf("claude returned error: %s", resp.Result)
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

func (lw *limitedWriter) Write(p []byte) (int, error) {
	remaining := lw.limit - lw.written
	if remaining <= 0 {
		return len(p), nil // silently discard
	}
	if len(p) > remaining {
		p = p[:remaining]
	}
	n, err := lw.w.Write(p)
	lw.written += n
	return n, err
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
