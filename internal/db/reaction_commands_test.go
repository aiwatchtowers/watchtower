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

// TestFilterUnseenReactionCommands_Idempotent pins REACT-03: once a command is
// recorded (a terminal outcome), a re-poll of the same reactions filters it out
// so it never re-dispatches; genuinely new reactions still come through.
func TestFilterUnseenReactionCommands_Idempotent(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	cands := []OwnerReaction{
		{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"},
		{AccountID: 1, ChannelID: "1:C1", MessageTS: "222.2", Emoji: "ticket"},
	}

	unseen, err := d.FilterUnseenReactionCommands(1, cands)
	require.NoError(t, err)
	assert.Len(t, unseen, 2, "first poll sees both as new")

	// Record a terminal outcome for both, then re-poll: nothing new.
	for _, u := range unseen {
		require.NoError(t, d.InsertReactionCommand(u, "dispatched", 7, ""))
	}
	again, err := d.FilterUnseenReactionCommands(1, cands)
	require.NoError(t, err)
	assert.Empty(t, again, "recorded commands are filtered out")

	// A genuinely new reaction is the only thing returned.
	cands = append(cands, OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "333.3", Emoji: "white_check_mark"})
	third, err := d.FilterUnseenReactionCommands(1, cands)
	require.NoError(t, err)
	require.Len(t, third, 1)
	assert.Equal(t, "333.3", third[0].MessageTS)
}

// TestFilterUnseen_TransientLeavesRetriable pins the transient-retry contract:
// a candidate NOT recorded (a transient dispatch failure) stays unseen and is
// returned again on the next poll.
func TestFilterUnseen_TransientLeavesRetriable(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	cands := []OwnerReaction{{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"}}

	first, err := d.FilterUnseenReactionCommands(1, cands)
	require.NoError(t, err)
	require.Len(t, first, 1)
	// Simulate a transient failure: DO NOT record it.
	second, err := d.FilterUnseenReactionCommands(1, cands)
	require.NoError(t, err)
	assert.Len(t, second, 1, "an unrecorded (transient) command retries")
}

func TestFilterUnseenReactionCommands_Empty(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	unseen, err := d.FilterUnseenReactionCommands(1, nil)
	require.NoError(t, err)
	assert.Empty(t, unseen)
}

func TestInsertReactionCommand_RecordsStatus(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	require.NoError(t, d.InsertReactionCommand(
		OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"}, "dispatched", 42, ""))
	require.NoError(t, d.InsertReactionCommand(
		OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "222.2", Emoji: "ticket"}, "failed", 0, "boom"))

	var status string
	var actionID int64
	require.NoError(t, d.QueryRow(`SELECT status, action_id FROM reaction_commands WHERE message_ts = '111.1'`).Scan(&status, &actionID))
	assert.Equal(t, "dispatched", status)
	assert.Equal(t, int64(42), actionID)

	var errText string
	require.NoError(t, d.QueryRow(`SELECT status, error FROM reaction_commands WHERE message_ts = '222.2'`).Scan(&status, &errText))
	assert.Equal(t, "failed", status)
	assert.Equal(t, "boom", errText)

	// INSERT OR IGNORE: a duplicate key is a no-op, not an error.
	require.NoError(t, d.InsertReactionCommand(
		OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"}, "dispatched", 99, ""))
	require.NoError(t, d.QueryRow(`SELECT action_id FROM reaction_commands WHERE message_ts = '111.1'`).Scan(&actionID))
	assert.Equal(t, int64(42), actionID, "duplicate insert ignored, original kept")
}
