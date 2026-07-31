package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestCalendarAuthState_DefaultsToOK, TestCalendarAuthState_RoundTrip, and
// TestCalendarAuthState_Overwrites (Get/SetCalendarAuthState, the
// calendar_auth_state singleton) were retired by migration 00043
// (google_accounts) in favor of per-account status/error columns — see
// TestGoogleAccount_SetAuthState_RoundTrip/TestGoogleAccount_SetAuthState_MissingRow
// in google_accounts_test.go.

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
