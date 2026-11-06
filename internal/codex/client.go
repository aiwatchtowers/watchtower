package codex

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/digest"
	"watchtower/internal/providers"
	"watchtower/internal/streamline"
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
	// a run in os.TempDir() with no --cd.
	readFolder string
	// childEnv replaces the os.Environ() base of the child's environment
	// when childEnvSet (SetChildEnv).
	childEnv    []string
	childEnvSet bool
	// loadExternal yields the owner's enabled Quick Connections, called once
	// per launch (SetExternalMCPServers / SetExternalMCPLoader).
	loadExternal func() []ai.ExternalMCPServer
	// serversFromHome: the child's CODEX_HOME declares its servers itself
	// (SetServersFromHome); no -c override is added.
	serversFromHome bool
	// noServers: the run mounts no MCP server at all (SetNoMCPServers).
	noServers bool
	// toolEvents: Query streams the protocol-v2 chat events (EmitToolEvents).
	toolEvents bool
	// maxTurns caps the run's model turns (SetMaxTurns, turncap.go); 0 = none.
	maxTurns int
	// runHome is the run's private CODEX_HOME (SetRunHome); "" = the
	// inherited one and an --ephemeral run.
	runHome string
	// webSearch: the run searches the web (SetWebSearch); off otherwise.
	webSearch bool
	// images are the next run's --image paths (SetImages), taken by it.
	imagesMu sync.Mutex
	images   []string
}

// SetImages hands the next run, and only it, the images at paths: one
// --image=<path> each (CHAT-04: a path, never content). The caller owns the
// files and removes them after the run.
func (c *Client) SetImages(paths []string) {
	c.imagesMu.Lock()
	defer c.imagesMu.Unlock()
	c.images = slices.Clone(paths)
}

// peekImages is the images set for the next run, left in place.
func (c *Client) peekImages() []string {
	c.imagesMu.Lock()
	defer c.imagesMu.Unlock()
	return c.images
}

// takeImages is the images set for this run, cleared for the next.
func (c *Client) takeImages() []string {
	c.imagesMu.Lock()
	defer c.imagesMu.Unlock()
	imgs := c.images
	c.images = nil
	return imgs
}

// SetWebSearch lets every run of this client search the web: codex's
// web_search on its cached index (the main chat session only, ask #533).
// Never "live": live opens any URL the model names, query string included,
// from OpenAI's side, which is a page fetch — the exfiltration channel
// WebFetch stays hidden for (chat-redesign.md). Without it a run turns web
// search off, whatever the owner's codex config says.
func (c *Client) SetWebSearch() { c.webSearch = true }

// webSearchArg is the run's explicit web_search setting (SetWebSearch).
func (c *Client) webSearchArg() string {
	if c.webSearch {
		return `web_search="cached"`
	}
	return `web_search="disabled"`
}

// SetNoMCPServers makes the run tool-less on MCP: every server of the
// owner's codex config layers is disabled and none is mounted, not even
// the watchtower one (the spec reviewer's read-only run).
func (c *Client) SetNoMCPServers() { c.noServers = true }

// SetServersFromHome is for a child whose CODEX_HOME (SetChildEnv) is a
// scrubbed per-run home that already declares exactly its servers (the
// automation agent() child): the run adds no mcp_servers override.
func (c *Client) SetServersFromHome() { c.serversFromHome = true }

// SetExternalMCPServers mounts the owner's enabled Quick Connections next to
// the watchtower server, each limited to its QC-02 allowed tools
// (mcpOverride). Only a run that mounts the watchtower server (a database
// path) gets them.
func (c *Client) SetExternalMCPServers(servers []ai.ExternalMCPServer) {
	c.loadExternal = func() []ai.ExternalMCPServer { return servers }
}

// SetExternalMCPLoader is SetExternalMCPServers for a client that launches
// codex once per turn (the chat session): load runs before every launch, so
// the connection set and each OAuth token are as fresh as a claude launch's
// (QC-04).
func (c *Client) SetExternalMCPLoader(load func() []ai.ExternalMCPServer) { c.loadExternal = load }

