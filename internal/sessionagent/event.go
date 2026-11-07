package sessionagent

import (
	"bytes"
	"encoding/json"
	"io"
)

// Event is a workbench hook's input, Claude Code's or Codex's, in one shape
// (spec 2026-10-12-codex-workbench-agent §6.2), or a pull event an adapter's
// Watch read from a transcript (spec 2026-11-05 §3.5). Every hook reads the
// fields it needs and ignores the rest. Codex leaves BackgroundTasks absent
// and NotificationType and Error empty: it has no such fields (no
// Notification or StopFailure event).
type Event struct {
	Event     string `json:"hook_event_name"`
	SessionID string `json:"session_id"`
	// Source is a SessionStart's: startup, resume, clear, compact, fork.
	Source string `json:"source"`
	// TurnID is Codex's turn id; Claude Code sends none.
	TurnID   string `json:"turn_id"`
	ToolName string `json:"tool_name"`
	// ToolInput is the tool call's input; the PermissionRequest hook
	// summarises it (permissionSummary).
	ToolInput json.RawMessage `json:"tool_input"`
	// ToolUseID with TranscriptPath places a PostToolUse against the last
	// Stop (board #368).
	ToolUseID string `json:"tool_use_id"`
	// AgentID is set when the hook fired inside a subagent or teammate;
	// AgentType is its type (a teammate's name), empty for Claude Code's
	// internal agents (boards #411, #543).
	AgentID              string `json:"agent_id"`
	AgentType            string `json:"agent_type"`
	LastAssistantMessage string `json:"last_assistant_message"`
	// TranscriptPath is the session's transcript. Empty for a Codex
	// SubagentStart, whose transcript_path is the child's rollout.
	TranscriptPath string `json:"transcript_path"`
	StopHookActive bool   `json:"stop_hook_active"`
	// IsInterrupt is a PostToolUseFailure's: the owner interrupted the tool
	// (Esc), so the failure says nothing about the agent working on.
	IsInterrupt bool `json:"is_interrupt"`
	// BackgroundTasks is a Claude Code Stop's or SubagentStop's snapshot of
	// in-flight background tasks (board #411).
	BackgroundTasks  BackgroundTasks `json:"background_tasks"`
	NotificationType string          `json:"notification_type"`
	// Error is a StopFailure's error type ("rate_limit", pinned by
	// cmd/testdata/stopfailure_rate_limit.json). Raw, so a non-string value
	// never fails the whole input.
	Error json.RawMessage `json:"error"`
	// Cwd is the session's working directory, a common hook input field of
	// both agents (board #566); the state hook decides whether it is recorded.
	Cwd string `json:"cwd"`
}

// AgentTurnEvent says the event starts or ends a subagent's or teammate's
// turn (board #543).
func (ev Event) AgentTurnEvent() bool {
	return ev.Event == "SubagentStart" || ev.Event == "SubagentStop"
}

// RecordsAgentTurn says a SubagentStart or SubagentStop names an agent the
// turns track: one with an agent_id and a type. Claude Code's internal agents
// (prompt suggestions, /btw) have no type and say nothing about the work.
func (ev Event) RecordsAgentTurn() bool {
	return ev.AgentID != "" && ev.AgentType != ""
}

// ToolEvent says the event is one of a tool call's: PreToolUse, PostToolUse
// or PostToolUseFailure.
func (ev Event) ToolEvent() bool {
	return ev.Event == "PreToolUse" || ev.Event == "PostToolUse" || ev.Event == "PostToolUseFailure"
}

// SubagentToolStart says the event is a PreToolUse fired inside a subagent
// or teammate: it records nothing (board #988 adds the tool start for the
// main thread only).
func (ev Event) SubagentToolStart() bool {
	return ev.Event == "PreToolUse" && ev.AgentID != ""
}

// InterruptedTool says the event is a PostToolUseFailure of a tool the owner
// interrupted (Esc). No Stop follows an interrupt, so a main-thread one
// records the turn's end itself — `waiting`, over `working` or `approval`,
// under a tool result's turn order (board #988) — and a subagent's records
// nothing.
func (ev Event) InterruptedTool() bool {
	return ev.Event == "PostToolUseFailure" && ev.IsInterrupt
}

// FailureText is a StopFailure's error type, or "" when the field is missing
// or not a string; ok is false for every other event.
func (ev Event) FailureText() (text string, ok bool) {
	if ev.Event != "StopFailure" {
		return "", false
	}
	if json.Unmarshal(ev.Error, &text) != nil {
		text = ""
	}
	return text, true
}

// BackgroundTask is one entry of a hook input's background_tasks; every
// other field is ignored.
type BackgroundTask struct{ ID, Type string }

// BackgroundTasks is a hook input's background_tasks, decoded tolerantly so
// a malformed field never fails the whole input: absent, null or not an
// array leaves Present false (an older Claude Code, or a shape we do not
// know); an array sets it, and an entry that is no object, or whose id or
// type is no string, is kept with those fields empty.
type BackgroundTasks struct {
	Present bool
	List    []BackgroundTask
}

// UnmarshalJSON decodes background_tasks tolerantly (see BackgroundTasks).
func (b *BackgroundTasks) UnmarshalJSON(data []byte) error {
	var raw []json.RawMessage
	if json.Unmarshal(data, &raw) != nil || raw == nil {
		*b = BackgroundTasks{}
		return nil //nolint:nilerr // not an array reads as absent, never a failed input
	}
	list := make([]BackgroundTask, len(raw))
	for i, entry := range raw {
		var fields map[string]json.RawMessage
		if json.Unmarshal(entry, &fields) != nil {
			continue
		}
		_ = json.Unmarshal(fields["id"], &list[i].ID)
		_ = json.Unmarshal(fields["type"], &list[i].Type)
	}
	*b = BackgroundTasks{Present: true, List: list}
	return nil
}

// decodeEvent decodes one hook input. Empty input (a manual run with stdin
// closed) is io.EOF, a clean exit; input that is no JSON object is an
// error. An unknown event decodes: each hook ignores events it does not
// handle.
func decodeEvent(raw []byte) (Event, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return Event{}, io.EOF
	}
	var ev Event
	if err := json.Unmarshal(raw, &ev); err != nil {
		return Event{}, err
	}
	return ev, nil
}
