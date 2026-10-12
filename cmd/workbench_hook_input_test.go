package cmd

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
)

// The private input structs the Claude hooks decoded before hookEvent,
// copied verbatim (tags and types): every Claude fixture must decode to the
// same values through parseHookEvent.
type (
	legacySessionStateInput struct {
		HookEventName    string          `json:"hook_event_name"`
		SessionID        string          `json:"session_id"`
		NotificationType string          `json:"notification_type"`
		AgentID          string          `json:"agent_id"`
		AgentType        string          `json:"agent_type"`
		BackgroundTasks  backgroundTasks `json:"background_tasks"`
		TranscriptPath   string          `json:"transcript_path"`
		ToolUseID        string          `json:"tool_use_id"`
		Error            json.RawMessage `json:"error"`
	}
	legacyStopHookInput struct {
		SessionID       string          `json:"session_id"`
		TranscriptPath  string          `json:"transcript_path"`
		StopHookActive  bool            `json:"stop_hook_active"`
		BackgroundTasks backgroundTasks `json:"background_tasks"`
	}
	legacySessionStartInput struct {
		SessionID string `json:"session_id"`
		Source    string `json:"source"`
	}
	legacyAskGuardInput struct {
		SessionID string `json:"session_id"`
		ToolName  string `json:"tool_name"`
	}
	legacyAskGuardStopInput struct {
		SessionID            string `json:"session_id"`
		StopHookActive       bool   `json:"stop_hook_active"`
		LastAssistantMessage string `json:"last_assistant_message"`
	}
)

// claudeHookInputs is every captured Claude Code fixture plus the inline
// payload shapes the hook tests build.
func claudeHookInputs(t *testing.T) map[string][]byte {
	t.Helper()
	files, err := filepath.Glob(filepath.Join("testdata", "*.json"))
	require.NoError(t, err)
	inputs := map[string][]byte{}
	for _, f := range files {
		if strings.HasPrefix(filepath.Base(f), "session_report") {
			continue // not a hook input
		}
		raw, err := os.ReadFile(f)
		require.NoError(t, err)
		inputs[f] = raw
	}
	require.GreaterOrEqual(t, len(inputs), 9, "the captured Claude Code hook fixtures")
	inputs["notification"] = []byte(statePayload("Notification", briefLaunchID, "permission_prompt"))
	inputs["session start"] = []byte(hookPayload("clear", briefClearedID))
	inputs["pre tool use"] = []byte(`{"session_id":"` + briefLaunchID + `","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}`)
	inputs["stop with message"] = []byte(`{"session_id":"` + briefLaunchID + `","hook_event_name":"Stop",` +
		`"stop_hook_active":true,"last_assistant_message":"Shall I merge?"}`)
	inputs["tool result"] = []byte(toolResultPayload("toolu_01", "/tmp/x.jsonl"))
	return inputs
}

func TestParseHookEvent_ClaudeFixturesUnchanged(t *testing.T) {
	for name, raw := range claudeHookInputs(t) {
		t.Run(name, func(t *testing.T) {
			ev, err := parseHookEvent(agentkind.Claude, raw)
			require.NoError(t, err)
			require.NotEmpty(t, ev.SessionID, "every fixture names its session")
			assertSameAsSessionState(t, raw, ev)
			assertSameAsStopHook(t, raw, ev)
			assertSameAsSmallInputs(t, raw, ev)
		})
	}
}

func assertSameAsSessionState(t *testing.T, raw []byte, ev hookEvent) {
	t.Helper()
	var old legacySessionStateInput
	require.NoError(t, json.Unmarshal(raw, &old))
	assert.Equal(t, old.HookEventName, ev.Event)
	assert.Equal(t, old.SessionID, ev.SessionID)
	assert.Equal(t, old.NotificationType, ev.NotificationType)
	assert.Equal(t, old.AgentID, ev.AgentID)
	assert.Equal(t, old.AgentType, ev.AgentType)
	assert.Equal(t, old.BackgroundTasks, ev.BackgroundTasks)
	assert.Equal(t, old.TranscriptPath, ev.TranscriptPath)
	assert.Equal(t, old.ToolUseID, ev.ToolUseID)
	assert.Equal(t, string(old.Error), string(ev.Error))
}

