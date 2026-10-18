package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/memory"
	"watchtower/internal/tools"
)

var automationMemoryTools = []string{"memory_map", "memory_open", "memory_recall"}

// newAutomationRegistryEnv points HOME at a temp dir (the memory vault lives
// under the workspace dir) and opens an in-memory database.
func newAutomationRegistryEnv(t *testing.T) (*config.Config, *db.DB) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	database.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = database.Close() })
	return &config.Config{ActiveWorkspace: "test-ws"}, database
}

func TestBuildAutomationRegistry_AddsMemoryTools(t *testing.T) {
	cfg, database := newAutomationRegistryEnv(t)

	reg := buildAutomationRegistry(cfg, database)
	for _, name := range automationMemoryTools {
		tool, ok := reg.Get(name)
		require.True(t, ok, "%s missing from the automation registry", name)
		assert.True(t, tool.VisibleOn(tools.AutomationSurface), name)
	}
	_, ok := reg.Get("load_skill")
	assert.False(t, ok, "load_skill is not an automation tool")
	// Everything buildToolRegistry has is there too.
	base := buildToolRegistry(cfg, database)
	for _, tool := range base.All() {
		_, ok := reg.Get(tool.Name)
		assert.True(t, ok, "%s missing from the automation registry", tool.Name)
	}
	assert.Len(t, reg.All(), len(base.All())+len(automationMemoryTools))
	for _, name := range append(slices.Clone(automationMemoryTools), "load_skill") {
		_, ok := base.Get(name)
		assert.False(t, ok, "buildToolRegistry must not gain %s (the chat MCP server registers it)", name)
	}

	// memory_recall on this registry has no shadow handle: no
	// memory_retrieve_shadow row, ever.
	v, err := memory.OpenVault(memoryVaultPath(cfg))
	require.NoError(t, err)
	_, err = v.WriteNodes([]memory.Node{{
		ID: "ent_01ARZ3NDEKTSV4RRFFQ69G5MP1", Type: "entity", Tier: "long", Status: "active",
		Title: "Payments Service", Aliases: []string{"pay-svc"}, Body: "# Payments Service\n\nOwns checkout.\n",
	}}, memory.CommitMsg{Op: "extract", Summary: "seed", Cause: "seed"})
	require.NoError(t, err)
	_, err = memory.Reconcile(v, database, t.Logf)
	require.NoError(t, err)
	data, err := reg.CallRead(context.Background(), "memory_recall", json.RawMessage(`{"query":"pay-svc"}`),
		tools.Binding{Surface: tools.AutomationSurface})
	require.NoError(t, err)
	b, err := json.Marshal(data)
	require.NoError(t, err)
	assert.Contains(t, string(b), "Payments Service")
	rows, err := database.ListMemoryRetrieveShadow("recall", time.Time{})
	require.NoError(t, err)
	assert.Empty(t, rows, "an automation's recall writes no shadow row")
}

// toolOnlyTools are the automation-visible tools deliberately admitted only
// by tool:<name>: the D21 knowledge tools and the D23 cross-source and
// single-purpose reads (spec 2026-10-14 §20.1 D21, D23).
var toolOnlyTools = []string{
	"search_knowledge", "get_knowledge_document", "get_task_context",
	"list_inbox", "memory_recall", "memory_open", "memory_map", "get_writing_style",
}

// Every tool the automation registry shows on the automation surface has a
// capability row or is tool:-only — never neither, never both — and every
// row maps to a valid capability.
func TestToolCapabilities_CoversEveryAutomationTool(t *testing.T) {
	cfg, database := newAutomationRegistryEnv(t)
	visible := buildAutomationRegistry(cfg, database).List(tools.AutomationSurface)
	require.NotEmpty(t, visible)
	// The ten write tools (Automations P2) are visible, so the coverage loop
	// below checks their capability rows too.
	for name := range automationWriteSurfaces {
		if !slices.ContainsFunc(visible, func(tool *tools.Tool) bool { return tool.Name == name }) {
			t.Errorf("write tool %s is not visible on the automation surface", name)
		}
	}
	for _, tool := range visible {
		_, has := automations.ToolCapabilities[tool.Name]
		if !has && !slices.Contains(toolOnlyTools, tool.Name) {
			t.Errorf("%s is visible on the automation surface but has no ToolCapabilities entry and is not tool:-only", tool.Name)
		}
	}
	for _, name := range toolOnlyTools {
		if _, has := automations.ToolCapabilities[name]; has {
			t.Errorf("%s is tool:-only but has a ToolCapabilities entry", name)
		}
		if !slices.ContainsFunc(visible, func(tool *tools.Tool) bool { return tool.Name == name }) {
			t.Errorf("tool:-only %s is not visible on the automation surface", name)
		}
	}
	for name, c := range automations.ToolCapabilities {
		if !capabilityParses(c.Capability + ":" + c.Verb) {
			t.Errorf("%s maps to an invalid capability %s:%s", name, c.Capability, c.Verb)
		}
	}
}

