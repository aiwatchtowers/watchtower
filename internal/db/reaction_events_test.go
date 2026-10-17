package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestInsertReactionEvent_OncePerKey(t *testing.T) {
	d := openTestDB(t)
	r := OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "100.1", Emoji: "eyes"}

	ok, err := d.InsertReactionEvent(r)
	require.NoError(t, err)
	assert.True(t, ok)

	ok, err = d.InsertReactionEvent(r)
	require.NoError(t, err)
	assert.False(t, ok, "a second insert of the same key is a duplicate")

	r.Emoji = "tada"
	ok, err = d.InsertReactionEvent(r)
	require.NoError(t, err)
	assert.True(t, ok, "another emoji on the same message is a new key")
}

func TestSeedReactionEvents_StampsAndRecords(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSlackAccount(SlackAccount{Label: "A"})
	require.NoError(t, err)
	r := OwnerReaction{AccountID: id, ChannelID: "1:C1", MessageTS: "100.1", Emoji: "eyes"}

	require.NoError(t, d.SeedReactionEvents(id, []OwnerReaction{r, r}))

	seeded, err := d.ReactionEventsSeeded(id)
	require.NoError(t, err)
	assert.True(t, seeded)

	ok, err := d.InsertReactionEvent(r)
	require.NoError(t, err)
	assert.False(t, ok, "a seeded key never fires")

	require.Error(t, d.SeedReactionEvents(999, nil), "a missing account is an error")
}

func TestResetReactionEventsSeeded(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSlackAccount(SlackAccount{Label: "A"})
	require.NoError(t, err)
	r := OwnerReaction{AccountID: id, ChannelID: "1:C1", MessageTS: "100.1", Emoji: "eyes"}
	require.NoError(t, d.SeedReactionEvents(id, []OwnerReaction{r}))

	require.NoError(t, d.ResetReactionEventsSeeded())

	seeded, err := d.ReactionEventsSeeded(id)
	require.NoError(t, err)
	assert.False(t, seeded)
	ok, err := d.InsertReactionEvent(r)
	require.NoError(t, err)
	assert.False(t, ok, "rows are kept after a reset")
}

func TestReactionEventsSeeded_MissingAccount(t *testing.T) {
	d := openTestDB(t)
	seeded, err := d.ReactionEventsSeeded(999)
	require.NoError(t, err)
	assert.False(t, seeded)
}

func TestFilterUnseenReactionEvents(t *testing.T) {
	d := openTestDB(t)
	seen := OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "100.1", Emoji: "eyes"}
	other := OwnerReaction{AccountID: 2, ChannelID: "2:C1", MessageTS: "100.1", Emoji: "eyes"}
	fresh := OwnerReaction{AccountID: 1, ChannelID: "1:C1", MessageTS: "100.1", Emoji: "tada"}
	_, err := d.InsertReactionEvent(seen)
	require.NoError(t, err)
	_, err = d.InsertReactionEvent(other)
	require.NoError(t, err)

	sameKeyOnAccount1 := other
	sameKeyOnAccount1.AccountID = 1
	sameKeyOnAccount1.ChannelID = "1:C2"
	got, err := d.FilterUnseenReactionEvents(1, []OwnerReaction{fresh, seen, sameKeyOnAccount1})
	require.NoError(t, err)
	assert.Equal(t, []OwnerReaction{fresh, sameKeyOnAccount1}, got)

	got, err = d.FilterUnseenReactionEvents(1, nil)
	require.NoError(t, err)
	assert.Empty(t, got)
}

// TestResetReactionEventsSeeded_NoStampNoWrite proves the reset takes no
// write when no stamp is set: on a query_only handle a write fails, so the
// reset only succeeds there if it never issued one.
func TestResetReactionEventsSeeded_NoStampNoWrite(t *testing.T) {
	d := openTestDB(t)
	_, err := d.CreateSlackAccount(SlackAccount{Label: "A"})
	require.NoError(t, err)
	require.NoError(t, d.SetReadOnly())
	_, err = d.Exec(`UPDATE slack_accounts SET reaction_events_seeded_at = '' WHERE reaction_events_seeded_at != ''`)
	require.Error(t, err, "query_only must refuse even a no-match UPDATE, or this test proves nothing")

	require.NoError(t, d.ResetReactionEventsSeeded())
}
