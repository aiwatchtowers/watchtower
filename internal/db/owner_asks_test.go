package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/asks"
)

func questionAsk(projectID int64, title string) OwnerAsk {
	return OwnerAsk{WorkbenchID: projectID, Kind: "question", Title: title}
}

func insertTestAsk(t *testing.T, d *DB, a OwnerAsk) (id, superseded int64, err error) {
	t.Helper()
	err = d.WithTx(func(tx *sql.Tx) error {
		var err error
		id, superseded, err = d.InsertOwnerAsk(tx, a)
		return err
	})
	return id, superseded, err
}

func mustInsertAsk(t *testing.T, d *DB, a OwnerAsk) int64 {
	t.Helper()
	id, _, err := insertTestAsk(t, d, a)
	require.NoError(t, err)
	return id
}

// markAskAnswered stands in for the Desktop, the only writer of answered.
func markAskAnswered(t *testing.T, d *DB, id int64) {
	t.Helper()
	_, err := d.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{"note":"ok"}',
		answered_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ? AND status = 'open'`, id)
	require.NoError(t, err)
}

func askStatus(t *testing.T, d *DB, id int64) (status, reason string) {
	t.Helper()
	require.NoError(t, d.QueryRow(`SELECT status, withdrawn_reason FROM owner_asks WHERE id = ?`, id).Scan(&status, &reason))
	return status, reason
}

func newTestSession(t *testing.T, d *DB, projectID int64) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'New session', '/tmp/acme', 'uuid')`, projectID)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func TestInsertOwnerAsk_FilesAnOpenAsk(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	tid := insertWorkbenchTargetRow(t, d, pid, "board item")
	sid := newTestSession(t, d, pid)

	id, superseded, err := insertTestAsk(t, d, OwnerAsk{WorkbenchID: pid, SessionID: nullID(sid), TargetID: nullID(tid),
		Kind: "review", Title: "Spec", Summary: "Read it", Payload: `{"focus":[]}`,
		DocPath: "docs/spec.md", DocSnapshot: "# Spec\n", Status: "answered", Answer: `{"verdict":"approved"}`})
	require.NoError(t, err)
	assert.Zero(t, superseded)

	a, err := d.GetOwnerAsk(pid, id)
	require.NoError(t, err)
	assert.Equal(t, OwnerAsk{ID: id, WorkbenchID: pid, SessionID: nullID(sid), TargetID: nullID(tid),
		Kind: "review", Title: "Spec", Summary: "Read it", Payload: `{"focus":[]}`,
		DocPath: "docs/spec.md", DocSnapshot: "# Spec\n", Status: "open", CreatedAt: a.CreatedAt}, *a,
		"an insert is always open and unanswered, whatever the caller passed")
	assert.NotEmpty(t, a.CreatedAt)

	id, _, err = insertTestAsk(t, d, questionAsk(pid, "Which?"))
	require.NoError(t, err)
	a, err = d.GetOwnerAsk(pid, id)
	require.NoError(t, err)
	assert.Equal(t, "{}", a.Payload, "an empty payload is stored as {}")
	assert.False(t, a.SessionID.Valid)
}

func TestInsertOwnerAsk_RefusesThe31stOpenAsk(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)

	answered := mustInsertAsk(t, d, questionAsk(pid, "Old"))
	markAskAnswered(t, d, answered)
	var first int64
	for i := 0; i < asks.MaxOpenPerWorkbench; i++ {
		id := mustInsertAsk(t, d, questionAsk(pid, "Q"))
		if first == 0 {
			first = id
		}
	}
	_, _, err = insertTestAsk(t, d, questionAsk(pid, "One too many"))
	assert.ErrorIs(t, err, ErrTooManyOpenAsks)
	assert.EqualError(t, err, "too many open asks (30) — withdraw or wait for answers")

	_, _, err = insertTestAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "question", Title: "Re-ask",
		PreviousAskID: nullID(answered)})
	assert.ErrorIs(t, err, ErrTooManyOpenAsks, "superseding an answered ask frees no slot")

	_, _, err = insertTestAsk(t, d, questionAsk(other, "Elsewhere"))
	assert.NoError(t, err, "the cap is per workbench")

	id, superseded, err := insertTestAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "question", Title: "Replacement",
		PreviousAskID: nullID(first)})
	require.NoError(t, err, "superseding an open ask at the cap keeps the count")
	assert.Equal(t, first, superseded)
	assert.NotZero(t, id)

	require.NoError(t, d.WithdrawOwnerAsk(pid, id, WithdrawnByAgent))
	_, _, err = insertTestAsk(t, d, questionAsk(pid, "Fits again"))
	assert.NoError(t, err, "a withdrawn ask frees its slot")
}

