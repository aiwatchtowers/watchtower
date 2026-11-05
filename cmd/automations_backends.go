package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/agentloop"
	"watchtower/internal/ai"
	"watchtower/internal/automations"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/externalmcp"
	"watchtower/internal/fsutil"
	"watchtower/internal/providerhealth"
	"watchtower/internal/providerrouting"
	"watchtower/internal/providers"
	"watchtower/internal/tools"
)

// automationMCPTimeout bounds one automation tool call (connect, call, stop);
// a var so tests can hit it.
var automationMCPTimeout = 30 * time.Second

// callServerTool is externalmcp.CallTool; a var so tests can probe the call.
var callServerTool = externalmcp.CallTool

// automationMCPCaller is the automations.MCPCaller over the owner's Quick
// Connections.
type automationMCPCaller struct {
	cfg      *config.Config
	database *db.DB
}

func newAutomationMCPCaller(cfg *config.Config, database *db.DB) automations.MCPCaller {
	return &automationMCPCaller{cfg: cfg, database: database}
}

// Call runs tool on the enabled connection named exactly server, only under
// QC-02's verdict (externalmcp.ResolveTools on the cached listing). An
// automation never lists tools itself: a never-listed connection is not
// available until the chat's launch-time listing or `connections tools
// --refresh` lists it. The tool is checked before credentials are resolved
// or any process starts.
func (m *automationMCPCaller) Call(ctx context.Context, server, tool string, args json.RawMessage) (json.RawMessage, error) {
	conns, err := m.database.ListEnabledExternalConnections()
	if err != nil {
		// A read failure, not an absent connection (a ToolError).
		return nil, fmt.Errorf("listing Quick Connections: %w", err)
	}
	i := slices.IndexFunc(conns, func(c db.ExternalConnection) bool { return c.Name == server })
	if i < 0 {
		return nil, fmt.Errorf("%w: no enabled connection named %q", automations.ErrMCPNotAvailable, server)
	}
	c := conns[i]
	// The organization's policy (#608): refused before tools, credentials or
	// any process; the SDK turns it into a PolicyError.
	if err := connectionPolicyError(c.Name, c.Kind, c.URL, c.Command); err != nil {
		return nil, err
	}
	if externalmcp.ReservedName(c.Name) {
		recordReservedName(m.database, c)
		return nil, fmt.Errorf("%w: %q: %w", automations.ErrMCPNotAvailable, server, errReservedName)
	}
	if !c.ToolsListed {
		return nil, fmt.Errorf("%w: %q's tools were never listed — `watchtower connections tools %d --refresh`",
			automations.ErrMCPNotAvailable, server, c.ID)
	}
	allowed, _ := externalmcp.ResolveTools(c)
	if len(allowed) == 0 {
		return nil, fmt.Errorf("%w: none of %q's tools is allowed", automations.ErrMCPNotAvailable, server)
	}
	if !slices.Contains(allowed, tool) {
		return nil, fmt.Errorf("%w: %s on %q", automations.ErrMCPToolNotAllowed, tool, server)
	}
	spec, err := connectionServer(m.cfg, m.database, c)
	if err != nil {
		return nil, fmt.Errorf("%w: %q's credentials: %w", automations.ErrMCPNotAvailable, server, err)
	}
	callCtx, cancel := context.WithTimeout(ctx, automationMCPTimeout)
	defer cancel()
	res, err := callServerTool(callCtx, serverSpec(spec), tool, args)
	if err != nil && errors.Is(callCtx.Err(), context.DeadlineExceeded) && ctx.Err() == nil {
		return nil, fmt.Errorf("the call hit the %s mcp() time limit: %w", automationMCPTimeout, err)
	}
	return res, err
}

// automationBackends are the backends of every executor that runs recipes:
// the daemon's and `automations dry-run`'s.
func automationBackends(cfg *config.Config, database *db.DB, gen digest.Generator) automations.Backends {
	return automations.Backends{
		DB:        database,
		Generator: gen,
		Registry:  buildAutomationRegistry(cfg, database),
		Clock:     automations.RealClock{},
		Workbench: automationWorkbenchResolver(cfg, database),
		Shell:     automations.NewProcessShellRunner(),
		MCP:       newAutomationMCPCaller(cfg, database),
		Agent:     newAutomationAgentRunner(cfg, flagConfig, cfg.DBPath(), database),
	}
}

