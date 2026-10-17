package digest

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/claude"
	"watchtower/internal/fsutil"
)

// limitedWriter wraps a writer and stops writing after limit bytes.
type limitedWriter struct {
	w       io.Writer
	limit   int
	written int
}

func (lw *limitedWriter) Write(p []byte) (int, error) {
	if lw.written >= lw.limit {
		return len(p), nil
	}
	total := len(p)
	remaining := lw.limit - lw.written
	if len(p) > remaining {
		p = p[:remaining]
	}
	n, err := lw.w.Write(p)
	lw.written += n
	if err != nil {
		return n, err
	}
	// Report full length consumed to avoid short-write errors from callers.
	return total, nil
}

// ClaudeGenerator implements Generator by calling the Claude Code CLI.
type ClaudeGenerator struct {
	modelLight  string
	modelStrong string
	claudePath  string // optional override from config (claude_path)
	// isolated runs the child in its own process group without the
	// variables in dropEnv (see SetIsolatedChild).
	isolated bool
	dropEnv  []string
}

// NewClaudeGenerator creates a generator that uses the Claude CLI.
// modelLight/modelStrong are the per-tier models (see TierForSource);
// claudePath is an optional explicit path to the claude binary; pass "" for auto-detection.
func NewClaudeGenerator(modelLight, modelStrong, claudePath string) *ClaudeGenerator {
	return &ClaudeGenerator{modelLight: modelLight, modelStrong: modelStrong, claudePath: claudePath}
}

// SetIsolatedChild makes every subsequent Generate run claude through
// IsolateChild: its own process group, killed whole on cancel, and none of
// the variables in dropEnv.
func (g *ClaudeGenerator) SetIsolatedChild(dropEnv ...string) {
	g.isolated, g.dropEnv = true, dropEnv
}

// modelForContext picks the tier model for a call: the source tag routes to
// light or strong; an untagged call uses the strong model.
func (g *ClaudeGenerator) modelForContext(ctx context.Context) string {
	if s, ok := SourceFromContext(ctx); ok && TierForSource(s) == TierLight {
		return g.modelLight
	}
	return g.modelStrong
}

// validateModelArgs builds the CLI args for a minimal model-validation request.
// --setting-sources project,local skips the user-level ~/.claude/settings.json so
// its plugins/hooks/CLAUDE.md auto-discovery don't probe ~/Desktop or ~/Documents
// at startup — those probes trigger macOS TCC prompts attributed to Watchtower.app.
// Keychain-backed OAuth still works because CLAUDE_CONFIG_DIR is left untouched.
func validateModelArgs(model string) []string {
	return []string{
		"-p", "reply ok",
		"--output-format", "json",
		"--model", model,
		"--no-session-persistence",
		"--tools", "",
		"--max-tokens", "10",
		"--setting-sources", "project,local",
	}
}

// generateArgs builds the CLI args for a digest generation request and their
// stdin content. The args carry flags and paths only: the user message is
// returned as the stdin content ("-p" with no value makes claude read the
// prompt from there) and a non-empty system prompt travels as the 0600
// systemPromptFile (see Generate) — on argv either would be readable by
// every local process through `ps` and could hit ARG_MAX.
// See validateModelArgs for why --setting-sources project,local is required.
func generateArgs(model, systemPromptFile, userMessage string) ([]string, string) {
	args := []string{
		"-p",
		"--output-format", "json",
		"--model", model,
		"--no-session-persistence",
		"--tools", "",
		"--setting-sources", "project,local",
	}
	if systemPromptFile != "" {
		args = append(args, "--system-prompt-file", systemPromptFile)
	}
	return args, userMessage
}

// ValidateModel sends a minimal request to verify the configured model is valid.
// Returns nil if the model works, or an error describing the problem.
func (g *ClaudeGenerator) ValidateModel() error {
	claudeBin := claude.FindBinary(g.claudePath)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, claudeBin, validateModelArgs(g.modelStrong)...)
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 5 * time.Second
	cmd.Dir = os.TempDir()
	cmd.Env = append(os.Environ(),
		"PATH="+claude.RichPATH(),
	)

	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("model validation failed for %q: %w", g.modelStrong, err)
	}

	resp, err := parseCLIOutput(output)
	if err != nil {
		return fmt.Errorf("model validation: unexpected response for %q: %w", g.modelStrong, err)
	}
	if resp.IsError {
		return fmt.Errorf("model %q is not available: %s", g.modelStrong, resp.Result)
	}
	return nil
}

// cliUsage is the nested usage object in the Claude CLI response.
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
	Subtype    string   `json:"subtype"`
	StopReason string   `json:"stop_reason"`
	Usage      cliUsage `json:"usage"`
}