func TestInsertOwnerAsk_SupersedesOnlyAnOpenPrevious(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)

	prev := mustInsertAsk(t, d, questionAsk(pid, "Round 1"))
	id, superseded, err := insertTestAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "question", Title: "Round 2",
		Changes: "narrowed", PreviousAskID: nullID(prev)})
	require.NoError(t, err)
	assert.Equal(t, prev, superseded)
	status, reason := askStatus(t, d, prev)
	assert.Equal(t, []string{"withdrawn", WithdrawnSuperseded}, []string{status, reason})
	a, err := d.GetOwnerAsk(pid, id)
	require.NoError(t, err)
	assert.Equal(t, nullID(prev), a.PreviousAskID)
	assert.Equal(t, "narrowed", a.Changes)

	markAskAnswered(t, d, id)
	_, superseded, err = insertTestAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "question", Title: "Round 3",
		PreviousAskID: nullID(id)})
	require.NoError(t, err)
	assert.Zero(t, superseded, "an answered previous ask is not superseded")
	status, _ = askStatus(t, d, id)
	assert.Equal(t, "answered", status, "an answered previous ask is left alone")
}

func TestInsertOwnerAsk_RefusesReferencesOutsideTheWorkbench(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	foreignAsk := mustInsertAsk(t, d, questionAsk(other, "Theirs"))
	foreignTarget := insertWorkbenchTargetRow(t, d, other, "their item")
	foreignSession := newTestSession(t, d, other)
	ownCheck := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "check", Title: "Run it"})

	_, _, err = insertTestAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "question", Title: "Q", PreviousAskID: nullID(foreignAsk)})
	assert.ErrorIs(t, err, ErrAskNotFound, "another workbench's ask is not found")
	status, _ := askStatus(t, d, foreignAsk)
	assert.Equal(t, "open", status, "another workbench's ask is never superseded")

	_, _, err = insertTestAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "question", Title: "Q", PreviousAskID: nullID(ownCheck)})
	assert.ErrorContains(t, err, "previous_ask_id: ask")
	status, _ = askStatus(t, d, ownCheck)
	assert.Equal(t, "open", status, "an ask of another kind is never superseded")

	_, _, err = insertTestAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "question", Title: "Q", TargetID: nullID(foreignTarget)})
	assert.ErrorIs(t, err, ErrNotInWorkbench, "another workbench's target")
	_, _, err = insertTestAsk(t, d, OwnerAsk{WorkbenchID: pid, Kind: "question", Title: "Q", SessionID: nullID(foreignSession)})
	assert.ErrorIs(t, err, ErrNotInWorkbench, "another workbench's session")
}

func TestGetOwnerAsk_AnotherWorkbenchsAskIsNotFound(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	id := mustInsertAsk(t, d, questionAsk(other, "Theirs"))

	_, err = d.GetOwnerAsk(pid, id)
	assert.ErrorIs(t, err, ErrAskNotFound)
	_, err = d.GetOwnerAsk(pid, id+100)
	assert.ErrorIs(t, err, ErrAskNotFound)
	a, err := d.GetOwnerAsk(other, id)
	require.NoError(t, err)
	assert.Equal(t, "Theirs", a.Title)
}

