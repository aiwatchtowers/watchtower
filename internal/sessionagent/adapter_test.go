package sessionagent

import (
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentkind"
	"watchtower/internal/sessionfeed"
)

//go:embed agent_capabilities.json
var capabilitiesJSON []byte

// snapshot is an Event as the golden records it.
func snapshot(ev Event) map[string]any {
	list := []map[string]string{}
	for _, b := range ev.BackgroundTasks.List {
		list = append(list, map[string]string{"id": b.ID, "type": b.Type})
	}
	return map[string]any{
		"event": ev.Event, "session_id": ev.SessionID, "source": ev.Source, "turn_id": ev.TurnID,
		"tool_name": ev.ToolName, "tool_input": string(ev.ToolInput), "tool_use_id": ev.ToolUseID,
		"agent_id": ev.AgentID, "agent_type": ev.AgentType, "last_assistant_message": ev.LastAssistantMessage,
		"transcript_path": ev.TranscriptPath, "stop_hook_active": ev.StopHookActive,
		"background_present": ev.BackgroundTasks.Present, "background": list,
		"notification_type": ev.NotificationType, "error": string(ev.Error), "cwd": ev.Cwd,
	}
}

// TestSessionAgent_ClaudeAndCodexNormalizeRecordedPayloads: every recorded
// hook payload (cmd/testdata/codex_hooks/*.json through the codex adapter,
// cmd/testdata/*.json through the claude adapter) gives the Event cmd's
// parseHookEvent gave before the move (testdata/normalized.golden.json,
// written from that code).
func TestSessionAgent_ClaudeAndCodexNormalizeRecordedPayloads(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "normalized.golden.json"))
	require.NoError(t, err)
	var want map[string]any
	require.NoError(t, json.Unmarshal(raw, &want))

	got := map[string]any{}
	add := func(k Kind, glob string) {
		a, ok := For(k)
		require.True(t, ok)
		files, err := filepath.Glob(glob)
		require.NoError(t, err)
		sort.Strings(files)
		for _, f := range files {
			b, err := os.ReadFile(f)
			require.NoError(t, err)
			var probe map[string]json.RawMessage
			if json.Unmarshal(b, &probe) != nil || probe["hook_event_name"] == nil {
				continue // not a hook payload (a session report, a golden)
			}
			ev, err := a.Normalize(b)
			require.NoError(t, err, f)
			got[string(k)+"/"+filepath.Base(f)] = snapshot(ev)
		}
	}
	add(agentkind.Codex, filepath.Join("..", "..", "cmd", "testdata", "codex_hooks", "*.json"))
	add(agentkind.Claude, filepath.Join("..", "..", "cmd", "testdata", "*.json"))
	// Round-trip through JSON so both sides compare as decoded values.
	b, err := json.Marshal(got)
	require.NoError(t, err)
	var gotDecoded map[string]any
	require.NoError(t, json.Unmarshal(b, &gotDecoded))
	require.NotEmpty(t, want)
	assert.Equal(t, want, gotDecoded)
}

// Normalize keeps parseHookEvent's input contract on both agents: empty
// input is io.EOF, input that is no JSON object an error.
func TestSessionAgent_NormalizeEmptyAndInvalidInput(t *testing.T) {
	for _, a := range All() {
		_, err := a.Normalize([]byte("  \n"))
		assert.ErrorIs(t, err, io.EOF, a.Kind())
		_, err = a.Normalize([]byte("not json"))
		assert.Error(t, err, a.Kind())
		assert.False(t, errors.Is(err, io.EOF), a.Kind())
	}
}

// TestSessionAgent_CapsFixtureMatchesAdapters: the shared fixture Swift and
// the phone read is every adapter's Caps, and lists no other kind.
func TestSessionAgent_CapsFixtureMatchesAdapters(t *testing.T) {
	var fx struct {
		Agents map[string]Caps `json:"agents"`
	}
	var top map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(capabilitiesJSON, &top))
	require.NoError(t, json.Unmarshal(top["agents"], &fx.Agents))
	for name := range top {
		if name != "agents" && name != "comment" && name != "kinds" {
			t.Errorf("unknown top-level key %q", name)
		}
	}
	// "kinds" (added 2026-11-08, A7a, additive: no row key changed) is
	// agentkind's registry in its order — kind, label (agent_label) and
	// display_name — so Swift can read the list instead of spelling it.
	type kindRow struct {
		Kind        string `json:"kind"`
		Label       string `json:"label"`
		DisplayName string `json:"display_name"`
	}
	var kinds []kindRow
	require.NoError(t, json.Unmarshal(top["kinds"], &kinds), "the fixture lists agentkind's registry under \"kinds\"")
	var wantKinds []kindRow
	for _, d := range agentkind.Registry() {
		wantKinds = append(wantKinds, kindRow{string(d.Kind), d.Label, d.DisplayName})
	}
	assert.Equal(t, wantKinds, kinds, "\"kinds\" is agentkind's registry, in its order")
	// Every key of every row is a Caps field: a typo cannot hide.
	var rows map[string]map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(top["agents"], &rows))
	fields := map[string]bool{}
	b, err := json.Marshal(Caps{})
	require.NoError(t, err)
	var zero map[string]json.RawMessage
	require.NoError(t, json.Unmarshal(b, &zero))
	for k := range zero {
		fields[k] = true
	}
	for name, row := range rows {
		assert.Len(t, row, len(fields), "%s lists every capability", name)
		for k := range row {
			assert.True(t, fields[k], "%s: unknown capability %q", name, k)
		}
	}

	assert.Len(t, fx.Agents, len(All()))
	for _, a := range All() {
		row, ok := fx.Agents[string(a.Kind())]
		if assert.True(t, ok, "fixture lacks %s", a.Kind()) {
			assert.Equal(t, a.Caps(), row, a.Kind())
		}
	}
}

