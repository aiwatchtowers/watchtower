// External test package: the seed helpers live in automationstest, which
// imports internal/automations, which imports this package.
package tools_test

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// autoArgs is what every fake automation write tool takes.
type autoArgs struct {
	Text   string `json:"text"`
	Reason string `json:"reason"`
}

const autoCallArgs = `{"text":"hi","reason":"scheduled"}`

// autoFixture is a file DB, a registry with the fake automation write tools
// and a record of every Execute: the call and the row's status Execute saw.
type autoFixture struct {
	d   *db.DB
	reg *tools.Registry

	mu       sync.Mutex
	calls    []tools.Call
	statuses []string
}

// newAutoFixture registers ext_write (External), local_write (local),
// bulk_write (AlwaysAsk), ext_pick and local_pick (External / local whose
// Ready always fails — several pinned candidates) and ext_fail (External
// whose Execute fails), all on main, target and automation.
func newAutoFixture(t *testing.T) *autoFixture {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	f := &autoFixture{d: d, reg: tools.New(d)}
	notReady := func(json.RawMessage) error {
		return &tools.ValidationError{Msg: "pick one of the candidate workspaces first"}
	}
	for _, tl := range []*tools.Tool{
		f.tool(t, "ext_write", func(tl *tools.Tool) { tl.External = true }),
		f.tool(t, "local_write", nil),
		f.tool(t, "bulk_write", func(tl *tools.Tool) { tl.AlwaysAsk = true }),
		f.tool(t, "ext_pick", func(tl *tools.Tool) { tl.External = true; tl.Ready = notReady }),
		f.tool(t, "local_pick", func(tl *tools.Tool) { tl.Ready = notReady }),
		f.tool(t, "ext_fail", func(tl *tools.Tool) {
			tl.External = true
			tl.Execute = func(context.Context, *db.DB, tools.Call) (any, error) {
				return nil, errors.New("the remote side refused")
			}
		}),
	} {
		require.NoError(t, f.reg.Register(tl))
	}
	return f
}

func (f *autoFixture) tool(t *testing.T, name string, tweak func(*tools.Tool)) *tools.Tool {
	t.Helper()
	schema, err := jsonschema.For[autoArgs](nil)
	require.NoError(t, err)
	tl := &tools.Tool{
		Name: name, Description: "fake automation write", InputSchema: schema, Access: tools.AccessWrite,
		Surfaces: []string{"main", "target", tools.AutomationSurface},
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(_ context.Context, d *db.DB, call tools.Call) (any, error) {
			row, err := d.GetAgentAction(call.ActionID)
			if err != nil || row == nil {
				return nil, errors.New("row not readable inside Execute")
			}
			f.mu.Lock()
			defer f.mu.Unlock()
			f.calls = append(f.calls, call)
			f.statuses = append(f.statuses, row.Status)
			return map[string]any{"ok": true}, nil
		},
	}
	if tweak != nil {
		tweak(tl)
	}
	return tl
}

func (f *autoFixture) executed() ([]tools.Call, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]tools.Call(nil), f.calls...), append([]string(nil), f.statuses...)
}

func autoRecipe(name, body string) string {
	return "---\nname: " + name + "\ntrigger:\n  manual: true\npermissions:\n  - llm:light\noutputs: [inbox]\n---\n" +
		"Writes for the registry tests.\n\n```js\n" + body + "\n```\n"
}

// seedAuto indexes, confirms and enables a personal automation.
func (f *autoFixture) seedAuto(t *testing.T, slug, body string) db.Automation {
	t.Helper()
	return automationstest.SeedAutomation(t, f.d, autoRecipe(slug, body), automationstest.SeedOptions{Slug: slug})
}

// claimRun queues and claims a run of automation id with its current
// approval hash, the way the executor does.
func (f *autoFixture) claimRun(t *testing.T, id int64) int64 {
	t.Helper()
	a, err := f.d.GetAutomation(id)
	require.NoError(t, err)
	now := time.Now()
	runID, coalesced, err := f.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: now})
	require.NoError(t, err)
	require.False(t, coalesced)
	ok, err := f.d.ClaimAutomationRun(runID, a.ApprovalHash, a.RecipeText, a.BudgetTokens, a.BudgetMinutes, now)
	require.NoError(t, err)
	require.True(t, ok)
	return runID
}

