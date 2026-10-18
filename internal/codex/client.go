package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
	"time"

	"watchtower/internal/ai"
)

// Client wraps the Codex CLI for AI queries (ask/chat).
type Client struct {
	model    string
	dbPath   string // path to SQLite database for MCP server
	codexCmd string // path to codex binary
	// mcpArgs are appended to `watchtower mcp --db-path <db>` — the chat
	// mode flags (--chat --surface … --conversation … --turn …) the Desktop
	// passes through `ai query --tools chat`. Empty = the read-only dev server.
	mcpArgs []string
	// mcpEnvVars are passed through to the MCP server (SetMCPEnvVars).
	mcpEnvVars []string
	// readFolder, when set (SetReadFolder), is the run's working root
	// (`--cd`, and the process cwd) under the read-only sandbox. Empty =
	// today's run in a temp dir holding the MCP config.
	readFolder string
	// childEnv replaces the os.Environ() base of the child's environment
	// when childEnvSet (SetChildEnv); processGroup runs the child in its own
	// process group killed as a group (SetProcessGroup).
	childEnv     []string
	childEnvSet  bool
	processGroup bool
}

// SetChildEnv replaces the inherited environment of the child with env (the
// rich PATH is still appended last). Unset = os.Environ() as today.
func (c *Client) SetChildEnv(env []string) { c.childEnv, c.childEnvSet = env, true }

// SetProcessGroup runs the child in its own process group and kills the
// whole group on cancel or deadline (see ai.ConfigureChild). codex has no
// per-tool MCP allowlist flag; the server-side tool filter is the
// enforcement, as for claude.
func (c *Client) SetProcessGroup(v bool) { c.processGroup = v }

// childEnviron is the child's environment: the base (os.Environ() unless
// replaced) without PATH, then the rich PATH.
func (c *Client) childEnviron() []string {
	base := os.Environ()
	if c.childEnvSet {
		base = c.childEnv
	}
	var env []string
	for _, e := range base {
		if strings.HasPrefix(e, "PATH=") {
			continue
		}
		env = append(env, e)
	}
	return append(env, "PATH="+RichPATH())
}

// SetReadFolder makes the run a read-only look at dir (`ai query
// --read-folder`, the workbench code questions): codex works in dir
// (`--cd`) under its read-only sandbox (`--sandbox read-only`, approvals
// off), with its shell on — codex reads files only through it — and every
// other local tool and web search off. The sandbox lets the shell read
// outside dir (accepted by the owner, spec 2026-10-02 §9.1) but never write
// or reach the network. The watchtower MCP server is mounted with -c
// overrides, since dir — not a temp dir — is the working root. dir must
// already be resolved to a workbench folder (cmd's resolveReadFolder).
func (c *Client) SetReadFolder(dir string) { c.readFolder = dir }

// SetMCPArgs appends extra flags to the MCP server command (chat mode).
func (c *Client) SetMCPArgs(extra []string) { c.mcpArgs = extra }

// SetMCPEnvVars names environment variables codex passes through to the
// watchtower MCP server (its env_vars; codex otherwise filters them out).
func (c *Client) SetMCPEnvVars(names []string) { c.mcpEnvVars = names }

// NewClient creates a new AI client that invokes the Codex CLI.
// dbPath is the path to the SQLite database; when non-empty, an MCP SQLite
// server is configured via .codex/config.toml.
// codexPath is an optional explicit path to the codex binary; pass "" for default lookup.
func NewClient(model, dbPath, codexPath string) *Client {
	return &Client{
		model:    model,
		dbPath:   dbPath,
		codexCmd: FindBinary(codexPath),
	}
}

// buildArgs constructs the CLI arguments for a codex exec call, plus its
// stdin content. The argv carries flags and paths only (promptArgs): the
// system prompt travels as a model_instructions_file — or, on a codex too
// old for one, ahead of the user message on stdin — and the user message on
// stdin behind the "-" positional, never as a positional prompt, where `ps`
// would show it. promptFile is the system-prompt file to remove once the
// child has exited. workDir is an optional working directory to pass via
// --cd.
func (c *Client) buildArgs(systemPrompt, userMessage, workDir string) (args []string, stdin, promptFile string, err error) {
	args = c.execArgs()
	if workDir != "" {
		args = append(args, "--cd", workDir)
	}
	instr, stdin, promptFile, err := promptArgs(c.codexCmd, systemPrompt, userMessage)
	if err != nil {
		return nil, "", "", err
	}
	args = append(append(args, instr...), "-")
	return args, stdin, promptFile, nil
}