func TestListOwnerAsks_FiltersAndOrders(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	s1 := newTestSession(t, d, pid)
	s2 := newTestSession(t, d, pid)

	open1 := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, SessionID: nullID(s1), Kind: "question", Title: "open 1"})
	answered1 := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, SessionID: nullID(s2), Kind: "question", Title: "answered 1"})
	markAskAnswered(t, d, answered1)
	review := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, SessionID: nullID(s1), Kind: "review", Title: "spec",
		DocPath: "docs/spec.md", DocSnapshot: "big text"})
	delivered := mustInsertAsk(t, d, questionAsk(pid, "delivered"))
	markAskAnswered(t, d, delivered)
	ok, err := d.MarkOwnerAskDelivered(pid, delivered)
	require.NoError(t, err)
	require.True(t, ok)
	withdrawn := mustInsertAsk(t, d, questionAsk(pid, "withdrawn"))
	require.NoError(t, d.WithdrawOwnerAsk(pid, withdrawn, WithdrawnByAgent))
	answered2 := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, SessionID: nullID(s1), Kind: "question", Title: "answered 2"})
	markAskAnswered(t, d, answered2)
	mustInsertAsk(t, d, questionAsk(other, "elsewhere"))

	ids := func(f OwnerAskFilter) []int64 {
		t.Helper()
		list, err := d.ListOwnerAsks(pid, f)
		require.NoError(t, err)
		out := []int64{}
		for _, a := range list {
			assert.Empty(t, a.DocSnapshot, "a list leaves the snapshot out")
			out = append(out, a.ID)
		}
		return out
	}
	assert.Equal(t, []int64{answered2, answered1, review, open1}, ids(OwnerAskFilter{}),
		"default: answered (not delivered) first, then open, newest first")
	assert.Equal(t, []int64{answered2, answered1, review, open1, withdrawn, delivered},
		ids(OwnerAskFilter{Statuses: []string{"open", "answered", "delivered", "withdrawn"}}))
	assert.Equal(t, []int64{review, open1}, ids(OwnerAskFilter{Statuses: []string{"open"}}))
	assert.Equal(t, []int64{answered2, review, open1}, ids(OwnerAskFilter{SessionID: s1}))
	assert.Equal(t, []int64{answered2, answered1}, ids(OwnerAskFilter{Limit: 2}))

	a, err := d.GetOwnerAsk(pid, review)
	require.NoError(t, err)
	assert.Equal(t, "big text", a.DocSnapshot, "a get carries the snapshot")
}

func TestWithdrawOwnerAsk_OnlyAnOpenAsk(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)

	id := mustInsertAsk(t, d, questionAsk(pid, "Q"))
	assert.Error(t, d.WithdrawOwnerAsk(pid, id, ""), "a withdrawal names its reason")
	require.NoError(t, d.WithdrawOwnerAsk(pid, id, WithdrawnByAgent))
	status, reason := askStatus(t, d, id)
	assert.Equal(t, []string{"withdrawn", WithdrawnByAgent}, []string{status, reason})

	err = d.WithdrawOwnerAsk(pid, id, WithdrawnByAgent)
	assert.ErrorIs(t, err, ErrAskNotOpen)
	assert.ErrorContains(t, err, "is withdrawn")

	answered := mustInsertAsk(t, d, questionAsk(pid, "A"))
	markAskAnswered(t, d, answered)
	err = d.WithdrawOwnerAsk(pid, answered, WithdrawnByAgent)
	assert.ErrorIs(t, err, ErrAskNotOpen)
	assert.ErrorContains(t, err, "is answered")
	status, _ = askStatus(t, d, answered)
	assert.Equal(t, "answered", status)

	theirs := mustInsertAsk(t, d, questionAsk(other, "Theirs"))
	assert.ErrorIs(t, d.WithdrawOwnerAsk(pid, theirs, WithdrawnByAgent), ErrAskNotFound)
	status, _ = askStatus(t, d, theirs)
	assert.Equal(t, "open", status, "another workbench's ask is untouched")
}

