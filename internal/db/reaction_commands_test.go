package db

import (
	"testing"
	"time"

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

// TestClaimReactionCommand_ProvisionalRowIsSeenAndClaimedOnce pins the claim
// half of the provisional-row state machine: the claimed row is `pending`, is
// already "seen" by the filter (so a later poll never re-dispatches it even if
// it is never finalized), and a second claim of the same key is refused.
func TestClaimReactionCommand_ProvisionalRowIsSeenAndClaimedOnce(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	c := OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"}

	id, claimed, err := d.ClaimReactionCommand(c)
	require.NoError(t, err)
	require.True(t, claimed)
	require.NotZero(t, id)

	var status string
	require.NoError(t, d.QueryRow(`SELECT status FROM reaction_commands WHERE id = ?`, id).Scan(&status))
	assert.Equal(t, ReactionCommandProvisional, status)

	unseen, err := d.FilterUnseenReactionCommands(1, []OwnerReaction{c})
	require.NoError(t, err)
	assert.Empty(t, unseen, "a provisional row counts as seen")

	_, again, err := d.ClaimReactionCommand(c)
	require.NoError(t, err)
	assert.False(t, again, "a key already in the ledger is never claimed twice")
}

func TestFinalizeReactionCommand_OnlyRewritesProvisional(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	c := OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"}
	id, _, err := d.ClaimReactionCommand(c)
	require.NoError(t, err)

	applied, err := d.FinalizeReactionCommand(id, "dispatched", 42, "")
	require.NoError(t, err)
	assert.True(t, applied)
	// A second finalize must not rewrite the terminal outcome, and says so.
	applied, err = d.FinalizeReactionCommand(id, "failed", 0, "late")
	require.NoError(t, err)
	assert.False(t, applied, "a row no longer provisional reports applied=false")

	var status string
	var actionID int64
	require.NoError(t, d.QueryRow(`SELECT status, action_id FROM reaction_commands WHERE id = ?`, id).Scan(&status, &actionID))
	assert.Equal(t, "dispatched", status)
	assert.Equal(t, int64(42), actionID)
}

func TestReleaseReactionCommand_DeletesOnlyProvisional(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	c := OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "111.1", Emoji: "white_check_mark"}
	id, _, err := d.ClaimReactionCommand(c)
	require.NoError(t, err)
	applied, err := d.ReleaseReactionCommand(id)
	require.NoError(t, err)
	assert.True(t, applied)

	unseen, err := d.FilterUnseenReactionCommands(1, []OwnerReaction{c})
	require.NoError(t, err)
	assert.Len(t, unseen, 1, "a released claim is unseen again, so the next poll retries it")

	terminal := OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "222.2", Emoji: "white_check_mark"}
	tid, _, err := d.ClaimReactionCommand(terminal)
	require.NoError(t, err)
	_, err = d.FinalizeReactionCommand(tid, "dispatched", 7, "")
	require.NoError(t, err)
	applied, err = d.ReleaseReactionCommand(tid)
	require.NoError(t, err)
	assert.False(t, applied)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM reaction_commands WHERE id = ?`, tid).Scan(&n))
	assert.Equal(t, 1, n, "a terminal row is never released (REACT-05)")
}

// TestFailStrandedReactionCommands_OnlyOldProvisionalRowsOfTheAccount pins the
// stranded-row surfacing: only a provisional row older than the cutoff, of the
// given account, becomes `failed` with the explanation; a fresh provisional
// row (a dispatch still in flight), a terminal row, and another account's row
// are untouched.
func TestFailStrandedReactionCommands_OnlyOldProvisionalRowsOfTheAccount(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	old := time.Now().Add(-2 * time.Hour).UTC().Format("2006-01-02T15:04:05Z")
	insert := func(acct int64, ts, status, created string) {
		_, err := d.Exec(`INSERT INTO reaction_commands (account_id, channel_id, message_ts, emoji, status, created_at)
			VALUES (?, '1:C1', ?, 'white_check_mark', ?, ?)`, acct, ts, status, created)
		require.NoError(t, err)
	}
	insert(1, "1.1", ReactionCommandProvisional, old)
	insert(1, "2.2", ReactionCommandProvisional, time.Now().UTC().Format("2006-01-02T15:04:05Z"))
	insert(1, "3.3", "dispatched", old)
	insert(2, "4.4", ReactionCommandProvisional, old)

	got, err := d.FailStrandedReactionCommands(1, time.Now().Add(-time.Hour), "stranded")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "1.1", got[0].MessageTS)
	assert.Equal(t, "failed", got[0].Status)
	assert.Equal(t, "stranded", got[0].Error)

	statusOf := func(acct int64, ts string) string {
		var s string
		require.NoError(t, d.QueryRow(`SELECT status FROM reaction_commands WHERE account_id = ? AND message_ts = ?`, acct, ts).Scan(&s))
		return s
	}
	assert.Equal(t, "failed", statusOf(1, "1.1"))
	assert.Equal(t, ReactionCommandProvisional, statusOf(1, "2.2"), "an in-flight claim is left alone")
	assert.Equal(t, "dispatched", statusOf(1, "3.3"))
	assert.Equal(t, ReactionCommandProvisional, statusOf(2, "4.4"), "another account's row is left alone")
}

// TestReactionAgentActionSince_OnlyNewerReactionRowsForTheBinding pins the
// lookup the pipeline uses after a failed Propose: only a reaction-surface row
// for the same message ref and tool, above the pre-Propose high-water mark.
func TestReactionAgentActionSince_OnlyNewerReactionRowsForTheBinding(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	floor, err := d.MaxAgentActionID()
	require.NoError(t, err)
	assert.Zero(t, floor)

	insert := func(surface, ctxID, tool string) int64 {
		id, err := d.InsertAgentAction(AgentAction{Tool: tool, ArgsJSON: "{}", Reason: "r", Surface: surface, ContextType: "reaction", ContextID: ctxID})
		require.NoError(t, err)
		return id
	}
	old := insert("reaction", "1:C1@1.1", "create_idea")
	floor, err = d.MaxAgentActionID()
	require.NoError(t, err)
	assert.Equal(t, old, floor)

	insert("chat", "1:C1@1.1", "create_idea")
	insert("reaction", "1:C1@2.2", "create_idea")
	insert("reaction", "1:C1@1.1", "create_target")
	got, err := d.ReactionAgentActionSince("1:C1@1.1", "create_idea", floor)
	require.NoError(t, err)
	assert.Zero(t, got, "the pre-floor row and other surfaces/refs/tools do not count")

	want := insert("reaction", "1:C1@1.1", "create_idea")
	got, err = d.ReactionAgentActionSince("1:C1@1.1", "create_idea", floor)
	require.NoError(t, err)
	assert.Equal(t, want, got)
}
