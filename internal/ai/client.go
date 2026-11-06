package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"watchtower/internal/claude"
	"watchtower/internal/fsutil"
	"watchtower/internal/llmusage"
	"watchtower/internal/logredact"
	"watchtower/internal/providers"
	"watchtower/internal/streamline"
)

// Usage holds token metrics from an AI call.
type Usage struct {
	llmusage.Tokens
}

// InputTokens is the fresh (uncached) input.
func (u Usage) InputTokens() int { return int(u.Input) }

// OutputTokens is the output tokens.
func (u Usage) OutputTokens() int { return int(u.Output) }

// TotalAPITokens is every input token, cache reads and writes included.
func (u Usage) TotalAPITokens() int { return int(u.AllInput()) }

// CostUSD is the provider's reported cost (claude's total_cost_usd); 0 = not
// reported.
func (u Usage) CostUSD() float64 { return u.ReportedCost() }

// cliUsage is the nested usage object in the Claude CLI JSON response.
type cliUsage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
	// CacheCreation splits CacheCreationInputTokens by cache TTL.
	CacheCreation struct {
		FiveMin int `json:"ephemeral_5m_input_tokens"`
		OneHour int `json:"ephemeral_1h_input_tokens"`
	} `json:"cache_creation"`
}

// tokens is the envelope's usage as a block, the cache writes split by TTL.
func (u cliUsage) tokens() llmusage.Tokens {
	return llmusage.ClaudeTokens(u.InputTokens, u.CacheReadInputTokens, u.CacheCreationInputTokens,
		u.CacheCreation.FiveMin, u.CacheCreation.OneHour, u.OutputTokens)
}

// resultUsage is the usage a result envelope or result stream event
// reports: the LLM usage ledger's numbers (recordClaude).
type resultUsage struct {
	CostUSD float64  `json:"total_cost_usd"`
	Usage   cliUsage `json:"usage"`
	// ModelUsage is the per-model usage keyed by the model's full name.
	ModelUsage map[string]json.RawMessage `json:"modelUsage"`
}

// tokens is the result's usage block with its reported cost (one claude
// child per call, so total_cost_usd is this call's own).
func (r resultUsage) tokens() llmusage.Tokens {
	t := r.Usage.tokens()
	if r.CostUSD > 0 {
		cost := r.CostUSD
		t.ReportedCostUSD = &cost
	}
	return t
}