// automationWorkbenchResolver is the workbench lookup of the executors and
// of save_automation: the workbench rows, fsutil.PrivacyProtected and
// workbench.default_agent.
func automationWorkbenchResolver(cfg *config.Config, database *db.DB) automations.WorkbenchResolver {
	return automations.NewWorkbenchResolver(database, func() string { return cfg.Workbench.DefaultAgent }, fsutil.PrivacyProtected)
}

// automationAgentMaxTurns bounds an agent() loop's model calls (spec §6.5).
const automationAgentMaxTurns = 12

// automationAgentSource is the LLM ledger purpose of an agent() child's
// model calls.
const automationAgentSource = "automation.agent"

// automationAgentSystemPrompt frames every agent() loop: the instruction is
// the task, the tools are the only way to act, writes are proposals.
const automationAgentSystemPrompt = "You are one step of an automation script the owner wrote. " +
	"Carry out the owner's instruction using only the tools you are given, then reply with a short result. " +
	"A write tool records a proposal the owner reviews later; do not wait for it and do not ask the owner anything."

// newAutomationAgentRunner is agent()'s runner for the configured provider:
// claude and codex run a headless CLI child bound to the automation-run MCP
// server (spec §20 D3); any other provider runs the runtime-B loop in
// process. configPath is the config file this process loaded (--config):
// the child's `watchtower mcp` is pointed at it, since the allowlisted env
// drops WATCHTOWER_CONFIG_PATH.
func newAutomationAgentRunner(cfg *config.Config, configPath, dbPath string, database *db.DB) automations.AgentRunner {
	switch cfg.AI.Provider {
	case "", "claude":
		return &cliAgentRunner{cfg: cfg, configPath: configPath, dbPath: dbPath, provider: "claude"}
	case "codex":
		return &cliAgentRunner{cfg: cfg, configPath: configPath, dbPath: dbPath, provider: "codex"}
	}
	return &runtimeBAgentRunner{cfg: cfg, database: database, reg: buildAutomationRegistry(cfg, database)}
}

// tierModel is the provider's model for an agent() tier.
func tierModel(cfg *config.Config, provider, tier string) string {
	light, strong := providers.ResolveModelsFor(cfg, provider)
	if tier == "strong" {
		return strong
	}
	return light
}

// cliAgentRunner runs agent() as one headless claude/codex query whose only
// tools are the `mcp --chat --surface automation --automation-run N` server's
// (the effective set plus get_action; never a Quick Connection). The child
// gets only PATH, HOME, LANG, USER and the run marker (codex also CODEX_HOME,
// a scrubbed per-run home: codexAgentHome), runs in its own
// process group (killed as a group on cancel or deadline), and is metered
// once: BeforeModelCall before it starts, its usage — or an estimate — after.
// Its server runs under this process's config and workspace (--config,
// --workspace), not whatever the default config path would resolve to.
type cliAgentRunner struct {
	cfg        *config.Config
	configPath string // "" = the child's default
	dbPath     string
	provider   string // "claude" | "codex"
	router     *providerrouting.Router
	prepared   bool
}

func (r *cliAgentRunner) Name() string { return r.provider }

// Prepare uses shared known health only. A selected runner remains bound for
// its entire tool loop, including failures after proposals.
func (r *cliAgentRunner) Prepare(ctx context.Context, tier string) (automations.AgentRunner, error) {
	selected := *r
	selected.prepared = true
	if !r.cfg.AI.Fallback.Enabled || flagProvider != "" || aiFlagModel != "" || (r.cfg.AI.ConfiguredProvider != "" && r.cfg.AI.Provider != r.cfg.AI.ConfiguredProvider) {
		selected.router = nil
		return &selected, nil
	}
	if err := r.cfg.AI.Validate(); err != nil {
		return nil, err
	}
	if selected.router == nil {
		health, err := providerhealth.Installation()
		selected.router = &providerrouting.Router{Health: health, Diagnostic: func(err error) { log.Printf("AI agent routing: %v", err) }}
		if err != nil {
			log.Printf("AI agent routing: %v", err)
		}
	}
	provider, err := selected.router.Select(ctx, selected.routingRequest(tier))
	if err != nil {
		var failure *providers.Failure
		if errors.As(err, &failure) && failure.Category == providers.Policy {
			return nil, automations.PolicyError(err)
		}
		return nil, err
	}
	selected.provider = provider
	return &selected, nil
}

