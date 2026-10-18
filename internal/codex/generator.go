package codex

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
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
	// isolated runs the child in its own process group without the
	// variables in dropEnv (see SetIsolatedChild).
	isolated bool
	dropEnv  []string
}

// NewCodexGenerator creates a generator that uses the Codex CLI.
// modelLight/modelStrong are the per-tier models (see digest.TierForSource);
// codexPath is an optional explicit path to the codex binary; pass "" for auto-detection.
func NewCodexGenerator(modelLight, modelStrong, codexPath string) *CodexGenerator {
	return &CodexGenerator{modelLight: modelLight, modelStrong: modelStrong, codexPath: codexPath}
}

// SetIsolatedChild makes every subsequent Generate run codex through
// digest.IsolateChild: its own process group, killed whole on cancel, and
// none of the variables in dropEnv.
func (g *CodexGenerator) SetIsolatedChild(dropEnv ...string) {
	g.isolated, g.dropEnv = true, dropEnv
}

// Generate calls Codex CLI with the given prompt and returns the response text,
// token usage statistics, and an empty session ID (Codex uses --ephemeral).
func (g *CodexGenerator) Generate(ctx context.Context, systemPrompt, userMessage, _ string) (string, *digest.Usage, string, error) {
	model := g.modelStrong
	if s, ok := digest.SourceFromContext(ctx); ok && digest.TierForSource(s) == digest.TierLight {
		model = g.modelLight
	}

	codexBin := FindBinary(g.codexPath)

	args, stdin, promptFile, err := buildArgs(codexBin, model, systemPrompt, userMessage)
	if err != nil {
		return "", nil, "", err
	}
	if promptFile != "" {
		defer os.Remove(promptFile)
	}

	cmd := exec.CommandContext(ctx, codexBin, args...)
	cmd.Stdin = strings.NewReader(stdin)
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
	if g.isolated {
		digest.IsolateChild(cmd, g.dropEnv)
	}

	var stderrBuf strings.Builder
	cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

	output, err := cmd.Output()
	if err != nil {
		return "", nil, "", runError(model, output, err, stderrBuf.String(), codexBin)
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

// execArgs is the common `codex exec` prefix every Watchtower call starts
// with. Beyond the read-only sandbox it switches off codex's local and
// account-connected tools: sandbox_mode=read-only still lets the model run
// shell commands that read anywhere on disk, and the prompts carry untrusted
// Slack/Gmail/Jira text, so an injected "list ~/Documents" (or a curious
// model) would trigger a macOS TCC prompt attributed to Watchtower or pull
// local files into stored output. This is the codex twin of the claude
// side's `--tools ""` (batch) and DisallowedTools (chat). shell_tool also
// gates unified exec; view_image reads local files; computer_use and the
// browser_use pair drive the screen and a browser (their own TCC prompts);
// apps/plugins would expose the owner's ChatGPT connectors — an
// exfiltration channel for an injected prompt. MCP servers configured in
// the owner's own codex config are disabled by a -c override in a run that
// mounts the watchtower server or runs tool-less (Client.mount); web search
// follows the owner's codex setting except where Client.execArgs turns it
// off; the generators here keep the owner's codex setup. An
// unknown features.* key is ignored by older codex builds.
func execArgs(model string) []string {
	return []string{
		"exec",
		"--model", model,
		"--json",
		"--ephemeral",
		"--skip-git-repo-check",
		"-c", "approval_policy=never",
		"-c", "sandbox_mode=read-only",
		"-c", "features.shell_tool=false",
		"-c", "features.unified_exec=false",
		"-c", "features.view_image=false",
		"-c", "features.computer_use=false",
		"-c", "features.browser_use=false",
		"-c", "features.browser_use_external=false",
		"-c", "features.apps=false",
		"-c", "features.plugins=false",
	}
}

// buildArgs builds the `codex exec` CLI args and their stdin content. The
// args carry no prompt text — on argv the owner's data would be readable by
// every local process through `ps`, and a large input (a meeting transcript)
// would hit ARG_MAX: the prompts travel as promptArgs lays them out for the
// codex binary bin (the Client.buildArgs layout), behind the "-" positional.
// promptFile is the system-prompt file to remove once the child has exited.
func buildArgs(bin, model, systemPrompt, userMessage string) (args []string, stdin, promptFile string, err error) {
	instr, stdin, promptFile, err := promptArgs(bin, systemPrompt, userMessage)
	if err != nil {
		return nil, "", "", err
	}
	return append(append(execArgs(model), instr...), "-"), stdin, promptFile, nil
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
	for line := range bytes.SplitSeq(output, []byte("\n")) {
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
	if errors.Is(err, exec.ErrNotFound) {
		return digest.WithCause(fmt.Errorf("codex CLI not found at %q — install Codex CLI first", codexBin), err)
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		stderrMsg := strings.TrimSpace(stderr)
		if stderrMsg == "" {
			stderrMsg = strings.TrimSpace(string(exitErr.Stderr))
		}
		if stderrMsg != "" {
			return digest.WithCause(fmt.Errorf("codex CLI failed (exit %d): %s", exitErr.ExitCode(), stderrMsg), exitErr)
		}
		return digest.WithCause(fmt.Errorf("codex CLI failed with exit code %d", exitErr.ExitCode()), exitErr)
	}
	return fmt.Errorf("codex CLI error: %w", err)
}
