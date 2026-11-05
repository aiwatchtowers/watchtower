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
	"slices"
	"strings"
	"time"

	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
	"watchtower/internal/llmusage"
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
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
	if digest.TierForContext(ctx) == digest.TierLight {
		model = g.modelLight
	}

	codexBin := FindBinary(g.codexPath)

	args, stdin, promptFile, err := buildArgs(codexBin, model, systemPrompt, userMessage)
	if err != nil {
		return "", nil, "", err
	}
	result, usage, err := g.run(ctx, providers.BatchText, codexBin, model, args, stdin, os.TempDir(), promptFile, systemPrompt+userMessage)
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
	model := g.modelStrong
	if tier, ok := digest.ModelTierFromContext(ctx); ok && tier == digest.TierLight {
		model = g.modelLight
	}
	args, stdin, promptFile, err := buildImageArgs(codexBin, model, systemPrompt, userMessage, imagePath, dir)
	if err != nil {
		return "", nil, err
	}
	result, usage, err := g.run(ctx, providers.Image, codexBin, model, args, stdin, dir, promptFile, systemPrompt+userMessage)
	return result, usage, err
}

// run starts codex with args in dir and parses its JSONL reply. promptFile
// (the 0600 model_instructions_file, "" for none) is held while codex runs
// and removed when run returns, not earlier: codex re-reads it for every
// model request (see Client.Query).
// prompt is the call's prompt text, for the ledger's estimate when codex
// reports no usage; every run is recorded (recordCodexCall), failures too.
func (g *CodexGenerator) run(ctx context.Context, profile providers.InvocationProfile, codexBin, model string, args []string, stdin, dir, promptFile, prompt string) (_ string, _ *digest.Usage, err error) {
	defer func() { err = providers.ContextFailure("codex", ctx, providers.ProcessFailure("codex", err)) }()
	defer holdPromptFile(promptFile)()
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
	output, err := cmd.Output()
	// The usage events codex printed count on every path, failures too.
	ran, reported := cmd.Process != nil, jsonlUsage(output)
	if err != nil {
		recordCodexCall(ctx, model, start, reported, ran, prompt, "", false)
		return "", nil, providers.ContextFailure("codex", ctx, providers.ProfileStartupFailure("codex", profile, stderrBuf.String(), runError(model, output, err, stderrBuf.String(), codexBin)))
	}

	// Parse JSONL output — find last item.completed with agent_message
	result, usage, parseErr := parseJSONLOutputForModel(output, model, stderrBuf.String())
	if parseErr != nil {
		recordCodexCall(ctx, model, start, reported, ran, prompt, "", false)
		return "", nil, parseErr
	}

	if strings.TrimSpace(result) == "" {
		recordCodexCall(ctx, model, start, reported, ran, prompt, "", false)
		return "", nil, providers.WithFailure("codex", providers.InvalidOutput, fmt.Errorf("codex returned empty result"))
	}
	recordCodexCall(ctx, model, start, reported, ran, prompt, result, true)

	digestUsage := &digest.Usage{
		Model:        model,
		InputTokens:  usage.InputTokens,
		OutputTokens: usage.OutputTokens,
	}

	return result, digestUsage, nil
}