// SetChildEnv replaces the inherited environment of the child with env (the
// rich PATH is still appended last). Unset = os.Environ() as today.
func (c *Client) SetChildEnv(env []string) { c.childEnv, c.childEnvSet = env, true }

// childEnviron is the child's environment: the base (os.Environ() unless
// replaced) without PATH, then extra (the run's Quick Connection secrets,
// mcpOverride), then the rich PATH.
func (c *Client) childEnviron(extra []string) []string {
	var env []string
	for _, e := range c.baseEnv() {
		if strings.HasPrefix(e, "PATH=") {
			continue
		}
		env = append(env, e)
	}
	env = append(env, extra...)
	return append(env, "PATH="+RichPATH())
}

func (c *Client) baseEnv() []string {
	base := os.Environ()
	if c.childEnvSet {
		base = c.childEnv
	}
	if c.runHome == "" {
		return base
	}
	env := make([]string, 0, len(base)+1)
	for _, e := range base {
		if !strings.HasPrefix(e, "CODEX_HOME=") {
			env = append(env, e)
		}
	}
	return append(env, "CODEX_HOME="+c.runHome)
}

// SetReadFolder makes the run a read-only look at dir (`ai query
// --read-folder`, the workbench code questions): codex works in dir
// (`--cd`) under its read-only sandbox (`--sandbox read-only`, approvals
// off), with its shell on — codex reads files only through it — and every
// other local tool and web search off. The sandbox lets the shell read
// outside dir (accepted by the owner, spec 2026-10-02 §9.1) but never write
// or reach the network. The watchtower MCP server is mounted by the same
// -c override as any run (mount), which also disables the servers of dir's
// own .codex/config.toml. dir must already be resolved to a workbench folder (cmd's resolveReadFolder).
func (c *Client) SetReadFolder(dir string) { c.readFolder = dir }

// ArgsForTest returns the argv a Query would run (tests outside this
// package: cmd's `ai query` wiring tests). A system-prompt file it may
// write is removed.
func (c *Client) ArgsForTest(systemPrompt, userMessage string) []string {
	m, err := c.mount()
	if err != nil {
		return nil
	}
	args, _, promptFile, err := c.buildRunArgs(m.prompt(systemPrompt), userMessage, c.readFolder, m.args, c.peekImages())
	if promptFile != "" {
		_ = os.Remove(promptFile)
	}
	if err != nil {
		return nil
	}
	return args
}

// SetMCPArgs appends extra flags to the MCP server command (chat mode).
func (c *Client) SetMCPArgs(extra []string) { c.mcpArgs = extra }

// SetMCPEnvVars names environment variables codex passes through to the
// watchtower MCP server (its env_vars; codex otherwise filters them out).
func (c *Client) SetMCPEnvVars(names []string) { c.mcpEnvVars = names }

// NewClient creates a new AI client that invokes the Codex CLI.
// dbPath is the path to the SQLite database; when non-empty, the watchtower
// MCP server is mounted by a -c mcp_servers override (mount).
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
	return c.buildRunArgs(systemPrompt, userMessage, workDir, nil, nil)
}

// buildRunArgs is buildArgs with the run's MCP mount flags (mount) after
// the exec prefix and the run's images (SetImages) before the prompt.
func (c *Client) buildRunArgs(systemPrompt, userMessage, workDir string, mount, images []string) (args []string, stdin, promptFile string, err error) {
	args = append(c.execArgs(), mount...)
	if workDir != "" {
		args = append(args, "--cd", workDir)
	}
	for _, p := range images {
		// codex splits an --image value on commas (buildImageArgs).
		if strings.Contains(p, ",") {
			return nil, "", "", errors.New("an image path contains a comma")
		}
		args = append(args, "--image="+p)
	}
	instr, stdin, promptFile, err := promptArgs(c.codexCmd, systemPrompt, userMessage)
	if err != nil {
		return nil, "", "", err
	}
	args = append(append(args, instr...), "-")
	return args, stdin, promptFile, nil
}

