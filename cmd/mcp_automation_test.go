package cmd

import (
	"context"
	"os"
	"sort"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
	internalmcp "watchtower/internal/mcp"
	"watchtower/internal/tools"
)

// agentMCPRecipe admits Jira reads of PAY and create_target through
// outputs:[target] only.
const agentMCPRecipe = "---\nname: Agent MCP\ntrigger:\n  manual: true\npermissions:\n  - jira:read@PAY\n" +
	"outputs: [target]\n---\nAn agent MCP test recipe.\n\n```js\nreturn 1\n```\n"

// agentMCP is a confirmed personal automation for the agent MCP server tests.
type agentMCP struct {
	*autoCLI
	cfg *config.Config
	a   *db.Automation
}

func newAgentMCP(t *testing.T) *agentMCP {
	t.Helper()
	resetMCPFlags(t)
	c := newAutoCLI(t)
	cfg, err := loadAutomationsConfig()
	require.NoError(t, err)
	return &agentMCP{autoCLI: c, cfg: cfg, a: c.confirmedRecipe(t, "agent-mcp", agentMCPRecipe)}
}

// queue enqueues a run of trigger; claim moves it to running with the
// automation's recipe as its snapshot.
func (s *agentMCP) queue(t *testing.T, trigger string) int64 {
	t.Helper()
	run, _, err := s.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: s.a.ID, Trigger: trigger, Now: time.Now()})
	require.NoError(t, err)
	return run
}

func (s *agentMCP) claim(t *testing.T, run int64) {
	t.Helper()
	ok, err := s.d.ClaimAutomationRun(run, s.a.ApprovalHash, s.a.RecipeText, 50000, 10, time.Now())
	require.NoError(t, err)
	require.True(t, ok)
}

func (s *agentMCP) running(t *testing.T, trigger string) int64 {
	t.Helper()
	run := s.queue(t, trigger)
	s.claim(t, run)
	return run
}

// options sets the agent-server flags for run with the requested tools and
// the run's own marker, and builds the server options.
func (s *agentMCP) options(t *testing.T, run int64, requested ...string) ([]internalmcp.ServerOption, error) {
	t.Helper()
	t.Setenv(automations.RunEnvMarker, strconv.FormatInt(run, 10))
	mcpFlagChat, mcpFlagSurface, mcpFlagAutomationRun, mcpFlagAutomationTools = true, tools.AutomationSurface, run, requested
	return mcpModeOptions(s.cfg, s.d, "", nil)
}

func (s *agentMCP) session(t *testing.T, run int64, requested ...string) (map[string]bool, *internalmcp.LocalSession) {
	t.Helper()
	opts, err := s.options(t, run, requested...)
	require.NoError(t, err)
	return localToolNames(t, s.d, opts)
}

