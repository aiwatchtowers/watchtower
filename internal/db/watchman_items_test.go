package db

import (
	"os"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func wmQueueAsk(t *testing.T, d *DB, refID int64) int64 {
	t.Helper()
	id, ins, err := d.QueueWatchmanItem(WatchmanItem{WorkbenchID: 1, Kind: "ask", RefKind: "ask", RefID: refID, Question: "q"})
	require.NoError(t, err)
	require.True(t, ins)
	return id
}

func wmAll(WatchmanItem) bool { return true }

func TestQueueWatchmanItem_OncePerWaitPoint(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	id1 := wmQueueAsk(t, d, 5)
	id2, ins, err := d.QueueWatchmanItem(WatchmanItem{WorkbenchID: 1, Kind: "ask", RefKind: "ask", RefID: 5})
	require.NoError(t, err)
	require.False(t, ins)
	require.Equal(t, id1, id2)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM watchman_items`).Scan(&n))
	require.Equal(t, 1, n)
}

func TestLeaseWatchmanItem_OneWinner(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmQueueAsk(t, d, 5)
	now := time.Now()
	var wg sync.WaitGroup
	got := make([]*WatchmanItem, 2)
	for i := range got {
		wg.Add(1)
		go func() {
			defer wg.Done()
			it, err := d.LeaseWatchmanItem(now, 10*time.Minute, wmAll)
			require.NoError(t, err)
			got[i] = it
		}()
	}
	wg.Wait()
	require.NotEqual(t, got[0] == nil, got[1] == nil, "exactly one winner")
	n, err := d.CountDecidingWatchmanItems(now)
	require.NoError(t, err)
	require.Equal(t, 1, n)
}

func TestLeaseWatchmanItem_ExpiredLeaseRetaken(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmQueueAsk(t, d, 5)
	future := wmQueueAsk(t, d, 6)
	now := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	_, err := d.Exec(`UPDATE watchman_items SET not_before = ? WHERE id = ?`, wmTime(now.Add(time.Hour)), future)
	require.NoError(t, err)
	first, err := d.LeaseWatchmanItem(now, 10*time.Minute, wmAll)
	require.NoError(t, err)
	require.NotNil(t, first)
	require.Equal(t, 1, first.Attempts)
	none, err := d.LeaseWatchmanItem(now.Add(time.Minute), 10*time.Minute, wmAll)
	require.NoError(t, err)
	require.Nil(t, none, "live lease and a future not_before are both skipped")
	again, err := d.LeaseWatchmanItem(now.Add(11*time.Minute), 10*time.Minute, wmAll)
	require.NoError(t, err)
	require.NotNil(t, again)
	require.Equal(t, first.ID, again.ID)
	require.Equal(t, 2, again.Attempts)
	skip, err := d.LeaseWatchmanItem(now.Add(2*time.Hour), 10*time.Minute, func(it WatchmanItem) bool { return it.ID != future })
	require.NoError(t, err)
	require.NotNil(t, skip)
	require.Equal(t, first.ID, skip.ID, "eligible filter is honoured")
}

func wmFinish(t *testing.T, d *DB, id int64, lease time.Time, o WatchmanOutcome) bool {
	t.Helper()
	tx, err := d.Begin()
	require.NoError(t, err)
	ok, err := d.FinishWatchmanItemTx(tx, id, lease, o)
	require.NoError(t, err)
	require.NoError(t, tx.Commit())
	return ok
}

func TestFinishWatchmanItem_StaleLeaseWritesNothing(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	id := wmQueueAsk(t, d, 5)
	now := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	first, err := d.LeaseWatchmanItem(now, 10*time.Minute, wmAll)
	require.NoError(t, err)
	second, err := d.LeaseWatchmanItem(now.Add(11*time.Minute), 10*time.Minute, wmAll)
	require.NoError(t, err)
	require.NotNil(t, second)
	require.False(t, wmFinish(t, d, id, *first.LeaseUntil, WatchmanOutcome{Outcome: "answered", Choice: "x"}))
	var state, choice string
	require.NoError(t, d.QueryRow(`SELECT state, choice FROM watchman_items WHERE id = ?`, id).Scan(&state, &choice))
	require.Equal(t, "deciding", state)
	require.Equal(t, "", choice)
	require.True(t, wmFinish(t, d, id, *second.LeaseUntil, WatchmanOutcome{Outcome: "answered", Choice: "x", PrecedentIDs: []int64{3, 4}}))
	got, err := d.LeaseWatchmanItem(now.Add(time.Hour), time.Minute, wmAll)
	require.NoError(t, err)
	require.Nil(t, got, "a done item is never leased")
}

func TestRequeueWatchmanItem_AndSetKind(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	id := wmQueueAsk(t, d, 5)
	ok, err := d.SetWatchmanItemKind("ask", 5, "ask", "check")
	require.NoError(t, err)
	require.True(t, ok)
	now := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	it, err := d.LeaseWatchmanItem(now, time.Minute, wmAll)
	require.NoError(t, err)
	ok, err = d.SetWatchmanItemKind("ask", 5, "check", "ask")
	require.NoError(t, err)
	require.False(t, ok, "only while queued")
	ok, err = d.RequeueWatchmanItem(id, *it.LeaseUntil, now.Add(time.Hour), "refused")
	require.NoError(t, err)
	require.True(t, ok)
	none, err := d.LeaseWatchmanItem(now.Add(time.Minute*5), time.Minute, wmAll)
	require.NoError(t, err)
	require.Nil(t, none)
	back, err := d.LeaseWatchmanItem(now.Add(2*time.Hour), time.Minute, wmAll)
	require.NoError(t, err)
	require.NotNil(t, back)
	require.Equal(t, 2, back.Attempts)
	require.Equal(t, "refused", back.Error)
}

func TestFinishWatchmanItem_NeverTouchesFeedback(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	id := wmQueueAsk(t, d, 5)
	_, err := d.Exec(`UPDATE watchman_items SET feedback = 'ok' WHERE id = ?`, id)
	require.NoError(t, err)
	now := time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC)
	it, err := d.LeaseWatchmanItem(now, time.Minute, wmAll)
	require.NoError(t, err)
	require.True(t, wmFinish(t, d, id, *it.LeaseUntil, WatchmanOutcome{Outcome: "parked", ParkReason: "r"}))
	var fb string
	require.NoError(t, d.QueryRow(`SELECT feedback FROM watchman_items WHERE id = ?`, id).Scan(&fb))
	require.Equal(t, "ok", fb)

	// No statement that writes watchman_items names a feedback column.
	src, err := os.ReadFile("watchman_items.go")
	require.NoError(t, err)
	write := regexp.MustCompile(`(?i)^\s*(UPDATE|INSERT)`)
	for _, seg := range strings.Split(string(src), "`") {
		if write.MatchString(seg) {
			require.NotContains(t, strings.ToLower(seg), "feedback", seg)
		}
	}
}