// execArgs is the `codex exec` prefix: the batch prefix (every
// disabledFeatures flag off) less toolRunFeatures, which the run's tools
// need, and web search set explicitly (webSearchArg); for a read-folder run
// also the read-only sandbox with the shell on (SetReadFolder). The MCP
// servers come from mount.
func (c *Client) execArgs() []string {
	prefix := execPrefix(c.model)
	if c.runHome != "" {
		// The rollout the turn cap counts lives in the run's own home,
		// which the caller removes after the run.
		prefix = slices.DeleteFunc(prefix, func(a string) bool { return a == "--ephemeral" })
	}
	off, sandbox := toolRunFeatures, []string(nil)
	if c.readFolder != "" {
		off = append([]string{"shell_tool"}, toolRunFeatures...)
		sandbox = []string{"-c", "features.shell_tool=true", "--sandbox", "read-only"}
	}
	args := append(append(prefix, featuresOff(off)...), sandbox...)
	return append(args, "-c", c.webSearchArg())
}

// runMount is one launch's MCP mount: the -c flags, the environment the
// mounted servers read their secrets from and the Quick Connections it
// mounts (fenced in the system prompt: prompt).
type runMount struct {
	args, env []string
	external  []ai.ExternalMCPServer
	// server is the watchtower server's key ("" = not mounted).
	server string
}

// prompt is systemPrompt with the mounted Quick Connections' external-data
// fence (ai.WithExternalDataRule).
func (m runMount) prompt(systemPrompt string) string {
	return ai.WithExternalDataRule(systemPrompt, m.external)
}

