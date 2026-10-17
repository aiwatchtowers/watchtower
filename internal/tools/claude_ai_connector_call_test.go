package tools

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// sessionToken is the session process the test proposes as.
const sessionToken = "session-a"

const connectorCallArgsJSON = `{"server":"claude.ai Connector A","tool":"send_mail",` +
	`"input":{"to":"someone@example.com","body":"hi"},"reason":"the owner asked to reply"}`

// newSessionRegistry is a registry holding the real claude_ai_connector_call.
func newSessionRegistry(t *testing.T) (*Registry, *db.DB) {
	t.Helper()
	database := openDB(t)
	reg := New(database)
	require.NoError(t, reg.Register(NewClaudeAIConnectorCall()))
	return reg, database
}

func proposeConnectorCall(t *testing.T, reg *Registry, conversationID int64) int64 {
	t.Helper()
	rc, err := reg.ProposeSessionCall(context.Background(), ClaudeAIConnectorCallTool,
		json.RawMessage(connectorCallArgsJSON), Binding{Surface: "main", ConversationID: conversationID, SessionToken: sessionToken})
	require.NoError(t, err)
	require.Equal(t, "pending", rc.Status)
	return rc.ActionID
}

func approveRow(t *testing.T, database *db.DB, id int64) {
	t.Helper()
	ok, err := database.TransitionAgentAction(id, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	require.True(t, ok)
}

func rowStatus(t *testing.T, database *db.DB, id int64) (string, string) {
	t.Helper()
	row, err := database.GetAgentAction(id)
	require.NoError(t, err)
	require.NotNil(t, row)
	return row.Status, row.Error
}

// AGENT-03 (#737 amendment): a connector write is External and AlwaysAsk — no
// surface takes an execute trust for it, and a trust row planted behind the
// registry's back still records it pending.
func TestAgent03_ConnectorCallIsAlwaysAsk(t *testing.T) {
	reg, database := newSessionRegistry(t)
	tool, ok := reg.Get(ClaudeAIConnectorCallTool)
	require.True(t, ok)
	assert.True(t, tool.External)
	assert.True(t, tool.AlwaysAsk)
	assert.True(t, tool.AppliedBySession)
	assert.Equal(t, []string{"main"}, tool.Surfaces)

	for _, surface := range []string{"main", "target", "reaction", WorkbenchSurface, AutomationSurface, AutomationEditorSurface} {
		assert.ErrorIs(t, reg.SetTrust(ClaudeAIConnectorCallTool, surface, TrustExecute), ErrExternalExecute, surface)
	}
	require.NoError(t, database.SetToolTrust(ClaudeAIConnectorCallTool, "main", "execute"))
	id := proposeConnectorCall(t, reg, 7)
	status, _ := rowStatus(t, database, id)
	assert.Equal(t, "pending", status)
	row, err := database.GetAgentAction(id)
	require.NoError(t, err)
	assert.Equal(t, "ask", row.TrustAtCreate)
	assert.True(t, row.External)
}

// AGENT-05: of two concurrent claims of one approved row exactly one wins.
func TestAgent05_SessionCallClaimsOnce(t *testing.T) {
	reg, database := newSessionRegistry(t)
	id := proposeConnectorCall(t, reg, 7)
	approveRow(t, database, id)

	var wg sync.WaitGroup
	wins := make(chan bool, 2)
	for range 2 {
		wg.Go(func() {
			_, ok, err := reg.ClaimSessionCall(id, sessionToken)
			assert.NoError(t, err)
			wins <- ok
		})
	}
	wg.Wait()
	close(wins)
	won := 0
	for ok := range wins {
		if ok {
			won++
		}
	}
	assert.Equal(t, 1, won)
	status, _ := rowStatus(t, database, id)
	assert.Equal(t, "executing", status)
}

// AGENT-05: Apply never runs a session call — refused before its claim, the
// row stays approved for its session, Execute never called.
func TestAgent05_ApplyRefusesASessionCall(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	tool := NewClaudeAIConnectorCall()
	executed := 0
	tool.Execute = func(context.Context, *db.DB, Call) (any, error) {
		executed++
		return map[string]any{"ok": true}, nil
	}
	require.NoError(t, reg.Register(tool))
	id := proposeConnectorCall(t, reg, 7)
	approveRow(t, database, id)

	row, err := reg.Apply(context.Background(), id)
	require.ErrorIs(t, err, ErrSessionApplied)
	assert.Contains(t, err.Error(), "claude_ai_connector_call runs only in the chat session that proposed it")
	assert.Nil(t, row)
	status, _ := rowStatus(t, database, id)
	assert.Equal(t, "approved", status)
	assert.Zero(t, executed)

	_, ok, err := reg.ClaimSessionCall(id, sessionToken)
	require.NoError(t, err)
	assert.True(t, ok, "the session can still claim the row Apply refused")
}

func TestSessionCall_ClaimFinishRecordsTheOutcome(t *testing.T) {
	reg, database := newSessionRegistry(t)

	before, ok, err := reg.ClaimSessionCall(proposeConnectorCall(t, reg, 7), sessionToken)
	require.NoError(t, err)
	assert.False(t, ok, "a pending row is not claimable")
	require.NotNil(t, before)
	assert.Equal(t, "pending", before.Status, "a lost claim says what the row is, so the caller keeps waiting")

	id := proposeConnectorCall(t, reg, 7)
	approveRow(t, database, id)
	row, ok, err := reg.ClaimSessionCall(id, sessionToken)
	require.NoError(t, err)
	require.True(t, ok)
	assert.JSONEq(t, connectorCallArgsJSON, row.ArgsJSON)
	require.NoError(t, reg.FinishSessionCall(id, sessionToken, "Message sent.", ""))
	row, err = database.GetAgentAction(id)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status)
	assert.JSONEq(t, `"Message sent."`, row.ResultJSON, "plain text is stored as a JSON string")
	assert.ErrorIs(t, reg.FinishSessionCall(id, sessionToken, "", ""), ErrBadTransition, "finished once")

	// Expiry won the race while the call ran: the outcome the row could not
	// record still reaches the caller.
	expired := proposeConnectorCall(t, reg, 7)
	approveRow(t, database, expired)
	_, ok, err = reg.ClaimSessionCall(expired, sessionToken)
	require.NoError(t, err)
	require.True(t, ok)
	_, err = reg.ExpireSessionCalls(7, time.Now())
	require.NoError(t, err)
	err = reg.FinishSessionCall(expired, sessionToken, "Message sent.", "")
	require.ErrorIs(t, err, ErrBadTransition)
	assert.Contains(t, err.Error(), "Message sent.")

	failed := proposeConnectorCall(t, reg, 7)
	approveRow(t, database, failed)
	_, ok, err = reg.ClaimSessionCall(failed, sessionToken)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, reg.FinishSessionCall(failed, sessionToken, `{"isError":true}`, "connector refused"))
	status, msg := rowStatus(t, database, failed)
	assert.Equal(t, "failed", status)
	assert.Equal(t, "connector refused", msg)
}

