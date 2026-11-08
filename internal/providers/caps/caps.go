// Package caps is the transport capability table (spec 2026-11-05 §3.3):
// what each AI provider's transport offers. It is a leaf so that config,
// which providers imports, can read the fallback pair rule too. Consumers
// read a row, never a provider name (LLMTRANSPORT-01); providers re-exports
// it as providers.Capabilities and providers.CapsFor, and `ai models --json`
// and the chat's session_ready carry it to the Desktop.
package caps

import (
	"maps"
	"slices"
)

// Values of the string fields.
const (
	ToolsNone = "none"
	// ToolsWithConnections is the watchtower tools plus the owner's Quick
	// Connections.
	ToolsWithConnections = "watchtower+quick_connections"

	ReadFolderNone         = "none"
	ReadFolderTools        = "tools"
	ReadFolderShellSandbox = "shell_sandbox"
)

// Capabilities is one transport's row. JSON keys are the Swift
// ProviderCapabilities' (pinned by the shared ai_models_capabilities.json).
type Capabilities struct {
	// Tools: none | watchtower | watchtower+quick_connections.
	Tools string `json:"tools"`
	// ToolEvents: each tool call is a visible step.
	ToolEvents bool `json:"tool_events"`
	// TextStream: token | message | final.
	TextStream string `json:"text_stream"`
	// Usage: none | totals | split (fresh input, cache, output).
	Usage        string `json:"usage"`
	CostReported bool   `json:"cost_reported"`
	Images       bool   `json:"images"`
	PDFs         bool   `json:"pdfs"`
	WebSearch    bool   `json:"web_search"`
	// ReadFolder: none | tools | shell_sandbox.
	ReadFolder string `json:"read_folder"`
	// TurnCap: native | counted | none (unit: model turns).
	TurnCap string `json:"turn_cap"`
	// Interrupt: in_turn | kill_turn.
	Interrupt     string `json:"interrupt"`
	WarmSession   bool   `json:"warm_session"`
	ClaudeAITools bool   `json:"claude_ai_tools"`
	// ReservePeer is the provider a fallback pairs this one with; "" =
	// none, so this provider is never in a fallback pair (ask #937's rule).
	ReservePeer string `json:"reserve_peer"`
	// Quota: the provider reports a subscription quota with its reset.
	Quota bool `json:"quota"`
}

// table is every provider's row, by provider id.
var table = map[string]Capabilities{
	"claude": {Tools: ToolsWithConnections, ToolEvents: true, TextStream: "token", Usage: "split",
		CostReported: true, Images: true, PDFs: true, WebSearch: true, ReadFolder: ReadFolderTools,
		TurnCap: "native", Interrupt: "in_turn", WarmSession: true, ClaudeAITools: true,
		ReservePeer: "codex", Quota: true},
	// WebSearch: the chat session's codex runs search the cached index
	// (codex.Client.SetWebSearch, ask #533); every other codex run has it off.
	"codex": {Tools: ToolsWithConnections, ToolEvents: true, TextStream: "message", Usage: "split",
		Images: true, WebSearch: true, ReadFolder: ReadFolderShellSandbox, TurnCap: "counted", Interrupt: "kill_turn",
		ReservePeer: "claude", Quota: true},
	// The chat and `ai query --tools chat` run runtime B (agentloop) with
	// the watchtower tools and the Quick Connections.
	"ollama": {Tools: ToolsWithConnections, ToolEvents: true, TextStream: "token", Usage: "totals",
		ReadFolder: ReadFolderNone, TurnCap: "native", Interrupt: "kill_turn"},
}

// For is id's row; false for an unknown id.
func For(id string) (Capabilities, bool) {
	c, ok := table[id]
	return c, ok
}

// IDs is every provider id with a row, sorted: the completeness guard
// checks it against the provider registry in both directions.
func IDs() []string { return slices.Sorted(maps.Keys(table)) }

// HasTools reports whether the transport runs the watchtower tools.
func (c Capabilities) HasTools() bool { return c.Tools != "" && c.Tools != ToolsNone }

// ReadsFolder reports whether the transport can read a folder's files.
func (c Capabilities) ReadsFolder() bool { return c.ReadFolder != "" && c.ReadFolder != ReadFolderNone }

// Pairs reports whether preferred and reserve form a fallback pair: each
// is the other's reserve peer.
func Pairs(preferred, reserve string) bool {
	p, ok := For(preferred)
	r, rok := For(reserve)
	return ok && rok && reserve != "" && p.ReservePeer == reserve && r.ReservePeer == preferred
}
