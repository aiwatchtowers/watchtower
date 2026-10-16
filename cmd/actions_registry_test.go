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

	names := func(surface string) map[string]bool { return surfaceToolNames(reg, surface) }
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

	// Bulk track dismiss (#227): main chat only, and always behind the
	// owner's Approve whatever the trust settings.
	dismiss, ok := reg.Get("dismiss_tracks")
	require.True(t, ok)
	assert.Equal(t, tools.AccessWrite, dismiss.Access)
	assert.True(t, dismiss.AlwaysAsk, "a bulk dismiss never auto-executes")
	assert.True(t, main["dismiss_tracks"], "dismiss_tracks missing on main")
	assert.False(t, target["dismiss_tracks"], "dismiss_tracks is main-only (TGT-BRIEF-01 axis 3)")

	reaction := names("reaction")
	assert.False(t, reaction["dismiss_tracks"], "dismiss_tracks is main-only")
	for _, w := range reactionTools {
		assert.True(t, reaction[w], "%s missing on the reaction surface", w)
	}
	for _, w := range append(jiraWrites, "get_confluence_page", "edit_confluence_page") {
		assert.False(t, reaction[w], "%s has no reacted message to act on", w)
	}
	// The seeded dictionary (migration 00063) maps :white_check_mark: and
	// :ticket: to these; Propose admits only a tool the calling surface lists.
	for _, w := range []string{"create_target", "create_jira_issue"} {
		assert.True(t, reaction[w], "%s is a seeded reaction command", w)
	}
	assert.False(t, reaction["connect_jira_board"], "connect_jira_board is main-only")

	project := pinProjectSurface(t, reg, main, target, reaction)
	pinAutomationSurface(t, reg, main, target, reaction, project)
	assert.Equal(t, []string{"main", "target"}, get.Surfaces, "get_confluence_page's surfaces are unchanged")
}

func surfaceToolNames(reg *tools.Registry, surface string) map[string]bool {
	out := map[string]bool{}
	for _, tool := range reg.List(surface) {
		out[tool.Name] = true
	}
	return out
}

func pinProjectSurface(t *testing.T, reg *tools.Registry, main, target, reaction map[string]bool) map[string]bool {
	t.Helper()
	// The workbench surface (`mcp --workbench N`, DEV-06): exactly the workbench
	// tools, the Slack pair and the surface-less read tools — no other write
	// tool, nothing External but the propose-only Slack send — and no
	// workbench tool leaks onto another surface.
	workbenchTools := []string{
		"workbench_info", "workbench_board", "update_workbench", "add_workbench_source", "remove_workbench_source",
		"create_targets", "update_target", "list_comments", "add_comment", "resolve_comment",
		"ask_owner", "get_ask", "get_review", "list_asks", "withdraw_ask", "finish_session",
	}
	project := surfaceToolNames(reg, "project")
	for _, p := range workbenchTools {
		assert.True(t, project[p], "%s missing on the project surface", p)
		assert.False(t, main[p] || target[p] || reaction[p], "%s is project-surface only", p)
	}
	for _, rt := range tools.ReadTools() {
		assert.True(t, project[rt.Name], "read tool %s missing on the project surface", rt.Name)
	}
	// Slack send (#166, owner decision 2026-10-02): the one External tool on
	// the project surface, and only because it is propose-only there — the
	// owner approves it in the Desktop (DEV-06 rule 3, amended).
	slackTools := []string{"send_slack_message", "get_writing_style"}
	for _, s := range slackTools {
		assert.True(t, project[s], "%s missing on the project surface", s)
		assert.True(t, main[s], "%s missing on main", s)
		assert.False(t, target[s] || reaction[s], "%s is main + project only", s)
	}
	for _, rt := range tools.ReadTools() {
		assert.NotEqual(t, "get_writing_style", rt.Name, "dev-mode MCP is unchanged (DEV-01)")
	}
	assert.Len(t, project, len(workbenchTools)+len(slackTools)+len(tools.ReadTools()), "nothing else on the project surface")
	for _, tool := range reg.List("project") {
		if tool.Name == "send_slack_message" {
			assert.True(t, tool.External, "a Slack send leaves the machine (AGENT-03)")
			assert.True(t, tool.ProposeUnderDirectApply, "in a workbench session it is only ever proposed (DEV-06)")
			continue
		}
		assert.False(t, tool.External, "%s is External on the project surface (DEV-06)", tool.Name)
		assert.False(t, tool.ProposeUnderDirectApply, "%s", tool.Name)
	}
	return project
}

