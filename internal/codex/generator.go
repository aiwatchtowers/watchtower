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
	"watchtower/internal/fsutil"
	"watchtower/internal/llmusage"
	"watchtower/internal/logredact"
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
	result, usage, err := g.run(ctx, codexBin, model, args, stdin, os.TempDir(), promptFile, systemPrompt+userMessage)
	return result, usage, "", err
}

// GenerateWithImage is Generate with one image on the call (`--image`): the
// same tool-less, read-only argv (features.view_image=false stays: that flag
// is the model's disk-reading tool, not image input), the prompts on stdin
// or in a 0600 file, and the child started in a fresh empty 0700 directory
// under the digest.WithWorkDir root, removed when the call returns. The
// image is passed by path; mediaType is not needed (codex sniffs the file).
func (g *CodexGenerator) GenerateWithImage(ctx context.Context, systemPrompt, userMessage, imagePath, _ string) (string, *digest.Usage, error) {
	root, ok := digest.WorkDirFromContext(ctx)
	if !ok {
		return "", nil, errors.New("image call without a work directory (digest.WithWorkDir)")
	}
	if err := digest.CheckImageFile(imagePath); err != nil {
		return "", nil, err
	}
	if err := fsutil.MakePrivateDir(root); err != nil {
		return "", nil, fmt.Errorf("creating the media work root: %w", err)
	}
	dir, err := os.MkdirTemp(root, "media-call-")
	if err != nil {
		return "", nil, fmt.Errorf("creating the call's work directory: %w", err)
	}
	defer func() { _ = os.RemoveAll(dir) }()

	codexBin := FindBinary(g.codexPath)
	args, stdin, promptFile, err := buildImageArgs(codexBin, g.modelStrong, systemPrompt, userMessage, imagePath, dir)
	if err != nil {
		return "", nil, err
	}
	result, usage, err := g.run(ctx, codexBin, g.modelStrong, args, stdin, dir, promptFile, systemPrompt+userMessage)
	return result, usage, err
}

// run starts codex with args in dir and parses its JSONL reply. promptFile
// (the 0600 model_instructions_file, "" for none) is removed at codex's first
// output, or when run returns: codex refuses a pipe there (see Client.Query).
// prompt is the call's prompt text, for the ledger's estimate when codex
// reports no usage; every run is recorded (recordCodexCall), failures too.
func (g *CodexGenerator) run(ctx context.Context, codexBin, model string, args []string, stdin, dir, promptFile, prompt string) (string, *digest.Usage, error) {
	removePrompt := fsutil.RemoveOnce(promptFile)
	defer removePrompt()
	cmd := exec.CommandContext(ctx, codexBin, args...)
	cmd.Stdin = strings.NewReader(stdin)
	cmd.Cancel = func() error {
		return cmd.Process.Signal(os.Interrupt)
	}
	cmd.WaitDelay = 5 * time.Second
	cmd.Dir = dir

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

	start := time.Now()
	output, err := outputRemovingPrompt(cmd, removePrompt)
	if err != nil {
		recordCodexCall(ctx, model, start, nil, prompt, "", false)
		return "", nil, runError(model, output, err, stderrBuf.String(), codexBin)
	}

	// Parse JSONL output — find last item.completed with agent_message
	result, usage, parseErr := parseJSONLOutput(output)
	if parseErr != nil {
		recordCodexCall(ctx, model, start, nil, prompt, "", false)
		return "", nil, parseErr
	}

	if strings.TrimSpace(result) == "" {
		recordCodexCall(ctx, model, start, usage, prompt, "", false)
		return "", nil, fmt.Errorf("codex returned empty result")
	}
	recordCodexCall(ctx, model, start, usage, prompt, result, true)

	digestUsage := &digest.Usage{
		Model:        model,
		InputTokens:  usage.InputTokens,
		OutputTokens: usage.OutputTokens,
	}

	return result, digestUsage, nil
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

// buildImageArgs is buildArgs for an image call. Beyond execArgs it turns
// off web search, every MCP server of the owner's codex config (fail closed
// when the config cannot be read) and the default-on features that reach
// outside the call (multi_agent, image_generation, skill_search, hooks), and
// adds `--image=<path>` (one value: --image splits on commas, so a comma in
// the path is refused) ahead of the instructions override and the "-".
// Residual risk: a codex feature that becomes default-on later is not on
// this list.
func buildImageArgs(bin, model, systemPrompt, userMessage, imagePath, workDir string) (args []string, stdin, promptFile string, err error) {
	if strings.Contains(imagePath, ",") {
		return nil, "", "", errors.New("the image path contains a comma")
	}
	owner, err := ownerServerNames(OwnerHome(), workDir)
	if err != nil {
		return nil, "", "", fmt.Errorf("reading the codex MCP config: %w", err)
	}
	instr, stdin, promptFile, err := promptArgs(bin, systemPrompt, userMessage)
	if err != nil {
		return nil, "", "", err
	}
	override, _, _ := mcpOverride("", nil, nil, nil, owner, nil)
	args = append(execArgs(model),
		"-c", `web_search="disabled"`,
		"-c", override,
		"-c", "features.multi_agent=false",
		"-c", "features.image_generation=false",
		"-c", "features.skill_search=false",
		"-c", "features.hooks=false",
		"-c", "features.in_app_browser=false",
		"-c", "features.skill_mcp_dependency_install=false",
		"-c", "features.tool_suggest=false",
		"--image="+imagePath)
	return append(append(args, instr...), "-"), stdin, promptFile, nil
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
			totalUsage.add(event.Usage)
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

// recordCodexCall records one codex run in the LLM ledger: the JSONL's
// usage with the cached input split out as cache read, or — when the run
// reported none — length/4 estimates of prompt and output.
func recordCodexCall(ctx context.Context, model string, start time.Time, u *CodexUsage, prompt, output string, ok bool) {
	c := llmusage.Call{Provider: "codex", Model: model, DurationMS: time.Since(start).Milliseconds(), OK: ok}
	if u != nil && (u.InputTokens > 0 || u.OutputTokens > 0) {
		cached := int64(min(u.CachedInputTokens, u.InputTokens))
		c.Input, c.CacheRead, c.Output = int64(u.InputTokens)-cached, cached, int64(u.OutputTokens)
	} else {
		c.Input, c.Output, c.Estimated = llmusage.EstimateTokens(prompt), llmusage.EstimateTokens(output), true
	}
	llmusage.Record(ctx, c)
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
			return digest.WithCause(logredact.Errorf("codex CLI failed (exit %d): %s", exitErr.ExitCode(), logredact.Text(stderrMsg)), exitErr)
		}
		return digest.WithCause(fmt.Errorf("codex CLI failed with exit code %d", exitErr.ExitCode()), exitErr)
	}
	return fmt.Errorf("codex CLI error: %w", err)
}