// errorEnvelopeMessage returns the CLI's own message for a failed run, falling
// back to a fixed string when the envelope carries none — an error whose tail
// is empty tells a reader nothing.
func errorEnvelopeMessage(resp *cliResponse) string {
	msg := strings.TrimSpace(resp.Result)
	if msg == "" {
		return "no message in the CLI result envelope"
	}
	// On subtype=error_max_turns the envelope's result carries the model's own
	// partial output rather than a short diagnostic, so bound what reaches the
	// log the way the sibling stderr path is bounded by limitedWriter.
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

// Generate calls Claude CLI with the given prompt and returns the response text,
// token usage statistics, and the session ID for reuse.
// Each call creates a fresh session with --no-session-persistence to avoid
// disk clutter. The sessionID parameter is accepted for interface compatibility
// but ignored — session reuse via --resume is not supported by the current CLI.
func (g *ClaudeGenerator) Generate(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, string, error) {
	model := g.modelForContext(ctx)

	// The system prompt goes to a 0600 file and the user message to stdin
	// (generateArgs): both carry the owner's data, which on argv would sit
	// readable in `ps` for the run (and a large payload would overflow
	// ARG_MAX).
	var systemPromptFile string
	if systemPrompt != "" {
		path, err := fsutil.WritePrivateTemp(fsutil.SystemPromptTempPrefix+"*.txt", systemPrompt)
		if err != nil {
			return "", nil, "", fmt.Errorf("writing system prompt file: %w", err)
		}
		defer os.Remove(path)
		systemPromptFile = path
	}
	args, stdin := generateArgs(model, systemPromptFile, userMessage)

	claudeBin := claude.FindBinary(g.claudePath)
	cmd := exec.CommandContext(ctx, claudeBin, args...)
	cmd.Stdin = strings.NewReader(stdin)
	// Send SIGINT first for graceful shutdown; SIGKILL after 5s.
	cmd.Cancel = func() error {
		return cmd.Process.Signal(os.Interrupt)
	}
	cmd.WaitDelay = 5 * time.Second
	// Run from ~/.config/watchtower as a stable working directory.
	configDir, _ := os.UserHomeDir()
	if configDir != "" {
		configDir = filepath.Join(configDir, ".config", "watchtower")
		if err := fsutil.MakePrivateDir(configDir); err != nil {
			configDir = os.TempDir()
		}
		cmd.Dir = configDir
	} else {
		cmd.Dir = os.TempDir()
	}
	// Build a clean environment:
	// - Enrich PATH so `#!/usr/bin/env node` resolves from macOS .app bundles.
	// - Remove CLAUDECODE to avoid "nested session" detection when launched
	//   from a parent process that is itself a Claude Code session.
	//
	// TCC isolation is handled via --setting-sources project,local on the args
	// (skips ~/.claude/settings.json plugins/hooks). We leave CLAUDE_CONFIG_DIR
	// alone — overriding it breaks keychain auth.
	richPATH := "PATH=" + claude.RichPATH()
	var env []string
	for _, e := range os.Environ() {
		if strings.HasPrefix(e, "CLAUDECODE=") {
			continue
		}
		if strings.HasPrefix(e, "PATH=") {
			continue
		}
		env = append(env, e)
	}
	cmd.Env = append(env, richPATH)
	if g.isolated {
		IsolateChild(cmd, g.dropEnv)
	}

	var stderrBuf strings.Builder
	cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

	output, err := cmd.Output()
	if err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			return "", nil, "", fmt.Errorf("claude CLI not found at %q (PATH=%s) — install Claude Code first", claudeBin, os.Getenv("PATH"))
		}
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			// The CLI reports an API or usage failure as an ordinary result
			// envelope on stdout and exits 1, with the human-readable message
			// behind kilobytes of usage telemetry. Parse it so the error
			// carries that message instead of the whole blob.
			if resp, perr := parseCLIOutput(output); perr == nil && resp.IsError {
				return "", nil, "", fmt.Errorf("claude CLI failed (exit %d, subtype=%s, stop_reason=%s): %s",
					exitErr.ExitCode(), resp.Subtype, resp.StopReason, errorEnvelopeMessage(resp))
			}
			stderrMsg := strings.TrimSpace(stderrBuf.String())
			if stderrMsg == "" {
				stderrMsg = strings.TrimSpace(string(exitErr.Stderr))
			}
			// Stdout the parser could not understand is model-derived text:
			// describe it, never echo it (see claude.DescribeOutput).
			if stderrMsg == "" && len(bytes.TrimSpace(output)) > 0 {
				stderrMsg = "unparseable stdout: " + claude.DescribeOutput(output)
			}
			if stderrMsg != "" {
				return "", nil, "", fmt.Errorf("claude CLI failed (exit %d): %s", exitErr.ExitCode(), stderrMsg)
			}
			return "", nil, "", fmt.Errorf("claude CLI failed with exit code %d", exitErr.ExitCode())
		}
		return "", nil, "", fmt.Errorf("claude CLI error: %w", err)
	}

	resp, err := parseCLIOutput(output)
	if err != nil {
		return "", nil, "", err
	}

	if resp.IsError {
		// Same envelope, same empty-result trap as the non-zero-exit branch
		// above — the CLI can flag is_error and still exit 0.
		return "", nil, "", fmt.Errorf("claude returned error (subtype=%s): %s", resp.Subtype, errorEnvelopeMessage(resp))
	}

	if strings.TrimSpace(resp.Result) == "" {
		return "", nil, "", fmt.Errorf("claude returned empty result (turns=%d, tokens=%d+%d)", resp.NumTurns, resp.Usage.InputTokens, resp.Usage.OutputTokens)
	}

	// Total API tokens = everything the API processed (including cache reads/writes).
	totalAPI := resp.Usage.InputTokens + resp.Usage.CacheReadInputTokens + resp.Usage.CacheCreationInputTokens
	usage := &Usage{
		Model:          model,
		InputTokens:    resp.Usage.InputTokens,
		OutputTokens:   resp.Usage.OutputTokens,
		CostUSD:        0,
		TotalAPITokens: totalAPI,
	}

	return resp.Result, usage, resp.SessionID, nil
}