// Cancel (timeout, Stop) takes only a pending row: an Approve that landed
// just before it wins, and the caller learns the row is approved so it goes
// on to claim it. Expire is the explicit path for an approved row the
// session will not run.
func TestSessionCall_CancelOnlyFromPending(t *testing.T) {
	reg, database := newSessionRegistry(t)

	pending := proposeConnectorCall(t, reg, 7)
	row, ok, err := reg.CancelSessionCall(pending, sessionToken, "stopped")
	require.NoError(t, err)
	assert.True(t, ok)
	assert.Equal(t, "rejected", row.Status)
	status, msg := rowStatus(t, database, pending)
	assert.Equal(t, "rejected", status)
	assert.Equal(t, "stopped", msg)

	approved := proposeConnectorCall(t, reg, 7)
	approveRow(t, database, approved)
	row, ok, err = reg.CancelSessionCall(approved, sessionToken, "not approved within 15 minutes")
	require.NoError(t, err)
	assert.False(t, ok, "the owner's Approve wins over the timeout")
	assert.Equal(t, "approved", row.Status, "the caller learns it may claim")
	_, won, err := reg.ClaimSessionCall(approved, sessionToken)
	require.NoError(t, err)
	assert.True(t, won)

	claimed := proposeConnectorCall(t, reg, 7)
	approveRow(t, database, claimed)
	_, won, err = reg.ClaimSessionCall(claimed, sessionToken)
	require.NoError(t, err)
	require.True(t, won)
	_, ok, err = reg.CancelSessionCall(claimed, sessionToken, "stopped")
	require.NoError(t, err)
	assert.False(t, ok, "a claimed call is running; cancel cannot take it back")
	ok, err = reg.ExpireSessionCall(claimed, sessionToken, "closed")
	require.NoError(t, err)
	assert.False(t, ok, "nor can expire")
	status, _ = rowStatus(t, database, claimed)
	assert.Equal(t, "executing", status)

	_, ok, err = reg.CancelSessionCall(pending, sessionToken, "again")
	require.NoError(t, err)
	assert.False(t, ok, "rejected is terminal")
}

