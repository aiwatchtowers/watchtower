package sync

import (
	"bytes"
	"context"
	"log"
	"net/http"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSearchWindow covers the C4 fix (owner decision 7): initial_history_days
// must apply only on a true first run (no watermark yet); once a watermark
// exists, the window is always search_last_date minus the 2-day indexing
// overlap, clamped to maxSearchCatchUpDays so a daemon that was down longer
// than that doesn't silently skip the gap and stamp the watermark to today.
func TestSearchWindow(t *testing.T) {
	now := time.Now()
	const initialDays = 7

	tests := []struct {
		name         string
		lastDateAgo  int // days before now the watermark was set; -1 = no watermark (first run)
		wantAfterAgo int // expected days-before-now for the returned `after`
		wantClamped  bool
	}{
		{
			name:         "empty watermark: true first run uses initial_history_days",
			lastDateAgo:  -1,
			wantAfterAgo: initialDays,
			wantClamped:  false,
		},
		{
			name:         "watermark 1 day ago: window is watermark minus 2-day overlap",
			lastDateAgo:  1,
			wantAfterAgo: 3,
			wantClamped:  false,
		},
		{
			name:         "watermark 10 days ago: still under the catch-up cap",
			lastDateAgo:  10,
			wantAfterAgo: 12,
			wantClamped:  false,
		},
		{
			name:         "watermark 45 days ago: gap exceeds the cap and clamps",
			lastDateAgo:  45,
			wantAfterAgo: maxSearchCatchUpDays,
			wantClamped:  true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			lastDate := ""
			if tc.lastDateAgo >= 0 {
				lastDate = now.AddDate(0, 0, -tc.lastDateAgo).Format(searchDateFormat)
			}

			after, gapDays, clamped := searchWindow(now, lastDate, initialDays)

			wantAfter := now.AddDate(0, 0, -tc.wantAfterAgo).Format(searchDateFormat)
			assert.Equal(t, wantAfter, after)
			assert.Equal(t, tc.wantClamped, clamped)
			if tc.lastDateAgo >= 0 {
				assert.Equal(t, tc.lastDateAgo+2, gapDays,
					"gapDays should reflect the watermark age plus the 2-day overlap")
			}
		})
	}
}

// TestSearchWindow_InvalidWatermarkFallsBackToFirstRun covers a corrupt
// search_last_date value (should never happen since Watchtower is the only
// writer, but the parse can't be trusted blindly) falling back to the same
// first-run window as an empty watermark, rather than erroring out sync.
func TestSearchWindow_InvalidWatermarkFallsBackToFirstRun(t *testing.T) {
	now := time.Now()

	after, gapDays, clamped := searchWindow(now, "not-a-date", 7)

	assert.Equal(t, now.AddDate(0, 0, -7).Format(searchDateFormat), after)
	assert.Equal(t, 7, gapDays)
	assert.False(t, clamped)
}

// TestSearchWindow_NonPositiveInitialDaysDefaultsTo30 pins the pre-existing
// "days <= 0 -> 30" fallback carried over from the old inline computation.
func TestSearchWindow_NonPositiveInitialDaysDefaultsTo30(t *testing.T) {
	now := time.Now()

	after, gapDays, clamped := searchWindow(now, "", 0)

	assert.Equal(t, now.AddDate(0, 0, -30).Format(searchDateFormat), after)
	assert.Equal(t, 30, gapDays)
	assert.False(t, clamped)
}

// emptySearchResultsMux answers search.messages with zero matches on one
// page — enough for syncViaSearch to complete without needing the rest of a
// full sync's endpoints, since these call-site tests exercise syncViaSearch
// directly rather than the full Orchestrator.Run.
func emptySearchResultsMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/search.messages", func(w http.ResponseWriter, _ *http.Request) {
		jsonOK(w, map[string]any{
			"ok": true,
			"messages": map[string]any{
				"matches": []map[string]any{},
				"paging":  map[string]any{"count": 100, "total": 0, "page": 1, "pages": 1},
				"total":   0,
			},
		})
	})
	return mux
}

