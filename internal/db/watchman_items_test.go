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

// wmArmSession arms session id directly.
func wmArmSession(t *testing.T, d *DB, id int64) {
	t.Helper()
	require.NoError(t, d.UpsertWatchmanArming(WatchmanArming{Scope: "session", RefID: id, ArmedAt: time.Now(), ArmedBy: "cli"}))
}

// wmPendingPermission records a pending permission request of session.
func wmPendingPermission(t *testing.T, d *DB, session, workbench int64) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, status, created_at)
		VALUES (?, ?, 'Bash', 'ls -la token=abc123SECRETxyz', 'pending', '2026-11-18T01:00:00.000Z')`, session, workbench)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func TestScanWatchmanWaitPoints_QueuesMissed(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	armed := newTestSession(t, d, wb)
	wmArmSession(t, d, armed)
	other := newTestSession(t, d, wb) // not armed
	auto := newTestSession(t, d, wb)
	wmArmSession(t, d, auto)
	_, run := seedRunningAutomationRun(t, d)
	_, err := d.Exec(`UPDATE terminal_sessions SET automation_run_id = ? WHERE id = ?`, run, auto)
	require.NoError(t, err)

	ask := questionAsk(wb, "Which store?")
	ask.Summary = "SQLite or files"
	ask.SessionID = nullID(armed)
	askID := mustInsertAsk(t, d, ask)
	perm := wmPendingPermission(t, d, armed, wb)
	unarmed := questionAsk(wb, "Not armed")
	unarmed.SessionID = nullID(other)
	mustInsertAsk(t, d, unarmed)
	wmPendingPermission(t, d, other, wb)
	autoAsk := questionAsk(wb, "Automation's")
	autoAsk.SessionID = nullID(auto)
	mustInsertAsk(t, d, autoAsk)
	runAsk := questionAsk(wb, "Run's own")
	runAsk.SessionID = nullID(armed)
	runAsk.AutomationRunID = nullID(run)
	mustInsertAsk(t, d, runAsk)

	now := time.Date(2026, 11, 18, 2, 0, 0, 0, time.UTC)
	n, err := d.ScanWatchmanWaitPoints(now, func(s string) string { return "clean:" + s })
	require.NoError(t, err)
	require.Equal(t, 2, n)

	it, err := d.WatchmanItemByRef("ask", askID, "ask")
	require.NoError(t, err)
	require.NotNil(t, it)
	require.Equal(t, "clean:Which store?\nSQLite or files", it.Question)
	require.Equal(t, armed, it.SessionID)
	require.Equal(t, wb, it.WorkbenchID)
	require.Equal(t, "queued", it.State)
	require.True(t, it.CreatedAt.Equal(now))
	p, err := d.WatchmanItemByRef("permission", perm, "permission")
	require.NoError(t, err)
	require.NotNil(t, p)
	require.Equal(t, "clean:Tool: Bash\nls -la token=abc123SECRETxyz", p.Question)

	n, err = d.ScanWatchmanWaitPoints(now, func(s string) string { return s })
	require.NoError(t, err)
	require.Equal(t, 0, n, "a second scan finds nothing new")
	var total int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM watchman_items`).Scan(&total))
	require.Equal(t, 2, total, "the automation's asks and the unarmed session's wait points are never queued")

	// An ask whose item changed kind (a handover) is not queued again as an ask.
	ok, err := d.SetWatchmanItemKind("ask", askID, "ask", "handover")
	require.NoError(t, err)
	require.True(t, ok)
	n, err = d.ScanWatchmanWaitPoints(now, func(s string) string { return s })
	require.NoError(t, err)
	require.Equal(t, 0, n)
}

func TestQueueWatchmanWaitPoint_OnlyArmed(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	s := newTestSession(t, d, wb)
	it := WatchmanItem{WorkbenchID: wb, SessionID: s, Kind: "review_doc", RefKind: "ask", RefID: 9, Question: "q"}
	id, ins, err := d.QueueWatchmanWaitPoint(it)
	require.NoError(t, err)
	require.False(t, ins)
	require.Zero(t, id, "an unarmed session queues nothing")

	wmArmSession(t, d, s)
	id, ins, err = d.QueueWatchmanWaitPoint(it)
	require.NoError(t, err)
	require.True(t, ins)
	require.NotZero(t, id)

	_, run := seedRunningAutomationRun(t, d)
	_, err = d.Exec(`UPDATE terminal_sessions SET automation_run_id = ? WHERE id = ?`, run, s)
	require.NoError(t, err)
	it.RefID = 10
	id, _, err = d.QueueWatchmanWaitPoint(it)
	require.NoError(t, err)
	require.Zero(t, id, "an ask of an automation's session is never the twin's")
	it.Kind, it.RefKind = "permission", "permission"
	id, _, err = d.QueueWatchmanWaitPoint(it)
	require.NoError(t, err)
	require.NotZero(t, id, "its permission prompts are")
}

func TestWatchmanAskItemKind(t *testing.T) {
	require.Equal(t, "ask", WatchmanAskItemKind("question"))
	require.Equal(t, "review_doc", WatchmanAskItemKind("review"))
	require.Equal(t, "check", WatchmanAskItemKind("check"))
}

