package db

import (
	"database/sql"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/asks"
)

// automationAsk is an ask an automation run filed: no session, the run set.
func automationAsk(workbenchID, runID int64, title string) OwnerAsk {
	a := questionAsk(workbenchID, title)
	a.AutomationRunID = sql.NullInt64{Int64: runID, Valid: true}
	return a
}

// An automation's ask never reaches a session-side reader (the brief, the
// series hint, the withdrawn-title check, list_asks' filter); the owner-facing
// readers and the per-workbench cap still see it.
func TestAutomationAsks_InvisibleToSessionReaders(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	sid := newTestSession(t, d, wb)
	_, run := seedRunningAutomationRun(t, d)

	auto := mustInsertAsk(t, d, automationAsk(wb, run, "Deploy now?"))
	external := mustInsertAsk(t, d, questionAsk(wb, "External terminal ask"))
	// An automation ask bound to another session (a shape ask() never files)
	// would otherwise be counted in the brief's "others".
	otherSession := automationAsk(wb, run, "Pick a zone")
	otherSession.SessionID = nullID(newTestSession(t, d, wb))
	boundAnswered := mustInsertAsk(t, d, otherSession)
	markAskAnswered(t, d, auto)
	markAskAnswered(t, d, external)
	markAskAnswered(t, d, boundAnswered)

	for _, session := range []int64{sid, 0} {
		list, others, err := d.AnsweredAsksForBrief(wb, session)
		require.NoError(t, err)
		require.Len(t, list, 1, "session %d", session)
		assert.Equal(t, external, list[0].ID)
		assert.Equal(t, 0, others, "an automation ask is not another session's either")
	}

	sessionSide, err := d.ListOwnerAsks(wb, OwnerAskFilter{ExcludeAutomation: true})
	require.NoError(t, err)
	require.Len(t, sessionSide, 1)
	assert.Equal(t, external, sessionSide[0].ID)
	ownerSide, err := d.ListOwnerAsks(wb, OwnerAskFilter{})
	require.NoError(t, err)
	assert.Len(t, ownerSide, 3, "the owner-facing list keeps automation asks")

	// A session-bound automation ask (a shape ask() never files) is still no
	// series ask.
	bound := automationAsk(wb, run, "Pick a region")
	bound.SessionID = nullID(sid)
	mustInsertAsk(t, d, bound)
	series, err := d.RecentOpenQuestionAsk(sid, time.Now().Add(-time.Hour), 0)
	require.NoError(t, err)
	assert.Nil(t, series)
	open, err := d.CountOpenOwnerAsks(wb)
	require.NoError(t, err)
	assert.Equal(t, 1, open, "the cap counts automation asks")

	withdrawn := mustInsertAsk(t, d, automationAsk(wb, run, "Rotate the keys?"))
	require.NoError(t, d.WithdrawOwnerAsk(wb, withdrawn, WithdrawnByAgent))
	w, err := d.LastWithdrawnByTitle(wb, asks.KindQuestion, asks.NormalizeTitle("Rotate the keys?"), time.Now().Add(-time.Hour))
	require.NoError(t, err)
	assert.Nil(t, w, "an automation's withdrawn ask is no revision candidate")
}

// The executor's sweep withdraws (agent) the open asks of runs that ended
// and leaves an active run's ask, an answered ask and a session's ask alone.
func TestAutomationAsks_WithdrawnWhenTheirRunEnded(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	_, live := seedRunningAutomationRun(t, d)
	ended := seedGrantRun(t, d, seedRunAutomation(t, d, "other", 1), "h")
	ok, err := d.CancelAutomationRun(ended, runTestNow)
	require.NoError(t, err)
	require.True(t, ok)

	liveAsk := mustInsertAsk(t, d, automationAsk(wb, live, "Live"))
	endedAsk := mustInsertAsk(t, d, automationAsk(wb, ended, "Ended"))
	answered := mustInsertAsk(t, d, automationAsk(wb, ended, "Answered"))
	markAskAnswered(t, d, answered)
	plain := mustInsertAsk(t, d, questionAsk(wb, "Plain"))

	n, err := d.WithdrawAsksOfEndedAutomationRuns()
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	for id, want := range map[int64][2]string{
		liveAsk: {"open", ""}, endedAsk: {"withdrawn", WithdrawnByAgent}, answered: {"answered", ""}, plain: {"open", ""},
	} {
		status, reason := askStatus(t, d, id)
		assert.Equal(t, want, [2]string{status, reason}, "ask %d", id)
	}
	n, err = d.WithdrawAsksOfEndedAutomationRuns()
	require.NoError(t, err)
	assert.Equal(t, 0, n, "a second sweep finds nothing")
}

// runAsks files an open, an answered and a delivered ask of run on wb.
func runAsks(t *testing.T, d *DB, wb, run int64) []int64 {
	t.Helper()
	open := mustInsertAsk(t, d, automationAsk(wb, run, "Open"))
	answered := mustInsertAsk(t, d, automationAsk(wb, run, "Answered"))
	markAskAnswered(t, d, answered)
	delivered := mustInsertAsk(t, d, automationAsk(wb, run, "Delivered"))
	markAskAnswered(t, d, delivered)
	ok, err := d.MarkOwnerAskDelivered(wb, delivered)
	require.NoError(t, err)
	require.True(t, ok)
	return []int64{open, answered, delivered}
}

func askCount(t *testing.T, d *DB, ids []int64) int {
	t.Helper()
	n := 0
	for _, id := range ids {
		var c int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM owner_asks WHERE id = ?`, id).Scan(&c))
		n += c
	}
	return n
}

// Deleting an automation deletes its runs' asks in every status in the same
// transaction: the run's FK would otherwise null automation_run_id and make
// them look like an external terminal's asks, which every session sees. A
// refused delete keeps them; another ask stays.
func TestAutomationAsks_DeleteIdleAutomationDeletesItsAsks(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	a, run := seedRunningAutomationRun(t, d)
	ids := runAsks(t, d, wb, run)
	plain := mustInsertAsk(t, d, questionAsk(wb, "Plain"))

	wantErrIs(t, "delete with an active run", d.DeleteIdleAutomation(a), ErrAutomationActive)
	assert.Equal(t, 3, askCount(t, d, ids), "a refused delete deletes nothing")

	mustFinishAutomationRun(t, d, run, RunFinish{Status: RunFailed, ErrorKind: ErrKindInterrupted}, nil)
	require.NoError(t, d.DeleteIdleAutomation(a))
	assert.Equal(t, 0, askCount(t, d, ids))
	assert.Equal(t, 1, askCount(t, d, []int64{plain}))
}

func TestAutomationAsks_DeleteAutomationDeletesItsAsks(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	a, run := seedRunningAutomationRun(t, d)
	ids := runAsks(t, d, wb, run)
	plain := mustInsertAsk(t, d, questionAsk(wb, "Plain"))
	require.NoError(t, d.DeleteAutomation(a))
	assert.Equal(t, 0, askCount(t, d, ids))
	assert.Equal(t, 1, askCount(t, d, []int64{plain}))
}