func sortedNames(names map[string]bool) []string {
	out := make([]string, 0, len(names))
	for n := range names {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

func TestAgentMCPServer_RefusesWithoutMatchingMarkerOrRunningRun(t *testing.T) {
	s := newAgentMCP(t)
	run := s.queue(t, db.TriggerManual)
	_, err := s.options(t, run, "list_jira_issues")
	require.ErrorContains(t, err, "not running", "a queued run")

	s.claim(t, run)
	_, err = s.options(t, run, "list_jira_issues")
	require.NoError(t, err, "the run's own child with the run running starts")

	require.NoError(t, os.Unsetenv(automations.RunEnvMarker))
	_, err = mcpModeOptions(s.cfg, s.d, "", nil)
	require.ErrorContains(t, err, automations.RunEnvMarker, "no marker")

	t.Setenv(automations.RunEnvMarker, strconv.FormatInt(run+1, 10))
	_, err = mcpModeOptions(s.cfg, s.d, "", nil)
	require.ErrorContains(t, err, automations.RunEnvMarker, "another run's marker")

	_, err = s.options(t, run+1, "list_jira_issues")
	require.ErrorIs(t, err, db.ErrAutomationRunNotFound, "a run that does not exist")

	require.NoError(t, s.d.FinishAutomationRun(run, db.RunFinish{Status: db.RunSucceeded, Now: time.Now()}, nil))
	_, err = s.options(t, run, "list_jira_issues")
	require.ErrorContains(t, err, "not running", "a finished run")
}

func TestAgentMCPServer_MountsOnlyEffectiveSet(t *testing.T) {
	s := newAgentMCP(t)
	run := s.running(t, db.TriggerManual)
	names, _ := s.session(t, run, "list_jira_issues", "create_target", "get_confluence_page")
	assert.Equal(t, []string{"create_target", "get_action", "list_jira_issues"}, sortedNames(names))

	names, _ = s.session(t, run)
	assert.Equal(t, []string{"get_action"}, sortedNames(names), "no tools asked for, none mounted")
}

func TestAgentMCPServer_GatesEachCallByManifest(t *testing.T) {
	s := newAgentMCP(t)
	run := s.running(t, db.TriggerManual)
	_, ls := s.session(t, run, "list_jira_issues")

	text, isErr, err := ls.Call(context.Background(), "list_jira_issues", map[string]any{"project": "OPS"})
	require.NoError(t, err)
	require.True(t, isErr, text)
	assert.Contains(t, text, "PermissionDenied: needs jira:read@OPS")

	text, isErr, err = ls.Call(context.Background(), "list_jira_issues", map[string]any{"project": "PAY"})
	require.NoError(t, err)
	assert.False(t, isErr, "PAY is admitted: %s", text)
	assert.Zero(t, countAgentActions(t, s.d), "reads record nothing")
}

func TestAgentMCPServer_DryRunMountsNoWrites(t *testing.T) {
	s := newAgentMCP(t)
	run := s.running(t, db.TriggerDryRun)
	names, _ := s.session(t, run, "list_jira_issues", "create_target")
	assert.Equal(t, []string{"get_action", "list_jira_issues"}, sortedNames(names))
}

// S8: inside agent() a write is always a pending proposal stamped with the
// run, even while an auto grant of the tool is active.
func TestAgentMCPServer_WriteIsPendingProposalWithRunContext(t *testing.T) {
	s := newAgentMCP(t)
	run := s.running(t, db.TriggerManual)
	require.NoError(t, s.d.SetAutomationToolGrant(s.a.ID, "create_target", s.a.ApprovalHash, time.Now()))
	granted, err := s.d.ActiveAutomationToolGrant(run, "create_target")
	require.NoError(t, err)
	require.True(t, granted, "the grant is active for this run")

	_, ls := s.session(t, run, "create_target")
	text, isErr, err := ls.Call(context.Background(), "create_target", map[string]any{"text": "Follow up", "reason": "agent"})
	require.NoError(t, err)
	require.False(t, isErr, text)

	var status, surface, ctxType, ctxID string
	require.Equal(t, 1, countAgentActions(t, s.d))
	require.NoError(t, s.d.QueryRow(`SELECT status, surface, context_type, context_id FROM agent_actions`).
		Scan(&status, &surface, &ctxType, &ctxID))
	assert.Equal(t, "pending", status)
	assert.Equal(t, tools.AutomationSurface, surface)
	assert.Equal(t, tools.AutomationContextType, ctxType)
	assert.Equal(t, strconv.FormatInt(run, 10), ctxID)
	var targets int
	require.NoError(t, s.d.QueryRow(`SELECT COUNT(*) FROM targets`).Scan(&targets))
	assert.Zero(t, targets, "nothing applied")
}

// S8: an execute trust row for the tool on the automation surface does not
// apply an agent's write either: it stays a pending proposal.
func TestAgentMCPServer_ExecuteTrustStillPending(t *testing.T) {
	s := newAgentMCP(t)
	run := s.running(t, db.TriggerManual)
	require.NoError(t, s.d.SetToolTrust("create_target", tools.AutomationSurface, "execute"))

	_, ls := s.session(t, run, "create_target")
	text, isErr, err := ls.Call(context.Background(), "create_target", map[string]any{"text": "Follow up", "reason": "agent"})
	require.NoError(t, err)
	require.False(t, isErr, text)

	var status, trust string
	require.Equal(t, 1, countAgentActions(t, s.d))
	require.NoError(t, s.d.QueryRow(`SELECT status, trust_at_create FROM agent_actions`).Scan(&status, &trust))
	assert.Equal(t, "pending", status)
	assert.Equal(t, "ask", trust)
	var targets int
	require.NoError(t, s.d.QueryRow(`SELECT COUNT(*) FROM targets`).Scan(&targets))
	assert.Zero(t, targets, "nothing applied")
}

// --workbench never combines with the automation flags: that would start a
// workbench DirectApply server for an automation's agent.
func TestMCP_WorkbenchWithAutomationFlagsRefused(t *testing.T) {
	for name, set := range map[string]func(){
		"surface":          func() { mcpFlagSurface = tools.AutomationSurface },
		"automation-run":   func() { mcpFlagAutomationRun = 7 },
		"automation-tools": func() { mcpFlagAutomationTools = []string{"list_targets"} },
	} {
		t.Run(name, func(t *testing.T) {
			resetMCPFlags(t)
			database := openMCPTestDB(t)
			mcpFlagWorkbench = 1
			set()
			_, err := mcpModeOptions(&config.Config{ActiveWorkspace: "test-ws"}, database, "", nil)
			require.ErrorContains(t, err, "--workbench and the automation flags")
		})
	}
}

func TestAgentMCPServer_CallAfterRunEndedRefused(t *testing.T) {
	s := newAgentMCP(t)
	run := s.running(t, db.TriggerManual)
	_, ls := s.session(t, run, "list_jira_issues", "create_target")
	require.NoError(t, s.d.FinishAutomationRun(run, db.RunFinish{Status: db.RunCancelled, Now: time.Now()}, nil))

	for name, args := range map[string]map[string]any{
		"list_jira_issues": {"project": "PAY"},
		"create_target":    {"text": "late", "reason": "agent"},
	} {
		text, isErr, err := ls.Call(context.Background(), name, args)
		require.NoError(t, err)
		require.True(t, isErr, text)
		assert.Contains(t, text, "the automation run has ended", name)
	}
	assert.Zero(t, countAgentActions(t, s.d))
}

func TestMCP_MainAndTargetUnchanged(t *testing.T) {
	resetMCPFlags(t)
	database := openMCPTestDB(t)
	cfg := &config.Config{ActiveWorkspace: "test-ws"}

	mcpFlagChat, mcpFlagSurface = true, tools.AutomationSurface
	_, err := mcpModeOptions(cfg, database, "t1", nil)
	require.ErrorContains(t, err, "--surface automation requires --automation-run")

	mcpFlagSurface, mcpFlagAutomationRun = "main", 7
	_, err = mcpModeOptions(cfg, database, "t1", nil)
	require.ErrorContains(t, err, "require --surface automation")

	mcpFlagChat = false
	_, err = mcpModeOptions(cfg, database, "", nil)
	require.ErrorContains(t, err, "require --chat")

	mcpFlagChat, mcpFlagAutomationRun = true, 0
	for surface, want := range map[string]bool{"main": true, "target": false} {
		mcpFlagSurface = surface
		opts, err := mcpModeOptions(cfg, database, "t1", nil)
		require.NoError(t, err, surface)
		names, _ := localToolNames(t, database, opts)
		assert.Equal(t, want, names["create_target"], surface)
		assert.True(t, names["get_action"], surface)
		assert.True(t, names["list_targets"], surface)
	}
}

func countAgentActions(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n))
	return n
}