func TestSessionCall_ExpireOneFailsAnUnclaimedCall(t *testing.T) {
	reg, database := newSessionRegistry(t)
	for _, approve := range []bool{false, true} {
		id := proposeConnectorCall(t, reg, 7)
		if approve {
			approveRow(t, database, id)
		}
		ok, err := reg.ExpireSessionCall(id, sessionToken, "the chat closed before the call ran")
		require.NoError(t, err)
		assert.True(t, ok)
		status, msg := rowStatus(t, database, id)
		assert.Equal(t, "failed", status)
		assert.Equal(t, "the chat closed before the call ran", msg)
		_, won, err := reg.ClaimSessionCall(id, sessionToken)
		require.NoError(t, err)
		assert.False(t, won)
		_, err = reg.Apply(context.Background(), id)
		assert.ErrorIs(t, err, ErrSessionApplied)
	}
}

// AGENT-05 (#737): a row is bound to the session process that proposed it,
// not just to its conversation — another process of the same conversation (a
// respawn, a --resume, a replay) can neither claim, finish, cancel nor expire
// it, and a call without a token is never recorded.
func TestAgent05_SessionCallBelongsToItsSessionProcess(t *testing.T) {
	reg, database := newSessionRegistry(t)
	id := proposeConnectorCall(t, reg, 7)
	approveRow(t, database, id)
	row, err := database.GetAgentAction(id)
	require.NoError(t, err)
	assert.Equal(t, sessionToken, row.SessionToken)

	for _, other := range []string{"session-b", ""} {
		_, ok, err := reg.ClaimSessionCall(id, other)
		assert.ErrorIs(t, err, ErrNotThisSession, other)
		assert.False(t, ok)
		_, _, err = reg.CancelSessionCall(id, other, "stopped")
		assert.ErrorIs(t, err, ErrNotThisSession, other)
		_, err = reg.ExpireSessionCall(id, other, "closed")
		assert.ErrorIs(t, err, ErrNotThisSession, other)
		assert.ErrorIs(t, reg.FinishSessionCall(id, other, "{}", ""), ErrNotThisSession, other)
	}
	status, _ := rowStatus(t, database, id)
	assert.Equal(t, "approved", status, "another process moved nothing")
	_, ok, err := reg.ClaimSessionCall(id, sessionToken)
	require.NoError(t, err)
	assert.True(t, ok, "its own process still claims it")

	_, err = reg.ProposeSessionCall(context.Background(), ClaudeAIConnectorCallTool,
		json.RawMessage(connectorCallArgsJSON), Binding{Surface: "main", ConversationID: 7})
	assert.Error(t, err, "no token, no row")
	var rows int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&rows))
	assert.Equal(t, 1, rows)
}

