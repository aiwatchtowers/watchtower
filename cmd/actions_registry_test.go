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
	// Spec 2026-09-26 §8: three reaction tools widen to the main chat; the
	// target chat still gets none (TGT-BRIEF-01 axis 3); brief_context stays
	// reaction-only (its summary needs a reacted thread).
	mainLocalTools := []string{"create_track", "create_idea", "remind_me"}
	jiraWrites := []string{"add_jira_comment", "transition_jira_issue", "assign_jira_issue", "update_jira_issue"}

	main := names("main")
	for _, w := range append([]string{"create_target", "create_jira_issue", "connect_jira_board"}, jiraWrites...) {
		assert.True(t, main[w], "write tool %s missing on main", w)
	}
	for _, rt := range tools.ReadTools() {
		assert.True(t, main[rt.Name], "read tool %s missing on main", rt.Name)
	}
	for _, w := range mainLocalTools {
		assert.True(t, main[w], "%s is offered in the main chat", w)
	}
	assert.False(t, main["brief_context"], "brief_context is reaction-path only")

	target := names("target")
	assert.False(t, target["create_target"], "create_target is main-only (TGT-BRIEF-01 axis 3)")
	assert.False(t, target["connect_jira_board"], "connect_jira_board is main-only (TGT-BRIEF-01 axis 3)")
	assert.True(t, target["create_jira_issue"], "create_jira_issue is offered on the target surface")
	for _, w := range reactionTools {
		assert.False(t, target[w], "%s must not be offered on the target surface (TGT-BRIEF-01 axis 3)", w)
	}
	for _, w := range jiraWrites {
		assert.True(t, target[w], "%s is offered on the target surface", w)
		tool, ok := reg.Get(w)
		require.True(t, ok)
		assert.True(t, tool.External, "%s leaves the machine (AGENT-03)", w)
	}

	// Confluence page editing (EXT-05): both tools on main + target; the
	// write is External (AGENT-03); the live read is chat-mode only — it is
	// not in tools.ReadTools(), which dev-mode MCP mounts (DEV-01).
	for _, w := range []string{"get_confluence_page", "edit_confluence_page"} {
		assert.True(t, main[w], "%s missing on main", w)
		assert.True(t, target[w], "%s missing on target", w)
	}
	edit, ok := reg.Get("edit_confluence_page")
	require.True(t, ok)
	assert.Equal(t, tools.AccessWrite, edit.Access)
	assert.True(t, edit.External, "a Confluence write leaves the machine (AGENT-03)")
	get, ok := reg.Get("get_confluence_page")
	require.True(t, ok)
	assert.Equal(t, tools.AccessRead, get.Access)
	for _, rt := range tools.ReadTools() {
		assert.NotEqual(t, "get_confluence_page", rt.Name, "dev-mode MCP never mounts a live network read (DEV-01)")
	}

	reaction := names("reaction")
	for _, w := range reactionTools {
		assert.True(t, reaction[w], "%s missing on the reaction surface", w)
	}
	for _, w := range append(jiraWrites, "get_confluence_page", "edit_confluence_page") {
		assert.False(t, reaction[w], "%s has no reacted message to act on", w)
	}
}