func assertSameAsStopHook(t *testing.T, raw []byte, ev hookEvent) {
	t.Helper()
	var old legacyStopHookInput
	require.NoError(t, json.Unmarshal(raw, &old))
	assert.Equal(t, old.SessionID, ev.SessionID)
	assert.Equal(t, old.TranscriptPath, ev.TranscriptPath)
	assert.Equal(t, old.StopHookActive, ev.StopHookActive)
	assert.Equal(t, old.BackgroundTasks, ev.BackgroundTasks)
}

func assertSameAsSmallInputs(t *testing.T, raw []byte, ev hookEvent) {
	t.Helper()
	var start legacySessionStartInput
	require.NoError(t, json.Unmarshal(raw, &start))
	assert.Equal(t, start.Source, ev.Source)
	var pre legacyAskGuardInput
	require.NoError(t, json.Unmarshal(raw, &pre))
	assert.Equal(t, pre.ToolName, ev.ToolName)
	var stop legacyAskGuardStopInput
	require.NoError(t, json.Unmarshal(raw, &stop))
	assert.Equal(t, stop.StopHookActive, ev.StopHookActive)
	assert.Equal(t, stop.LastAssistantMessage, ev.LastAssistantMessage)
}

// Spot checks with literal values, so the comparison above cannot pass on
// two equally wrong decodes.
func TestParseHookEvent_ClaudeFixtureValues(t *testing.T) {
	inputs := claudeHookInputs(t)

	stop, err := parseHookEvent(agentkind.Claude, inputs[filepath.Join("testdata", "stop_background_tasks.json")])
	require.NoError(t, err)
	assert.Equal(t, "Stop", stop.Event)
	assert.True(t, stop.BackgroundTasks.present)
	n, ok := backgroundAgents(stop.BackgroundTasks, nil, "")
	assert.True(t, ok)
	assert.Equal(t, int64(2), n)

	failure, err := parseHookEvent(agentkind.Claude, inputs[filepath.Join("testdata", "stopfailure_rate_limit.json")])
	require.NoError(t, err)
	assert.Equal(t, "StopFailure", failure.Event)
	require.NotNil(t, failure.agentFailure())
	assert.Equal(t, "rate_limit", failure.agentFailure().Error)

	note, err := parseHookEvent(agentkind.Claude, inputs["notification"])
	require.NoError(t, err)
	assert.Equal(t, "permission_prompt", note.NotificationType)
	assert.Equal(t, "/tmp/x.jsonl", note.TranscriptPath)

	start, err := parseHookEvent(agentkind.Claude, inputs["session start"])
	require.NoError(t, err)
	assert.Equal(t, hookEvent{Event: "SessionStart", SessionID: briefClearedID, Source: "clear", TranscriptPath: "/tmp/x.jsonl"}, start)
}

const (
	codexTUISession   = "01a10000-0000-7000-8000-000000000001"
	codexExecSession  = "01a10000-0000-7000-8000-000000000006"
	codexTUIRollout   = "/Users/example/.codex/sessions/2026/10/12/rollout-2026-10-12T15-00-11-01a10000-0000-7000-8000-000000000001.jsonl"
	codexExecRollout  = "/Users/example/.codex/sessions/2026/10/12/rollout-2026-10-12T14-52-51-01a10000-0000-7000-8000-000000000006.jsonl"
	codexSubagentID   = "01a10000-0000-7000-8000-000000000010"
	codexBashToolCall = "exec-00000000-0000-4000-8000-000000000004"
)

func codexHookFixture(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "codex_hooks", name+".json"))
	require.NoError(t, err)
	return raw
}

