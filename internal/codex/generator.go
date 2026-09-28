package codex

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"watchtower/internal/digest"
)

// CodexGenerator implements digest.Generator by calling the Codex CLI.
type CodexGenerator struct {
	modelLight  string
	modelStrong string
	codexPath   string
	// stdinOnly routes every user message through stdin regardless of its
	// size (see SetStdinOnly).
	stdinOnly bool
}

// NewCodexGenerator creates a generator that uses the Codex CLI.
// modelLight/modelStrong are the per-tier models (see digest.TierForSource);
// codexPath is an optional explicit path to the codex binary; pass "" for auto-detection.
func NewCodexGenerator(modelLight, modelStrong, codexPath string) *CodexGenerator {
	return &CodexGenerator{modelLight: modelLight, modelStrong: modelStrong, codexPath: codexPath}
}

// SetStdinOnly makes every subsequent Generate pass the user message on
// stdin ("-" positional), never as a positional argv value, whatever its
// size. Callers whose user message carries the owner's chat text set it
// (CHAT-04: `chat title`); every other caller keeps the size-based routing.
func (g *CodexGenerator) SetStdinOnly(v bool) { g.stdinOnly = v }

// Generate calls Codex CLI with the given prompt and returns the response text,
// token usage statistics, and an empty session ID (Codex uses --ephemeral).
func (g *CodexGenerator) Generate(ctx context.Context, systemPrompt, userMessage, _ string) (string, *digest.Usage, string, error) {
	model := g.modelStrong
	if s, ok := digest.SourceFromContext(ctx); ok && digest.TierForSource(s) == digest.TierLight {
		model = g.modelLight
	}

	codexBin := FindBinary(g.codexPath)

	args, stdin := buildArgs(model, systemPrompt, userMessage, g.stdinOnly)

	cmd := exec.CommandContext(ctx, codexBin, args...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	cmd.Cancel = func() error {
		return cmd.Process.Signal(os.Interrupt)
	}
	cmd.WaitDelay = 5 * time.Second
	cmd.Dir = os.TempDir()

	// Build clean environment with enriched PATH.
	var env []string
	for _, e := range os.Environ() {
		if strings.HasPrefix(e, "PATH=") {
			continue
		}
		env = append(env, e)
	}
	cmd.Env = append(env, "PATH="+RichPATH())

	var stderrBuf strings.Builder
	cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

	output, err := cmd.Output()
	if err != nil {
		return "", nil, "", classifyError(err, stderrBuf.String(), codexBin)
	}

	// Parse JSONL output — find last item.completed with agent_message
	result, usage, parseErr := parseJSONLOutput(output)
	if parseErr != nil {
		return "", nil, "", parseErr
	}

	if strings.TrimSpace(result) == "" {
		return "", nil, "", fmt.Errorf("codex returned empty result")
	}

	digestUsage := &digest.Usage{
		Model:        model,
		InputTokens:  usage.InputTokens,
		OutputTokens: usage.OutputTokens,
	}

	return result, digestUsage, "", nil
}

// buildArgs builds the `codex exec` CLI args; when userMessage exceeds
// digest.StdinThreshold (or stdinOnly is set) the final positional arg is "-" (codex reads the
// prompt from stdin) and the message is returned as stdin content instead,
// to stay clear of ARG_MAX on very large inputs (e.g. meeting transcripts).
func buildArgs(model, systemPrompt, userMessage string, stdinOnly bool) ([]string, string) {
	args := []string{
		"exec",
		"--model", model,
		"--json",
		"--ephemeral",
		"--skip-git-repo-check",
		"-c", "approval_policy=never",
		"-c", "sandbox_mode=read-only",
	}
	if systemPrompt != "" {
		args = append(args, "-c", fmt.Sprintf("developer_instructions=%s", systemPrompt))
	}
	stdin := ""
	if stdinOnly || len(userMessage) > digest.StdinThreshold {
		stdin = userMessage
		args = append(args, "-")
	} else {
		args = append(args, userMessage)
	}
	return args, stdin
}

// parseJSONLOutput parses Codex JSONL output and extracts the final agent_message
// content and accumulated usage.
func parseJSONLOutput(output []byte) (string, *CodexUsage, error) {
	var lastContent string
	totalUsage := &CodexUsage{}

	// The whole output is already in memory, so split it instead of using a
	// bufio.Scanner: a command_execution / mcp_tool_call item can exceed any
	// scanner buffer, and a scanner stopping there silently returned the
	// pre-tool preamble as the answer.
	for _, line := range bytes.Split(output, []byte("\n")) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}

		var event CodexEvent
		if err := json.Unmarshal(line, &event); err != nil {
			continue
		}

		if event.Error != nil {
			return "", nil, fmt.Errorf("codex error: %s", event.Error.Message)
		}

		if event.Usage != nil {
			totalUsage.InputTokens += event.Usage.InputTokens
			totalUsage.OutputTokens += event.Usage.OutputTokens
		}

		if event.Type == "item.completed" && event.Item != nil && event.Item.Type == "agent_message" {
			lastContent = event.Item.MessageText()
		}
	}

	if lastContent == "" {
		return "", nil, fmt.Errorf("no agent_message found in codex output")
	}

	return lastContent, totalUsage, nil
}

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
	return total, nil
}

// classifyError wraps CLI errors with user-friendly messages.
func classifyError(err error, stderr, codexBin string) error {
	if execErr, ok := err.(*exec.Error); ok {
		if execErr.Err == exec.ErrNotFound {
			return fmt.Errorf("codex CLI not found at %q — install Codex CLI first", codexBin)
		}
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		stderrMsg := strings.TrimSpace(stderr)
		if stderrMsg == "" {
			stderrMsg = strings.TrimSpace(string(exitErr.Stderr))
		}
		if stderrMsg != "" {
			return fmt.Errorf("codex CLI failed (exit %d): %s", exitErr.ExitCode(), stderrMsg)
		}
		return fmt.Errorf("codex CLI failed with exit code %d", exitErr.ExitCode())
	}
	return fmt.Errorf("codex CLI error: %w", err)
}