// The session methods never move a row Apply owns.
func TestSessionCall_MethodsRefuseOtherTools(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	var executed []Call
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	require.NoError(t, reg.Register(NewClaudeAIConnectorCall()))
	rc, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"text":"hi","reason":"r"}`), Binding{Surface: "main"})
	require.NoError(t, err)
	approveRow(t, database, rc.ActionID)

	_, _, err = reg.ClaimSessionCall(rc.ActionID, sessionToken)
	assert.ErrorIs(t, err, ErrBadTransition)
	_, _, err = reg.CancelSessionCall(rc.ActionID, sessionToken, "x")
	assert.ErrorIs(t, err, ErrBadTransition)
	_, err = reg.ExpireSessionCall(rc.ActionID, sessionToken, "x")
	assert.ErrorIs(t, err, ErrBadTransition)
	assert.ErrorIs(t, reg.FinishSessionCall(rc.ActionID, sessionToken, "", ""), ErrBadTransition)
	_, _, err = reg.ClaimSessionCall(9999, sessionToken)
	assert.ErrorIs(t, err, ErrNotFound)
	status, _ := rowStatus(t, database, rc.ActionID)
	assert.Equal(t, "approved", status)

	_, err = reg.ProposeSessionCall(context.Background(), "echo", json.RawMessage(`{"text":"hi","reason":"r"}`),
		Binding{Surface: "main", SessionToken: sessionToken})
	assert.Error(t, err, "ProposeSessionCall takes only a session-applied tool")
	assert.Empty(t, executed)
}

func TestSessionCall_ExpireLandsFailed(t *testing.T) {
	reg, database := newSessionRegistry(t)
	const own, other = int64(7), int64(8)
	setCreated := func(id int64, at time.Time) {
		_, err := database.Exec(`UPDATE agent_actions SET created_at = ? WHERE id = ?`,
			at.UTC().Format("2006-01-02T15:04:05Z"), id)
		require.NoError(t, err)
	}
	now := time.Now()
	cutoff := now.Add(-20 * time.Minute)

	ownOld := proposeConnectorCall(t, reg, own)
	setCreated(ownOld, now.Add(-time.Hour))
	ownFresh := proposeConnectorCall(t, reg, own)
	approveRow(t, database, ownFresh)
	ownRunning := proposeConnectorCall(t, reg, own)
	approveRow(t, database, ownRunning)
	_, ok, err := reg.ClaimSessionCall(ownRunning, sessionToken)
	require.NoError(t, err)
	require.True(t, ok)
	otherFresh := proposeConnectorCall(t, reg, other)
	otherStale := proposeConnectorCall(t, reg, other)
	setCreated(otherStale, now.Add(-21*time.Minute))
	ownApplied := proposeConnectorCall(t, reg, own)
	approveRow(t, database, ownApplied)
	_, ok, err = reg.ClaimSessionCall(ownApplied, sessionToken)
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, reg.FinishSessionCall(ownApplied, sessionToken, "{}", ""))
	ownRejected := proposeConnectorCall(t, reg, own)
	_, ok, err = reg.CancelSessionCall(ownRejected, sessionToken, "stopped")
	require.NoError(t, err)
	require.True(t, ok)

	n, err := reg.ExpireSessionCalls(own, cutoff)
	require.NoError(t, err)
	assert.Equal(t, 4, n)

	for _, id := range []int64{ownOld, ownFresh, otherStale} {
		status, msg := rowStatus(t, database, id)
		assert.Equal(t, "failed", status, id)
		assert.Equal(t, "session ended before approval", msg, id)
	}
	status, msg := rowStatus(t, database, ownRunning)
	assert.Equal(t, "failed", status)
	assert.Equal(t, "session ended while the call ran; outcome unknown", msg)
	status, _ = rowStatus(t, database, otherFresh)
	assert.Equal(t, "pending", status, "a live session of another conversation may still wait on it")
	status, _ = rowStatus(t, database, ownApplied)
	assert.Equal(t, "applied", status)
	status, _ = rowStatus(t, database, ownRejected)
	assert.Equal(t, "rejected", status)

	_, ok, err = reg.ClaimSessionCall(ownFresh, sessionToken)
	require.NoError(t, err)
	assert.False(t, ok, "an expired row can never be claimed")
	_, err = reg.Apply(context.Background(), ownFresh)
	assert.ErrorIs(t, err, ErrSessionApplied, "nor applied")
}

// Expire touches session calls only: an open row of any other tool, in the
// same conversation and however old, is left alone.
func TestSessionCall_ExpireLeavesOtherToolsAlone(t *testing.T) {
	database := openDB(t)
	reg := New(database)
	var executed []Call
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))
	require.NoError(t, reg.Register(NewClaudeAIConnectorCall()))
	rc, err := reg.Propose(context.Background(), "echo", json.RawMessage(`{"text":"hi","reason":"r"}`),
		Binding{Surface: "main", ConversationID: 7})
	require.NoError(t, err)

	n, err := reg.ExpireSessionCalls(7, time.Now().Add(time.Hour))
	require.NoError(t, err)
	assert.Zero(t, n)
	status, _ := rowStatus(t, database, rc.ActionID)
	assert.Equal(t, "pending", status)
}

func TestSessionCall_ReviseReplacesInput(t *testing.T) {
	reg, database := newSessionRegistry(t)
	ctx := context.Background()

	for _, patch := range []string{`{"input":"x"}`, `{"input":null}`, `{"input":[1]}`, `{}`,
		`{"server":"claude.ai Connector B","input":{}}`, `[1]`} {
		id := proposeConnectorCall(t, reg, 7)
		_, err := reg.Approve(ctx, id, json.RawMessage(patch))
		var verr *ValidationError
		assert.ErrorAs(t, err, &verr, patch)
		status, _ := rowStatus(t, database, id)
		assert.Equal(t, "pending", status, patch)
	}

	id := proposeConnectorCall(t, reg, 7)
	ok, err := reg.Approve(ctx, id, json.RawMessage(`{"input":{"to":"other@example.com","body":"edited"}}`))
	require.NoError(t, err)
	require.True(t, ok)
	row, err := database.GetAgentAction(id)
	require.NoError(t, err)
	assert.Equal(t, "approved", row.Status)
	var stored storedConnectorCall
	require.NoError(t, json.Unmarshal([]byte(row.ArgsJSON), &stored))
	assert.JSONEq(t, `{"to":"other@example.com","body":"edited"}`, string(stored.Input))
	assert.Equal(t, "claude.ai Connector A", stored.Server, "server is not editable")
	assert.Equal(t, "send_mail", stored.Tool)
}

func TestSessionCall_ValidateRefusesBadArgs(t *testing.T) {
	reg, database := newSessionRegistry(t)
	for _, args := range []string{
		`{"server":"","tool":"send_mail","input":{},"reason":"r"}`,
		`{"server":"S","tool":" ","input":{},"reason":"r"}`,
		`{"server":"S","tool":"t","input":null,"reason":"r"}`,
		`{"server":"S","tool":"t","input":{},"reason":""}`,
		`{"server":"S","tool":"t","input":{},"reason":"r","extra":1}`,
	} {
		_, err := reg.ProposeSessionCall(context.Background(), ClaudeAIConnectorCallTool, json.RawMessage(args),
			Binding{Surface: "main", SessionToken: sessionToken})
		assert.Error(t, err, args)
	}
	var rows int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&rows))
	assert.Zero(t, rows, "a refused call writes no row")
}

// No MCP surface or tool loop ever offers the session-applied tool, and a
// model naming it on a dispatch-by-name path is refused without a row.
func TestRegistry_ListNeverOffersSessionCalls(t *testing.T) {
	reg, database := newSessionRegistry(t)
	for _, surface := range []string{"", "main", "target", "reaction", WorkbenchSurface, AutomationSurface, AutomationEditorSurface} {
		for _, tool := range reg.List(surface) {
			assert.NotEqual(t, ClaudeAIConnectorCallTool, tool.Name, surface)
		}
	}
	_, err := reg.Propose(context.Background(), ClaudeAIConnectorCallTool, json.RawMessage(connectorCallArgsJSON), Binding{Surface: "main"})
	var verr *ValidationError
	assert.ErrorAs(t, err, &verr)
	var rows int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&rows))
	assert.Zero(t, rows)
}
