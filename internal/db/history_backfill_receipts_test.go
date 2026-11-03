package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestHistoryDailyReceiptAtomicScopedAndPreservesScheduledToken(t *testing.T) {
	d, err := Open(":memory:")
	require.NoError(t, err)
	defer d.Close()
	original := Digest{Type: "daily", PeriodFrom: 100, PeriodTo: 200, Summary: "scheduled"}
	id, err := d.UpsertDailyDigestAttempt(original, "scheduled-token")
	require.NoError(t, err)
	_, err = d.Exec(`CREATE TRIGGER fail_history_daily BEFORE INSERT ON history_backfill_daily BEGIN SELECT RAISE(ABORT,'receipt unavailable'); END`)
	require.NoError(t, err)
	changed := original
	changed.Summary = "historical"
	_, err = d.UpsertHistoryBackfillDaily(changed, 1, 50, 300)
	require.Error(t, err)
	var summary string
	require.NoError(t, d.QueryRow(`SELECT summary FROM digests WHERE id=?`, id).Scan(&summary))
	require.Equal(t, "scheduled", summary)
	_, err = d.Exec(`DROP TRIGGER fail_history_daily`)
	require.NoError(t, err)
	_, err = d.UpsertHistoryBackfillDaily(changed, 1, 50, 300)
	require.NoError(t, err)
	scheduled, err := d.DailyDigestAttemptCompleted(100, 200, "scheduled-token")
	require.NoError(t, err)
	require.True(t, scheduled)
	done, err := d.HistoryBackfillDailyCompleted(1, 50, 300, 100)
	require.NoError(t, err)
	require.True(t, done)
	done, err = d.HistoryBackfillDailyCompleted(2, 50, 300, 100)
	require.NoError(t, err)
	require.False(t, done, "another account owns a different historical claim")
	_, err = d.StartHistoryBackfill("slack", 1, 0, 400, time.Now())
	require.NoError(t, err)
	_, err = d.Exec(`DELETE FROM history_backfill WHERE source_kind='slack' AND account_id=1`)
	require.NoError(t, err)
	done, err = d.HistoryBackfillDailyCompleted(1, 50, 300, 100)
	require.NoError(t, err)
	require.False(t, done, "explicit reset invalidates the old claim")
}