// mount builds the launch's MCP servers in place of the owner's own codex
// config ones, keeping the owner's CODEX_HOME (sign-in, model provider,
// profiles): a run with a database disables every server of the owner's
// codex config layers and mounts the watchtower server plus the Quick
// Connections (mcpOverride). A run with none (a plain query), or whose
// CODEX_HOME declares its servers (SetServersFromHome), is left as codex
// configures it. SetNoMCPServers disables the owner's servers and mounts none.
func (c *Client) mount() (runMount, error) {
	if !c.noServers && (c.serversFromHome || c.dbPath == "") {
		return runMount{}, nil
	}
	base := c.baseEnv()
	owner, err := ownerServerNames(codexHomeIn(envMap(base)["CODEX_HOME"]), c.processDir())
	if err != nil {
		return runMount{}, err
	}
	if c.noServers {
		override, _, _ := mcpOverride("", nil, nil, nil, owner, base)
		return runMount{args: []string{"-c", override}}, nil
	}
	var external []ai.ExternalMCPServer
	if c.loadExternal != nil {
		external = c.loadExternal()
	}
	// The caller already left out what EnvConflicts refuses; anything the
	// override still skips is only logged.
	override, env, skipped := mcpOverride(c.dbPath, c.mcpArgs, c.mcpEnvVars, external, owner, base)
	var mounted []ai.ExternalMCPServer
	for _, s := range external {
		if _, skip := skipped[s.ID]; !skip {
			mounted = append(mounted, s)
		}
	}
	return runMount{args: []string{"-c", override}, env: env, external: mounted, server: watchtowerKey(owner)}, nil
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

// EmitToolEvents switches on the protocol-v2 chat events (the stateless chat
// turn backend calls it): every tool call becomes a start and an end chunk
// (ai.StreamChunk.Tool), the turn's usage a Usage chunk, and agent messages
// are separated even across a tool call. A v1 consumer leaves it off and
// keeps the reset-on-boundary stream.
func (c *Client) EmitToolEvents() { c.toolEvents = true }

// Query sends a streaming request via the Codex CLI and returns channels
// for text chunks, errors, and the session ID (always empty for Codex).
func (c *Client) Query(ctx context.Context, systemPrompt, userMessage, _ string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	textCh := make(chan ai.StreamChunk, 64)
	errCh := make(chan error, 1)
	sidCh := make(chan string, 1)
	images := c.takeImages() // now: the caller may set the next turn's while this one runs

	go func() {
		defer close(textCh)
		defer close(errCh)
		defer close(sidCh)

		m, mountErr := c.mount()
		if mountErr != nil {
			errCh <- mountErr
			return
		}
		args, promptStdin, promptFile, buildErr := c.buildRunArgs(m.prompt(systemPrompt), userMessage, c.readFolder, m.args, images)
		if buildErr != nil {
			errCh <- buildErr
			return
		}
		// codex refuses a pipe for model_instructions_file (it stats the
		// file), so the prompt is a 0600 file. It is held until codex exits:
		// codex re-reads it for every model request of the run, so removing
		// it at the first output line fails the next request ("failed to
		// load workspace requirements"); the hold also keeps the stale-temp
		// sweep off it during a long run. It is removed on every return.
		defer holdPromptFile(promptFile)()

		// runCtx ends the child when the read below fails, so the run never
		// waits on a codex blocked writing into a pipe nobody reads.
		runCtx, cancelRun := context.WithCancel(ctx)
		defer cancelRun()
		turns := newTurnCap(c.maxTurns, c.runHome, cancelRun)
		go turns.watch(runCtx)
		cmd := exec.CommandContext(runCtx, c.codexCmd, args...)
		cmd.Stdin = strings.NewReader(promptStdin)
		reap := ai.ConfigureChild(cmd)
		defer reap()
		cmd.Dir = c.processDir()
		cmd.Env = c.childEnviron(m.env)

		var stderrBuf strings.Builder
		cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

		start := time.Now()
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			recordCodexCall(ctx, c.model, start, nil, false, systemPrompt+userMessage, "", false)
			errCh <- fmt.Errorf("creating stdout pipe: %w", err)
			return
		}
		if err := cmd.Start(); err != nil {
			recordCodexCall(ctx, c.model, start, nil, false, systemPrompt+userMessage, "", false)
			errCh <- classifyError(err, "", c.codexCmd)
			return
		}
		// One ledger row per run, recorded on every return below: the
		// turn's usage events summed (usage stays nil without one), else
		// estimates of the prompt and the streamed text.
		s := &queryStream{ctx: ctx, out: textCh, model: c.model, v2: c.toolEvents, watchtower: m.server}
		ok := false
		defer func() {
			recordCodexCall(ctx, c.model, start, s.usage, true, systemPrompt+userMessage, s.answer.String(), ok)
		}()

		lines := streamline.NewWithLimit(stdout, maxStreamLine)
		for {
			line, readErr := lines.Next()
			s.skipped = lines.Skipped()
			// A line past the turn cap is not shown — that turn never does —,
			// only its usage still counts.
			trimmed := bytes.TrimSpace(line)
			past := len(trimmed) != 0 && !turns.line(trimmed)
			if past {
				s.addUsage(trimmed)
			}
			if len(trimmed) != 0 && !past && !s.handle(trimmed) {
				_ = cmd.Wait()
				s.finish()
				errCh <- ctx.Err()
				return
			}
			if errors.Is(readErr, io.EOF) {
				break
			}
			if readErr != nil {
				cancelRun()
				_ = cmd.Wait()
				s.finish()
				// The cap's kill may close the pipe under the read.
				if capErr := turns.done(s.terminal != nil, true); capErr != nil {
					errCh <- capErr
					return
				}
				errCh <- providers.ContextFailure("codex", ctx, fmt.Errorf("reading codex output: %w", readErr))
				return
			}
		}
		s.finish()

		err = cmd.Wait()
		capErr := turns.done(s.terminal != nil, err != nil || !s.completed)
		switch {
		case capErr != nil:
			errCh <- capErr
		case s.terminal != nil:
			terminal := s.terminal
			if err != nil {
				terminal = digest.WithCause(terminal, err)
			}
			errCh <- providers.ContextFailure("codex", ctx, terminal)
		case err != nil:
			errCh <- providers.ContextFailure("codex", ctx, runError(c.model, s.errLines, err, stderrBuf.String(), c.codexCmd))
		case !s.completed:
			// A clean exit is a success only after turn.completed (the claude
			// backend's "exited without a result"): an empty or cut-off run
			// is never a blank or partial "complete" answer.
			errCh <- providers.ContextFailure("codex", ctx, incompleteRunError(c.model, s.errLines, stderrBuf.String()))
		default:
			if err := s.answerErr(); err != nil {
				errCh <- providers.ContextFailure("codex", ctx, err)
			} else {
				ok = true
			}
		}

		// Codex doesn't support session resumption — emit empty session ID.
		sidCh <- ""
	}()

	return textCh, errCh, sidCh
}

