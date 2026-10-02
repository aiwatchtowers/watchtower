package tools

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// DEV-06 rule 3 (amended 2026-10-02, owner decision on #166): an External tool
// that opts into ProposeUnderDirectApply and names the project surface is
// recorded as a PENDING proposal in a direct-apply session — one row, bound to
// the project, trust ask — and never executes there. The owner's Approve in
// the Desktop is the only way it runs.
func TestDev06_ProposeOnlyExternalToolLandsPendingUnderDirectApply(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var executed []Call
	tool := newProjectEchoTool(t, true, []string{"project"}, &executed)
	tool.ProposeUnderDirectApply = true
	reg := New(d)
	require.NoError(t, reg.Register(tool))
	// Even a stale execute trust row cannot run it (AGENT-03's read side).
	require.NoError(t, d.SetToolTrust("pecho", "execute"))

	rc, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), directBinding(pid))
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)
	assert.Contains(t, rc.Message, "Watchtower Desktop", "the agent is told where the owner approves it")
	assert.Empty(t, executed, "a propose-only tool never executes on propose")

	rows, err := d.ListAgentActions(db.AgentActionFilter{})
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, "pending", rows[0].Status)
	assert.Equal(t, "ask", rows[0].TrustAtCreate)
	assert.True(t, rows[0].External)
	assert.Equal(t, ProjectContextType, rows[0].ContextType)
	assert.Equal(t, strconv.FormatInt(pid, 10), rows[0].ContextID)

	// The owner approves; Apply runs it once, with the project binding.
	ok, err := reg.Approve(context.Background(), rc.ActionID, nil)
	require.NoError(t, err)
	require.True(t, ok)
	applied, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", applied.Status)
	require.Len(t, executed, 1)
	assert.Equal(t, pid, executed[0].Binding.ProjectID)
}

// The opt-in does not widen the surface rule: a propose-only tool that does
// not name the session's surface is still refused there, with no row.
func TestDirectApply_ProposeOnlyToolStillNeedsTheSurface(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var executed []Call
	tool := newProjectEchoTool(t, true, []string{"main"}, &executed)
	tool.ProposeUnderDirectApply = true
	reg := New(d)
	require.NoError(t, reg.Register(tool))

	_, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), directBinding(pid))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "not available on the project surface")
	rows, err := d.ListAgentActions(db.AgentActionFilter{})
	require.NoError(t, err)
	assert.Empty(t, rows)
}

// editableEchoTool takes a "text" edit and is ready only with a non-empty text.
func editableEchoTool(t *testing.T, executed *[]Call) *Tool {
	t.Helper()
	tool := newEchoTool(t, true, executed)
	tool.Revise = func(_ context.Context, _ *db.DB, stored, patch json.RawMessage) (json.RawMessage, error) {
		var p struct {
			Text *string `json:"text"`
		}
		if err := json.Unmarshal(patch, &p); err != nil {
			return nil, &ValidationError{Msg: "patch is not a JSON object"}
		}
		if p.Text == nil {
			return stored, nil
		}
		return mergeJSON(stored, map[string]any{"text": *p.Text})
	}
	tool.Ready = func(args json.RawMessage) error {
		var a echoArgs
		_ = json.Unmarshal(args, &a)
		if strings.TrimSpace(a.Text) == "" {
			return &ValidationError{Msg: "text is empty"}
		}
		return nil
	}
	return tool
}

func proposeEcho(t *testing.T, reg *Registry, args string) int64 {
	t.Helper()
	rc, err := reg.Propose(context.Background(), "echo", json.RawMessage(args), Binding{Surface: "main"})
	require.NoError(t, err)
	return rc.ActionID
}

func TestApprove_PatchLandsWithTheApprovalAndApplyRunsTheEditedArgs(t *testing.T) {
	d := openDB(t)
	var executed []Call
	reg := New(d)
	require.NoError(t, reg.Register(editableEchoTool(t, &executed)))
	id := proposeEcho(t, reg, `{"text":"draft","reason":"r"}`)

	ok, err := reg.Approve(context.Background(), id, json.RawMessage(`{"text":"edited"}`))
	require.NoError(t, err)
	require.True(t, ok)
	row, err := d.GetAgentAction(id)
	require.NoError(t, err)
	assert.Equal(t, "approved", row.Status)
	assert.JSONEq(t, `{"text":"edited","reason":"r"}`, row.ArgsJSON)

	_, err = reg.Apply(context.Background(), id)
	require.NoError(t, err)
	require.Len(t, executed, 1)
	assert.JSONEq(t, `{"text":"edited","reason":"r"}`, string(executed[0].Args), "Execute sees exactly what the owner approved")
}

