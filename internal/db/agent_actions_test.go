package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAgentActions_InsertGetList(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	id, err := database.InsertAgentAction(AgentAction{
		Tool: "create_target", ArgsJSON: `{"text":"x"}`, Reason: "owner asked",
		Surface: "main", ConversationID: 7, TurnID: "turn-1",
	})
	require.NoError(t, err)

	got, err := database.GetAgentAction(id)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "pending", got.Status)
	assert.Equal(t, "ask", got.TrustAtCreate)
	assert.Equal(t, int64(7), got.ConversationID)
	assert.NotEmpty(t, got.CreatedAt)

	rows, err := database.ListAgentActions(AgentActionFilter{ConversationID: 7})
	require.NoError(t, err)
	assert.Len(t, rows, 1)

	rows, err = database.ListAgentActions(AgentActionFilter{Status: "applied"})
	require.NoError(t, err)
	assert.Empty(t, rows)

	missing, err := database.GetAgentAction(999)
	require.NoError(t, err)
	assert.Nil(t, missing)
}

func TestAgentActions_TransitionIsConditional(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()
	id, err := database.InsertAgentAction(AgentAction{Tool: "create_target", ArgsJSON: `{}`})
	require.NoError(t, err)

	ok, err := database.TransitionAgentAction(id, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	assert.True(t, ok)
	row, _ := database.GetAgentAction(id)
	assert.Equal(t, "approved", row.Status)
	assert.NotEmpty(t, row.DecidedAt)
	assert.Empty(t, row.AppliedAt)

	// A second pending→approved must not match: the row is no longer pending.
	ok, err = database.TransitionAgentAction(id, []string{"pending"}, "approved", "", "")
	require.NoError(t, err)
	assert.False(t, ok)

	ok, err = database.TransitionAgentAction(id, []string{"approved", "failed"}, "applied", `{"target_id":3}`, "")
	require.NoError(t, err)
	assert.True(t, ok)
	row, _ = database.GetAgentAction(id)
	assert.Equal(t, "applied", row.Status)
	assert.Equal(t, `{"target_id":3}`, row.ResultJSON)
	assert.NotEmpty(t, row.AppliedAt)
}

func TestToolTrust_DefaultAskAndUpsert(t *testing.T) {
	database := openTestDB(t)
	defer database.Close()

	trust, err := database.GetToolTrust("create_target")
	require.NoError(t, err)
	assert.Equal(t, "ask", trust)

	require.NoError(t, database.SetToolTrust("create_target", "execute"))
	trust, _ = database.GetToolTrust("create_target")
	assert.Equal(t, "execute", trust)

	require.NoError(t, database.SetToolTrust("create_target", "ask"))
	trust, _ = database.GetToolTrust("create_target")
	assert.Equal(t, "ask", trust)
}
