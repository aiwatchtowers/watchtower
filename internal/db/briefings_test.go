package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func makeBriefing(userID, date string) Briefing {
	return Briefing{
		WorkspaceID:  "WS1",
		UserID:       userID,
		Date:         date,
		Role:         "EM",
		Attention:    "[]",
		YourDay:      "[]",
		WhatHappened: "[]",
		TeamPulse:    "[]",
		Coaching:     "[]",
		Model:        "haiku",
	}
}

func TestUpsertBriefing_InsertAndUpdate(t *testing.T) {
	db := openTestDB(t)

	id, err := db.UpsertBriefing(makeBriefing("U1", "2026-04-02"))
	require.NoError(t, err)
	require.NotZero(t, id)

	// Re-upsert same (user_id, date) returns the same id but updates fields.
	b := makeBriefing("U1", "2026-04-02")
	b.Role = "Updated"
	id2, err := db.UpsertBriefing(b)
	require.NoError(t, err)
	assert.Equal(t, id, id2)

	got, err := db.GetBriefingByID(int(id))
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "Updated", got.Role)
}

func TestGetBriefing_ByUserAndDate(t *testing.T) {
	db := openTestDB(t)
	_, err := db.UpsertBriefing(makeBriefing("U2", "2026-04-02"))
	require.NoError(t, err)

	got, err := db.GetBriefing("U2", "2026-04-02")
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "U2", got.UserID)
}

func TestGetBriefing_NotFound(t *testing.T) {
	db := openTestDB(t)
	got, err := db.GetBriefing("nobody", "2026-01-01")
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestGetBriefingByID_NotFound(t *testing.T) {
	db := openTestDB(t)
	got, err := db.GetBriefingByID(99999)
	require.NoError(t, err)
	assert.Nil(t, got)
}

func TestGetRecentBriefings_OrderedDescByDate(t *testing.T) {
	db := openTestDB(t)
	for _, date := range []string{"2026-04-01", "2026-04-03", "2026-04-02"} {
		_, err := db.UpsertBriefing(makeBriefing("U3", date))
		require.NoError(t, err)
	}

	got, err := db.GetRecentBriefings("U3", 10)
	require.NoError(t, err)
	require.Len(t, got, 3)
	assert.Equal(t, "2026-04-03", got[0].Date)
	assert.Equal(t, "2026-04-02", got[1].Date)
	assert.Equal(t, "2026-04-01", got[2].Date)
}

func TestGetRecentBriefings_DefaultLimit(t *testing.T) {
	db := openTestDB(t)
	_, err := db.UpsertBriefing(makeBriefing("U4", "2026-04-02"))
	require.NoError(t, err)

	got, err := db.GetRecentBriefings("U4", 0) // 0 → default 20.
	require.NoError(t, err)
	assert.NotEmpty(t, got)
}

func TestMarkBriefingRead(t *testing.T) {
	db := openTestDB(t)
	id, err := db.UpsertBriefing(makeBriefing("U5", "2026-04-02"))
	require.NoError(t, err)

	require.NoError(t, db.MarkBriefingRead(int(id)))

	got, err := db.GetBriefingByID(int(id))
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.True(t, got.ReadAt.Valid)
}

func TestMarkBriefingRead_NoOpForNonexistent(t *testing.T) {
	db := openTestDB(t)
	require.NoError(t, db.MarkBriefingRead(99999), "missing id should not error")
}