func (f *autoFixture) grant(t *testing.T, id int64, tool string) {
	t.Helper()
	a, err := f.d.GetAutomation(id)
	require.NoError(t, err)
	require.NoError(t, f.d.SetAutomationToolGrant(id, tool, a.ApprovalHash, time.Now()))
}

func autoBinding(runID int64) tools.Binding {
	return tools.Binding{
		Surface: tools.AutomationSurface, ContextType: tools.AutomationContextType,
		ContextID: strconv.FormatInt(runID, 10), AutomationRunID: runID,
	}
}

func (f *autoFixture) propose(t *testing.T, tool string, b tools.Binding) (tools.Receipt, *db.AgentAction) {
	t.Helper()
	rc, err := f.reg.Propose(context.Background(), tool, json.RawMessage(autoCallArgs), b)
	require.NoError(t, err)
	row, err := f.d.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	require.NotNil(t, row)
	return rc, row
}

// assertPendingAsk: the call is one pending row recorded with trust ask, and
// nothing executed.
func (f *autoFixture) assertPendingAsk(t *testing.T, rc tools.Receipt, row *db.AgentAction, msg string) {
	t.Helper()
	assert.Equal(t, "pending", rc.Status, msg)
	assert.Equal(t, "pending", row.Status, msg)
	assert.Equal(t, string(tools.TrustAsk), row.TrustAtCreate, msg)
	assert.False(t, rc.Auto, msg)
	calls, _ := f.executed()
	assert.Empty(t, calls, msg)
}

func TestTrustOrder_AutomationSurface(t *testing.T) {
	cases := []struct {
		name      string
		tool      string
		grant     bool
		trust     map[string]tools.Trust // surface → trust row, written straight to tool_trust
		agent     bool
		wantTrust tools.Trust
		wantAuto  bool
	}{
		{name: "always-ask beats a grant", tool: "bulk_write", grant: true, wantTrust: tools.TrustAsk},
		{name: "external with an active grant", tool: "ext_write", grant: true, wantTrust: tools.TrustExecute, wantAuto: true},
		{name: "external without a grant", tool: "ext_write", wantTrust: tools.TrustAsk},
		{name: "external ignores an execute trust row", tool: "ext_write",
			trust: map[string]tools.Trust{tools.AutomationSurface: tools.TrustExecute}, wantTrust: tools.TrustAsk},
		{name: "local with automation execute trust", tool: "local_write",
			trust: map[string]tools.Trust{tools.AutomationSurface: tools.TrustExecute}, wantTrust: tools.TrustExecute},
		{name: "local without a trust row", tool: "local_write", wantTrust: tools.TrustAsk},
		{name: "local with execute on main only", tool: "local_write",
			trust: map[string]tools.Trust{"main": tools.TrustExecute}, wantTrust: tools.TrustAsk},
		{name: "local with an active grant", tool: "local_write", grant: true, wantTrust: tools.TrustExecute, wantAuto: true},
		{name: "local with a grant and execute trust: the grant decides", tool: "local_write", grant: true,
			trust: map[string]tools.Trust{tools.AutomationSurface: tools.TrustExecute}, wantTrust: tools.TrustExecute, wantAuto: true},
		{name: "local execute trust whose Ready fails", tool: "local_pick",
			trust: map[string]tools.Trust{tools.AutomationSurface: tools.TrustExecute}, wantTrust: tools.TrustAsk},
		{name: "agent() call under an active grant", tool: "ext_write", grant: true, agent: true, wantTrust: tools.TrustAsk},
		{name: "agent() call under execute trust", tool: "local_write", agent: true,
			trust: map[string]tools.Trust{tools.AutomationSurface: tools.TrustExecute}, wantTrust: tools.TrustAsk},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newAutoFixture(t)
			a := f.seedAuto(t, "order", `llm("x")`)
			if tc.grant {
				f.grant(t, a.ID, tc.tool)
			}
			for surface, trust := range tc.trust {
				require.NoError(t, f.d.SetToolTrust(tc.tool, surface, string(trust)))
			}
			b := autoBinding(f.claimRun(t, a.ID))
			b.AutomationAgent = tc.agent
			rc, row := f.propose(t, tc.tool, b)
			assert.Equal(t, string(tc.wantTrust), row.TrustAtCreate)
			assert.Equal(t, tc.wantAuto, rc.Auto)
			calls, _ := f.executed()
			if tc.wantTrust == tools.TrustExecute {
				assert.Equal(t, "applied", row.Status)
				assert.Len(t, calls, 1)
			} else {
				f.assertPendingAsk(t, rc, row, tc.name)
			}
		})
	}
}

