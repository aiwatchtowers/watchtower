package briefing

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// Ids the model invents are blanked before the briefing is stored — the
// Desktop navigates on them — while the items and every shown id survive.
func TestRunForDate_BlanksIDsThePromptNeverShowed(t *testing.T) {
	database := testDB(t)
	require.NoError(t, database.UpsertWorkspace(db.Workspace{ID: "T1", Name: "test", Domain: "test"}))
	_, err := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U001"})
	require.NoError(t, err)

	now := time.Now()
	dayStart := time.Date(now.Year(), now.Month(), now.Day()-1, 0, 0, 0, 0, now.Location())
	digestID, err := database.UpsertDigest(db.Digest{
		ChannelID: "C1", Type: "channel",
		PeriodFrom: float64(dayStart.Unix()), PeriodTo: float64(dayStart.Add(48 * time.Hour).Unix()),
		Summary: "Release discussion", MessageCount: 5,
	})
	require.NoError(t, err)
	require.Equal(t, int64(1), digestID)

	gen := &mockGenerator{response: `{
		"attention": [
			{"text": "shown digest", "source_type": "digest", "source_id": "1", "priority": "high", "reason": "r"},
			{"text": "invented track", "source_type": "track", "source_id": "7", "priority": "high", "reason": "r"},
			{"text": "unknown type", "source_type": "calendar", "source_id": "evt-1", "priority": "medium", "reason": "r"}
		],
		"your_day": [
			{"text": "invented target", "target_id": 42, "priority": "high", "status": "todo", "ownership": "mine"}
		],
		"what_happened": [
			{"text": "shown", "digest_id": 1, "channel_name": "#c", "item_type": "decision", "importance": "high"},
			{"text": "invented", "digest_id": 99, "channel_name": "#c", "item_type": "decision", "importance": "high"}
		],
		"team_pulse": [], "coaching": []
	}`}
	pipe := New(database, testConfig(), gen, log.New(io.Discard, "", 0))
	today := now.Format("2006-01-02")
	_, err = pipe.RunForDate(context.Background(), today)
	require.NoError(t, err)

	b, err := database.GetBriefing("U001", today)
	require.NoError(t, err)
	require.NotNil(t, b)

	var attention []AttentionItem
	require.NoError(t, json.Unmarshal([]byte(b.Attention), &attention))
	require.Len(t, attention, 3)
	assert.Equal(t, "1", attention[0].SourceID)
	assert.Equal(t, "", attention[1].SourceID)
	assert.Equal(t, "track", attention[1].SourceType, "the item keeps its type")
	assert.Equal(t, "evt-1", attention[2].SourceID, "a type with no id set is left alone")

	var yourDay []YourDayItem
	require.NoError(t, json.Unmarshal([]byte(b.YourDay), &yourDay))
	require.Len(t, yourDay, 1)
	assert.Zero(t, yourDay[0].TargetID)

	var happened []WhatHappenedItem
	require.NoError(t, json.Unmarshal([]byte(b.WhatHappened), &happened))
	require.Len(t, happened, 2)
	assert.Equal(t, 1, happened[0].DigestID)
	assert.Zero(t, happened[1].DigestID)
}

func TestShownIDs_ResolvePerson(t *testing.T) {
	s := newShownIDs()
	s.addPerson("1:U1")
	s.addPerson("1:U7")
	s.addPerson("2:U7")

	for in, want := range map[string]string{
		"1:U1": "1:U1", // exact
		"U1":   "1:U1", // unique raw echo → stored form
		"@U1":  "1:U1", // prompt renders "@<id>"
		"U7":   "",     // raw id two accounts share
		"U9":   "",     // never shown
		"":     "",
	} {
		got, ok := s.resolvePerson(in)
		assert.Equal(t, want, got, in)
		assert.Equal(t, want != "", ok, in)
	}
}

func TestShownIDs_NilIsSafeAndEmptyResultIsNoop(t *testing.T) {
	var s *shownIDs
	s.addTarget(1)
	s.addPerson("1:U1")
	assert.Zero(t, newShownIDs().validateIDs(&BriefingResult{}))
}