// disabledFeatures are the codex feature flags every codex run Watchtower
// launches itself turns off: batch and image calls, the chat session, `ai
// query` (Discuss and embedded chats, code questions), the spec reviewer and
// the automation agent() child. They are the local tools and the default-on
// extras that would run the owner's own code or reach outside the run
// (hooks, skills, subagents, plugins, memories, screen and voice features, a
// background daemon) — the codex counterpart of claude's
// `--setting-sources project,local` (or "" for a read run). A read-folder run
// turns shell_tool back on (Client.execArgs): codex reads files through it.
// Workbench terminal sessions are the owner's own codex and get none of
// these (devpack.CodexLaunchArgs). shell_tool=false is the gate for
// UnifiedExec too (codex 0.166 core/src/tools/spec_plan.rs add_shell_tools);
// unified_exec=false alone is insufficient on that version; shell_snapshot*
// are separate gates of the login-shell helper (core/src/shell_snapshot.rs).
// codex_hooks is the legacy alias of hooks. A run with tools keeps
// toolRunFeatures. Pinned against
// testdata/codex_features.txt (TestDisabledFeatures_MatchSnapshot); refresh
// after a codex upgrade with scripts/check-codex-features.sh. Each is set
// as a scalar `=false`, which both the old bool-map and the current
// bool-or-object feature schemas accept.
var disabledFeatures = []string{
	"shell_tool",
	"unified_exec",
	"view_image",
	"computer_use",
	"browser_use",
	"browser_use_external",
	"apps",
	"plugins",
	"shell_snapshot",
	"shell_snapshot_v2",
	"multi_agent",
	"multi_agent_v2",
	"image_generation",
	"skill_search",
	"skill_mcp_dependency_install",
	"hooks",
	"codex_hooks",
	"in_app_browser",
	"tool_suggest",
	"code_mode",
	"code_mode_host",
	"goals",
	"memories",
	"external_agent_memory_import",
	"chronicle",
	"realtime_conversation",
	"remote_plugin",
	"plugin_sharing",
	"recommended_plugins",
	"daemon_auto_start",
}

// toolRunFeatures are the disabledFeatures a run with tools (every Client
// run) leaves as codex configures them: code_mode_host carries every tool
// call — with it off, codex 0.159.2 answers each MCP or shell call
// "unavailable" (TestCodexLive_*). Only tool-less batch and image calls turn
// them off.
var toolRunFeatures = []string{"code_mode_host"}

// execArgs is the common read-only prefix with every disabledFeatures flag
// off — the batch and image calls' prefix, to which noToolsArgs adds web
// search off and the owner's MCP servers off.
func execArgs(model string) []string {
	return append(execPrefix(model), featuresOff(nil)...)
}

// featuresOff is `-c features.<name>=false` for each disabledFeatures name
// not in keep.
func featuresOff(keep []string) []string {
	var args []string
	for _, f := range disabledFeatures {
		if !slices.Contains(keep, f) {
			args = append(args, "-c", "features."+f+"=false")
		}
	}
	return args
}