func (r *cliAgentRunner) routingRequest(tier string) providerrouting.Request {
	t := digest.TierLight
	if tier == "strong" {
		t = digest.TierStrong
	}
	return providerrouting.Request{Preferred: r.cfg.AI.Provider, Reserve: r.cfg.AI.Fallback.Provider,
		Mode: providerrouting.PreferredReserve, Profile: providers.ToolPreflight, Retry: providerrouting.BeforeChild,
		Tier: t, Revision: providers.RoutingRevision(r.cfg), Model: func(p string, _ digest.Tier) string { return tierModel(r.cfg, p, tier) },
		Capable: func(p string, profile providers.InvocationProfile) bool {
			return profile == providers.ToolPreflight && (p == "claude" || p == "codex")
		}}
}

func (r *cliAgentRunner) Run(ctx context.Context, req automations.AgentRequest) (automations.AgentResult, error) {
	if !r.prepared {
		selected, err := r.Prepare(ctx, req.Tier)
		if err != nil {
			return automations.AgentResult{}, err
		}
		return selected.Run(ctx, req)
	}
	if err := providers.Allowed(r.provider); err != nil {
		return automations.AgentResult{}, automations.PolicyError(err) // #608: nothing spawned, nothing metered
	}
	ctx, cancel := context.WithDeadline(digest.WithSource(ctx, automationAgentSource), req.Deadline)
	defer cancel()
	model := tierModel(r.cfg, r.provider, req.Tier)
	readyDir, err := os.MkdirTemp("", "wt-agent-ready-*")
	if err != nil {
		return automations.AgentResult{}, fmt.Errorf("creating the agent's ready folder: %w", err)
	}
	defer func() { _ = os.RemoveAll(readyDir) }()
	readyFile := filepath.Join(readyDir, "ready")
	mcpArgs := append(r.mcpArgs(req), "--automation-ready-file", readyFile)
	env := automationAgentEnv(req.RunID)
	var client ai.Provider
	if r.provider == "codex" {
		home, err := codexAgentHome(r.dbPath, mcpArgs)
		if err != nil {
			return automations.AgentResult{}, err
		}
		defer func() { _ = os.RemoveAll(home) }()
		c := codex.NewClient(model, r.dbPath, r.cfg.CodexPath)
		c.SetMCPArgs(mcpArgs)
		c.SetMCPEnvVars(codexAgentServerEnv)
		// codex only: CODEX_HOME joins the env allowlist, pointing at the
		// scrubbed per-run home (codexAgentHome) instead of ~/.codex.
		c.SetChildEnv(append(env, "CODEX_HOME="+home))
		c.SetServersFromHome()
		c.SetProcessGroup(true)
		client = c
	} else {
		c := ai.NewClient(model, r.dbPath, r.cfg.ClaudePath)
		c.SetMCPArgs(mcpArgs)
		c.SetWatchtowerTools(append(slices.Clone(req.Tools), "get_action"))
		c.SetMaxTurns(automationAgentMaxTurns)
		c.SetChildEnv(env)
		c.SetProcessGroup(true)
		client = c
	}
	if err := req.BeforeModelCall(); err != nil {
		return automations.AgentResult{}, err
	}
	var text string
	var usage *ai.Usage
	var observed agentUsageObserver
	query := func(callCtx context.Context) error {
		var callErr error
		text, usage, callErr = client.QuerySync(callCtx, automationAgentSystemPrompt, req.Instruction, "")
		return callErr
	}
	if r.router == nil {
		err = query(ctx)
	} else {
		route := r.routingRequest(req.Tier)
		route.Preferred, route.Mode, route.Retry = r.provider, providerrouting.Pinned, providerrouting.Never
		route.InputBytes = len(automationAgentSystemPrompt) + len(req.Instruction)
		route.Hook = &observed
		_, err = r.router.Run(ctx, route, func(callCtx context.Context, _ providerrouting.Attempt) (providerrouting.Result, error) {
			callErr := query(callCtx)
			return providerrouting.Result{Text: text}, callErr
		})
	}
	if err != nil {
		if observed.seen {
			return observed.result, err
		}
		// A child that failed or was killed (cancel, deadline) reports no
		// usage; it still read the instruction, so a provider without usage
		// numbers cannot run unbounded (spec §7.5).
		return automations.AgentResult{InputTokens: int64(len(req.Instruction)+3) / 4, Estimated: true}, err
	}
	res := agentResult(req.Instruction, text, usage)
	if observed.seen {
		res = observed.result
		res.Text = text
	}
	// The server touches readyFile once it accepted the run's binding and
	// serves: without it the child answered with no watchtower tools at all
	// (e.g. the marker never reached the server), which is not a success.
	if _, err := os.Stat(readyFile); err != nil {
		return res, errAgentToolsNeverConnected
	}
	return res, nil
}

