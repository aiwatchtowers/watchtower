package tools

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

type echoArgs struct {
	Text   string `json:"text"`
	Reason string `json:"reason"`
}

// newEchoTool is a write tool whose Execute records what it was called with.
func newEchoTool(t *testing.T, external bool, executed *[]Call) *Tool {
	t.Helper()
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	return &Tool{
		Name: "echo", Description: "test tool", InputSchema: schema,
		Access: AccessWrite, External: external, Surfaces: []string{"main"},
		Validate: func(_ context.Context, _ *db.DB, raw json.RawMessage) error {
			var a echoArgs
			if err := json.Unmarshal(raw, &a); err != nil {
				return &ValidationError{Msg: "bad json"}
			}
			if a.Text == "" {
				return &ValidationError{Msg: "text is required"}
			}
			return nil
		},
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			*executed = append(*executed, call)
			return map[string]any{"echoed": true}, nil
		},
	}
}

func openDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(filepath.Join(t.TempDir(), "t.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	return database
}

func TestPropose_RecordsPendingAndNeverExecutes(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))

	rc, err := reg.Propose(context.Background(), "echo",
		json.RawMessage(`{"text":"hi","reason":"because"}`),
		Binding{Surface: "main", ConversationID: 4, TurnID: "t1"})
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)
	assert.Contains(t, rc.Message, "do not claim it is done")
	assert.Empty(t, executed, "a write tool must not execute on propose (AGENT-01)")

	row, err := database.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "because", row.Reason)
	assert.Equal(t, "main", row.Surface)
	assert.Equal(t, int64(4), row.ConversationID)
	assert.Equal(t, "t1", row.TurnID)
}

func TestPropose_ValidationErrorWritesNoRow(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))

	_, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"reason":"x"}`), Binding{})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	rows, _ := database.ListAgentActions(db.AgentActionFilter{})
	assert.Empty(t, rows)
}

func TestPropose_InvalidJSONWritesNoRow(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))

	_, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{not json`), Binding{})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	rows, _ := database.ListAgentActions(db.AgentActionFilter{})
	assert.Empty(t, rows)
	assert.Empty(t, executed)
}