// codexFixtureWants is every Task 0 fixture's normalized event.
var codexFixtureWants = map[string]hookEvent{
	"session_start_startup": {Event: "SessionStart", SessionID: codexTUISession, Source: "startup", TranscriptPath: codexTUIRollout},
	"session_start_resume":  {Event: "SessionStart", SessionID: codexTUISession, Source: "resume", TranscriptPath: codexTUIRollout},
	"session_start_compact": {Event: "SessionStart", SessionID: codexTUISession, Source: "compact", TranscriptPath: codexTUIRollout},
	"session_start_clear": {Event: "SessionStart", SessionID: "01a10000-0000-7000-8000-000000000002", Source: "clear",
		TranscriptPath: "/Users/example/.codex/sessions/2026/10/12/rollout-2026-10-12T14-59-31-01a10000-0000-7000-8000-000000000002.jsonl"},
	"user_prompt_submit": {Event: "UserPromptSubmit", SessionID: codexTUISession,
		TurnID: "01a10000-0000-7000-8000-000000000003", TranscriptPath: codexTUIRollout},
	"pre_tool_use_bash": {Event: "PreToolUse", SessionID: codexTUISession, TurnID: "01a10000-0000-7000-8000-000000000003",
		ToolName: "Bash", ToolUseID: codexBashToolCall, TranscriptPath: codexTUIRollout},
	"permission_request": {Event: "PermissionRequest", SessionID: codexTUISession,
		TurnID: "01a10000-0000-7000-8000-000000000003", ToolName: "Bash", TranscriptPath: codexTUIRollout},
	"post_tool_use": {Event: "PostToolUse", SessionID: codexTUISession, TurnID: "01a10000-0000-7000-8000-000000000003",
		ToolName: "Bash", ToolUseID: codexBashToolCall, TranscriptPath: codexTUIRollout},
	"pre_tool_use_request_user_input": {Event: "PreToolUse", SessionID: codexTUISession,
		TurnID: "01a10000-0000-7000-8000-000000000005", ToolName: "request_user_input",
		ToolUseID: "call_00000000000000000000000000000001", TranscriptPath: codexTUIRollout},
	"pre_tool_use_mcp": {Event: "PreToolUse", SessionID: codexExecSession, TurnID: "01a10000-0000-7000-8000-000000000007",
		ToolName: "mcp__watchtower_workbench__ping", ToolUseID: "exec-00000000-0000-4000-8000-000000000008",
		TranscriptPath: codexExecRollout},
	"stop": {Event: "Stop", SessionID: codexTUISession, TurnID: "01a10000-0000-7000-8000-000000000003",
		LastAssistantMessage: "example", TranscriptPath: codexTUIRollout},
	"stop_hook_active": {Event: "Stop", SessionID: codexExecSession, TurnID: "01a10000-0000-7000-8000-000000000007",
		LastAssistantMessage: "example", TranscriptPath: codexExecRollout, StopHookActive: true},
	// The child's rollout is not the session's transcript.
	"subagent_start": {Event: "SubagentStart", SessionID: codexExecSession, TurnID: "01a10000-0000-7000-8000-000000000009",
		AgentID: codexSubagentID, AgentType: "default"},
	"subagent_stop": {Event: "SubagentStop", SessionID: codexExecSession, TurnID: "01a10000-0000-7000-8000-000000000009",
		AgentID: codexSubagentID, AgentType: "default", LastAssistantMessage: "example", TranscriptPath: codexExecRollout},
	"session_end": {Event: "SessionEnd", SessionID: codexExecSession, TranscriptPath: codexExecRollout},
}

func TestParseHookEvent_CodexFixtures(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("testdata", "codex_hooks", "*.json"))
	require.NoError(t, err)
	require.Len(t, files, len(codexFixtureWants), "every Task 0 fixture has a want")
	for name, want := range codexFixtureWants {
		t.Run(name, func(t *testing.T) {
			ev, err := parseHookEvent(agentkind.Codex, codexHookFixture(t, name))
			require.NoError(t, err)
			assert.Equal(t, want, ev)
			assert.False(t, ev.BackgroundTasks.present, "codex has no background_tasks")
		})
	}
}

// A Codex payload that carried Claude-only fields still leaves them empty.
func TestParseHookEvent_CodexDropsClaudeOnlyFields(t *testing.T) {
	raw := strings.Replace(string(codexHookFixture(t, "stop")), `"stop_hook_active": false,`,
		`"stop_hook_active": false, "background_tasks": [{"id":"a1","type":"subagent"}],`+
			` "notification_type": "permission_prompt", "error": "rate_limit",`, 1)
	require.Contains(t, raw, "background_tasks")

	ev, err := parseHookEvent(agentkind.Codex, []byte(raw))

	require.NoError(t, err)
	assert.Equal(t, codexFixtureWants["stop"], ev)
	_, ok := backgroundAgents(ev.BackgroundTasks, nil, "")
	assert.False(t, ok, "no count from a codex payload")

	claude, err := parseHookEvent(agentkind.Claude, []byte(raw))
	require.NoError(t, err)
	assert.True(t, claude.BackgroundTasks.present, "the same bytes as Claude Code's keep it")
	assert.Equal(t, "permission_prompt", claude.NotificationType)
}

