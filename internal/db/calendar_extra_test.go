package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCalendarAuthState_DefaultsToOK(t *testing.T) {
	db := openTestDB(t)

	state, err := db.GetCalendarAuthState()
	require.NoError(t, err)
	assert.Equal(t, "ok", state.Status, "missing row → defaults to ok")
	assert.Equal(t, "", state.Error)
}

func TestCalendarAuthState_RoundTrip(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.SetCalendarAuthState("revoked", "expired"))

	state, err := db.GetCalendarAuthState()
	require.NoError(t, err)
	assert.Equal(t, "revoked", state.Status)
	assert.Equal(t, "expired", state.Error)
	assert.NotEmpty(t, state.UpdatedAt)
}

func TestCalendarAuthState_Overwrites(t *testing.T) {
	db := openTestDB(t)

	require.NoError(t, db.SetCalendarAuthState("error", "first"))
	require.NoError(t, db.SetCalendarAuthState("ok", ""))

	state, err := db.GetCalendarAuthState()
	require.NoError(t, err)
	assert.Equal(t, "ok", state.Status)
	assert.Equal(t, "", state.Error)
}

func TestMeetingPrepCache_RoundTrip(t *testing.T) {
	db := openTestDB(t)

	// Missing event → ErrNoRows-derived error.
	_, err := db.GetMeetingPrepCache("evt1")
	require.Error(t, err)

	require.NoError(t, db.SaveMeetingPrepCache(MeetingPrepCache{
		EventID:    "evt1",
		ResultJSON: `{"talking_points":[]}`,
		UserNotes:  "agenda",
	}))

	got, err := db.GetMeetingPrepCache("evt1")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "evt1", got.EventID)
	assert.Contains(t, got.ResultJSON, "talking_points")
	assert.Equal(t, "agenda", got.UserNotes)
	assert.NotEmpty(t, got.GeneratedAt)
}

func TestMeetingPrepCache_Overwrites(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.SaveMeetingPrepCache(MeetingPrepCache{EventID: "evt1", ResultJSON: `{"v":1}`}))
	require.NoError(t, db.SaveMeetingPrepCache(MeetingPrepCache{EventID: "evt1", ResultJSON: `{"v":2}`}))

	got, err := db.GetMeetingPrepCache("evt1")
	require.NoError(t, err)
	assert.Contains(t, got.ResultJSON, `"v":2`)
}

func TestMeetingPrepCache_Delete(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.SaveMeetingPrepCache(MeetingPrepCache{EventID: "evt1"}))
	require.NoError(t, db.DeleteMeetingPrepCache("evt1"))

	_, err := db.GetMeetingPrepCache("evt1")
	require.Error(t, err)
}

func TestMeetingPrepCache_DeleteMissingIsNoop(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.DeleteMeetingPrepCache("never-existed"))
}
