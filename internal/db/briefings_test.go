package db

import (
	"testing"
	"time"

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

func TestLastBriefingCreatedAtBefore_LatestEarlierDateOfThatUser(t *testing.T) {
	d := openTestDB(t)
	day := time.Now()
	date := func(back int) string { return day.AddDate(0, 0, -back).Format("2006-01-02") }
	seed := func(user, d0, created string) {
		t.Helper()
		if _, err := d.UpsertBriefing(makeBriefing(user, d0)); err != nil {
			t.Fatal(err)
		}
		if _, err := d.Exec(`UPDATE briefings SET created_at = ? WHERE user_id = ? AND date = ?`, created, user, d0); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok, err := d.LastBriefingCreatedAtBefore("U1", date(0)); err != nil || ok {
		t.Fatalf("no briefing = (%v, %v); want (false, nil)", ok, err)
	}
	seed("U1", date(5), "2020-01-01T08:00:00Z")
	seed("U1", date(3), "2020-01-03T17:00:00Z")
	seed("U1", date(0), "2020-01-06T08:00:00Z") // today's own row is not "before"
	seed("U2", date(1), "2020-01-05T08:00:00Z") // another user
	got, ok, err := d.LastBriefingCreatedAtBefore("U1", date(0))
	if err != nil || !ok {
		t.Fatalf("LastBriefingCreatedAtBefore = (%v, %v)", ok, err)
	}
	if want := time.Date(2020, 1, 3, 17, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Errorf("created = %v; want %v", got, want)
	}
}
