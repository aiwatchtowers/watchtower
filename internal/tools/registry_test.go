package tools

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"

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

// newLooseTool is a write tool whose own Validate accepts ANY arguments, so a
// rejection can only have come from the schema layer — `echoArgs` marks both
// `text` and `reason` required.
func newLooseTool(t *testing.T) *Tool {
	t.Helper()
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	return &Tool{
		Name: "loose", Description: "test tool", InputSchema: schema, Access: AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute:  func(context.Context, *db.DB, Call) (any, error) { return map[string]any{"ok": true}, nil },
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

	// A read tool is registered but can never be proposed — the proposal flow
	// exists for writes only.
	require.NoError(t, reg.Register(&Tool{Name: "read_thing", Description: "x", Access: AccessRead}))
	_, err = reg.Propose(context.Background(), "read_thing", json.RawMessage(`{}`), Binding{})
	assert.ErrorIs(t, err, ErrNotWritable)
}

// Spec §4: schema validation runs BEFORE the tool's own semantic Validate, so
// a call missing a required argument is rejected even by a tool that would
// have accepted it — and no row is written.
func TestPropose_SchemaRejectsMissingRequiredField(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	require.NoError(t, reg.Register(newLooseTool(t)))

	_, err := reg.Propose(context.Background(), "loose", json.RawMessage(`{"reason":"r"}`), Binding{})
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "text", "the schema message must name the missing argument")
	rows, _ := database.ListAgentActions(db.AgentActionFilter{})
	assert.Empty(t, rows)
}

// RunDirect (the CLI face) gets a tool that never went through Register, so it
// resolves the schema itself — the same gate, before Validate and Execute.
func TestRunDirect_SchemaRejectsMissingRequiredField(t *testing.T) {
	database := openDB(t)
	tool := newLooseTool(t)

	_, err := RunDirect(context.Background(), database, tool, json.RawMessage(`{"reason":"r"}`))
	var verr *ValidationError
	require.ErrorAs(t, err, &verr)
	assert.Contains(t, verr.Msg, "text")

	out, err := RunDirect(context.Background(), database, tool, json.RawMessage(`{"text":"hi","reason":"r"}`))
	require.NoError(t, err)
	assert.Equal(t, map[string]any{"ok": true}, out)
}

func TestRegister_RejectsUnknownAccess(t *testing.T) {
	reg := New(openDB(t))
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	err = reg.Register(&Tool{
		Name: "bogus", Description: "x", InputSchema: schema, Access: Access("bogus"),
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute:  func(context.Context, *db.DB, Call) (any, error) { return nil, nil },
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "access")
	_, ok := reg.Get("bogus")
	assert.False(t, ok, "a rejected tool must not land in the registry")
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
	rc, _ := reg.Propose(context.Background(), "flaky", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
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

// TestApply_ClaimPreservesPriorErrorUntilFinish pins the fix for the claim
// wiping a failed row's error text: `approved|failed → executing` used to
// write error="" unconditionally, so a process that died mid-execute left an
// `executing` row with no trace of the failure that led to the retry — the
// audit trail (agent_actions rows are never deleted) lost the very thing it
// exists to keep. The claim must carry the row's existing error through
// until the new outcome overwrites it.
func TestApply_ClaimPreservesPriorErrorUntilFinish(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	calls := 0
	var errorWhileExecuting string
	schema, _ := jsonschema.For[echoArgs](nil)
	require.NoError(t, reg.Register(&Tool{
		Name: "retry", Description: "x", InputSchema: schema, Access: AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			calls++
			row, err := database.GetAgentAction(call.ActionID)
			require.NoError(t, err)
			errorWhileExecuting = row.Error
			if calls == 1 {
				return nil, errors.New("boom")
			}
			return map[string]any{"ok": true}, nil
		},
	}))
	rc, _ := reg.Propose(context.Background(), "retry", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	_, _ = database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")

	row, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "boom", row.Error)
	assert.Empty(t, errorWhileExecuting, "the first attempt has no prior failure to preserve")

	// Retry: while the second Execute runs, the row is `executing` and must
	// still read the PRIOR failure's error, not "" — the claim UPDATE must
	// not wipe it ahead of the new outcome.
	row, err = reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status)
	assert.Empty(t, row.Error, "a successful retry clears the old error")
	assert.Equal(t, "boom", errorWhileExecuting, "the claim must preserve the prior failure's error while executing")
}

// TestAgent05_RejectDuringExecuteCannotStealTheClaim pins the other half of
// the claim: once Apply has moved the row to `executing`, a decision that
// lands while Execute is in flight (the owner hitting Reject in the Desktop)
// no longer matches, so the apply that is ALREADY performing the side effect
// finishes and records it. Before the claim this same race left the write
// done and the row `rejected`.
func TestAgent05_RejectDuringExecuteCannotStealTheClaim(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	var rejectMatched bool
	require.NoError(t, reg.Register(&Tool{
		Name: "racy", Description: "x", InputSchema: schema, Access: AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			// The owner rejects the action in the Desktop while this Execute
			// call is still running: the row is claimed, so nothing matches.
			ok, terr := database.TransitionAgentAction(call.ActionID, []string{"pending", "approved"}, "rejected", "", "")
			require.NoError(t, terr)
			rejectMatched = ok
			return map[string]any{"ok": true}, nil
		},
	}))
	rc, err := reg.Propose(context.Background(), "racy", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	require.NoError(t, err)
	ok, err := database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)

	applied, err := reg.Apply(context.Background(), rc.ActionID)
	require.NoError(t, err)
	assert.False(t, rejectMatched, "a claimed row must not be decidable from under the apply that holds it")
	assert.Equal(t, "applied", applied.Status)

	row, err := database.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status)
}

