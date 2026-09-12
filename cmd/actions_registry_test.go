package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// buildToolRegistry is the ONE assembly point every entry point ships
// (`mcp --chat`, `ai query --tools chat`, `jira create`, reaction commands):
// pin its full write-tool set, its read-tool mount and the per-surface gate,
// so a bad merge or a dropped registration cannot pass silently.
func TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces(t *testing.T) {
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	database.SetMaxOpenConns(1)
	defer database.Close()
	cfg := &config.Config{ActiveWorkspace: "test-ws"}

	reg := buildToolRegistry(cfg, database)

	names := func(surface string) map[string]bool {
		out := map[string]bool{}
		for _, tool := range reg.List(surface) {
			out[tool.Name] = true
		}
		return out
	}
	reactionTools := []string{"create_track", "create_idea", "remind_me", "brief_context"}

	main := names("main")
	for _, w := range []string{"create_target", "create_jira_issue", "connect_jira_board"} {
		assert.True(t, main[w], "write tool %s missing on main", w)
	}
	for _, rt := range tools.ReadTools() {
		assert.True(t, main[rt.Name], "read tool %s missing on main", rt.Name)
	}
	for _, w := range reactionTools {
		assert.False(t, main[w], "%s is reaction-path only; in chat it would create work with no message to bind to", w)
	}

	target := names("target")
	assert.False(t, target["create_target"], "create_target is main-only (TGT-BRIEF-01 axis 3)")
	assert.False(t, target["connect_jira_board"], "connect_jira_board is main-only (TGT-BRIEF-01 axis 3)")
	assert.True(t, target["create_jira_issue"], "create_jira_issue is offered on the target surface")
	for _, w := range reactionTools {
		assert.False(t, target[w], "%s must not be offered on the target surface (TGT-BRIEF-01 axis 3)", w)
	}

	reaction := names("reaction")
	for _, w := range reactionTools {
		assert.True(t, reaction[w], "%s missing on the reaction surface", w)
	}
}
