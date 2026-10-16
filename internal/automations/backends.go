package automations

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/tools"
)

// ToolRegistry is the part of the tool registry the SDK calls: Get and
// CallRead for reads, Propose for writes (ToolWriteModule), List for
// agent()'s effective tool set (EffectiveAgentTools).
// *tools.Registry satisfies it.
type ToolRegistry interface {
	Get(name string) (*tools.Tool, bool)
	List(surface string) []*tools.Tool
	CallRead(ctx context.Context, name string, args json.RawMessage, b tools.Binding) (any, error)
	Propose(ctx context.Context, name string, args json.RawMessage, b tools.Binding) (tools.Receipt, error)
}

var _ ToolRegistry = (*tools.Registry)(nil)

// Backends is what the SDK modules call. DB is used for read-only lookups
// only (AllowTool's account labels, a tool write's {wait} reading its
// agent_actions row) and may be nil (a {wait} then throws NotAvailable).
// Workbench is NewWorkbenchResolver's in the daemon and the CLI; Shell stays
// nil until P5 wires it; a module that needs a nil backend throws
// NotAvailable. Later phases append fields here, never rename one.
type Backends struct {
	DB        *db.DB
	Generator digest.Generator
	Registry  ToolRegistry
	Clock     Clock
	Shell     ShellRunner
	Workbench WorkbenchResolver
	MCP       MCPCaller
	Agent     AgentRunner
}

// AgentRequest is one agent() call (P6, spec §6.5) as its runner gets it.
// Tools is the effective set (EffectiveAgentTools); Budget is the carve from
// the run's remainder and Deadline the earlier of the run's and the carve's.
// Binding is the run's, marked AutomationAgent; Manifest is the run's, for
// GateAgentCall. A runner calls BeforeModelCall before each model call (its
// error ends the call with that error) and reports each call's usage to
// AfterModelCall.
type AgentRequest struct {
	Instruction     string
	Tools           []string
	DryRun          bool
	Tier            string
	Budget          Budget
	Deadline        time.Time
	Binding         tools.Binding
	RunID           int64
	Manifest        *Manifest
	BeforeModelCall func() error
	AfterModelCall  func(in, out int)
}

// AgentResult is what an agent() runner returns. The tokens are the call's
// whole usage; the part AfterModelCall did not already report (a CLI child's
// usage, an estimate) is debited once after the call.
type AgentResult struct {
	Text                      string
	InputTokens, OutputTokens int64
	Estimated                 bool
	ReportedCostUSD           *float64
}

// AgentRunner runs agent() calls; Name ("claude", "codex", "runtime-b") is
// the step's name.
type AgentRunner interface {
	Name() string
	Run(ctx context.Context, req AgentRequest) (AgentResult, error)
}

// MCPCaller calls one tool of an enabled Quick Connection (P6). Only a tool
// QC-02's verdict allows is ever called: the connection's last listing shows
// it read-only, or the owner named it and the server does not mark it a
// write.
type MCPCaller interface {
	Call(ctx context.Context, server, tool string, args json.RawMessage) (json.RawMessage, error)
}

// ErrMCPNotAvailable means no enabled Quick Connection has exactly that name, its
// tools were never listed (or the connections could not be read), its
// credentials are unusable, or none of its tools is allowed.
var ErrMCPNotAvailable = errors.New("quick connection not available")

// ErrMCPToolNotAllowed means the connection is available but QC-02 does not allow
// that tool. The server is never started.
var ErrMCPToolNotAllowed = errors.New("quick connection tool not allowed")

// RunEnvMarker is the environment variable every child process an automation
// run starts carries (P5 shell()/session(), P6 agent()), set to the run id.
// It is one of AGENT-07's agent markers: a command an automation runs can no
// more approve, confirm or dry-run an unconfirmed recipe than an AI agent can.
const RunEnvMarker = "WATCHTOWER_AUTOMATION_RUN_ID"

// ShellCommand is one shell() call (P5).
type ShellCommand struct {
	Cmd, Dir string
	Env      []string
	Deadline time.Time
}

// ShellResult is what a shell() call returns (P5).
type ShellResult struct {
	ExitCode                         int
	Stdout, Stderr                   string
	StdoutTruncated, StderrTruncated bool
}

// ShellRunner runs shell() commands (P5).
type ShellRunner interface {
	Run(ctx context.Context, c ShellCommand) (ShellResult, error)
}

// WorkbenchInfo describes the workbench a workbench automation belongs to
// (P5).
type WorkbenchInfo struct {
	ID           int64
	Folder       string
	Protected    bool
	DefaultAgent string // "claude" | "codex"
}

// WorkbenchResolver looks up a workbench (P5).
type WorkbenchResolver interface {
	Workbench(ctx context.Context, id int64) (WorkbenchInfo, error)
}