func TestApprove_WithoutPatchIsThePlainTransition(t *testing.T) {
	d := openDB(t)
	var executed []Call
	reg := New(d)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	id := proposeEcho(t, reg, `{"text":"x","reason":"r"}`)

	ok, err := reg.Approve(context.Background(), id, nil)
	require.NoError(t, err)
	assert.True(t, ok)
	ok, err = reg.Approve(context.Background(), id, nil)
	require.NoError(t, err)
	assert.False(t, ok, "an approved row is not approved twice")
	assert.Empty(t, executed, "Approve only decides; Apply runs")

	_, err = reg.Approve(context.Background(), 9999, nil)
	assert.ErrorIs(t, err, ErrNotFound)
}

func TestApprove_RefusesAPatchForAToolWithoutRevise(t *testing.T) {
	d := openDB(t)
	var executed []Call
	reg := New(d)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	id := proposeEcho(t, reg, `{"text":"x","reason":"r"}`)

	_, err := reg.Approve(context.Background(), id, json.RawMessage(`{"text":"y"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	row, _ := d.GetAgentAction(id)
	assert.Equal(t, "pending", row.Status)
	assert.JSONEq(t, `{"text":"x","reason":"r"}`, row.ArgsJSON)
}

func TestApprove_NotReadyLeavesTheRowPendingAndUnchanged(t *testing.T) {
	d := openDB(t)
	var executed []Call
	reg := New(d)
	require.NoError(t, reg.Register(editableEchoTool(t, &executed)))
	id := proposeEcho(t, reg, `{"text":"draft","reason":"r"}`)

	_, err := reg.Approve(context.Background(), id, json.RawMessage(`{"text":"  "}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Equal(t, "text is empty", verr.Msg)
	row, _ := d.GetAgentAction(id)
	assert.Equal(t, "pending", row.Status)
	assert.JSONEq(t, `{"text":"draft","reason":"r"}`, row.ArgsJSON, "a refused edit is not saved")
}

func TestApprove_PatchOnADecidedRowIsNotApplied(t *testing.T) {
	d := openDB(t)
	var executed []Call
	reg := New(d)
	require.NoError(t, reg.Register(editableEchoTool(t, &executed)))
	id := proposeEcho(t, reg, `{"text":"draft","reason":"r"}`)
	ok, err := d.TransitionAgentAction(id, []string{"pending"}, "rejected", "", "")
	require.NoError(t, err)
	require.True(t, ok)

	ok, err = reg.Approve(context.Background(), id, json.RawMessage(`{"text":"late"}`))
	require.NoError(t, err)
	assert.False(t, ok)
	row, _ := d.GetAgentAction(id)
	assert.Equal(t, "rejected", row.Status)
	assert.JSONEq(t, `{"text":"draft","reason":"r"}`, row.ArgsJSON)
}

// Two edits racing: the one that read stale args is refused rather than
// approving text the owner did not see.
func TestApprove_EditRaceIsRefused(t *testing.T) {
	d := openDB(t)
	var executed []Call
	reg := New(d)
	tool := editableEchoTool(t, &executed)
	inner := tool.Revise
	tool.Revise = func(ctx context.Context, d *db.DB, stored, patch json.RawMessage) (json.RawMessage, error) {
		// Another writer changes the row between this read and the update.
		_, err := d.Exec(`UPDATE agent_actions SET args_json = '{"text":"other","reason":"r"}' WHERE status = 'pending'`)
		require.NoError(t, err)
		return inner(ctx, d, stored, patch)
	}
	require.NoError(t, reg.Register(tool))
	id := proposeEcho(t, reg, `{"text":"draft","reason":"r"}`)

	_, err := reg.Approve(context.Background(), id, json.RawMessage(`{"text":"mine"}`))
	require.Error(t, err)
	assert.True(t, errors.Is(err, ErrBadTransition))
	row, _ := d.GetAgentAction(id)
	assert.Equal(t, "pending", row.Status)
	assert.JSONEq(t, `{"text":"other","reason":"r"}`, row.ArgsJSON)
}