// execArgs is the `codex exec` prefix: the shared execArgs, or for a
// read-folder run the read-only sandbox with the shell on (SetReadFolder).
func (c *Client) execArgs() []string {
	if c.readFolder == "" {
		return execArgs(c.model)
	}
	args := slices.Clone(execArgs(c.model))
	for i, a := range args {
		if a == "features.shell_tool=false" {
			args[i] = "features.shell_tool=true"
		}
	}
	args = append(args, "--sandbox", "read-only", "-c", `web_search="disabled"`)
	if c.dbPath != "" {
		args = append(args, mcpConfigOverrides(c.dbPath, c.mcpArgs)...)
	}
	return args
}

// workDir prepares where the run works: the read folder as is, or a temp
// dir holding the MCP config when there is a database (removed by the
// returned cleanup), or none.
func (c *Client) workDir() (dir string, cleanup func(), err error) {
	if c.readFolder != "" {
		return c.readFolder, func() {}, nil
	}
	if c.dbPath == "" {
		return "", func() {}, nil
	}
	tmpDir, err := mcpWorkDir(c.dbPath, c.mcpArgs, c.mcpEnvVars)
	if err != nil {
		return "", func() {}, err
	}
	return tmpDir, func() { _ = os.RemoveAll(tmpDir) }, nil
}

// processDir is the subprocess cwd: the read folder, or a TCC-neutral
// directory so the Node-based Codex CLI never inherits a parent CWD inside
// ~/Documents or ~/Desktop (macOS Files & Folders prompts attributed to
// Watchtower).
func (c *Client) processDir() string {
	if c.readFolder != "" {
		return c.readFolder
	}
	return os.TempDir()
}

// Query sends a streaming request via the Codex CLI and returns channels
// for text chunks, errors, and the session ID (always empty for Codex). A
// model codex refuses is retried once with the strong tier's fallback
// (providers.FallbackModel) — the refusal comes before any text, so the
// consumer sees only the fallback's answer.
func (c *Client) Query(ctx context.Context, systemPrompt, userMessage, _ string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	textCh := make(chan ai.StreamChunk, 64)
	errCh := make(chan error, 1)
	sidCh := make(chan string, 1)

	go func() {
		defer close(textCh)
		defer close(errCh)
		defer close(sidCh)

		run := c.withModel(modelFor(c.model))
		sent, err := run.stream(ctx, systemPrompt, userMessage, textCh)
		if fb := fallbackFor(run.model, false, err); fb != "" && !sent {
			first := err
			_, err = c.withModel(fb).stream(ctx, systemPrompt, userMessage, textCh)
			err = withFallbackErr(first, fb, err)
		}
		if err != nil {
			errCh <- err
			return
		}
		// Codex doesn't support session resumption — emit empty session ID.
		sidCh <- ""
	}()

	return textCh, errCh, sidCh
}

// stream runs one streaming `codex exec` turn on c.model, sending its
// chunks to textCh; sent reports whether any chunk went out.
func (c *Client) stream(ctx context.Context, systemPrompt, userMessage string, textCh chan<- ai.StreamChunk) (sent bool, err error) {
	// Set up MCP config if database path is provided.
	workDir, cleanup, err := c.workDir()
	if err != nil {
		return false, err
	}
	defer cleanup()

	args, promptStdin, promptFile, err := c.buildArgs(systemPrompt, userMessage, workDir)
	if err != nil {
		return false, err
	}
	if promptFile != "" {
		// Every return below comes after the child is reaped or never
		// started, so the file is never removed while codex reads it.
		defer os.Remove(promptFile)
	}

	cmd := exec.CommandContext(ctx, c.codexCmd, args...)
	cmd.Stdin = strings.NewReader(promptStdin)
	reap := ai.ConfigureChild(cmd, c.processGroup, 5*time.Second)
	defer reap()
	cmd.Dir = c.processDir()
	cmd.Env = c.childEnviron()

	var stderrBuf strings.Builder
	cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return false, fmt.Errorf("creating stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return false, classifyError(err, "", c.codexCmd)
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		chunk, done, err := c.streamEvent(scanner.Text())
		if err != nil || done {
			_ = cmd.Wait()
			return sent, err
		}
		if chunk == nil {
			continue
		}
		select {
		case textCh <- *chunk:
			sent = true
		case <-ctx.Done():
			_ = cmd.Wait()
			return sent, ctx.Err()
		}
	}

	if err := scanner.Err(); err != nil {
		_ = cmd.Wait()
		return sent, fmt.Errorf("reading codex output: %w", err)
	}

	if err := cmd.Wait(); err != nil {
		return sent, classifyError(err, stderrBuf.String(), c.codexCmd)
	}
	return sent, nil
}

