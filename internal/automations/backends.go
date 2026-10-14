package automations

import (
	"context"
	"encoding/json"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/tools"
)

// ToolRegistry is the part of the tool registry the SDK calls (P1 reads
// only Get and CallRead; P2 proposes). *tools.Registry satisfies it.
type ToolRegistry interface {
	Get(name string) (*tools.Tool, bool)
	CallRead(ctx context.Context, name string, args json.RawMessage, b tools.Binding) (any, error)
	Propose(ctx context.Context, name string, args json.RawMessage, b tools.Binding) (tools.Receipt, error)
}

var _ ToolRegistry = (*tools.Registry)(nil)

// Backends is what the SDK modules call. DB is used for read-only lookups
// only (AllowTool's account labels) and may be nil. Shell and Workbench stay
// nil until P5 wires them; a module that needs a nil backend throws
// NotAvailable. Later phases append fields here, never rename one.
type Backends struct {
	DB        *db.DB
	Generator digest.Generator
	Registry  ToolRegistry
	Clock     Clock
	Shell     ShellRunner
	Workbench WorkbenchResolver
}

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
