package cmd

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/ownerconfirm"
)

// withoutOwnerDesktop puts AGENT-07's refusals back for one test: no Desktop
// answers and stdin is not a terminal, so an owner-only gesture is refused.
func withoutOwnerDesktop(t *testing.T) {
	t.Helper()
	desk, tty := askOwnerDesktop, ownerTerminal
	t.Cleanup(func() { askOwnerDesktop, ownerTerminal = desk, tty })
	askOwnerDesktop = func(context.Context, string, ownerconfirm.Request) (ownerconfirm.Reply, error) {
		return ownerconfirm.Reply{}, fmt.Errorf("%w: test", ownerconfirm.ErrNoDesktop)
	}
	ownerTerminal = func() (io.Reader, io.Writer, bool) { return nil, nil, false }
}

// withOwnerDesktop stands in for a running Desktop that answers decision;
// the requests it was sent are returned.
func withOwnerDesktop(t *testing.T, decision string) *[]ownerconfirm.Request {
	t.Helper()
	desk := askOwnerDesktop
	t.Cleanup(func() { askOwnerDesktop = desk })
	var got []ownerconfirm.Request
	askOwnerDesktop = func(_ context.Context, _ string, req ownerconfirm.Request) (ownerconfirm.Reply, error) {
		got = append(got, req)
		return ownerconfirm.Reply{Decision: decision}, nil
	}
	return &got
}

// withOwnerTerminal stands in for an interactive terminal on which typed is
// entered; the code shown is 123456 and what was printed is returned.
func withOwnerTerminal(t *testing.T, typed string) *bytes.Buffer {
	t.Helper()
	tty, code := ownerTerminal, ownerConfirmCode
	t.Cleanup(func() { ownerTerminal, ownerConfirmCode = tty, code })
	var out bytes.Buffer
	ownerTerminal = func() (io.Reader, io.Writer, bool) { return strings.NewReader(typed), &out, true }
	ownerConfirmCode = func() string { return "123456" }
	return &out
}

func clearAgentMarkers(t *testing.T) {
	t.Helper()
	for _, name := range agentEnvMarkers {
		t.Setenv(name, "")
		require.NoError(t, os.Unsetenv(name))
	}
}

// AGENT-07 amended (board #568, owner decision ask #306): an owner-only
// gesture is confirmed by the owner — in the running Desktop, or with a code
// typed on a terminal — and unsetting the agent markers (`env -u CLAUDECODE
// …`) no longer lets an agent through: without a Desktop and a terminal the
// gesture is refused whatever the environment says.
func TestAgent07_OwnerGestureNeedsTheOwnersConfirmation(t *testing.T) {
	setup := func(t *testing.T) (*db.DB, int64) {
		database := writeActionsConfig(t)
		id, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target",
			ArgsJSON: `{"text":"x","reason":"r"}`, Reason: "r", Surface: "main"})
		require.NoError(t, err)
		return database, id
	}
	status := func(t *testing.T, database *db.DB, id int64) string {
		row, err := database.GetAgentAction(id)
		require.NoError(t, err)
		return row.Status
	}

	t.Run("markers unset, no Desktop, no terminal: refused", func(t *testing.T) {
		database, id := setup(t)
		withoutOwnerDesktop(t)
		_, err := runActions(t, "approve", strconv.FormatInt(id, 10), "--json")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "open Watchtower Desktop")
		assert.Equal(t, "pending", status(t, database, id))
	})
	t.Run("the Desktop denies: refused", func(t *testing.T) {
		database, id := setup(t)
		withOwnerDesktop(t, ownerconfirm.Denied)
		_, err := runActions(t, "approve", strconv.FormatInt(id, 10), "--json")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "did not confirm")
		assert.Equal(t, "pending", status(t, database, id))
	})
	t.Run("the Desktop confirms an agent's request: approved", func(t *testing.T) {
		database, id := setup(t)
		got := withOwnerDesktop(t, ownerconfirm.Confirmed)
		t.Setenv("CLAUDECODE", "1")
		_, err := runActions(t, "approve", strconv.FormatInt(id, 10), "--json")
		require.NoError(t, err)
		assert.NotEqual(t, "pending", status(t, database, id))
		require.Len(t, *got, 1)
		assert.Equal(t, "approve an action", (*got)[0].Verb)
		assert.Equal(t, "CLAUDECODE", (*got)[0].Agent)
		assert.Contains(t, (*got)[0].Detail, "create_target", "the window says what is approved")
	})
	t.Run("no Desktop, a terminal, the right code: approved", func(t *testing.T) {
		database, id := setup(t)
		withoutOwnerDesktop(t)
		out := withOwnerTerminal(t, "123456\n")
		_, err := runActions(t, "approve", strconv.FormatInt(id, 10), "--json")
		require.NoError(t, err)
		assert.Contains(t, out.String(), "123456")
		assert.NotEqual(t, "pending", status(t, database, id))
	})
	t.Run("no Desktop, a terminal, a wrong code: refused", func(t *testing.T) {
		database, id := setup(t)
		withoutOwnerDesktop(t)
		withOwnerTerminal(t, "000000\n")
		_, err := runActions(t, "approve", strconv.FormatInt(id, 10), "--json")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "did not match")
		assert.Equal(t, "pending", status(t, database, id))
	})
	t.Run("no Desktop, a terminal, under a marker: refused without asking", func(t *testing.T) {
		database, id := setup(t)
		withoutOwnerDesktop(t)
		out := withOwnerTerminal(t, "123456\n")
		t.Setenv("CODEX_THREAD_ID", "t")
		_, err := runActions(t, "approve", strconv.FormatInt(id, 10), "--json")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "CODEX_THREAD_ID")
		assert.Empty(t, out.String(), "no code is offered to an agent")
		assert.Equal(t, "pending", status(t, database, id))
	})
}

func TestAgentMarkerNamesTheFirstSetMarker(t *testing.T) {
	clearAgentMarkers(t)
	assert.Empty(t, agentMarker())
	t.Setenv(agentEnvMarkers[1], "x")
	assert.Equal(t, agentEnvMarkers[1], agentMarker())
}