// agentUsageObserver keeps the tool child's leaf usage even when QuerySync
// returns a typed quota instead of a successful result. It never admits a replay.
type agentUsageObserver struct {
	seen   bool
	result automations.AgentResult
}

func (*agentUsageObserver) Before(context.Context, providerrouting.Attempt) error { return nil }
func (o *agentUsageObserver) After(_ context.Context, a providerrouting.Attempt, outcome providerrouting.Outcome) error {
	if len(outcome.Calls) == 0 {
		return nil
	}
	u := automations.ModelAttemptUsage(a, outcome)
	o.seen = true
	o.result = automations.AgentResult{Text: outcome.Result.Text, InputTokens: u.InputTokens, OutputTokens: u.OutputTokens, Estimated: u.Estimated, ReportedCostUSD: u.ReportedUSD}
	return nil
}

// errAgentToolsNeverConnected is an agent() CLI child that exited without its
// bound watchtower server ever starting (no ready file).
var errAgentToolsNeverConnected = errors.New("the watchtower tools never connected (the bound MCP server did not start)")

// mcpArgs are the flags of the child's `watchtower mcp` server: the
// automation-run binding, then this process's config file and workspace.
func (r *cliAgentRunner) mcpArgs(req automations.AgentRequest) []string {
	args := []string{"--chat", "--surface", tools.AutomationSurface,
		"--automation-run", strconv.FormatInt(req.RunID, 10), "--automation-tools", strings.Join(req.Tools, ",")}
	if r.configPath != "" {
		path := r.configPath
		if abs, err := filepath.Abs(path); err == nil {
			path = abs
		}
		args = append(args, "--config", path)
	}
	if r.cfg.ActiveWorkspace != "" {
		args = append(args, "--workspace", r.cfg.ActiveWorkspace)
	}
	return args
}

// codexAgentServerEnv is what codex passes through to the agent's watchtower
// server: codex starts MCP servers with a filtered environment, and the
// server refuses to start without the run marker (mcpAutomationOptions).
var codexAgentServerEnv = []string{automations.RunEnvMarker}

// codexAgentHome is the CODEX_HOME of one agent() codex child, a fresh 0700
// temp folder the caller removes after the run. Its config.toml turns web
// search off and declares only the watchtower automation-run server, so
// neither the owner's ~/.codex/config.toml MCP servers nor web search —
// both outside the effective tool set and GateAgentCall, and an
// exfiltration channel for injected text — reach the child. The owner's
// auth.json is linked, never copied, so codex can sign in; removing the
// folder removes only the link.
func codexAgentHome(dbPath string, mcpArgs []string) (string, error) {
	dir, err := os.MkdirTemp("", "wt-agent-codex-home-*")
	if err != nil {
		return "", fmt.Errorf("creating the agent's codex home: %w", err)
	}
	config := "web_search = \"disabled\"\n\n" + codex.WatchtowerServerTOML(dbPath, mcpArgs, codexAgentServerEnv)
	if err := os.WriteFile(filepath.Join(dir, "config.toml"), []byte(config), 0o600); err != nil {
		_ = os.RemoveAll(dir)
		return "", fmt.Errorf("writing the agent's codex config: %w", err)
	}
	auth := filepath.Join(ownerCodexHome(), "auth.json")
	if _, err := os.Stat(auth); err == nil {
		if err := os.Symlink(auth, filepath.Join(dir, "auth.json")); err != nil {
			_ = os.RemoveAll(dir)
			return "", fmt.Errorf("linking the codex sign-in: %w", err)
		}
	}
	return dir, nil
}