func TestParseHookEvent_EmptyStdinIsCleanExit(t *testing.T) {
	for _, agent := range []agentkind.Kind{agentkind.Claude, agentkind.Codex} {
		for _, raw := range []string{"", " \n\t"} {
			ev, err := parseHookEvent(agent, []byte(raw))
			assert.ErrorIs(t, err, io.EOF, "%s %q", agent, raw)
			assert.Equal(t, hookEvent{}, ev)
		}
		ev, err := readHookEvent(context.Background(), strings.NewReader(""), hookStdinLimit, agent)
		assert.ErrorIs(t, err, io.EOF, "a closed stdin reads as a manual run")
		assert.Equal(t, hookEvent{}, ev)
	}
}

func TestParseHookEvent_NonJSONIsNoop(t *testing.T) {
	for _, raw := range []string{"not json", `{"session_id":`, `[1,2]`, `"Stop"`, `{"session_id":5}`} {
		for _, agent := range []agentkind.Kind{agentkind.Claude, agentkind.Codex} {
			ev, err := parseHookEvent(agent, []byte(raw))
			require.Error(t, err, "%s %q", agent, raw)
			assert.NotErrorIs(t, err, io.EOF, "a broken input is reported, not read as a manual run")
			assert.Equal(t, hookEvent{}, ev)
		}
	}
}

func TestParseHookEvent_UnknownEventIsNoop(t *testing.T) {
	raw := strings.Replace(string(codexHookFixture(t, "session_end")), `"SessionEnd"`, `"PreCompact"`, 1)

	ev, err := parseHookEvent(agentkind.Codex, []byte(raw))

	require.NoError(t, err, "an unknown event decodes")
	assert.Equal(t, "PreCompact", ev.Event)
	assert.Equal(t, codexExecSession, ev.SessionID)
	_, _, ok := agentStateFor(ev.Event, ev.NotificationType)
	assert.False(t, ok, "and maps to no state")

	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	before := rowSnapshot(t, database, row)
	out, errOut, err := runSessionState(t, pid, strings.NewReader(statePayload("PreCompact", briefLaunchID, "")))
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
	assert.Equal(t, before, rowSnapshot(t, database, row), "the Claude state hook writes nothing for it")
}

func TestParseHookEvent_MissingSessionIDIsNoWrite(t *testing.T) {
	var fields map[string]any
	require.NoError(t, json.Unmarshal(codexHookFixture(t, "user_prompt_submit"), &fields))
	delete(fields, "session_id")
	raw, err := json.Marshal(fields)
	require.NoError(t, err)

	ev, err := parseHookEvent(agentkind.Codex, raw)

	require.NoError(t, err)
	assert.Equal(t, "UserPromptSubmit", ev.Event)
	assert.Empty(t, ev.SessionID)
	assert.Equal(t, "01a10000-0000-7000-8000-000000000003", ev.TurnID)

	// The Claude state hook on its row: no session id, no write; the same
	// prompt with the row's id records working.
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	before := rowSnapshot(t, database, row)
	out, errOut, err := runSessionState(t, pid, strings.NewReader(`{"hook_event_name":"UserPromptSubmit","prompt":"x"}`))
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
	assert.Equal(t, before, rowSnapshot(t, database, row))

	_, _, err = runSessionState(t, pid, strings.NewReader(statePayload("UserPromptSubmit", briefLaunchID, "")))
	require.NoError(t, err)
	assert.Equal(t, agentStateWorking, storedAgentState(t, database, row))
}

func TestParseHookEvent_UnknownAgentIsAnError(t *testing.T) {
	_, err := parseHookEvent("shell", codexHookFixture(t, "stop"))
	assert.ErrorContains(t, err, "unknown agent")
}