// TestAgent05_ConcurrentApplyExecutesOnce is the guard the claim exists for:
// two overlapping applies on one approved row must produce exactly one side
// effect. The loser has to be refused BEFORE Execute, not after — a
// check-then-execute-then-CAS Apply passes the status assertions and still
// files two Jira issues.
func TestAgent05_ConcurrentApplyExecutesOnce(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	release := make(chan struct{})
	entered := make(chan struct{}, 2)
	var mu sync.Mutex
	executions := 0
	require.NoError(t, reg.Register(&Tool{
		Name: "slow", Description: "x", InputSchema: schema, Access: AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(context.Context, *db.DB, Call) (any, error) {
			mu.Lock()
			executions++
			mu.Unlock()
			entered <- struct{}{}
			<-release
			return map[string]any{"ok": true}, nil
		},
	}))
	rc, err := reg.Propose(context.Background(), "slow", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	require.NoError(t, err)
	ok, err := database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)

	type outcome struct {
		row *db.AgentAction
		err error
	}
	results := make(chan outcome, 2)
	for range 2 {
		go func() {
			row, err := reg.Apply(context.Background(), rc.ActionID)
			results <- outcome{row, err}
		}()
	}

	<-entered // one Apply holds the claim and is inside Execute
	// The winner cannot answer while it is blocked, so this is the loser. If
	// nothing answers, the second Apply is blocked inside Execute too — which
	// is exactly the defect, so say so instead of deadlocking the suite.
	select {
	case loser := <-results:
		assert.ErrorIs(t, loser.err, ErrBadTransition)
		assert.Nil(t, loser.row)
	case <-time.After(5 * time.Second):
		close(release)
		t.Fatal("the second Apply reached Execute: the claim did not refuse it")
	}

	close(release)
	winner := <-results
	require.NoError(t, winner.err)
	assert.Equal(t, "applied", winner.row.Status)

	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, 1, executions, "the claim must keep the second apply out of Execute entirely")
}

// TestApply_ExecutingIsNotApplicable pins that a row stranded in `executing`
// by an interrupted apply is refused like any other non-applicable state —
// reclaiming it is the CLI's `--force` job, never an implicit retry.
func TestApply_ExecutingIsNotApplicable(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	rc, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	require.NoError(t, err)
	ok, err := database.TransitionAgentAction(rc.ActionID, []string{"pending"}, "executing", "", "")
	require.NoError(t, err)
	require.True(t, ok)

	_, err = reg.Apply(context.Background(), rc.ActionID)
	assert.ErrorIs(t, err, ErrBadTransition)
	assert.Empty(t, executed)
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

// AGENT-03 is enforced on the read side too: db.SetToolTrust is exported and
// does not know about External, and a trust row keyed by tool NAME outlives a
// tool later being marked External — so Propose re-checks rather than trusting
// the persisted value.
func TestAgent03_ExternalToolNeverExecutesFromAPersistedTrustRow(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, true, &executed)))
	// Written behind the registry's back, exactly as a pre-External row would be.
	require.NoError(t, database.SetToolTrust("echo", "execute"))

	rc, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	require.NoError(t, err)
	assert.Equal(t, "pending", rc.Status)
	assert.Empty(t, executed, "an external tool can never execute without an approval")
	row, err := database.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "pending", row.Status)
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

// TestPropose_ExecuteTrustSurfacesRowWhenApplyErrors pins the fix for the
// execute-trust path returning a bare Receipt{} when Apply itself errors
// after the row was already inserted: the model must still learn the action
// id (and the row's own terminal status/error) instead of being told nothing
// was recorded, which risks a duplicate re-propose. Racing the row out of
// `executing` from inside Execute forces Apply's own finishTransition CAS to
// fail — a real (if rare) way for Apply to return an error while the row
// still exists.
func TestPropose_ExecuteTrustSurfacesRowWhenApplyErrors(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	schema, err := jsonschema.For[echoArgs](nil)
	require.NoError(t, err)
	require.NoError(t, reg.Register(&Tool{
		Name: "stolen", Description: "x", InputSchema: schema, Access: AccessWrite,
		Validate: func(context.Context, *db.DB, json.RawMessage) error { return nil },
		Execute: func(_ context.Context, _ *db.DB, call Call) (any, error) {
			// Simulate another process finishing the row out from under this
			// Apply before its own finishTransition runs: Apply's claim left
			// it `executing`, so this direct write is what a concurrent actor
			// would have to do to race it away.
			ok, terr := database.TransitionAgentAction(call.ActionID, []string{"executing"}, "failed", "", "boom")
			require.NoError(t, terr)
			require.True(t, ok)
			return nil, errors.New("boom")
		},
	}))
	require.NoError(t, reg.SetTrust("stolen", TrustExecute))

	rc, err := reg.Propose(context.Background(), "stolen", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{})
	require.NoError(t, err, "the model must not be told a proposal failed to record when the row exists")
	assert.NotZero(t, rc.ActionID, "the model must learn the action id even when execution failed")
	assert.Equal(t, "failed", rc.Status)
	assert.Equal(t, "boom", rc.Error)
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
