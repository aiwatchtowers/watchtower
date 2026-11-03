package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// targetPressArgs is the Desktop's target-button press (Inbox builder A):
// create_target on the inbox surface with the button's context, no
// --approve unless the caller adds it.
func targetPressArgs(ctxID, args string, extra ...string) []string {
	return append([]string{"--tool", "create_target", "--surface", "inbox", "--context-type", "automation_output",
		"--context-id", ctxID, "--args", args, "--json"}, extra...)
}

const buttonArgs = `{"text":"Write the summary","intent":"for colleague A","reason":"From the Inbox card"}`

func exitCodeOf(err error) int {
	var ec *exitCodeError
	if errors.As(err, &ec) {
		return ec.code
	}
	if err != nil {
		return 1
	}
	return 0
}

func targetCount(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM targets`).Scan(&n))
	return n
}

// pressButton proposes through the CLI and returns the new row id.
func pressButton(t *testing.T, ctxID string) int64 {
	t.Helper()
	out, err := runPropose(t, targetPressArgs(ctxID, buttonArgs)...)
	require.NoError(t, err, out)
	var env proposeEnvelope
	require.NoError(t, json.Unmarshal([]byte(out), &env), out)
	return env.Action.ID
}

// applyRow approves (if pending) and applies row id through the CLI.
func applyRow(t *testing.T, id int64) {
	t.Helper()
	out, err := runActions(t, "approve", strconv.FormatInt(id, 10), "--json")
	require.NoError(t, err, out)
	require.Contains(t, out, `"applied_ok": true`)
}

// AUTO-02: a target button's press only proposes — one pending row with the
// button's context, no task until the owner's Approve.
func TestAuto02_TargetButtonOnlyProposes(t *testing.T) {
	database := writeActionsConfig(t)

	out, err := runPropose(t, targetPressArgs("7:2", buttonArgs)...)
	require.NoError(t, err, out)
	var env proposeEnvelope
	require.NoError(t, json.Unmarshal([]byte(out), &env), out)
	assert.Equal(t, "pending", env.Action.Status)
	assert.Equal(t, "create_target", env.Action.Tool)
	assert.Equal(t, "inbox", env.Action.Surface)

	assert.Equal(t, 1, actionRowCount(t, database))
	var ctxType, ctxID string
	require.NoError(t, database.QueryRow(`SELECT context_type, context_id FROM agent_actions`).Scan(&ctxType, &ctxID))
	assert.Equal(t, "automation_output", ctxType)
	assert.Equal(t, "7:2", ctxID)
	assert.Zero(t, targetCount(t, database), "nothing is created before the owner's Approve")
}

// Exit 3 with the spec's text for a button whose state moved; no row is
// written. Any other refusal stays exit 1.
func TestActionsPropose_ButtonRefusalExit3(t *testing.T) {
	database := writeActionsConfig(t)
	first := pressButton(t, "7:0:abc")

	out, err := runPropose(t, targetPressArgs("7:0:abc", buttonArgs)...)
	require.Error(t, err, out)
	assert.Equal(t, 3, exitCodeOf(err))
	assert.Equal(t, "This button already has a proposal (#"+strconv.FormatInt(first, 10)+")", err.Error())
	assert.Equal(t, 1, actionRowCount(t, database))

	applyRow(t, first)
	var targetID int64
	require.NoError(t, database.QueryRow(`SELECT id FROM targets`).Scan(&targetID))
	out, err = runPropose(t, targetPressArgs("7:0:abc", buttonArgs)...)
	require.Error(t, err, out)
	assert.Equal(t, 3, exitCodeOf(err))
	assert.Equal(t, "This button's task already exists (task #"+strconv.FormatInt(targetID, 10)+")", err.Error())
	assert.Equal(t, 1, actionRowCount(t, database))

	// Another refusal — a parent that does not exist — exits 1.
	out, err = runPropose(t, targetPressArgs("7:1:def", `{"text":"x","parent_id":9999,"reason":"r"}`)...)
	require.Error(t, err, out)
	assert.Equal(t, 1, exitCodeOf(err))
	assert.Contains(t, err.Error(), "parent_id: task #9999 does not exist")
	assert.Equal(t, 1, actionRowCount(t, database))
}

// AGENT-05: an applied proposal whose task exists locks the button; once
// the owner deletes the task, a new press is accepted.
func TestAgent05_DeletedTaskUnlocksButton(t *testing.T) {
	database := writeActionsConfig(t)
	first := pressButton(t, "7:0:abc")
	applyRow(t, first)

	out, err := runPropose(t, targetPressArgs("7:0:abc", buttonArgs)...)
	require.Error(t, err, out)
	assert.Equal(t, 3, exitCodeOf(err))
	assert.Contains(t, err.Error(), "task already exists")

	var targetID int64
	require.NoError(t, database.QueryRow(`SELECT id FROM targets`).Scan(&targetID))
	require.NoError(t, database.DeleteTarget(int(targetID)))
	second := pressButton(t, "7:0:abc")
	assert.Greater(t, second, first)
}

// olderFailedNewerPending is a button with an older failed row and a newer
// pending one; it returns both ids.
func olderFailedNewerPending(t *testing.T, database *db.DB) (int64, int64) {
	t.Helper()
	older := pressButton(t, "7:0:abc")
	ok, err := database.TransitionAgentAction(older, []string{"pending"}, "failed", "", "boom")
	require.NoError(t, err)
	require.True(t, ok)
	newer := pressButton(t, "7:0:abc")
	return older, newer
}

func TestActionsApply_OlderRowExit3(t *testing.T) {
	database := writeActionsConfig(t)
	older, newer := olderFailedNewerPending(t, database)
	want := "A newer proposal for this button is open (#" + strconv.FormatInt(newer, 10) + ")"
	for _, extra := range [][]string{nil, {"--force"}} {
		out, err := runActions(t, append([]string{"apply", strconv.FormatInt(older, 10), "--json"}, extra...)...)
		require.Error(t, err, out)
		assert.Equal(t, 3, exitCodeOf(err))
		assert.Equal(t, want, err.Error())
	}
	row, err := database.GetAgentAction(older)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "boom", row.Error)
	assert.Zero(t, targetCount(t, database))
}

// AGENT-05: the retry of an older row is refused before any state change,
// --force included; and a unique violation forced at the claim (the check
// passed by) maps to the same error, the row unchanged.
func TestAgent05_OlderRowRetryRefused(t *testing.T) {
	database := writeActionsConfig(t)
	older, newer := olderFailedNewerPending(t, database)
	for _, extra := range [][]string{nil, {"--force"}} {
		out, err := runActions(t, append([]string{"apply", strconv.FormatInt(older, 10), "--json"}, extra...)...)
		require.Error(t, err, out)
		assert.Equal(t, 3, exitCodeOf(err))
	}

	// The claim itself: the registry's Apply, past prepareApply.
	reg := buildToolRegistry(&config.Config{ActiveWorkspace: "test"}, database)
	_, err := reg.Apply(context.Background(), older)
	require.Error(t, err)
	var newerErr *db.ErrButtonNewerProposalOpen
	require.ErrorAs(t, err, &newerErr)
	assert.Equal(t, newer, newerErr.ID)
	mapped := buttonStateExit(err)
	assert.Equal(t, 3, exitCodeOf(mapped))
	assert.Equal(t, "A newer proposal for this button is open (#"+strconv.FormatInt(newer, 10)+")", mapped.Error())

	row, err := database.GetAgentAction(older)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Equal(t, "boom", row.Error)
	assert.Zero(t, targetCount(t, database))
}

// AGENT-05: the owner's --force reclaim of a row whose apply already
// inserted the task ends applied with that same task, never a second one;
// a row left executing before any insert ends with one new task.
func TestAgent05_CreateTargetReclaimDoesNotDuplicate(t *testing.T) {
	database := writeActionsConfig(t)
	id := pressButton(t, "7:0:abc")
	applyRow(t, id)
	var targetID int64
	require.NoError(t, database.QueryRow(`SELECT id FROM targets`).Scan(&targetID))

	// A process died after the insert: the row is back in executing.
	_, err := database.Exec(`UPDATE agent_actions SET status = 'executing' WHERE id = ?`, id)
	require.NoError(t, err)
	out, err := runActions(t, "apply", strconv.FormatInt(id, 10), "--force", "--json")
	require.NoError(t, err, out)
	assert.Contains(t, out, `"applied_ok": true`)
	assert.Contains(t, out, `"target_id": `+strconv.FormatInt(targetID, 10))
	assert.Equal(t, 1, targetCount(t, database), "one task per action id")

	// A row left executing before any insert: one new task.
	other, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target", ArgsJSON: buttonArgs,
		Reason: "r", Surface: "inbox", ContextType: "automation_output", ContextID: "8:0:abc", Status: "executing"})
	require.NoError(t, err)
	out, err = runActions(t, "apply", strconv.FormatInt(other, 10), "--force", "--json")
	require.NoError(t, err, out)
	assert.Contains(t, out, `"applied_ok": true`)
	assert.Equal(t, 2, targetCount(t, database))

	// An approved row applies normally.
	third := pressButton(t, "9:0:abc")
	applyRow(t, third)
	assert.Equal(t, 3, targetCount(t, database))
}
