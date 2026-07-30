package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// NOTE: TestCalendarAuthState_DefaultsToOK, TestCalendarAuthState_RoundTrip,
// and TestCalendarAuthState_Overwrites were removed by migration 00043
// (google_accounts): Get/SetCalendarAuthState target the calendar_auth_state
// singleton, which 00043 drops in favor of per-account status/error columns
// on google_accounts. The accessors are left in place — cmd and
// internal/calendar still call them, so they keep compiling — but they now
// fail at runtime; Task 2 of the multi-account plan rewrites them to take an
// account id and will need fresh tests for the new signatures.

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
