package cmd

import (
	"context"
	"encoding/json"
	"slices"
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