// QuerySync sends a non-streaming request via the Codex CLI and returns
// the full response text and token usage.
func (c *Client) QuerySync(ctx context.Context, systemPrompt, userMessage, _ string) (text string, usage *ai.Usage, err error) {
	defer func() { err = providers.ContextFailure("codex", ctx, providers.ProcessFailure("codex", err)) }()
	images := c.takeImages()
	m, mountErr := c.mount()
	if mountErr != nil {
		return "", nil, mountErr
	}
	args, promptStdin, promptFile, err := c.buildRunArgs(m.prompt(systemPrompt), userMessage, c.readFolder, m.args, images)
	if err != nil {
		return "", nil, err
	}
	defer holdPromptFile(promptFile)() // see Query

	runCtx, cancelRun := context.WithCancel(ctx)
	defer cancelRun()
	turns := newTurnCap(c.maxTurns, c.runHome, cancelRun)
	go turns.watch(runCtx)
	cmd := exec.CommandContext(runCtx, c.codexCmd, args...)
	cmd.Stdin = strings.NewReader(promptStdin)
	reap := ai.ConfigureChild(cmd)
	defer reap()
	cmd.Dir = c.processDir()
	cmd.Env = c.childEnviron(m.env)

	var stderrBuf strings.Builder
	cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

	start := time.Now()
	stdout := &lineSink{turns: turns}
	cmd.Stdout = stdout
	err = cmd.Run()
	stdout.flush()
	output := stdout.buf.Bytes()
	// The usage events codex printed count on every path, failures too.
	ran, reported := cmd.Process != nil, jsonlUsage(output)
	// A failed turn is the run's own failure even when codex exits 0.
	if capErr := turns.done(turnFailed(output), err != nil); capErr != nil {
		recordCodexCall(ctx, c.model, start, reported, ran, systemPrompt+userMessage, "", false)
		return "", nil, capErr
	}
	if err != nil {
		recordCodexCall(ctx, c.model, start, reported, ran, systemPrompt+userMessage, "", false)
		return "", nil, runError(c.model, output, err, stderrBuf.String(), c.codexCmd)
	}

	result, codexUsage, parseErr := parseJSONLOutputForModel(output, c.model, stderrBuf.String())
	if parseErr != nil {
		recordCodexCall(ctx, c.model, start, reported, ran, systemPrompt+userMessage, "", false)
		return "", nil, parseErr
	}
	recordCodexCall(ctx, c.model, start, reported, ran, systemPrompt+userMessage, result, true)

	// claude's shape: InputTokens without the cached part (freshInput).
	usage = &ai.Usage{
		InputTokens:    codexUsage.freshInput(),
		OutputTokens:   codexUsage.OutputTokens,
		TotalAPITokens: codexUsage.InputTokens,
	}

	return result, usage, nil
}

// InvocationProfile marks the reviewer's distinct readonly runtime. Ordinary
// clients keep their tool runtime and are eligible only for preflight selection.
func (c *Client) InvocationProfile() providers.InvocationProfile {
	if c.noServers {
		return providers.ReviewReadonly
	}
	return providers.ToolPreflight
}