// ownerCodexHome is the owner's codex home: CODEX_HOME, else ~/.codex.
func ownerCodexHome() string {
	if v := os.Getenv("CODEX_HOME"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".codex")
}

// automationAgentPassthrough is the env an agent() child inherits from this
// process when set: identity plus network plumbing (proxy, CA bundle, TMPDIR;
// owner ask #185). Never an API key or token.
var automationAgentPassthrough = []string{
	"HOME", "LANG", "USER",
	"HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy",
	"ALL_PROXY", "all_proxy",
	"NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR", "TMPDIR",
}

// automationAgentEnv is an agent() child's environment besides PATH (the
// clients append the rich PATH): automationAgentPassthrough from this process
// when set (absent ones omitted), and the run marker (AGENT-07).
func automationAgentEnv(runID int64) []string {
	var env []string
	for _, k := range automationAgentPassthrough {
		if v := os.Getenv(k); v != "" {
			env = append(env, k+"="+v)
		}
	}
	return append(env, automations.RunEnvMarker+"="+strconv.FormatInt(runID, 10))
}

// agentResult is a finished agent() loop: the provider's usage and cost
// (claude's total_cost_usd), or, when it reported no tokens at all (a fully
// cached input counts as reported), an estimate of
// ceil(len(instruction+text)/4) tokens (the reply's share as output).
func agentResult(instruction, text string, u *ai.Usage) automations.AgentResult {
	res := automations.AgentResult{Text: text}
	if u != nil && u.CostUSD > 0 {
		cost := u.CostUSD
		res.ReportedCostUSD = &cost
	}
	if u != nil && (u.InputTokens > 0 || u.OutputTokens > 0 || u.TotalAPITokens > 0) {
		res.InputTokens, res.OutputTokens = int64(u.InputTokens), int64(u.OutputTokens)
		return res
	}
	total := int64(len(instruction)+len(text)+3) / 4
	res.OutputTokens = min(total, int64(len(text)+3)/4)
	res.InputTokens, res.Estimated = total-res.OutputTokens, true
	return res
}

// runtimeBAgentRunner runs agent() on the in-process runtime-B loop
// (agentloop) for the OpenAI-compatible providers: the effective set only,
// every call through GateAgentCall, every result through CheckAgentResult,
// at most automationAgentMaxTurns model calls, each metered by the request's
// hooks.
type runtimeBAgentRunner struct {
	cfg      *config.Config
	database *db.DB
	reg      *tools.Registry
}

func (r *runtimeBAgentRunner) Name() string { return "runtime-b" }

func (r *runtimeBAgentRunner) Run(ctx context.Context, req automations.AgentRequest) (automations.AgentResult, error) {
	if err := providers.Allowed(r.cfg.AI.Provider); err != nil {
		return automations.AgentResult{}, automations.PolicyError(err) // #608
	}
	ctx, cancel := context.WithDeadline(digest.WithSource(ctx, automationAgentSource), req.Deadline)
	defer cancel()
	allowed := req.Tools
	if allowed == nil {
		allowed = []string{} // nil would offer every surface tool
	}
	c := agentloop.NewClientWithOptions(tierModel(r.cfg, r.cfg.AI.Provider, req.Tier), r.cfg.AI.OllamaURL, r.reg, req.Binding,
		agentloop.Options{
			Tools: allowed,
			Gate: func(ctx context.Context, t *tools.Tool, args json.RawMessage) (json.RawMessage, error) {
				return automations.GateAgentCall(ctx, r.database, req.Manifest, req.RunID, t, args)
			},
			ResultCheck:     automations.CheckAgentResult,
			MaxIterations:   automationAgentMaxTurns,
			BeforeModelCall: req.BeforeModelCall,
			AfterModelCall:  req.AfterModelCall,
		})
	text, usage, err := c.QuerySync(ctx, automationAgentSystemPrompt, req.Instruction, "")
	if err != nil {
		return automations.AgentResult{}, err
	}
	return agentResult(req.Instruction, text, usage), nil
}