// TestSyncViaSearch_ClampedGapLogsWarningAndRecordsError pins the call-site
// half of the C4 fix: a watermark stale enough to clamp (45 days ago, gap 47
// > maxSearchCatchUpDays) must log the warning line and record it on the
// account's error column, without touching status.
func TestSyncViaSearch_ClampedGapLogsWarningAndRecordsError(t *testing.T) {
	ts := newTestSetup(t, emptySearchResultsMux())

	var logBuf bytes.Buffer
	ts.orch.logger = log.New(&logBuf, "", 0)

	staleDate := time.Now().AddDate(0, 0, -45).Format(searchDateFormat)
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, staleDate))
	require.NoError(t, ts.db.SetSlackAccountAuthState(ts.accountID, "ok", ""))

	err := ts.orch.syncViaSearch(context.Background())
	require.NoError(t, err)

	assert.Contains(t, logBuf.String(), "gap of 47 days exceeds the 30-day catch-up cap",
		"a clamped gap must log the warning line")

	got, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Contains(t, got.Error, "catch-up cap", "the gap must be recorded on the account's error column")
	assert.Equal(t, "ok", got.Status, "a data gap is not an auth failure and must not touch status")
}

// TestSyncViaSearch_UnclampedGapDoesNotWarnOrRecordError is the negative
// case: a 10-day-old watermark (gap 12, under the cap) must neither log the
// warning nor write anything to the account's error column.
func TestSyncViaSearch_UnclampedGapDoesNotWarnOrRecordError(t *testing.T) {
	ts := newTestSetup(t, emptySearchResultsMux())

	var logBuf bytes.Buffer
	ts.orch.logger = log.New(&logBuf, "", 0)

	recentDate := time.Now().AddDate(0, 0, -10).Format(searchDateFormat)
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, recentDate))

	err := ts.orch.syncViaSearch(context.Background())
	require.NoError(t, err)

	assert.NotContains(t, logBuf.String(), "catch-up cap")

	got, err := ts.db.GetSlackAccount(ts.accountID)
	require.NoError(t, err)
	assert.Empty(t, got.Error)
}

// TestSyncViaSearch_FailedGapWriteDoesNotAbortSync is fix round 1's F1: the
// SetSlackAccountError write is diagnostic telemetry about the gap, not
// correctness-load-bearing — losing it must never abort the sync itself.
// Renaming the error column (leaving search_last_date untouched) makes only
// that write fail, without disturbing the watermark read/advance the rest
// of the sync depends on.
func TestSyncViaSearch_FailedGapWriteDoesNotAbortSync(t *testing.T) {
	ts := newTestSetup(t, emptySearchResultsMux())

	staleDate := time.Now().AddDate(0, 0, -45).Format(searchDateFormat)
	require.NoError(t, ts.db.SetSlackAccountSearchWatermark(ts.accountID, staleDate))

	_, err := ts.db.Exec(`ALTER TABLE slack_accounts RENAME COLUMN error TO error_disabled_for_test`)
	require.NoError(t, err)

	var logBuf bytes.Buffer
	ts.orch.logger = log.New(&logBuf, "", 0)

	err = ts.orch.syncViaSearch(context.Background())
	require.NoError(t, err, "a failed gap-note write must not abort the sync")

	assert.Contains(t, logBuf.String(), "gap of 47 days exceeds the 30-day catch-up cap",
		"the warning must still be logged even though the DB write fails")
	assert.Contains(t, logBuf.String(), "failed to record gap on account",
		"the write failure itself must be logged, not silently dropped")

	watermark, err := ts.db.GetSlackAccountSearchWatermark(ts.accountID)
	require.NoError(t, err)
	assert.Equal(t, time.Now().Format(searchDateFormat), watermark,
		"the sync must still run to completion and advance the watermark")
}

// TestSyncViaSearch_InvalidWatermarkLogsWarning restores the anomaly signal
// for a corrupt search_last_date (Watchtower is the sole writer, so this
// should never happen, but if it does the daemon log should say so) that
// was dropped when the window math moved into searchWindow.
func TestSyncViaSearch_InvalidWatermarkLogsWarning(t *testing.T) {
	ts := newTestSetup(t, emptySearchResultsMux())

	var logBuf bytes.Buffer
	ts.orch.logger = log.New(&logBuf, "", 0)

	_, err := ts.db.Exec(`UPDATE slack_accounts SET search_last_date = ? WHERE id = ?`, "not-a-date", ts.accountID)
	require.NoError(t, err)

	err = ts.orch.syncViaSearch(context.Background())
	require.NoError(t, err)

	assert.Contains(t, logBuf.String(), `invalid search_last_date "not-a-date", treating as first run`)
}
