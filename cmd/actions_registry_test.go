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

	reaction := names("reaction")
	for _, w := range reactionTools {
		assert.True(t, reaction[w], "%s missing on the reaction surface", w)
	}
	for _, w := range jiraWrites {
		assert.False(t, reaction[w], "%s has no reacted message to act on", w)
	}

	// The project surface (`mcp --project N`, DEV-06): exactly the project
	// tools plus the surface-less read tools — no other write tool, nothing
	// External — and no project tool leaks onto another surface.
	projectTools := []string{
		"project_info", "project_board", "update_project", "add_project_source", "remove_project_source",
		"create_targets", "update_target", "attach_document", "list_comments", "add_comment", "resolve_comment",
	}
	project := names("project")
	for _, p := range projectTools {
		assert.True(t, project[p], "%s missing on the project surface", p)
		assert.False(t, main[p] || target[p] || reaction[p], "%s is project-surface only", p)
	}
	for _, rt := range tools.ReadTools() {
		assert.True(t, project[rt.Name], "read tool %s missing on the project surface", rt.Name)
	}
	assert.Len(t, project, len(projectTools)+len(tools.ReadTools()), "nothing else on the project surface")
	for _, tool := range reg.List("project") {
		assert.False(t, tool.External, "%s is External on the project surface (DEV-06)", tool.Name)
	}
}
