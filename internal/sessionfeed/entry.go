// Package sessionfeed turns a Claude Code transcript into the chat of a
// workbench session: owner messages, agent text, ask answers, subagents.
// Read-only on transcripts, no AI, no transcript text stored anywhere.
package sessionfeed

import "time"

// Kind is the agent-neutral entry kind.
type Kind string

const (
	KindOwner      Kind = "owner"
	KindAgent      Kind = "agent"
	KindAskAnswer  Kind = "ask_answer"
	KindWatchtower Kind = "watchtower"
	KindBrief      Kind = "brief"
	KindSubagent   Kind = "subagent"
	KindSeparator  Kind = "separator"
)

// Via values for KindWatchtower entries.
const (
	ViaReview  = "review"
	ViaHandoff = "handoff"
)

// SubagentRef is the subagent marker payload (filled by the subagent reader).
type SubagentRef struct {
	ToolUseID    string `json:"tool_use_id"`
	AgentID      string `json:"agent_id"`
	Type         string `json:"type"`
	Description  string `json:"description"`
	Status       string `json:"status"`
	ParentReport string `json:"-"`
}

// Entry is one chat line. An entry can be re-emitted with the same ID and
// new content (streamed message grows); callers upsert by ID.
type Entry struct {
	ID           string       `json:"id"`
	Kind         Kind         `json:"kind"`
	At           time.Time    `json:"at"`
	Text         string       `json:"text,omitempty"`
	AskID        int64        `json:"ask_id,omitempty"`
	Title        string       `json:"title,omitempty"`
	Via          string       `json:"via,omitempty"`
	Subagent     *SubagentRef `json:"subagent,omitempty"`
	Conversation string       `json:"conversation,omitempty"`
}

// Result is what Parse returns. Offset is the byte offset after the last
// complete line read.
type Result struct {
	Entries []Entry
	Offset  int64
	Skipped int
	Unknown map[string]int
}
