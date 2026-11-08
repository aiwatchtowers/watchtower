package db

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestDailyDigestAttemptReceiptIsAtomicAndSurvivesOrdinaryUpserts(t *testing.T) {
	database := OpenTestDB(t)
	d := Digest{Type: "daily", PeriodFrom: 172800, PeriodTo: 259199, Summary: "identical output", Topics: "[]"}
	baseline, err := database.UpsertDigest(d)
	require.NoError(t, err)
	completed, err := database.DailyDigestAttemptCompleted(d.PeriodFrom, d.PeriodTo, "first")
	require.NoError(t, err)
	require.False(t, completed, "a preclaim row is not this attempt's completion")
	id, err := database.UpsertDailyDigestAttempt(d, "first")
	require.NoError(t, err)
	require.Equal(t, baseline, id)
	// Fix the same second for identical output before and after an ordinary write:
	// neither row id, timestamp nor output content is completion evidence.
	_, err = database.Exec("UPDATE digests SET created_at='2026-01-01T00:00:00Z' WHERE id=?", id)
	require.NoError(t, err)
	ordinary, err := database.UpsertDigest(d)
	require.NoError(t, err)
	require.Equal(t, id, ordinary)
	_, err = database.Exec("UPDATE digests SET created_at='2026-01-01T00:00:00Z' WHERE id=?", id)
	require.NoError(t, err)
	completed, err = database.DailyDigestAttemptCompleted(d.PeriodFrom, d.PeriodTo, "first")
	require.NoError(t, err)
	require.True(t, completed)
	encoded, err := json.Marshal(d)
	require.NoError(t, err)
	require.NotContains(t, string(encoded), "attempt", "receipt is local metadata, absent from Digest/wire shape")
	// A failed receipt update cannot commit its output separately.
	_, err = database.Exec(`CREATE TRIGGER fail_daily_attempt BEFORE UPDATE OF daily_attempt_id ON digests WHEN NEW.daily_attempt_id='second' BEGIN SELECT RAISE(FAIL,'receipt write failed'); END`)
	require.NoError(t, err)
	d.Summary = "new output"
	_, err = database.UpsertDailyDigestAttempt(d, "second")
	require.ErrorContains(t, err, "receipt write failed")
	var summary string
	require.NoError(t, database.QueryRow("SELECT summary FROM digests WHERE id=?", id).Scan(&summary))
	require.Equal(t, "identical output", summary)
	completed, err = database.DailyDigestAttemptCompleted(d.PeriodFrom, d.PeriodTo, "second")
	require.NoError(t, err)
	require.False(t, completed)
	require.NoError(t, func() error { _, err := database.Exec("DROP TRIGGER fail_daily_attempt"); return err }())
	_, err = database.UpsertDailyDigestAttempt(d, "second")
	require.NoError(t, err)
	completed, err = database.DailyDigestAttemptCompleted(d.PeriodFrom, d.PeriodTo, "second")
	require.NoError(t, err)
	require.True(t, completed)
	completed, err = database.DailyDigestAttemptCompleted(d.PeriodFrom, d.PeriodTo, "first")
	require.NoError(t, err)
	require.False(t, completed, "only a new explicit scheduled claim replaces the receipt")
}