// cliResponse is the JSON structure returned by `claude --output-format json`.
type cliResponse struct {
	Error      json.RawMessage `json:"error"`
	limit      *providers.ClaudeRateLimitInfo
	Type       string `json:"type"`
	Subtype    string `json:"subtype"`
	Result     string `json:"result"`
	DurationMS int    `json:"duration_ms"`
	NumTurns   int    `json:"num_turns"`
	IsError    bool   `json:"is_error"`
	SessionID  string `json:"session_id"`
	resultUsage
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
			resp.limit = providers.ClaudeResultLimit(output)
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
				events[i].limit = providers.ClaudeResultLimit(output)
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
func envelopeMessage(result string) logredact.Text {
	msg := strings.TrimSpace(result)
	if msg == "" {
		return logredact.Text("no message in the CLI result envelope")
	}
	const maxEnvelopeMessage = 4096
	if len(msg) <= maxEnvelopeMessage {
		return logredact.Text(msg)
	}
	// Back off to a rune boundary: this text is model output and routinely
	// Cyrillic, so a byte cut lands mid-rune and writes a broken one into logs.
	cut := maxEnvelopeMessage
	for cut > 0 && !utf8.RuneStart(msg[cut]) {
		cut--
	}
	return logredact.Text(msg[:cut] + fmt.Sprintf("… (%d bytes truncated)", len(msg)-cut))
}

// ExternalMCPServer is a plain DTO describing an owner-added external MCP
// server to merge into the chat config and tool allowlist. It mirrors the
// shape of db.ExternalConnection without importing internal/db, keeping
// internal/ai free of a DB dependency.
type ExternalMCPServer struct {
	ID      int64  // the external_connections row (codex names its header variables after it)
	Name    string // becomes the mcpServers key and the mcp__<Name>__ tool prefix
	Kind    string // "stdio" | "http"
	Command string
	Args    []string
	URL     string
	Env     map[string]string
	Headers map[string]string
	// AllowTools are the tool names the chat may call without a prompt
	// (QC-02: only tools known to be read-only, or the owner's explicit
	// list); DenyTools are the server's other listed tools, hidden from the
	// model outright. A tool in neither (added after the last tools/list)
	// is visible but never approved — headless chats cannot prompt.
	AllowTools []string
	DenyTools  []string
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
	// readFolder, when set (SetReadFolder), runs the CLI in that folder
	// with its file-read tools allowed and unhidden and no settings files
	// loaded. Empty = today's run in os.TempDir().
	readFolder string
	// watchtowerTools narrows the watchtower allowlist from the whole server
	// to these tools when watchtowerToolsSet (SetWatchtowerTools); an empty
	// set then allows no watchtower tool at all.
	watchtowerTools    []string
	watchtowerToolsSet bool
	// childEnv replaces the os.Environ() base of the child's environment
	// when childEnvSet (SetChildEnv).
	childEnv    []string
	childEnvSet bool
	// maxTurns, when > 0, is passed as --max-turns (SetMaxTurns).
	maxTurns int
	// toolEvents streams tool calls and the turn's usage as chunks
	// (EmitToolEvents) instead of a boundary per tool call.
	toolEvents bool
}

// EmitToolEvents switches Query onto the chat events `ai query --events v2`
// renders (transport.Options.ToolEvents): each tool call a start and an end chunk,
// the turn's usage last, and no ToolBoundary — text streamed before a call is
// kept, and the text of a later message starts after a blank line.
func (c *Client) EmitToolEvents() { c.toolEvents = true }

// SetWatchtowerTools narrows --allowedTools from the whole `mcp__watchtower`
// server to one mcp__watchtower__<name> token per name (an automation's
// headless agent() child). An empty or nil names grants no watchtower tool;
// never calling it keeps today's whole-server token.
func (c *Client) SetWatchtowerTools(names []string) {
	c.watchtowerTools, c.watchtowerToolsSet = names, true
}

// SetChildEnv replaces the inherited environment of the child with env (the
// rich PATH is still appended last). Unset = os.Environ() as today.
func (c *Client) SetChildEnv(env []string) { c.childEnv, c.childEnvSet = env, true }

// SetMaxTurns passes --max-turns n to the CLI; 0 = no limit flag.
func (c *Client) SetMaxTurns(n int) { c.maxTurns = n }

// childEnviron is the child's environment: os.Environ() plus the rich PATH,
// or, with SetChildEnv, exactly that env (any PATH entry dropped) plus the
// rich PATH.
func (c *Client) childEnviron() []string {
	if !c.childEnvSet {
		return append(os.Environ(), "PATH="+claude.RichPATH())
	}
	env := make([]string, 0, len(c.childEnv)+1)
	for _, e := range c.childEnv {
		if !strings.HasPrefix(e, "PATH=") {
			env = append(env, e)
		}
	}
	return append(env, "PATH="+claude.RichPATH())
}

// GroupKillGrace is how long a CLI child (ConfigureChild, e.g. an
// automation's agent() child) has between SIGINT and the group's SIGKILL. It
// stays under the automation sandbox's 2 s AbandonGrace, so a cancelled or
// stopped run's call returns — the whole group dead — before the run would
// be abandoned and before the daemon, which waits for its runs, can exit and
// leave a SIGINT-ignoring child behind.
const GroupKillGrace = time.Second

// ConfigureChild applies the one cancel policy of every CLI child (spec
// 2026-11-05 §3.4: group-only, so no caller can forget it): a process group
// of its own that is interrupted and then killed as a whole (the leader's
// grandchildren included) after GroupKillGrace. Shared with the codex
// client. The caller runs the returned reap once cmd.Wait has returned (or
// the child never started): a cancelled group's pending SIGKILL is then
// sent at once and its timer stopped, so the group is dead when the call
// returns — even when WaitDelay ended the wait first — and no timer
// outlives the call to signal a reused process group id later.
func ConfigureChild(cmd *exec.Cmd) (reap func()) {
	cmd.WaitDelay = GroupKillGrace
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var mu sync.Mutex
	var kill *time.Timer
	var pgid int
	cmd.Cancel = func() error {
		mu.Lock()
		defer mu.Unlock()
		leader := cmd.Process.Pid // Setpgid: the leader's pid is the group id
		pgid = leader
		kill = time.AfterFunc(GroupKillGrace, func() { _ = syscall.Kill(-leader, syscall.SIGKILL) })
		return syscall.Kill(-pgid, syscall.SIGINT)
	}
	return func() {
		mu.Lock()
		defer mu.Unlock()
		if kill != nil && kill.Stop() {
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
		}
	}
}

// SetMCPArgs appends extra flags to the MCP server command (chat mode).
func (c *Client) SetMCPArgs(extra []string) { c.mcpArgs = extra }

// SetExternalMCPServers registers owner-added external MCP servers to merge
// into the chat's mcp-config and tool allowlist alongside the built-in
// watchtower server.
func (c *Client) SetExternalMCPServers(s []ExternalMCPServer) { c.externalServers = s }

// SetReadFolder makes the run a read-only look at dir (`ai query
// --read-folder`, the workbench code questions; owner decision 2026-10-03,
// ruling R55): the CLI starts with cwd = dir, and Read, Grep, Glob and LS
// are the only built-ins added to the --tools allowlist and taken off
// --disallowedTools — every write, shell, web and task tool stays hidden.
// The tools can read outside dir and a read can raise a macOS privacy
// prompt (accepted by the owner, spec 2026-10-02 §9.1); nothing can write
// or reach the network. Settings files are not loaded
// (`--setting-sources ""`): a workbench folder carries
// .claude/settings.local.json hooks that write session state and run the
// board drift check, and a read run must start none of them. dir must
// already be resolved to a workbench folder (cmd's resolveReadFolder).
func (c *Client) SetReadFolder(dir string) { c.readFolder = dir }

// ArgsForTest returns the argv a QuerySync would run (tests outside this
// package: cmd's spec reviewer wiring). Nothing is written to disk: the
// prompt and a secret-bearing config travel as /dev/fd payloads.
func (c *Client) ArgsForTest(systemPrompt, userMessage string) []string {
	args, _, _ := c.buildArgs(systemPrompt, userMessage, "json")
	return args
}

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

// buildArgs constructs the common CLI arguments, plus the stdin content: the
// user message always travels on stdin (a bare "-p" makes claude read the
// prompt from there), never on argv, where every local process could read
// it through `ps` and a large one would hit ARG_MAX. No Claude session is
// stored (--no-session-persistence): a caller that wants continuity puts
// the history in the message. payloads are the
// contents the argv names as /dev/fd/3, /dev/fd/4, … (fsutil.PayloadPath):
// the system prompt and a secret-bearing mcp-config, which the caller hands
// over inherited pipes (fsutil.AttachPayloads on a cmd with no other
// ExtraFiles) — nothing written to disk, nothing on argv. Returned rather
// than kept on the Client, so concurrent calls never share them.
func (c *Client) buildArgs(systemPrompt, userMessage, outputFormat string) (args []string, stdin string, payloads []string) {
	viaFD := func(content string) string {
		payloads = append(payloads, content)
		return fsutil.PayloadPath(len(payloads) - 1)
	}
	stdin = userMessage
	args = slices.Concat([]string{
		"-p",
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
		// Built-in allowlist: the model sees exactly the Claude Code built-ins
		// named here (MCP tools are unaffected), so a built-in a future CLI
		// release adds stays hidden by default instead of slipping past the
		// deny list below. See ChatBuiltinTools.
		// A read-folder run adds the file reads (ReadFolderBuiltinTools).
		"--tools", c.builtinTools(),
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
		// The deny list is defence in depth behind --tools: it keeps every
		// known built-in hidden even if a CLI release stopped honouring the
		// allowlist. A read-folder run unhides only the file reads.
		"--disallowedTools", WithExternalDisallowed(c.disallowedTools(), c.externalServers),
		// Skip user-level ~/.claude/settings.json so its plugins/hooks/CLAUDE.md
		// auto-discovery don't probe ~/Desktop or ~/Documents at startup —
		// those probes trigger macOS TCC prompts attributed to Watchtower.app.
		// Keychain-backed OAuth still works because we don't override CLAUDE_CONFIG_DIR.
		// A read-folder run loads no settings file at all (see SetReadFolder).
		"--setting-sources", c.settingSources(),
		// Only the MCP servers named in --mcp-config (watchtower + the owner's
		// Quick Connections): never the owner's claude.ai connectors or any
		// other server the CLI would load on its own.
		"--strict-mcp-config",
	})
	if c.maxTurns > 0 {
		args = append(args, "--max-turns", strconv.Itoa(c.maxTurns))
	}
	// Claude CLI requires --verbose for stream-json output format.
	if outputFormat == "stream-json" {
		args = append(args, "--verbose")
	}
	if c.dbPath != "" {
		mcpConfig := c.buildMCPConfig()
		if c.hasSecret() {
			// A secret (Env/Headers) must never sit in argv — it's visible to
			// every other process on the box via `ps` — nor in a temp file:
			// the config reaches the child over an inherited pipe.
			args = append(args, "--mcp-config", viaFD(mcpConfig))
		} else {
			args = append(args, "--mcp-config", mcpConfig)
		}
	}
	// No session store on disk (#604 G11): every call is a fresh session,
	// so the prompt is always sent.
	args = append(args, "--no-session-persistence")
	// Mounted Quick Connections' texts are fenced as external data.
	systemPrompt = WithExternalDataRule(systemPrompt, c.externalServers)
	if systemPrompt == "" {
		// An empty prompt still replaces claude's default one and
		// carries nothing.
		args = append(args, "--system-prompt", "")
	} else {
		// The prompt carries the owner's data (a pipeline's whole
		// payload, a chat's context): on argv it would be readable in
		// `ps` for the process lifetime and could hit ARG_MAX, and in a
		// temp file it would outlive a crash. It goes over a pipe.
		args = append(args, "--system-prompt-file", viaFD(systemPrompt))
	}
	return args, stdin, payloads
}

// builtinTools is the --tools allowlist: ReadFolderBuiltinTools for a
// read-folder run, ChatBuiltinTools otherwise.
func (c *Client) builtinTools() string {
	if c.readFolder != "" {
		return ReadFolderBuiltinTools
	}
	return ChatBuiltinTools
}

// disallowedTools is the --disallowedTools base: ReadOnlyFolderDisallowedTools
// for a read-folder run, DisallowedTools otherwise.
func (c *Client) disallowedTools() string {
	if c.readFolder != "" {
		return ReadOnlyFolderDisallowedTools
	}
	return DisallowedTools
}

// settingSources is the --setting-sources value: none for a read-folder run
// (the folder's own .claude settings carry hooks), project and local otherwise.
func (c *Client) settingSources() string {
	if c.readFolder != "" {
		return ""
	}
	return "project,local"
}

// workDir is where the CLI runs: the read folder, or a TCC-neutral
// directory so the Node-based CLI never inherits a parent CWD inside
// ~/Documents or ~/Desktop (macOS Files & Folders prompts attributed to
// Watchtower).
func (c *Client) workDir() string {
	if c.readFolder != "" {
		return c.readFolder
	}
	return os.TempDir()
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

// ChatBuiltinTools is the --tools value of every chat run on the one-shot
// client: the only Claude Code built-in it may see is ToolSearch, which loads
// the deferred watchtower tool schemas. --tools is an allowlist over the
// CLI's built-in set (MCP tools are not affected), so a built-in added by a
// later CLI release is hidden by default — the deny list alone went stale
// with every release (DesignSync, ReportFindings, ShareOnboardingGuide in
// 2.1.288). Adding a name here exposes it to every chat: it must be approved
// in TestChatBuiltins_OnlyApprovedNamesExposed first.
const ChatBuiltinTools = ToolSearchTool

// SessionBuiltinTools is the warm `ai session` (main chat, Claude backend)
// --tools value: ChatBuiltinTools plus WebSearch, which that session alone
// may use (see SessionDisallowedTools).
const SessionBuiltinTools = ChatBuiltinTools + "," + WebSearchTool

// ClaudeAISessionBuiltinTools is the warm `ai session` --tools value in
// claude.ai mode (main chat, Claude provider, a claude.ai login — see
// chat.ClaudeAIAvailability): SessionBuiltinTools plus Artifact, which
// publishes to the owner's claude.ai account, and Write, which writes the
// page's source file. The session's permission gate confines both to the
// conversation's publish dir. Read and Edit stay hidden: Claude Code may run
// a read-only built-in without asking, so the gate could not confine a Read.
var ClaudeAISessionBuiltinTools = SessionBuiltinTools + "," + strings.Join(claudeAITools, ",")

// claudeAITools are the built-ins claude.ai mode adds to the session and
// unhides.
var claudeAITools = []string{"Artifact", "Write"}

// fileReadTools are the built-ins a read-folder run allows and unhides.
var fileReadTools = []string{"Read", "Grep", "Glob", "LS"}

// ReadFolderBuiltinTools is the --tools value of a read-folder run (a
// workbench code question, Client.SetReadFolder): ChatBuiltinTools plus the
// four file reads.
var ReadFolderBuiltinTools = ChatBuiltinTools + "," + strings.Join(fileReadTools, ",")

// ReadOnlyFolderDisallowedTools is DisallowedTools minus Read, Grep, Glob
// and LS: the hidden set of a read-folder run (Client.SetReadFolder).
var ReadOnlyFolderDisallowedTools = withoutTools(DisallowedTools, fileReadTools)

// withoutTools drops the named tools from a comma-separated tool list.
func withoutTools(list string, drop []string) string {
	kept := slices.DeleteFunc(strings.Split(list, ","), func(tool string) bool {
		return slices.Contains(drop, tool)
	})
	return strings.Join(kept, ",")
}

// ToolSearchTool is Claude Code's built-in deferred-tool loader.
const ToolSearchTool = "ToolSearch"

// DisallowedTools hides every built-in Claude Code tool from the chat model
// (see buildArgs for why each group is hidden). Shared by the one-shot client
// and the warm `ai session` backend. It is defence in depth behind the
// ChatBuiltinTools/SessionBuiltinTools allowlist: the lines after the first
// three are the newer CLI built-ins (scheduling/remote triggers, workflows,
// agent/task plumbing, MCP resource readers that would bypass the Quick
// Connections allowlist, host-UI tools) — an unknown name is ignored by older
// CLIs. TestChatBuiltins_DenyListCoversSnapshot keeps it in step with the
// pinned CLI built-in snapshot. ToolSearch stays allowed: it loads the
// deferred watchtower tool schemas.
const DisallowedTools = sessionDisallowedTools + "," + WebSearchTool

// SessionDisallowedTools is DisallowedTools minus WebSearch: the main chat's
// warm `ai session` (Claude backend) may search the public web. WebFetch stays
// hidden there too — fetching an arbitrary URL is the exfiltration channel a
// prompt-injection payload in synced content would use, while a search query
// only reaches the provider's own search backend.
const SessionDisallowedTools = sessionDisallowedTools

// ClaudeAISessionDisallowedTools is SessionDisallowedTools minus Artifact and
// Write: the hidden set of the warm session in claude.ai mode. Every other
// run — the one-shot client and the session outside claude.ai mode — keeps
// both hidden, and ArtifactCheck, ArtifactComments and ArtifactData stay
// hidden here too.
var ClaudeAISessionDisallowedTools = withoutTools(SessionDisallowedTools, claudeAITools)

// WebSearchTool is Claude Code's built-in web search tool.
const WebSearchTool = "WebSearch"

const sessionDisallowedTools = "Edit,Write,NotebookEdit,TodoWrite,Task,TodoRead," +
	"Bash,BashOutput,KillShell,WebFetch,Read,Grep,Glob,LS," +
	"ExitPlanMode,SlashCommand,Skill," +
	"CronCreate,CronDelete,CronList,RemoteTrigger,ScheduleWakeup,PushNotification,Workflow,Monitor," +
	"EnterWorktree,ExitWorktree,ListAgents,SendMessage,TaskCreate,TaskGet,TaskList,TaskStop,TaskUpdate," +
	"ListMcpResourcesTool,ReadMcpResourceTool,ReadMcpResourceDirTool," +
	"Agent,AskUserQuestion,EnterPlanMode,PowerShell,SendUserMessage,SubagentHandback,StructuredOutput," +
	"Artifact,ArtifactCheck,ArtifactComments,ArtifactData,ConnectGitHub," +
	"DesignSync,ReportFindings,ShareOnboardingGuide,WaitForMcpServers"

// AllowedTools builds the --allowedTools value: the built-in watchtower
// server plus one mcp__<Name>__<tool> token per allowed external tool, in
// slice order. An external server is never granted whole (QC-02): a whole
// `mcp__<Name>` token would let the chat call its write tools unapproved.
func AllowedTools(ext []ExternalMCPServer) string {
	return allowedTools([]string{"mcp__watchtower"}, ext)
}

// allowedTools joins the base tokens and every allowed external tool token.
func allowedTools(base []string, ext []ExternalMCPServer) string {
	tokens := slices.Clone(base)
	for _, s := range ext {
		for _, t := range s.AllowTools {
			tokens = append(tokens, externalToolToken(s.Name, t))
		}
	}
	return strings.Join(tokens, ",")
}

// ExternalDisallowedTools lists every external tool the chat must not call
// (each server's DenyTools) as mcp__<Name>__<tool> tokens, for appending to
// --disallowedTools so the model never sees them; "" when there are none.
func ExternalDisallowedTools(ext []ExternalMCPServer) string {
	var tokens []string
	for _, s := range ext {
		for _, t := range s.DenyTools {
			tokens = append(tokens, externalToolToken(s.Name, t))
		}
	}
	return strings.Join(tokens, ",")
}

// WithExternalDisallowed appends ExternalDisallowedTools(ext) to a base
// --disallowedTools value.
func WithExternalDisallowed(base string, ext []ExternalMCPServer) string {
	if extra := ExternalDisallowedTools(ext); extra != "" {
		return base + "," + extra
	}
	return base
}

// externalToolToken is the name Claude Code gives an MCP tool,
// mcp__<server>__<tool>, with every character outside [A-Za-z0-9_-] replaced
// by '_' the way the CLI normalizes it — which also keeps a hostile tool name
// from injecting a comma-separated token into the flag.
func externalToolToken(server, tool string) string {
	return "mcp__" + server + "__" + nonToolNameChars.ReplaceAllString(tool, "_")
}

var nonToolNameChars = regexp.MustCompile(`[^A-Za-z0-9_-]`)

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

// allowedToolsFlag builds the --allowedTools value (see AllowedTools; no
// external servers means byte-identical to the pre-feature value).
func (c *Client) allowedToolsFlag() string {
	if c.watchtowerToolsSet {
		tokens := make([]string, len(c.watchtowerTools))
		for i, n := range c.watchtowerTools {
			tokens[i] = externalToolToken("watchtower", n)
		}
		return allowedTools(tokens, c.externalServers)
	}
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
// one value — the session ID from the "result" event, for display only: no
// session is stored (--no-session-persistence), so the Provider's sessionID
// argument is ignored.
func (c *Client) Query(ctx context.Context, systemPrompt, userMessage, _ string) (<-chan StreamChunk, <-chan error, <-chan string) {
	textCh := make(chan StreamChunk, 64)
	errCh := make(chan error, 1)
	sidCh := make(chan string, 1)

	go func() {
		defer close(textCh)
		defer close(errCh)
		defer close(sidCh)

		args, promptStdin, payloads := c.buildArgs(systemPrompt, userMessage, "stream-json")
		// runCtx ends the child when the read below fails, so the run never
		// waits on a claude blocked writing into a pipe nobody reads.
		runCtx, cancelRun := context.WithCancel(ctx)
		defer cancelRun()
		cmd := exec.CommandContext(runCtx, c.claudeCmd, args...)
		_, closePayloads, err := fsutil.AttachPayloads(cmd, payloads...)
		if err != nil {
			errCh <- err
			return
		}

		// The run is recorded in the LLM usage ledger when the stream ends,
		// however it ends: from the last result event's usage, else
		// estimated from the prompt and the text streamed so far.
		start := time.Now()
		var (
			lastResult *streamEvent
			streamed   strings.Builder
			runErr     error
		)
		defer func() {
			var u *resultUsage
			if lastResult != nil {
				u = &lastResult.resultUsage
			}
			recordClaude(ctx, c.model, u, cmd.Process != nil, start, runErr, systemPrompt+userMessage, streamed.String())
		}()
		fail := func(err error) {
			err = providers.ContextFailure("claude", ctx, providers.ProcessFailure("claude", err))
			runErr = err
			errCh <- err
		}
		defer closePayloads()
		if promptStdin != "" {
			cmd.Stdin = strings.NewReader(promptStdin)
		}
		// The group gets SIGINT, then SIGKILL after GroupKillGrace.
		reap := ConfigureChild(cmd)
		defer reap()
		cmd.Dir = c.workDir()
		cmd.Env = c.childEnviron()

		stdout, err := cmd.StdoutPipe()
		if err != nil {
			fail(fmt.Errorf("creating stdout pipe: %w", err))
			return
		}

		// Cap stderr to 64KB to prevent unbounded memory growth.
		var stderrBuf strings.Builder
		cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

		if err := cmd.Start(); err != nil {
			fail(classifyError(err, ""))
			return
		}
		closePayloads()

		// Lines up to maxStreamLine are read (a tool result can carry
		// megabytes); a longer one is skipped and counted (L1).
		lines := streamline.NewWithLimit(stdout, maxStreamLine)
		defer logSkippedLines(lines)

		// lastResult (declared above) remembers the most recent "result"
		// event: its usage for the ledger, and its is_error/result fields —
		// the CLI's own diagnostic (e.g. "Invalid API key · Please run
		// /login") for an API/usage failure, which otherwise arrives on stdout
		// as an ordinary envelope (classifyError only ever sees stderr, which
		// is empty in this case; see internal/digest/generator.go's
		// errorEnvelopeMessage for the same pattern on the batch path).

		var limits providers.ClaudeLimitTracker
		chatEvents := newChatEventState()
		for {
			line, readErr := lines.Next()
			if errors.Is(readErr, io.EOF) {
				break
			}
			if readErr != nil {
				cancelRun()
				_ = cmd.Wait()
				fail(fmt.Errorf("reading claude output: %w", readErr))
				return
			}
			if len(line) == 0 {
				continue
			}

			var event streamEvent
			if err := json.Unmarshal(line, &event); err != nil {
				lines.MarkUndecodable()
				continue
			}

			hint := limits.Observe(line)
			if event.Type == "result" {
				event.limit = hint
				captured := event
				lastResult = &captured
				if event.SessionID != "" {
					sidCh <- event.SessionID
				}
			}

			if c.toolEvents {
				for _, chunk := range chatEvents.chunks(&event) {
					streamed.WriteString(chunk.Text)
					select {
					case textCh <- chunk:
					case <-ctx.Done():
						_ = cmd.Wait()
						fail(ctx.Err())
						return
					}
				}
				continue
			}

			// A tool call interrupts the turn: signal a boundary so the consumer
			// drops the pre-tool preamble (including any text in this very event)
			// and starts the visible answer fresh from what follows the tool.
			if event.hasToolUse() {
				select {
				case textCh <- StreamChunk{ToolBoundary: true}:
				case <-ctx.Done():
					_ = cmd.Wait()
					fail(ctx.Err())
					return
				}
				continue
			}

			text := event.extractText()
			if text == "" {
				continue
			}
			streamed.WriteString(text)

			select {
			case textCh <- StreamChunk{Text: text}:
			case <-ctx.Done():
				// CommandContext handles killing the process; just reap it.
				_ = cmd.Wait()
				fail(ctx.Err())
				return
			}
		}

		// A tool whose result was in a skipped line still gets its end, with
		// a reason, so no step stays running (the codex rule).
		if c.toolEvents && lines.Skipped() > 0 {
			for _, chunk := range chatEvents.closeOpen("claude's report of this tool's result could not be read") {
				select {
				case textCh <- chunk:
				case <-ctx.Done():
					_ = cmd.Wait()
					fail(ctx.Err())
					return
				}
			}
		}

		waitErr := cmd.Wait()

		// The CLI can flag is_error in its own envelope regardless of exit
		// code (a failure surfaced this way, or one that exits 0 anyway) —
		// its own message is always more actionable than a bare exit code or
		// empty stderr, so it takes priority over classifyError below.
		if lastResult != nil && lastResult.IsError {
			fail(providers.ContextFailure("claude", ctx, providers.ClaudeResultFailure(lastResult.Type, lastResult.Subtype, lastResult.IsError, lastResult.Error, lastResult.Result, lastResult.limit, withCause(logredact.Errorf("claude returned error (subtype=%s): %s", lastResult.Subtype, envelopeMessage(lastResult.Result)), waitErr))))
			return
		}

		if waitErr != nil {
			fail(classifyError(waitErr, stderrBuf.String()))
			return
		}

		// A clean exit without a result event never ends as a blank or
		// partial "complete" turn (L12): the answer may be cut short, and a
		// skipped line may have been the answer or the result itself. Codex
		// and the batch path refuse the same run.
		if lastResult == nil {
			err := errNoResultEvent
			if n := lines.Skipped(); n > 0 {
				err = fmt.Errorf("%w (%d line(s) over %d bytes skipped)", err, n, maxStreamLine)
			}
			fail(noResultFailure(err, stderrBuf.String()))
		}
	}()

	return textCh, errCh, sidCh
}

// errNoResultEvent fails a claude run that exited cleanly without its
// result event.
var errNoResultEvent = errors.New("claude output had no result event")

// noResultFailure is the typed failure of a claude run that exited 0
// without its result (L12): claude's stderr rides along (redacted in logs)
// and decides the category when it is one of the CLI's own auth or
// rate-limit diagnostics, else invalid_output (providers.CleanExitFailure).
func noResultFailure(cause error, stderr string) error {
	stderr = strings.TrimSpace(stderr)
	if stderr != "" {
		cause = logredact.Errorf("%w (stderr: %s)", cause, logredact.Text(stderr))
	}
	return providers.CleanExitFailure("claude", stderr, cause)
}

// maxStreamLine is the longest stream-json line Query decodes
// (streamline.MaxLine); a variable so tests can lower it.
var maxStreamLine = streamline.MaxLine

// logSkippedLines logs how many lines of claude's stream-json output were
// skipped as over the limit or were not a JSON event (counts, never
// content: FILES-01); nothing for none.
func logSkippedLines(lines *streamline.Reader) {
	if n := lines.Skipped(); n > 0 {
		log.Printf("claude: skipped %d stream-json line(s) over %d bytes", n, maxStreamLine)
	}
	if n := lines.Undecodable(); n > 0 {
		log.Printf("claude: %d undecodable stream-json line(s) ignored", n)
	}
}

// QuerySync sends a non-streaming request via the Claude Code CLI and returns
// the full response text and token usage. The sessionID argument is ignored
// (see Query).
func (c *Client) QuerySync(ctx context.Context, systemPrompt, userMessage, _ string) (text string, _ *Usage, err error) {
	defer func() { err = providers.ContextFailure("claude", ctx, providers.ProcessFailure("claude", err)) }()
	args, promptStdin, payloads := c.buildArgs(systemPrompt, userMessage, "json")
	cmd := exec.CommandContext(ctx, c.claudeCmd, args...)
	// cmd.Output starts the child before it blocks; the parent's read ends
	// close once it returns (the child holds its own).
	_, closePayloads, err := fsutil.AttachPayloads(cmd, payloads...)
	if err != nil {
		return "", nil, err
	}
	defer closePayloads()
	if promptStdin != "" {
		cmd.Stdin = strings.NewReader(promptStdin)
	}
	reap := ConfigureChild(cmd)
	defer reap()
	cmd.Dir = c.workDir()
	cmd.Env = c.childEnviron()

	var stderrBuf strings.Builder
	cmd.Stderr = &limitedWriter{w: &stderrBuf, limit: 64 * 1024}

	// Every run is recorded in the LLM usage ledger, failed ones included.
	start := time.Now()
	var envelope *resultUsage
	defer func() {
		recordClaude(ctx, c.model, envelope, cmd.Process != nil, start, err, systemPrompt+userMessage, text)
	}()

	output, err := cmd.Output()
	if err != nil {
		// The CLI reports an API or usage failure as an ordinary result
		// envelope on stdout and exits 1, with the actionable reason (e.g.
		// "Invalid API key · Please run /login") behind kilobytes of usage
		// telemetry — and with stderr empty. Parse it first so that message
		// survives instead of a bare "exit code 1" (the digest generator's
		// errorEnvelopeMessage precedent, internal/digest/generator.go).
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			if resp, perr := parseCLIOutput(output); perr == nil && resp.IsError {
				envelope = &resp.resultUsage
				return "", nil, providers.ClaudeResultFailure(resp.Type, resp.Subtype, resp.IsError, resp.Error, resp.Result, resp.limit, withCause(logredact.Errorf("claude CLI failed (exit %d, subtype=%s): %s",
					exitErr.ExitCode(), resp.Subtype, envelopeMessage(resp.Result)), exitErr))
			}
		}
		return "", nil, classifyError(err, stderrBuf.String())
	}

	// A clean exit must leave a result object (L12): empty output, an array
	// without a result event, another event or plain text is never handed
	// back as the answer. --output-format json always prints JSON, so no
	// caller gets plain text; the parse error describes the output, never
	// echoes it.
	resp, err := parseCLIOutput(output)
	if err == nil && resp.Type != "result" {
		err = logredact.Errorf("claude CLI output is a %q object, not a result", logredact.Text(resp.Type))
	}
	if err != nil {
		return "", nil, noResultFailure(fmt.Errorf("%w: %w", errNoResultEvent, err), stderrBuf.String())
	}
	envelope = &resp.resultUsage

	if resp.IsError {
		return "", nil, providers.ClaudeResultFailure(resp.Type, resp.Subtype, resp.IsError, resp.Error, resp.Result, resp.limit, logredact.Errorf("claude returned error (subtype=%s): %s", resp.Subtype, envelopeMessage(resp.Result)))
	}

	usage := &Usage{Tokens: resp.tokens()}

	return strings.TrimRight(resp.Result, "\n"), usage, nil
}

// streamEvent represents a JSON event from Claude Code CLI stream-json output.
type streamEvent struct {
	Error     json.RawMessage `json:"error"`
	limit     *providers.ClaudeRateLimitInfo
	Type      string         `json:"type"`
	Subtype   string         `json:"subtype"`
	SessionID string         `json:"session_id"`
	Message   *streamMessage `json:"message"`
	Result    string         `json:"result"`
	IsError   bool           `json:"is_error"`
	// ParentToolUseID is set on a subagent's events.
	ParentToolUseID string `json:"parent_tool_use_id"`
	// resultUsage is filled on a "result" event only.
	resultUsage
}

type streamMessage struct {
	ID      string          `json:"id"`
	Model   string          `json:"model"`
	Content []streamContent `json:"content"`
}

// streamContent is one content block: text, a tool_use (ID, Name, Input) on
// an assistant event, a tool_result (ToolUseID, Content, IsError) on a user
// event.
type streamContent struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
}

// claudeInternalTools are Claude Code's own plumbing tools (ToolSearch loads
// deferred MCP tool schemas). They are not steps the owner asked for, so they
// never surface as tool steps. They stay allowed: hiding ToolSearch would
// leave the deferred watchtower tools unloadable.
var claudeInternalTools = map[string]bool{"ToolSearch": true}

// IsClaudeInternalTool reports whether a raw Claude tool name is one of
// Claude Code's plumbing tools, never shown as a step.
func IsClaudeInternalTool(name string) bool { return claudeInternalTools[name] }

// ToolResultText flattens a tool_result's content: a string, or the text
// parts of a content array; "" for any other shape.
func ToolResultText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &parts); err != nil {
		return ""
	}
	var b strings.Builder
	for _, p := range parts {
		if p.Type == "text" {
			b.WriteString(p.Text)
		}
	}
	return b.String()
}

