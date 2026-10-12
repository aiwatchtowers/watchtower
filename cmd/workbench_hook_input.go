package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"

	"watchtower/internal/agentkind"
)

// hookEvent is a workbench hook's input, Claude Code's or Codex's, in one
// shape (spec 2026-10-12-codex-workbench-agent §6.2). Every hook reads the
// fields it needs and ignores the rest. Codex leaves BackgroundTasks absent
// and NotificationType and Error empty: it has no such fields (no
// Notification or StopFailure event).
type hookEvent struct {
	Event     string `json:"hook_event_name"`
	SessionID string `json:"session_id"`
	// Source is a SessionStart's: startup, resume, clear, compact, fork.
	Source string `json:"source"`
	// TurnID is Codex's turn id; Claude Code sends none.
	TurnID   string `json:"turn_id"`
	ToolName string `json:"tool_name"`
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
	// BackgroundTasks is a Claude Code Stop's or SubagentStop's snapshot of
	// in-flight background tasks (board #411).
	BackgroundTasks  backgroundTasks `json:"background_tasks"`
	NotificationType string          `json:"notification_type"`
	// Error is a StopFailure's error type ("rate_limit", pinned by
	// testdata/stopfailure_rate_limit.json). Raw, so a non-string value
	// never fails the whole input.
	Error json.RawMessage `json:"error"`
}

// stopHookInput is the Stop hook's input: the shared hook event.
type stopHookInput = hookEvent

// parseHookEvent decodes one hook input of agent. Empty input (a manual run
// with stdin closed) is io.EOF, a clean exit; input that is no JSON object
// is an error. An unknown event decodes: each hook ignores events it does
// not handle.
func parseHookEvent(agent agentkind.Kind, raw []byte) (hookEvent, error) {
	if _, ok := agentkind.Parse(string(agent)); !ok {
		return hookEvent{}, fmt.Errorf("unknown agent %q", briefClip(string(agent), 40))
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return hookEvent{}, io.EOF
	}
	var ev hookEvent
	if err := json.Unmarshal(raw, &ev); err != nil {
		return hookEvent{}, err
	}
	if agent == agentkind.Codex {
		normalizeCodexEvent(&ev)
	}
	return ev, nil
}

// normalizeCodexEvent drops what a Codex payload cannot mean the Claude Code
// way: the Claude-only fields, and a SubagentStart's transcript_path, which
// names the child's rollout, not the session's (capture note, answer 1).
func normalizeCodexEvent(ev *hookEvent) {
	ev.BackgroundTasks = backgroundTasks{}
	ev.NotificationType = ""
	ev.Error = nil
	if ev.Event == "SubagentStart" {
		ev.TranscriptPath = ""
	}
}

// readHookEvent reads one hook input of agent from stdin, at most limit
// bytes and until ctx ends (readHookInputLimit), and decodes it.
func readHookEvent(ctx context.Context, stdin io.Reader, limit int64, agent agentkind.Kind) (hookEvent, error) {
	raw, err := readHookInputLimit[json.RawMessage](ctx, stdin, limit)
	if err != nil {
		return hookEvent{}, err
	}
	return parseHookEvent(agent, raw)
}