func pinAutomationSurface(t *testing.T, reg *tools.Registry, main, target, reaction, project map[string]bool) {
	t.Helper()
	// Automations (spec 2026-10-14 §6.1, D2): the local-store email reads are
	// on the automation surface only — never in tools.ReadTools() (DEV-01).
	automation := surfaceToolNames(reg, tools.AutomationSurface)
	// The D23 reads (ask #277) are automation-surface only too.
	d23 := []string{
		"list_inbox", "list_calendar_events", "list_meeting_recaps", "get_meeting_recap", "list_meeting_notes",
		"list_day_plans", "get_day_plan", "list_reminders", "list_jira_sprints", "list_jira_releases",
	}
	for _, e := range append([]string{"list_emails", "get_email"}, d23...) {
		tool, ok := reg.Get(e)
		require.True(t, ok, "%s missing", e)
		assert.Equal(t, tools.AccessRead, tool.Access, e)
		assert.Equal(t, []string{tools.AutomationSurface}, tool.Surfaces, e)
		assert.True(t, automation[e], "%s missing on the automation surface", e)
		assert.False(t, main[e] || target[e] || reaction[e] || project[e], "%s is automation-surface only", e)
		for _, rt := range tools.ReadTools() {
			assert.NotEqual(t, e, rt.Name, "dev-mode MCP never mounts %s (DEV-01)", e)
		}
	}
	// get_writing_style gains the automation surface (D23); get_confluence_page
	// — a live network read — stays off it.
	style, ok := reg.Get("get_writing_style")
	require.True(t, ok)
	assert.Equal(t, []string{"main", tools.WorkbenchSurface, tools.AutomationSurface}, style.Surfaces)
	assert.True(t, automation["get_writing_style"])
	assert.False(t, automation["get_confluence_page"], "a live network read is never on the automation surface")
	pinAutomationWriteTools(t, reg, automation)
}

// automationWriteSurfaces is the pinned surface set of each write tool
// offered to automations (Automations P2, spec 2026-10-14 §6.1): its
// pre-P2 surfaces plus the automation surface.
var automationWriteSurfaces = map[string][]string{
	"create_target":         {"main", "reaction", tools.AutomationSurface},
	"create_idea":           {"reaction", "main", tools.AutomationSurface},
	"create_track":          {"reaction", "main", tools.AutomationSurface},
	"remind_me":             {"reaction", "main", tools.AutomationSurface},
	"create_jira_issue":     {"main", "target", "reaction", tools.AutomationSurface},
	"add_jira_comment":      {"main", "target", tools.AutomationSurface},
	"transition_jira_issue": {"main", "target", tools.AutomationSurface},
	"assign_jira_issue":     {"main", "target", tools.AutomationSurface},
	"update_jira_issue":     {"main", "target", tools.AutomationSurface},
	"send_slack_message":    {"main", tools.WorkbenchSurface, tools.AutomationSurface},
}

func pinAutomationWriteTools(t *testing.T, reg *tools.Registry, automation map[string]bool) {
	t.Helper()
	for name, want := range automationWriteSurfaces {
		tool, ok := reg.Get(name)
		require.True(t, ok, "%s missing", name)
		assert.Equal(t, tools.AccessWrite, tool.Access, name)
		assert.Equal(t, want, tool.Surfaces, "%s: exact surfaces", name)
		assert.True(t, automation[name], "%s missing on the automation surface", name)
	}
	// Exactly the ten write tools: the bulk dismiss (AlwaysAsk), the board
	// connect, the Confluence edit, the reaction-only brief and every
	// workbench tool stay off the automation surface.
	for _, tool := range reg.List(tools.AutomationSurface) {
		if tool.Access == tools.AccessWrite {
			_, pinned := automationWriteSurfaces[tool.Name]
			assert.True(t, pinned, "%s is a write tool on the automation surface but not one of the ten", tool.Name)
		}
	}
	for _, name := range []string{"connect_jira_board", "dismiss_tracks", "edit_confluence_page", "brief_context",
		"create_targets", "update_target", "add_comment", "ask_owner", "finish_session", "update_workbench"} {
		assert.False(t, automation[name], "%s is never offered to automations", name)
	}
}
