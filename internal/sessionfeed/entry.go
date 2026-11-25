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
	KindEvent      Kind = "event"
	KindPeer       Kind = "peer"
)

// Peer directions and kinds (spec 2026-11-18 §6.6).
const (
	PeerIn  = "in"
	PeerOut = "out"

	PeerMessage  = "message"
	PeerFinished = "finished"
	PeerStarted  = "started"
)

// PeerRef is the payload of a KindPeer entry: another agent of the workbench
// speaking to this session (in) or this session speaking to one (out).
// Title and Folder of an outgoing message are filled by the reader that has
// the database (the transcript carries only the receiver's id); Worktree is
// set on a started sub-session once the start_session result names one.
type PeerRef struct {
	Direction string `json:"direction"`
	Kind      string `json:"kind"`
	SessionID int64  `json:"session_id"`
	Title     string `json:"title"`
	Folder    string `json:"folder"`
	Worktree  string `json:"worktree"`
	// Error is why a call of this session was refused ("" when it was not).
	Error string `json:"error"`
}

// EventType values for KindEvent entries: Claude Code notices written as user records.
const (
	EventTask     = "task"
	EventTeammate = "teammate"
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
	// StartedAt is when the call was made, else the meta file's mtime; never in
	// the entry JSON (the CLI prints it on `subagents` list items only).
	StartedAt time.Time `json:"-"`
}

// TaskRef is the structured form of a Claude Code task notification (an
// agent or a background command finished), on an event entry of type task.
// Result is "" when the notification carries only the delivery boilerplate;
// the feed builder then fills it from the matching subagent's report.
type TaskRef struct {
	TaskID     string `json:"task_id"`
	ToolUseID  string `json:"tool_use_id"`
	Status     string `json:"status"`
	Summary    string `json:"summary"`
	Result     string `json:"result"`
	OutputFile string `json:"output_file"`
	Tokens     int    `json:"tokens"`
	ToolUses   int    `json:"tool_uses"`
	DurationMS int    `json:"duration_ms"`
	// Kind is "agent" or "command".
	Kind     string `json:"kind"`
	ExitCode *int   `json:"exit_code,omitempty"`
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
	EventType    string       `json:"event_type,omitempty"`
	Subagent     *SubagentRef `json:"subagent,omitempty"`
	Peer         *PeerRef     `json:"peer,omitempty"`
	Task         *TaskRef     `json:"task,omitempty"`
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
