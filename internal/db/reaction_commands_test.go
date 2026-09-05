package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestListReactionCommandMap_SeededDefaults(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	m, err := d.ListReactionCommandMap()
	require.NoError(t, err)
	require.Contains(t, m, "white_check_mark")
	require.Contains(t, m, "ticket")
	assert.Equal(t, "create_target", m["white_check_mark"].Tool)
	assert.Equal(t, "builtin_tool", m["white_check_mark"].Kind)
	assert.Equal(t, "create_jira_issue", m["ticket"].Tool)
}

func TestListReactionCommandMap_OmitsDisabled(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	_, err := d.Exec(`UPDATE reaction_command_map SET enabled = 0 WHERE emoji = 'ticket'`)
	require.NoError(t, err)

	m, err := d.ListReactionCommandMap()
	require.NoError(t, err)
	assert.Contains(t, m, "white_check_mark")
	assert.NotContains(t, m, "ticket")
}

// TestRecordNewReactionCommands_Idempotent pins REACT-03: re-polling the same
// owner reactions never re-dispatches — only genuinely new ones come back.
func TestRecordNewReactionCommands_Idempotent(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	cands := []OwnerReaction{
		{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"},
		{AccountID: 1, ChannelID: "1:C1", MessageTS: "222.2", Emoji: "ticket"},
	}

	fresh, err := d.RecordNewReactionCommands(cands)
	require.NoError(t, err)
	assert.Len(t, fresh, 2, "first poll records both")
	for _, f := range fresh {
		assert.NotZero(t, f.ID)
		assert.Equal(t, "pending", f.Status)
	}

	// Second poll with the identical set: nothing new.
	again, err := d.RecordNewReactionCommands(cands)
	require.NoError(t, err)
	assert.Empty(t, again, "re-poll re-dispatches nothing")

	// A genuinely new reaction is the only thing returned.
	cands = append(cands, OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "333.3", Emoji: "white_check_mark"})
	third, err := d.RecordNewReactionCommands(cands)
	require.NoError(t, err)
	require.Len(t, third, 1)
	assert.Equal(t, "333.3", third[0].MessageTS)
}

func TestRecordNewReactionCommands_Empty(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	fresh, err := d.RecordNewReactionCommands(nil)
	require.NoError(t, err)
	assert.Empty(t, fresh)
}

func TestMarkReactionCommand_StatusTransitions(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	fresh, err := d.RecordNewReactionCommands([]OwnerReaction{
		{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"},
		{AccountID: 1, ChannelID: "1:C1", MessageTS: "222.2", Emoji: "ticket"},
	})
	require.NoError(t, err)
	require.Len(t, fresh, 2)

	require.NoError(t, d.MarkReactionCommandDispatched(fresh[0].ID, 42))
	require.NoError(t, d.MarkReactionCommandFailed(fresh[1].ID, "boom"))

	var status string
	var actionID int64
	require.NoError(t, d.QueryRow(`SELECT status, action_id FROM reaction_commands WHERE id = ?`,
		fresh[0].ID).Scan(&status, &actionID))
	assert.Equal(t, "dispatched", status)
	assert.Equal(t, int64(42), actionID)

	var errText string
	require.NoError(t, d.QueryRow(`SELECT status, error FROM reaction_commands WHERE id = ?`,
		fresh[1].ID).Scan(&status, &errText))
	assert.Equal(t, "failed", status)
	assert.Equal(t, "boom", errText)
}