// chatEventState maps one run's stream-json events onto the chat-event
// chunks (EmitToolEvents). It is not chat.ClaudeTranslator (the warm
// session's, which reads partial-message deltas and cannot be imported
// here): this one reads whole messages, so the two must hide the same tools
// (IsClaudeInternalTool) and separate messages alike. A subagent's events
// are dropped, as the translator drops them.
type chatEventState struct {
	model  string
	names  map[string]string // tool_use id → raw name, until its result
	order  []string          // tool_use ids in names, in call order
	hidden map[string]bool   // tool_use ids of Claude-internal tools
	// textMessage is the id of the message that last emitted text and
	// afterTool records a tool call since then: a later message's text, or
	// any text after a tool call, starts after a blank line, as the
	// translator separates messages.
	textMessage          string
	wroteText, afterTool bool
}

func newChatEventState() *chatEventState {
	return &chatEventState{names: map[string]string{}, hidden: map[string]bool{}}
}

func (s *chatEventState) chunks(e *streamEvent) []StreamChunk {
	if e.ParentToolUseID != "" {
		return nil
	}
	switch e.Type {
	case "assistant":
		if e.Message == nil {
			return nil
		}
		if e.Message.Model != "" {
			s.model = e.Message.Model
		}
		var out []StreamChunk
		for _, b := range e.Message.Content {
			switch b.Type {
			case "text":
				if b.Text == "" {
					continue
				}
				text := b.Text
				if s.wroteText && (s.afterTool || e.Message.ID != s.textMessage) {
					text = "\n\n" + text
				}
				s.wroteText, s.afterTool, s.textMessage = true, false, e.Message.ID
				out = append(out, StreamChunk{Text: text})
			case "tool_use":
				s.afterTool = true
				if IsClaudeInternalTool(b.Name) {
					s.hidden[b.ID] = true
					continue
				}
				s.names[b.ID] = b.Name
				s.order = append(s.order, b.ID)
				args := b.Input
				if len(args) == 0 {
					args = json.RawMessage("{}")
				}
				out = append(out, StreamChunk{Tool: &ToolEvent{ID: b.ID, Name: b.Name, Args: args}})
			}
		}
		return out
	case "user":
		if e.Message == nil {
			return nil
		}
		var out []StreamChunk
		for _, b := range e.Message.Content {
			if b.Type != "tool_result" {
				continue
			}
			if s.hidden[b.ToolUseID] {
				delete(s.hidden, b.ToolUseID)
				continue
			}
			name := s.names[b.ToolUseID]
			delete(s.names, b.ToolUseID)
			out = append(out, StreamChunk{Tool: &ToolEvent{ID: b.ToolUseID, Name: name, Done: true,
				OK: !b.IsError, Result: ToolResultText(b.Content)}})
		}
		return out
	case "result":
		return []StreamChunk{{Usage: &TurnUsage{Model: s.model, Tokens: e.tokens()}}}
	}
	return nil
}