// streamEvent turns one JSONL line of a streaming run into the chunk to
// send (nil = none), or the turn's error.
func (c *Client) streamEvent(line string) (chunk *ai.StreamChunk, done bool, err error) {
	if line == "" {
		return nil, false, nil
	}
	var event CodexEvent
	if json.Unmarshal([]byte(line), &event) != nil {
		return nil, false, nil //nolint:nilerr // a non-JSON line is skipped, not a failed turn
	}
	if event.Error != nil {
		return nil, true, turnError(c.model, event.Error.Message)
	}
	if event.Item == nil {
		return nil, false, nil
	}
	// A tool call interrupts the turn: signal a boundary so the consumer
	// drops the pre-tool preamble and starts the answer fresh from what
	// follows the tool (the ai.Client tool_use precedent). Codex wraps one
	// item across item.started/updated/completed, so a single tool call
	// fires a boundary per stage — deliberately unfiltered by stage, since
	// it is idempotent: each extra boundary just re-clears an
	// already-empty accumulator on the consumer side.
	if event.Item.Type == "mcp_tool_call" || event.Item.Type == "command_execution" {
		return &ai.StreamChunk{ToolBoundary: true}, false, nil
	}
	// Stream agent_message content as it arrives.
	if event.Item.Type == "agent_message" && event.Item.MessageText() != "" {
		return &ai.StreamChunk{Text: event.Item.MessageText()}, false, nil
	}
	return nil, false, nil
}

// withModel is c running model instead (a refused model's fallback).
func (c *Client) withModel(model string) *Client {
	cc := *c
	cc.model = model
	return &cc
}

// QuerySync sends a non-streaming request via the Codex CLI and returns
// the full response text and token usage. A model codex refuses is
// retried once with the strong tier's fallback (providers.FallbackModel).
func (c *Client) QuerySync(ctx context.Context, systemPrompt, userMessage, _ string) (string, *ai.Usage, error) {
	run := c.withModel(modelFor(c.model))
	result, usage, err := run.querySync(ctx, systemPrompt, userMessage)
	if fb := fallbackFor(run.model, false, err); fb != "" {
		first := err
		result, usage, err = c.withModel(fb).querySync(ctx, systemPrompt, userMessage)
		err = withFallbackErr(first, fb, err)
	}
	return result, usage, err
}

// querySync runs one non-streaming `codex exec` turn on c.model.
func (c *Client) querySync(ctx context.Context, systemPrompt, userMessage string) (string, *ai.Usage, error) {
	// Set up MCP config if database path is provided.
	workDir, cleanup, mcpErr := c.workDir()
	if mcpErr != nil {
		return "", nil, mcpErr
	}
	defer cleanup()

	args, promptStdin, promptFile, err := c.buildArgs(systemPrompt, userMessage, workDir)
	if err != nil {
		return "", nil, err
	}
	if promptFile != "" {
		defer os.Remove(promptFile)
	}

	cmd := exec.CommandContext(ctx, c.codexCmd, args...)
	cmd.Stdin = strings.NewReader(promptStdin)
	reap := ai.ConfigureChild(cmd, c.processGroup, 5*time.Second)
	defer reap()
	cmd.Dir = c.processDir()
	cmd.Env = c.childEnviron()

	var stderrBuf strings.Builder
	cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

	output, err := cmd.Output()
	if err != nil {
		return "", nil, runError(c.model, output, err, stderrBuf.String(), c.codexCmd)
	}

	result, codexUsage, parseErr := parseJSONLOutput(output)
	if parseErr != nil {
		return "", nil, parseErr
	}

	usage := &ai.Usage{
		InputTokens:  codexUsage.InputTokens,
		OutputTokens: codexUsage.OutputTokens,
	}

	return result, usage, nil
}
