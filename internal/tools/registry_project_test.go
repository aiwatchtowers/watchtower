package tools

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedProject creates a project bound to a fresh temp folder and returns its id.
func seedProject(t *testing.T, d *db.DB, name string) int64 {
	t.Helper()
	folder, err := db.ResolveProjectFolder(t.TempDir())
	require.NoError(t, err)
	id, err := d.CreateProject(name, folder)
	require.NoError(t, err)
	return id
}

// newProjectEchoTool is a write tool on the given surfaces that records every
// Execute call, so a test can see whether and with which binding it ran.
func newProjectEchoTool(t *testing.T, external bool, surfaces []string, executed *[]Call) *Tool {
	t.Helper()
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	return &Tool{
		Name: "pecho", Description: "test tool", InputSchema: schema,
		Access: AccessWrite, External: external, Surfaces: surfaces,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			*executed = append(*executed, call)
			return map[string]any{"ok": true}, nil
		},
	}
}

func directBinding(projectID int64) Binding {
	return Binding{Surface: "project", ProjectID: projectID, DirectApply: true}
}

const pechoArgs = `{"text":"hi","reason":"r"}`

// DEV-06: DirectApply never runs an External tool — not even once, not as a
// pending proposal: the call is refused before any row is written.
func TestDev06_ExternalToolRefusedUnderDirectApply(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var executed []Call
	reg := New(d)
	require.NoError(t, reg.Register(newProjectEchoTool(t, true, []string{"project"}, &executed)))

	_, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), directBinding(pid))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "never runs in a direct-apply session")
	assert.Empty(t, executed, "an External tool must never execute under DirectApply")
	rows, err := d.ListAgentActions(db.AgentActionFilter{})
	require.NoError(t, err)
	assert.Empty(t, rows, "a refused direct-apply call writes no row")
}

// DirectApply applies a non-External tool inline with a full audit row, for
// this call only: the owner's stored trust stays "ask".
func TestDirectApply_AppliesInlineWithAuditRow(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var executed []Call
	reg := New(d)
	require.NoError(t, reg.Register(newProjectEchoTool(t, false, []string{"project"}, &executed)))

	rc, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), directBinding(pid))
	require.NoError(t, err)
	assert.Equal(t, "applied", rc.Status)
	require.Len(t, executed, 1)
	assert.Equal(t, pid, executed[0].Binding.ProjectID, "Execute sees the bound project")

	row, err := d.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status)
	assert.Equal(t, "execute", row.TrustAtCreate)
	assert.Equal(t, "project", row.ContextType)
	assert.Equal(t, strconv.FormatInt(pid, 10), row.ContextID)
	assert.Equal(t, "r", row.Reason)

	trust, err := reg.Trust("pecho")
	require.NoError(t, err)
	assert.Equal(t, TrustAsk, trust, "DirectApply is not global trust")
}

// A tool that does not name the project surface (or names none, which means
// "every surface") never inherits direct apply.
func TestDirectApply_RefusesToolNotOnTheSurface(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	for _, surfaces := range [][]string{nil, {"main"}} {
		var executed []Call
		reg := New(d)
		require.NoError(t, reg.Register(newProjectEchoTool(t, false, surfaces, &executed)))
		_, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), directBinding(pid))
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, "surfaces %v", surfaces)
		assert.Empty(t, executed)
	}
}

// Review Focus #5: once the bound project is deleted, every call — write or
// read, project tool or not — answers "project N no longer exists".
func TestProjectBinding_DeletedProjectAnswersNoLongerExists(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var executed, reads []Call
	reg := New(d)
	require.NoError(t, reg.Register(newProjectEchoTool(t, false, []string{"project"}, &executed)))
	require.NoError(t, reg.Register(newPeekTool(t, &reads)))
	require.NoError(t, d.DeleteProject(pid))
	want := "project " + strconv.FormatInt(pid, 10) + " no longer exists"

	_, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), directBinding(pid))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Equal(t, want, verr.Msg)

	_, err = reg.CallRead(context.Background(), "peek", json.RawMessage(`{"query":"x"}`), directBinding(pid))
	require.ErrorAs(t, err, &verr)
	assert.Equal(t, want, verr.Msg)
	assert.Empty(t, executed)
	assert.Empty(t, reads)
}

// CallRead hands the binding to Execute.
func TestCallRead_PassesBindingToExecute(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var reads []Call
	reg := New(d)
	require.NoError(t, reg.Register(newPeekTool(t, &reads)))

	_, err := reg.CallRead(context.Background(), "peek", json.RawMessage(`{"query":"x"}`), Binding{Surface: "project", ProjectID: pid})
	require.NoError(t, err)
	require.Len(t, reads, 1)
	assert.Equal(t, pid, reads[0].Binding.ProjectID)
}

// Scope runs in Propose (a refusal writes no row) and again in Apply against
// the binding rebuilt from the row: an approved project proposal whose
// project was deleted meanwhile fails instead of executing.
func TestScope_RunsInProposeAndAgainInApply(t *testing.T) {
	d := openDB(t)
	pid := seedProject(t, d, "acme")
	var executed []Call
	tool := newProjectEchoTool(t, false, []string{"project"}, &executed)
	var scoped []Binding
	tool.Scope = func(_ context.Context, _ *db.DB, raw json.RawMessage, b Binding) error {
		scoped = append(scoped, b)
		if string(raw) == `{"text":"bad","reason":"r"}` {
			return &ValidationError{Msg: "out of scope"}
		}
		return nil
	}
	reg := New(d)
	require.NoError(t, reg.Register(tool))
	bound := Binding{Surface: "project", ProjectID: pid} // ask trust: stays pending

	_, err := reg.Propose(context.Background(), "pecho", json.RawMessage(`{"text":"bad","reason":"r"}`), bound)
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	rows, _ := d.ListAgentActions(db.AgentActionFilter{})
	assert.Empty(t, rows, "a Scope refusal writes no row")

	rc, err := reg.Propose(context.Background(), "pecho", json.RawMessage(pechoArgs), bound)
	require.NoError(t, err)
	require.Equal(t, "pending", rc.Status)
	ok, err := d.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, d.DeleteProject(pid))

	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, "no longer exists")
	assert.Empty(t, executed, "a de-scoped row never executes")
	require.Len(t, scoped, 2, "Scope ran for both proposals, never again once the project was gone")
	assert.Equal(t, pid, scoped[1].ProjectID)
}