// The adapters are exactly agentkind's registry, in its order: a kind with
// no adapter, or an adapter of no registered kind, is named.
func TestSessionAgent_AdaptersMatchAgentKindRegistry(t *testing.T) {
	require.NoError(t, checkAdapters(agentkind.All(), adapterList))
	got := make([]Kind, 0, len(All()))
	for _, a := range All() {
		got = append(got, a.Kind())
	}
	assert.Equal(t, agentkind.All(), got)

	err := checkAdapters([]Kind{agentkind.Claude, "gemini"}, []Adapter{claudeAdapter{}, codexAdapter{}})
	require.Error(t, err)
	assert.Contains(t, err.Error(), `agent kind "gemini" has no session adapter`)
	assert.Contains(t, err.Error(), `session adapter "codex" serves no registered agent kind`)
	err = checkAdapters([]Kind{agentkind.Claude}, []Adapter{claudeAdapter{}, claudeAdapter{}})
	require.Error(t, err)
	assert.Contains(t, err.Error(), `two session adapters for agent kind "claude"`)
}

func TestSessionAgent_ForKnowsTheAgentKindsOnly(t *testing.T) {
	for _, a := range All() {
		got, ok := For(a.Kind())
		require.True(t, ok)
		assert.Equal(t, a.Kind(), got.Kind())
		assert.True(t, agentkind.IsAgent(string(a.Kind())))
	}
	_, ok := Of("shell")
	assert.False(t, ok)
	assert.Equal(t, Caps{}, CapsOf("shell"))
	assert.Equal(t, CapsOf("codex"), codexAdapter{}.Caps())
}

// The derived gates keep G7's rows: Claude reports every mid-turn dialog;
// Codex's MCP forms raise no state, so nothing goes to it while it works and
// the phone sends it no Esc.
func TestSessionAgent_DerivedGates(t *testing.T) {
	claude, codex := claudeAdapter{}.Caps(), codexAdapter{}.Caps()
	// G7's rows on codex 0.159.2 (moved from agentkind.SessionCaps).
	assert.True(t, claude.MidturnInput && claude.PhoneInput && claude.PermissionWait && claude.IdleSignal && claude.Elicitation)
	assert.True(t, codex.MidturnInput && codex.PhoneInput)
	assert.False(t, codex.PermissionWait || codex.IdleSignal || codex.Elicitation)
	assert.True(t, claude.TakesLineWhileWorking())
	assert.True(t, claude.TakesInterrupt())
	assert.False(t, claude.RolloutWatch())
	assert.False(t, codex.TakesLineWhileWorking())
	assert.False(t, codex.TakesInterrupt())
	assert.True(t, codex.RolloutWatch())
	_, pulls := claudeAdapter{}.Watch()
	assert.False(t, pulls)
	_, pulls = codexAdapter{}.Watch()
	assert.True(t, pulls)
}

// A pulled turn reads as the hook event the agent lacks: a failure as a
// StopFailure carrying codex_error_info, an abort as an Interrupt.
func TestSessionAgent_CodexPullEvents(t *testing.T) {
	p, _ := codexAdapter{}.Watch()
	at := time.Date(2026, 11, 6, 9, 0, 0, 0, time.UTC)
	ev, ok := p.Event("s", sessionfeed.CodexTurn{Failed: true, Error: "usage_limit_exceeded", At: at})
	require.True(t, ok)
	text, failure := ev.FailureText()
	assert.True(t, failure)
	assert.Equal(t, "usage_limit_exceeded", text)
	assert.Equal(t, "s", ev.SessionID)
	ev, ok = p.Event("s", sessionfeed.CodexTurn{Aborted: true, At: at})
	require.True(t, ok)
	assert.Equal(t, "Interrupt", ev.Event)
	_, ok = p.Event("s", sessionfeed.CodexTurn{At: at})
	assert.False(t, ok)
}

func TestSessionAgent_CodexHomeOf(t *testing.T) {
	p, _ := codexAdapter{}.Watch()
	assert.Equal(t, "/x/codex", p.HomeOf([]string{"CODEX_HOME=/y", "CODEX_HOME=/x/codex"}))
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(home, ".codex"), p.HomeOf([]string{"CODEX_HOME=relative"}))
}

// The phone's half of the capability rows (the terminal_session slice's
// `phone` key, U5) is one table for Go, the Desktop hub and the Kit: the
// Kit fixture phone_caps.json, which the Desktop's TerminalSessionSliceTests
// and the Kit's WorkbenchMirrorFixtureTests read too.
func TestSessionAgent_PhoneCapsMatchKitFixture(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "WatchtowerKit", "Tests", "Fixtures", "workbench", "phone_caps.json"))
	require.NoError(t, err)
	var fx struct {
		Agents map[string]map[string]any `json:"agents"`
	}
	require.NoError(t, json.Unmarshal(b, &fx))
	assert.Len(t, fx.Agents, len(All()))
	for _, a := range All() {
		got, err := json.Marshal(a.Caps().Phone())
		require.NoError(t, err)
		var row map[string]any
		require.NoError(t, json.Unmarshal(got, &row))
		assert.Equal(t, fx.Agents[string(a.Kind())], row, a.Kind())
	}
	assert.Equal(t, PhoneCaps{}, CapsOf("shell").Phone(), "a kind that is not an agent takes nothing")
}