// execPrefix is `codex exec` with the flags every run shares: JSON events,
// no session file, no approvals, the read-only sandbox.
func execPrefix(model string) []string {
	return []string{
		"exec",
		"--model", model,
		"--json",
		"--ephemeral",
		"--skip-git-repo-check",
		"-c", "approval_policy=never",
		"-c", "sandbox_mode=read-only",
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
	safe, err := noToolsArgs(providers.BatchText, model, os.TempDir())
	if err != nil {
		_ = os.Remove(promptFile)
		return nil, "", "", err
	}
	return append(append(safe, instr...), "-"), stdin, promptFile, nil
}

// buildImageArgs is buildArgs for an image call. Beyond execArgs (whose
// disabledFeatures cover the default-on features that reach outside the
// call) it turns off web search and every MCP server of the owner's codex
// config (fail closed when the config cannot be read), and adds
// `--image=<path>` (one value: --image splits on commas, so a comma in the
// path is refused) ahead of the instructions override and the "-".
// Residual risk: a codex feature that becomes default-on later is off only
// once scripts/check-codex-features.sh has flagged it and it was added.
func buildImageArgs(bin, model, systemPrompt, userMessage, imagePath, workDir string) (args []string, stdin, promptFile string, err error) {
	if strings.Contains(imagePath, ",") {
		return nil, "", "", errors.New("the image path contains a comma")
	}
	safe, err := noToolsArgs(providers.Image, model, workDir)
	if err != nil {
		return nil, "", "", err
	}
	instr, stdin, promptFile, err := promptArgs(bin, systemPrompt, userMessage)
	if err != nil {
		return nil, "", "", err
	}
	args = append(safe, "--image="+imagePath)
	return append(append(args, instr...), "-"), stdin, promptFile, nil
}

// noToolsArgs disables merged owner/system/project tools while retaining
// authentication and custom model-provider transport in the original home.
func noToolsArgs(profile providers.InvocationProfile, model, workDir string) ([]string, error) {
	if !profile.ReplaySafe() {
		return nil, providers.CapabilityError("codex", profile, errors.New("unsupported generator invocation profile"))
	}
	owner, err := ownerServerNames(OwnerHome(), workDir)
	if err != nil {
		return nil, providers.CapabilityError("codex", profile, fmt.Errorf("cannot isolate codex MCP config: %w", err))
	}
	override, _, _ := mcpOverride("", nil, nil, nil, owner, nil)
	return append(execArgs(model), "-c", `web_search="disabled"`, "-c", override), nil
}

// parseJSONLOutput parses Codex JSONL output and extracts the final agent_message
// content and accumulated usage.
func parseJSONLOutput(output []byte) (string, *CodexUsage, error) {
	return parseJSONLOutputForModel(output, "", "")
}

// stderr is codex's, for the error of a run cut off before turn.completed.
func parseJSONLOutputForModel(output []byte, model, stderr string) (string, *CodexUsage, error) {
	var terminalFailure error
	var lastContent string
	completed := false
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

		if (event.Type == "turn.failed" || event.Type == "error") && event.Error != nil {
			terminalFailure = eventTurnError(model, event.Error)
		}

		if event.Type == "turn.completed" || event.Type == "turn.started" {
			terminalFailure = nil
			completed = event.Type == "turn.completed"
		}
		if event.Usage != nil {
			totalUsage.add(event.Usage)
		}

		if event.Type == "item.completed" && event.Item != nil && event.Item.Type == "agent_message" {
			lastContent = event.Item.MessageText()
		}
	}

	if terminalFailure != nil {
		return "", nil, terminalFailure
	}
	// A run that exited cleanly is a success only after turn.completed, as
	// in the streaming Query: a cut-off run never returns its preamble.
	if !completed {
		return "", nil, incompleteRunError(model, output, stderr)
	}
	if lastContent == "" {
		return "", nil, providers.WithFailure("codex", providers.InvalidOutput, fmt.Errorf("no agent_message found in codex output"))
	}

	return lastContent, totalUsage, nil
}

// jsonlUsage sums the usage events in codex's JSONL output; nil when it
// printed none (the ledger then estimates a run that happened).
func jsonlUsage(output []byte) *CodexUsage {
	var total *CodexUsage
	for line := range bytes.SplitSeq(output, []byte("\n")) {
		var event CodexEvent
		if json.Unmarshal(bytes.TrimSpace(line), &event) != nil || event.Usage == nil {
			continue
		}
		if total == nil {
			total = &CodexUsage{}
		}
		total.add(event.Usage)
	}
	return total
}

// recordCodexCall records one codex run in the LLM ledger: the reported
// usage (u, summed from the JSONL) as it is, zeros included, with the cached
// input split out as cache read; a run that never started (ran false) as a
// failed call with no tokens; and only a run that ran and reported no usage
// with length/4 estimates of prompt and output.
func recordCodexCall(ctx context.Context, model string, start time.Time, u *CodexUsage, ran bool, prompt, output string, ok bool) {
	c := llmusage.Call{Provider: "codex", Model: model, DurationMS: time.Since(start).Milliseconds(), OK: ok && ran}
	switch {
	case u != nil:
		cached := int64(min(u.CachedInputTokens, u.InputTokens))
		c.Input, c.CacheRead, c.Output = int64(u.InputTokens)-cached, cached, int64(u.OutputTokens)
	case ran:
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

// InvocationProfile identifies text generation as an isolated batch call.
func (g *CodexGenerator) InvocationProfile() providers.InvocationProfile { return providers.BatchText }