func TestAgent03_AutoGrantAppliesExternalOnlyOnAutomationSurfaceWithMatchingHash(t *testing.T) {
	f := newAutoFixture(t)
	a := f.seedAuto(t, "poster", `llm("x")`)
	f.grant(t, a.ID, "ext_write")
	run := f.claimRun(t, a.ID)

	rc, row := f.propose(t, "ext_write", autoBinding(run))
	assert.Equal(t, "applied", rc.Status)
	assert.True(t, rc.Auto)
	assert.Equal(t, "applied", row.Status)
	assert.Equal(t, string(tools.TrustExecute), row.TrustAtCreate)
	assert.Equal(t, tools.AutomationContextType, row.ContextType)
	assert.Equal(t, strconv.FormatInt(run, 10), row.ContextID)
	assert.True(t, row.External)
	calls, statuses := f.executed()
	require.Len(t, calls, 1, "Execute runs exactly once")
	assert.Equal(t, []string{"executing"}, statuses, "Execute ran under Apply's claim (AGENT-05)")
	assert.Equal(t, run, calls[0].Binding.AutomationRunID)
	var rows int
	require.NoError(t, f.d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&rows))
	assert.Equal(t, 1, rows, "an auto write is one agent_actions row")
}

func TestAgent03_AutoGrantNeverCoversAnotherAutomationOrSurface(t *testing.T) {
	f := newAutoFixture(t)
	granted := f.seedAuto(t, "granted", `llm("a")`)
	other := f.seedAuto(t, "other", `llm("b")`)
	f.grant(t, granted.ID, "ext_write")
	otherRun := f.claimRun(t, other.ID)
	grantedRun := f.claimRun(t, granted.ID)

	rc, row := f.propose(t, "ext_write", autoBinding(otherRun))
	f.assertPendingAsk(t, rc, row, "a run of another automation")

	// Another surface never reads a grant, and a run's context off the
	// automation surface is refused outright: no row, nothing executed.
	for _, surface := range []string{"main", "target"} {
		withRun := autoBinding(grantedRun)
		withRun.Surface = surface
		contextOnly := tools.Binding{Surface: surface, ContextType: tools.AutomationContextType,
			ContextID: strconv.FormatInt(grantedRun, 10)}
		for name, b := range map[string]tools.Binding{"run id": withRun, "context only": contextOnly} {
			_, err := f.reg.Propose(context.Background(), "ext_write", json.RawMessage(autoCallArgs), b)
			var verr *tools.ValidationError
			require.ErrorAs(t, err, &verr, surface+" "+name)
			assert.Contains(t, verr.Msg, "valid only on the automation surface", surface+" "+name)
		}
		rc, row := f.propose(t, "ext_write", tools.Binding{Surface: surface})
		f.assertPendingAsk(t, rc, row, "a plain "+surface+" call of the granted tool")
	}
	var rows int
	require.NoError(t, f.d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&rows))
	assert.Equal(t, 3, rows, "only the other automation's call and the two plain calls are recorded")
}