func TestWatchmanExtraLimitsAndGaps(t *testing.T) {
	d := openTestDB(t)
	id, err := d.AddWatchmanExtraLimit("command", "terraform apply")
	require.NoError(t, err)
	again, err := d.AddWatchmanExtraLimit("command", "terraform apply")
	require.NoError(t, err)
	require.Equal(t, id, again)
	ls, err := d.WatchmanExtraLimits()
	require.NoError(t, err)
	require.Equal(t, []WatchmanExtraLimit{{ID: id, Kind: "command", Pattern: "terraform apply"}}, ls)
	ok, err := d.DeleteWatchmanExtraLimit(id)
	require.NoError(t, err)
	require.True(t, ok)
	t0 := time.Date(2026, 11, 1, 1, 0, 0, 0, time.UTC)
	require.NoError(t, d.AddWatchmanGap(t0, t0.Add(time.Hour)))
}

func TestLeaseWatchmanItem_PagesPastIneligibleOlderRows(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	old := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	for i := int64(1); i <= watchmanLeaseScanMax+1; i++ {
		_, _, err := d.QueueWatchmanItem(WatchmanItem{WorkbenchID: 1, Kind: "ask", RefKind: "ask", RefID: i, CreatedAt: old})
		require.NoError(t, err)
	}
	_, _, err := d.QueueWatchmanItem(WatchmanItem{WorkbenchID: 1, Kind: "check", RefKind: "session", RefID: 1, CreatedAt: old.Add(time.Hour)})
	require.NoError(t, err)
	it, err := d.LeaseWatchmanItem(time.Now(), time.Minute, func(it WatchmanItem) bool { return it.Kind == "check" })
	require.NoError(t, err)
	require.NotNil(t, it)
	require.Equal(t, "check", it.Kind)
}

func TestLeaseWatchmanItem_KindChangedAfterReadIsNotLeased(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmQueueAsk(t, d, 5)
	it, err := d.LeaseWatchmanItem(time.Now(), time.Minute, func(WatchmanItem) bool {
		ok, err := d.SetWatchmanItemKind("ask", 5, "ask", "check")
		require.NoError(t, err)
		require.True(t, ok)
		return true
	})
	require.NoError(t, err)
	require.Nil(t, it, "the row changed after it was read")
	var state string
	require.NoError(t, d.QueryRow(`SELECT state FROM watchman_items WHERE ref_id = 5`).Scan(&state))
	require.Equal(t, "queued", state)
}

func TestSetWatchmanItemKind_CollisionIsSentinel(t *testing.T) {
	d := openTestDB(t)
	wmTestWorkbench(t, d, 1)
	wmQueueAsk(t, d, 5)
	_, _, err := d.QueueWatchmanItem(WatchmanItem{WorkbenchID: 1, Kind: "check", RefKind: "ask", RefID: 5})
	require.NoError(t, err)
	ok, err := d.SetWatchmanItemKind("ask", 5, "ask", "check")
	require.False(t, ok)
	require.ErrorIs(t, err, ErrWatchmanItemExists)
}