// closeOpen ends every tool still waiting for its result as failed with
// reason, in call order.
func (s *chatEventState) closeOpen(reason string) []StreamChunk {
	var out []StreamChunk
	for _, id := range s.order {
		if name, open := s.names[id]; open {
			delete(s.names, id)
			out = append(out, StreamChunk{Tool: &ToolEvent{ID: id, Name: name, Done: true, Result: reason}})
		}
	}
	s.order = nil
	return out
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
	if errors.Is(err, exec.ErrNotFound) {
		return withCause(fmt.Errorf("claude CLI not found — install Claude Code first: https://docs.anthropic.com/en/docs/claude-code"), err)
	}

	// Check exit error for details
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code := exitErr.ExitCode()
		stderrMsg := strings.TrimSpace(stderr)
		if stderrMsg == "" {
			stderrMsg = strings.TrimSpace(string(exitErr.Stderr))
		}

		if stderrMsg != "" {
			return withCause(logredact.Errorf("claude CLI failed (exit %d): %s", code, logredact.Text(stderrMsg)), exitErr)
		}
		return withCause(fmt.Errorf("claude CLI failed with exit code %d", code), exitErr)
	}

	return fmt.Errorf("claude CLI error: %w", err)
}

// withCause preserves CLI exit errors behind an owner-readable diagnostic.
func withCause(message, cause error) error {
	if cause == nil {
		return message
	}
	return cliCause{message, cause}
}

type cliCause struct{ message, cause error }

func (e cliCause) Error() string   { return e.message.Error() }
func (e cliCause) Unwrap() []error { return []error{e.message, e.cause} }

// InvocationProfile keeps readonly review separate from tool-bearing clients.
func (c *Client) InvocationProfile() providers.InvocationProfile {
	if c.dbPath == "" && c.readFolder != "" {
		return providers.ReviewReadonly
	}
	return providers.ToolPreflight
}