// capabilityParses: a capability is valid when exactly one form of its entry
// parses — bare (scope refused) or with @* (scope required).
func capabilityParses(entry string) bool {
	_, bare := automations.ParsePermission(entry)
	_, star := automations.ParsePermission(entry + "@*")
	return (bare == nil) != (star == nil)
}

// The authoring tools' dry run (draft_automation) sees exactly the tools a
// run sees: its backends use buildAutomationRegistry, memory tools included.
func TestAutomationAuthoringDeps_UseTheAutomationRegistry(t *testing.T) {
	cfg, database := newAutomationRegistryEnv(t)
	deps := automationAuthoringDeps(cfg, database)
	assert.Equal(t, cfg.WorkspaceDir(), deps.WorkspaceDir)
	assert.False(t, deps.Enabled(), "off while automations.enabled is off")
	cfg.Automations.Enabled = true
	assert.True(t, deps.Enabled(), "read per call, not captured at build")
	b := deps.Backends()
	require.NotNil(t, b.Generator)
	reg, ok := b.Registry.(*tools.Registry)
	require.True(t, ok, "the registry is a *tools.Registry")
	for _, name := range automationMemoryTools {
		_, found := reg.Get(name)
		assert.True(t, found, "%s missing from the dry run's registry", name)
	}
}

// The chat MCP server runs under claude, so it inherits CLAUDECODE (and in a
// workbench terminal or Codex, their markers): the authoring generator's
// child carries none of AGENT-07's agent markers. A fake claude records its
// environment; the real CLI is never invoked.
func TestAutomationsGenerator_ChildEnvHasNoAgentMarkers(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	dir := t.TempDir()
	reply, err := json.Marshal(map[string]any{"type": "result", "result": "ok", "is_error": false})
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "reply"), append(reply, '\n'), 0o600))
	script := filepath.Join(dir, "fake-claude")
	require.NoError(t, os.WriteFile(script, []byte("#!/bin/sh\n"+
		"env > '"+dir+"/env'\n"+
		"cat > /dev/null\n"+
		"cat '"+dir+"/reply'\n"), 0o755))
	markers := []string{"CLAUDECODE", "CODEX_THREAD_ID", "CODEX_SANDBOX", "WATCHTOWER_TERMINAL_SESSION_ID"}
	for _, m := range markers {
		t.Setenv(m, "1")
	}
	cfg, err := config.Load(fakeModelConfig(t, dir, "claude", script))
	require.NoError(t, err)

	out, _, _, err := automationsAuthoringGenerator(cfg).Generate(context.Background(), "system", "user", "")

	require.NoError(t, err)
	assert.Equal(t, "ok", out)
	env, err := os.ReadFile(filepath.Join(dir, "env"))
	require.NoError(t, err)
	for line := range strings.SplitSeq(string(env), "\n") {
		name, _, _ := strings.Cut(line, "=")
		assert.NotContains(t, markers, name, "the generator's child carries %s", name)
	}
}

func TestAutomationAuthoringDeps_BackendsCarryMCPAndAgent(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg, err := config.Load(fakeModelConfig(t, t.TempDir(), "claude", "/usr/bin/false"))
	require.NoError(t, err)

	b := automationAuthoringDeps(cfg, nil).Backends()

	assert.NotNil(t, b.Generator)
	assert.NotNil(t, b.Registry)
	assert.NotNil(t, b.MCP)
	assert.NotNil(t, b.Agent)
	// The agent runner's children get an allowlisted env, never the markers.
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("WATCHTOWER_TERMINAL_SESSION_ID", "1")
	for _, kv := range automationAgentEnv(1) {
		name, _, _ := strings.Cut(kv, "=")
		if name != automations.RunEnvMarker { // the run's own marker is set on purpose
			assert.NotContains(t, agentEnvMarkers, name)
		}
	}
}