func TestAgent03_RecipeEditMakesAutoGrantInactive(t *testing.T) {
	f := newAutoFixture(t)
	a := f.seedAuto(t, "editable", `llm("v1")`)
	f.grant(t, a.ID, "ext_write")
	oldRun := f.claimRun(t, a.ID)

	// The script changes on disk: the rescan writes a new approval_hash.
	edited := automationstest.SeedAutomation(t, f.d, autoRecipe("editable", `llm("v2")`),
		automationstest.SeedOptions{Slug: "editable", Unconfirmed: true})
	require.NotEqual(t, a.ApprovalHash, edited.ApprovalHash)
	rc, row := f.propose(t, "ext_write", autoBinding(oldRun))
	f.assertPendingAsk(t, rc, row, "after the edit, before a re-grant")

	// The owner re-confirms and re-grants the new hash; the run claimed under
	// the old recipe still does not qualify.
	require.NoError(t, f.d.ConfirmAutomation(a.ID, edited.ApprovalHash, time.Now()))
	f.grant(t, a.ID, "ext_write")
	rc, row = f.propose(t, "ext_write", autoBinding(oldRun))
	f.assertPendingAsk(t, rc, row, "a run claimed with the old recipe_hash")

	// Concurrency 1: the old run ends before the next one is claimed.
	ended, err := f.d.CancelAutomationRun(oldRun, time.Now())
	require.NoError(t, err)
	require.True(t, ended)
	rc, row = f.propose(t, "ext_write", autoBinding(f.claimRun(t, a.ID)))
	assert.Equal(t, "applied", row.Status, "a run of the re-granted recipe")
	assert.True(t, rc.Auto)
}

func TestAgent03_AlwaysAskIsNeverAuto(t *testing.T) {
	f := newAutoFixture(t)
	a := f.seedAuto(t, "bulk", `llm("x")`)
	_, err := f.d.Exec(`INSERT INTO automation_tool_grants (automation_id, tool, grant_hash) VALUES (?, 'bulk_write', ?)`,
		a.ID, a.ApprovalHash)
	require.NoError(t, err)
	require.NoError(t, f.d.SetToolTrust("bulk_write", tools.AutomationSurface, string(tools.TrustExecute)))

	rc, row := f.propose(t, "bulk_write", autoBinding(f.claimRun(t, a.ID)))
	f.assertPendingAsk(t, rc, row, "an AlwaysAsk tool under a forced grant and execute trust")
}