// A writer that queues the ask between the scan's read and its insert — even
// under another kind (a handover) — wins: the scan adds no second row.
func TestScanWatchmanWaitPoints_RaceWithWriterKeepsOneRow(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	s := newTestSession(t, d, wb)
	wmArmSession(t, d, s)
	ask := questionAsk(wb, "Images later?")
	ask.SessionID = nullID(s)
	askID := mustInsertAsk(t, d, ask)
	prev := watchmanScanBeforeInsert
	watchmanScanBeforeInsert = func() {
		_, ins, err := d.QueueWatchmanItem(WatchmanItem{WorkbenchID: wb, SessionID: s, Kind: "handover", RefKind: "ask", RefID: askID})
		require.NoError(t, err)
		require.True(t, ins)
	}
	t.Cleanup(func() { watchmanScanBeforeInsert = prev })

	n, err := d.ScanWatchmanWaitPoints(time.Now(), func(s string) string { return s })
	require.NoError(t, err)
	require.Zero(t, n)
	var total int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM watchman_items WHERE ref_kind = 'ask' AND ref_id = ?`, askID).Scan(&total))
	require.Equal(t, 1, total)
}

// The writers use the scan's automation filter: an ask an automation run
// filed is not queued even from a session no automation started.
func TestQueueWatchmanWaitPoint_AutomationRunAskSkipped(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	s := newTestSession(t, d, wb)
	wmArmSession(t, d, s)
	_, run := seedRunningAutomationRun(t, d)
	ask := questionAsk(wb, "Run's own")
	ask.SessionID = nullID(s)
	ask.AutomationRunID = nullID(run)
	askID := mustInsertAsk(t, d, ask)
	id, _, err := d.QueueWatchmanWaitPoint(WatchmanItem{WorkbenchID: wb, SessionID: s, Kind: "ask", RefKind: "ask", RefID: askID})
	require.NoError(t, err)
	require.Zero(t, id)
}

// A wait point with an item of another kind keeps that one item.
func TestQueueWatchmanWaitPoint_AnyKindKeepsOneRow(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	s := newTestSession(t, d, wb)
	wmArmSession(t, d, s)
	first, ins, err := d.QueueWatchmanWaitPoint(WatchmanItem{WorkbenchID: wb, SessionID: s, Kind: "ask", RefKind: "ask", RefID: 7})
	require.NoError(t, err)
	require.True(t, ins)
	id, ins, err := d.QueueWatchmanWaitPoint(WatchmanItem{WorkbenchID: wb, SessionID: s, Kind: "handover", RefKind: "ask", RefID: 7})
	require.NoError(t, err)
	require.False(t, ins)
	require.Equal(t, first, id)
}

// A scan that queues the ask as an ordinary ask between the handover's read
// and its write transaction: the end state is exactly one handover row.
func TestPromoteWatchmanHandover_RaceWithScanEndsAsOneHandover(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	s := newTestSession(t, d, wb)
	wmArmSession(t, d, s)
	ask := questionAsk(wb, "Images later?")
	ask.SessionID = nullID(s)
	askID := mustInsertAsk(t, d, ask)
	prev := watchmanHandoverBeforeWrite
	watchmanHandoverBeforeWrite = func() {
		n, err := d.ScanWatchmanWaitPoints(time.Now(), func(s string) string { return s })
		require.NoError(t, err)
		require.Equal(t, 1, n, "the scan queued the ask as an ask")
	}
	t.Cleanup(func() { watchmanHandoverBeforeWrite = prev })

	promoted, inserted, err := d.PromoteWatchmanHandover(WatchmanItem{WorkbenchID: wb, SessionID: s, RefID: askID, Question: "q"})
	require.NoError(t, err)
	require.True(t, promoted)
	require.False(t, inserted)
	var kinds []string
	rows, err := d.Query(`SELECT kind FROM watchman_items WHERE ref_kind = 'ask' AND ref_id = ?`, askID)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var k string
		require.NoError(t, rows.Scan(&k))
		kinds = append(kinds, k)
	}
	require.NoError(t, rows.Err())
	require.Equal(t, []string{"handover"}, kinds)
}

// With no row at all an open ask is inserted as a handover; one that is no
// longer open is not.
func TestPromoteWatchmanHandover_InsertsOnlyForOpenAsk(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	s := newTestSession(t, d, wb)
	open := questionAsk(wb, "Open")
	open.SessionID = nullID(s)
	openID := mustInsertAsk(t, d, open)
	_, inserted, err := d.PromoteWatchmanHandover(WatchmanItem{WorkbenchID: wb, SessionID: s, RefID: openID, Question: "q"})
	require.NoError(t, err)
	require.True(t, inserted)
	it, err := d.WatchmanItemByRef("ask", openID, "handover")
	require.NoError(t, err)
	require.NotNil(t, it)

	done := questionAsk(wb, "Answered")
	done.SessionID = nullID(s)
	doneID := mustInsertAsk(t, d, done)
	markAskAnswered(t, d, doneID)
	promoted, inserted, err := d.PromoteWatchmanHandover(WatchmanItem{WorkbenchID: wb, SessionID: s, RefID: doneID, Question: "q"})
	require.NoError(t, err)
	require.False(t, promoted)
	require.False(t, inserted)
	it, err = d.WatchmanItemByRef("ask", doneID, "handover")
	require.NoError(t, err)
	require.Nil(t, it)
}