func TestMarkOwnerAskDelivered_OnlyAnAnsweredAskOnce(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)

	id := mustInsertAsk(t, d, questionAsk(pid, "Q"))
	ok, err := d.MarkOwnerAskDelivered(pid, id)
	require.NoError(t, err)
	assert.False(t, ok, "an open ask is not delivered")
	status, _ := askStatus(t, d, id)
	assert.Equal(t, "open", status)

	markAskAnswered(t, d, id)
	ok, err = d.MarkOwnerAskDelivered(other, id)
	require.NoError(t, err)
	assert.False(t, ok, "another workbench cannot deliver it")

	ok, err = d.MarkOwnerAskDelivered(pid, id)
	require.NoError(t, err)
	assert.True(t, ok)
	a, err := d.GetOwnerAsk(pid, id)
	require.NoError(t, err)
	assert.Equal(t, "delivered", a.Status)
	assert.NotEmpty(t, a.DeliveredAt)
	assert.Equal(t, `{"note":"ok"}`, a.Answer, "delivery keeps the answer")

	ok, err = d.MarkOwnerAskDelivered(pid, id)
	require.NoError(t, err)
	assert.False(t, ok, "a second delivery is a no-op")
}

func TestOwnerAsk_DeletedSessionSetsSessionNull(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sid := newTestSession(t, d, pid)
	id := mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, SessionID: nullID(sid), Kind: "question", Title: "Q"})

	_, err := d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, sid)
	require.NoError(t, err)
	a, err := d.GetOwnerAsk(pid, id)
	require.NoError(t, err)
	assert.False(t, a.SessionID.Valid, "the ask outlives its session, unbound")
}

func TestAnsweredAsksForBrief_OwnSessionUnboundAndGone(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	mine := newTestSession(t, d, pid)
	theirs := newTestSession(t, d, pid)

	answer := func(a OwnerAsk) int64 {
		t.Helper()
		id := mustInsertAsk(t, d, a)
		markAskAnswered(t, d, id)
		return id
	}
	own := answer(OwnerAsk{WorkbenchID: pid, SessionID: nullID(mine), Kind: "question", Title: "own"})
	unbound := answer(questionAsk(pid, "unbound"))
	answer(OwnerAsk{WorkbenchID: pid, SessionID: nullID(theirs), Kind: "question", Title: "theirs"})
	gone := answer(questionAsk(pid, "gone session"))
	// A session id naming no row: a writer that ran with foreign keys off.
	_, err = d.Exec(`PRAGMA foreign_keys = OFF`)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE owner_asks SET session_id = 9999 WHERE id = ?`, gone)
	require.NoError(t, err)
	_, err = d.Exec(`PRAGMA foreign_keys = ON`)
	require.NoError(t, err)
	mustInsertAsk(t, d, OwnerAsk{WorkbenchID: pid, SessionID: nullID(mine), Kind: "question", Title: "still open"})
	delivered := answer(OwnerAsk{WorkbenchID: pid, SessionID: nullID(mine), Kind: "question", Title: "delivered"})
	_, err = d.MarkOwnerAskDelivered(pid, delivered)
	require.NoError(t, err)
	answer(questionAsk(other, "other workbench"))

	list, others, err := d.AnsweredAsksForBrief(pid, mine)
	require.NoError(t, err)
	var ids []int64
	for _, a := range list {
		ids = append(ids, a.ID)
	}
	assert.Equal(t, []int64{own, unbound, gone}, ids)
	assert.Equal(t, 1, others, "the other session's answered ask is only counted")

	list, others, err = d.AnsweredAsksForBrief(pid, 0)
	require.NoError(t, err)
	assert.Len(t, list, 2, "no session: the unbound and gone-session asks")
	assert.Equal(t, 2, others)
}