// guardTableCounts counts every table but agent_actions and the run rows the
// fixture itself writes before the call.
func guardTableCounts(t *testing.T, d *db.DB) map[string]int {
	t.Helper()
	rows, err := d.Query(`SELECT name FROM sqlite_master WHERE type = 'table'
		AND name NOT LIKE 'sqlite_%' AND name <> 'agent_actions' ORDER BY name`)
	require.NoError(t, err)
	var names []string
	for rows.Next() {
		var n string
		require.NoError(t, rows.Scan(&n))
		names = append(names, n)
	}
	require.NoError(t, rows.Err())
	require.NoError(t, rows.Close())
	out := make(map[string]int, len(names))
	for _, n := range names {
		var c int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM "`+n+`"`).Scan(&c))
		out[n] = c
	}
	return out
}

func TestAgent01_AutomationWriteRecordsProposalOnly(t *testing.T) {
	f := newAutoFixture(t)
	a := f.seedAuto(t, "proposer", `llm("x")`)
	run := f.claimRun(t, a.ID)
	before := guardTableCounts(t, f.d)

	rc, row := f.propose(t, "local_write", autoBinding(run))
	f.assertPendingAsk(t, rc, row, "no grant, no trust")
	assert.Equal(t, before, guardTableCounts(t, f.d), "no table but agent_actions changes on propose")
	var rows int
	require.NoError(t, f.d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&rows))
	assert.Equal(t, 1, rows)
	assert.Contains(t, rc.Message, "Inbox", "an automation has no chat card; the proposal waits in the Inbox")
}

func TestAutoGrant_NotReadyRecordsPending(t *testing.T) {
	f := newAutoFixture(t)
	a := f.seedAuto(t, "picker", `llm("x")`)
	f.grant(t, a.ID, "ext_pick")

	rc, row := f.propose(t, "ext_pick", autoBinding(f.claimRun(t, a.ID)))
	f.assertPendingAsk(t, rc, row, "an auto write whose Ready fails waits for the owner's pick")
}

func TestAutoGrant_FailedExecuteIsNotAuto(t *testing.T) {
	f := newAutoFixture(t)
	a := f.seedAuto(t, "failing", `llm("x")`)
	f.grant(t, a.ID, "ext_fail")

	rc, row := f.propose(t, "ext_fail", autoBinding(f.claimRun(t, a.ID)))
	assert.Equal(t, "failed", rc.Status)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, string(tools.TrustExecute), row.TrustAtCreate, "the grant decided execute")
	assert.False(t, rc.Auto, "a failed auto write is no auto=1 step")
	assert.Contains(t, rc.Error, "the remote side refused")
}

func TestProposalRow_WorkbenchAutomationKeepsRunContext(t *testing.T) {
	f := newAutoFixture(t)
	folder, err := db.ResolveWorkbenchFolder(t.TempDir(), nil)
	require.NoError(t, err)
	wb, err := f.d.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	a := automationstest.SeedAutomation(t, f.d, autoRecipe("wbauto", `llm("x")`), automationstest.SeedOptions{
		Slug: "wbauto", Scope: automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: wb},
	})
	run := f.claimRun(t, a.ID)
	b := autoBinding(run)
	b.WorkbenchID = wb

	rc, row := f.propose(t, "local_write", b)
	assert.Equal(t, tools.AutomationContextType, row.ContextType, "not the workbench context")
	assert.Equal(t, strconv.FormatInt(run, 10), row.ContextID)

	ok, err := f.reg.Approve(context.Background(), rc.ActionID, nil)
	require.NoError(t, err)
	require.True(t, ok)
	applied, err := f.reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", applied.Status)
	calls, _ := f.executed()
	require.Len(t, calls, 1)
	assert.Equal(t, run, calls[0].Binding.AutomationRunID, "Apply rebuilds the run from the row")
	assert.Equal(t, tools.AutomationSurface, calls[0].Binding.Surface)
}

func TestAutomationBinding_DirectApplyRefused(t *testing.T) {
	f := newAutoFixture(t)
	a := f.seedAuto(t, "direct", `llm("x")`)
	run := f.claimRun(t, a.ID)
	withRunOnMain := autoBinding(run)
	withRunOnMain.Surface = "main"
	for name, tc := range map[string]struct {
		b    tools.Binding
		want string
	}{
		"automation surface":       {autoBinding(run), "automations never apply directly"},
		"automation surface no id": {tools.Binding{Surface: tools.AutomationSurface}, "automations never apply directly"},
		"automation run on main":   {withRunOnMain, "valid only on the automation surface"},
	} {
		tc.b.DirectApply = true
		_, err := f.reg.Propose(context.Background(), "local_write", json.RawMessage(autoCallArgs), tc.b)
		var verr *tools.ValidationError
		require.ErrorAs(t, err, &verr, name)
		assert.Contains(t, verr.Msg, tc.want, name)
	}
	var rows int
	require.NoError(t, f.d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&rows))
	assert.Zero(t, rows, "a refused call writes no row")
	calls, _ := f.executed()
	assert.Empty(t, calls)
}

// P2 makes the automation surface a trust place (spec §6.2 step 4): SetTrust
// takes it for a local write tool on it, and External/AlwaysAsk stay refused.
func TestSetTrust_AutomationSurfaceIsATrustPlace(t *testing.T) {
	f := newAutoFixture(t)
	require.NoError(t, f.reg.SetTrust("local_write", tools.AutomationSurface, tools.TrustExecute))
	got, err := f.reg.Trust("local_write", tools.AutomationSurface)
	require.NoError(t, err)
	assert.Equal(t, tools.TrustExecute, got)
	require.ErrorIs(t, f.reg.SetTrust("ext_write", tools.AutomationSurface, tools.TrustExecute), tools.ErrExternalExecute)
	require.ErrorIs(t, f.reg.SetTrust("bulk_write", tools.AutomationSurface, tools.TrustExecute), tools.ErrAlwaysAsk)
	tl, ok := f.reg.Get("local_write")
	require.True(t, ok)
	assert.Equal(t, []string{"main", "target", tools.AutomationSurface}, tools.TrustSurfaces(tl))
}