func TestPropose_MissingReasonWritesNoRow(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))

	// text is present (so the tool's own Validate passes) but reason is not.
	_, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"text":"hi"}`), Binding{})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	rows, _ := database.ListAgentActions(db.AgentActionFilter{})
	assert.Empty(t, rows)
	assert.Empty(t, executed)
}

func TestPropose_UnknownOrReadToolRejected(t *testing.T) {
	reg := New(openDB(t))
	_, err := reg.Propose(context.Background(), "nope", json.RawMessage(`{}`), Binding{})
	assert.ErrorIs(t, err, ErrUnknownTool)
}

func TestApply_ExecutesOnceAndRecordsResult(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	rc, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	require.NoError(t, err)

	// pending is not applicable — the owner has to approve first.
	_, err = reg.Apply(context.Background(), rc.ActionID)
	assert.ErrorIs(t, err, ErrBadTransition)

	ok, err := database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)

	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status)
	assert.JSONEq(t, `{"echoed":true}`, row.ResultJSON)
	assert.Len(t, executed, 1)
	assert.Equal(t, rc.ActionID, executed[0].ActionID)

	// AGENT-05: applied is terminal.
	_, err = reg.Apply(context.Background(), rc.ActionID)
	assert.ErrorIs(t, err, ErrBadTransition)
	assert.Len(t, executed, 1)
}

func TestApply_FailureLandsFailedAndIsRetriable(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	calls := 0
	schema, _ := jsonschema.For[echoArgs](nil)
	require.NoError(t, reg.Register(&Tool{
		Name: "flaky", Description: "x", InputSchema: schema, Access: AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(context.Context, *db.DB, Call) (any, error) {
			calls++
			if calls == 1 {
				return nil, errors.New("boom")
			}
			return map[string]any{"ok": true}, nil
		},
	}))
	rc, _ := reg.Propose(context.Background(), "flaky", json.RawMessage(`{"reason":"r"}`), Binding{})
	_, _ = database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")

	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "boom", row.Error)

	row, err = reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status)
	assert.Empty(t, row.Error)
}

// TestApply_LostRaceDuringExecuteReturnsBadTransition pins that a status
// change that lands while Execute is in flight (the owner rejects the
// action in the Desktop while the tool call is running) is surfaced as
// ErrBadTransition rather than silently reported as applied — and that the
// row is left in whatever state won the race, not overwritten.
func TestApply_LostRaceDuringExecuteReturnsBadTransition(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	require.NoError(t, reg.Register(&Tool{
		Name: "racy", Description: "x", InputSchema: schema, Access: AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			// Simulate the owner rejecting the action in the Desktop while
			// this Execute call is still running.
			ok, terr := database.TransitionAgentAction(call.ActionID, []string{"approved"}, "rejected", "", "")
			require.NoError(t, terr)
			require.True(t, ok)
			return map[string]any{"ok": true}, nil
		},
	}))
	rc, err := reg.Propose(context.Background(), "racy", json.RawMessage(`{"reason":"r"}`), Binding{})
	require.NoError(t, err)
	ok, err := database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)

	_, err = reg.Apply(context.Background(), rc.ActionID)
	assert.ErrorIs(t, err, ErrBadTransition)

	row, err := database.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "rejected", row.Status, "the rejection that won the race must not be overwritten by applied")
}

// TestApply_RowGoneOnReReadIsNotFound pins that Apply never returns
// (nil, nil): a row missing on read is reported as ErrNotFound. Production
// never deletes agent_actions rows; this only forces the state the guard
// defends against.
func TestApply_RowGoneOnReReadIsNotFound(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	rc, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	require.NoError(t, err)
	ok, err := database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)

	_, err = database.Exec(`DELETE FROM agent_actions WHERE id = ?`, rc.ActionID)
	require.NoError(t, err)

	row, err := reg.Apply(context.Background(), rc.ActionID)
	assert.Nil(t, row)
	assert.ErrorIs(t, err, ErrNotFound)
}

func TestAgent03_ExternalToolCannotBeExecuteTrust(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, true, &executed)))

	err := reg.SetTrust("echo", TrustExecute)
	assert.ErrorIs(t, err, ErrExternalExecute)
	trust, _ := reg.Trust("echo")
	assert.Equal(t, TrustAsk, trust)
	assert.ErrorIs(t, reg.SetTrust("nope", TrustAsk), ErrUnknownTool)
}

func TestPropose_ExecuteTrustAppliesInline(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	require.NoError(t, reg.SetTrust("echo", TrustExecute))

	rc, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	require.NoError(t, err)
	assert.Equal(t, "applied", rc.Status)
	assert.Len(t, executed, 1)
	row, _ := database.GetAgentAction(rc.ActionID)
	assert.Equal(t, "execute", row.TrustAtCreate)
	assert.NotEmpty(t, row.DecidedAt)
}

func TestList_FiltersBySurface(t *testing.T) {
	reg := New(openDB(t))
	var executed []Call
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	assert.Len(t, reg.List("main"), 1)
	assert.Empty(t, reg.List("target"))
	assert.Error(t, reg.Register(newEchoTool(t, false, &executed)), "duplicate name")
}

func TestAll_ReturnsEveryToolInRegistrationOrder(t *testing.T) {
	reg := New(openDB(t))
	var executed []Call
	echo := newEchoTool(t, false, &executed)
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	other := &Tool{
		Name: "other", Description: "x", InputSchema: schema, Access: AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute:  func(context.Context, *db.DB, Call) (any, error) { return nil, nil },
	}
	require.NoError(t, reg.Register(echo))
	require.NoError(t, reg.Register(other))

	all := reg.All()
	require.Len(t, all, 2)
	assert.Equal(t, "echo", all[0].Name)
	assert.Equal(t, "other", all[1].Name)
}
