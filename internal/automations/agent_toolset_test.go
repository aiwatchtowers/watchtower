package automations_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/tools"
)

// The agent() tool set is requested ∩ what the manifest admits (P2's
// by-name rule, outputs:[target] admitting create_target), minus writes in
// a dry run, sorted, unknown names dropped (spec §6.5).
func TestAgent_ToolSetIsIntersection(t *testing.T) {
	read := func(name string) *tools.Tool { return &tools.Tool{Name: name, Access: tools.AccessRead} }
	write := func(name string) *tools.Tool { return &tools.Tool{Name: name, Access: tools.AccessWrite} }
	reg := &automationstest.FakeRegistry{Tools: map[string]*tools.Tool{
		"list_jira_issues":    read("list_jira_issues"),
		"list_targets":        read("list_targets"),
		"get_target":          read("get_target"),
		"get_confluence_page": read("get_confluence_page"),
		"search_knowledge":    read("search_knowledge"),
		"create_target":       write("create_target"),
		"send_slack_message":  write("send_slack_message"),
		"main_only":           {Name: "main_only", Access: tools.AccessRead, Surfaces: []string{"main"}},
	}}
	manifest := func(t *testing.T, entries ...string) *automations.Manifest {
		t.Helper()
		m, err := automations.ParseManifest(entries, []string{"target"}, automations.Scope{Kind: automations.ScopePersonal})
		require.NoError(t, err)
		return m
	}
	requested := []string{"list_jira_issues", "list_targets", "create_target", "get_confluence_page",
		"send_slack_message", "search_knowledge", "bogus", "main_only"}

	m := manifest(t, "jira:read@PAY", "targets:read")
	assert.Equal(t, []string{"create_target", "list_jira_issues", "list_targets"},
		automations.EffectiveAgentTools(reg, m, requested, false),
		"search_knowledge needs tool:search_knowledge (ask #273)")

	withSearch := manifest(t, "jira:read@PAY", "targets:read", "tool:search_knowledge")
	assert.Equal(t, []string{"create_target", "list_jira_issues", "list_targets", "search_knowledge"},
		automations.EffectiveAgentTools(reg, withSearch, requested, false))

	assert.Equal(t, []string{"create_target", "get_target", "list_jira_issues", "list_targets"},
		automations.EffectiveAgentTools(reg, m, nil, false), "omitted = every admitted tool")

	assert.Equal(t, []string{"list_jira_issues", "list_targets"},
		automations.EffectiveAgentTools(reg, m, requested, true), "a dry run drops write tools")
}
