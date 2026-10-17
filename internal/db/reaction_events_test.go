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
