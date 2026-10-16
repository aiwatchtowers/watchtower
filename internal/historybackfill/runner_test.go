package historybackfill

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

var _ Store = (*db.DB)(nil)

const day = 86400.0

type fakeStore struct {
	rows     []db.HistoryBackfill
	plan     *db.PlanUsageStatus
	failures int // RecordHistoryBackfillFailure calls
}

func (s *fakeStore) row(id int64) *db.HistoryBackfill {
	for i := range s.rows {
		if s.rows[i].ID == id {
			return &s.rows[i]
		}
	}
	panic("no row")
}

func (s *fakeStore) ListHistoryBackfills() ([]db.HistoryBackfill, error) {
	return append([]db.HistoryBackfill(nil), s.rows...), nil
}

func (s *fakeStore) AdvanceHistoryBackfill(id int64, reachedTS float64, _ time.Time) error {
	r := s.row(id)
	r.ReachedTS, r.ChunkFailures, r.LastError, r.Waiting = reachedTS, 0, "", ""
	if reachedTS <= r.FloorTS {
		r.Status = "done"
	}
	return nil
}

func (s *fakeStore) RecordHistoryBackfillFailure(id int64, msg string, _ time.Time) (int, error) {
	s.failures++
	r := s.row(id)
	r.ChunkFailures++
	r.LastError = msg
	return r.ChunkFailures, nil
}

func (s *fakeStore) SetHistoryBackfillStatus(id int64, status string, _ time.Time) error {
	s.row(id).Status = status
	return nil
}

func (s *fakeStore) SetHistoryBackfillWaiting(id int64, waiting string, _ time.Time) error {
	s.row(id).Waiting = waiting
	return nil
}

func (s *fakeStore) SetHistoryBackfillLastError(id int64, msg string, _ time.Time) error {
	s.row(id).LastError = msg
	return nil
}

func (s *fakeStore) GetPlanUsageStatus() (*db.PlanUsageStatus, error) { return s.plan, nil }

type call struct {
	op       string
	from, to time.Time
}

type fakeSource struct {
	kind       string
	id         int64
	fetchErr   error
	processErr error
	incomplete bool
	onProcess  func()
	block      bool // Process waits for its ctx to end
	calls      []call
}

func (f *fakeSource) Kind() string     { return f.kind }
func (f *fakeSource) AccountID() int64 { return f.id }

func (f *fakeSource) Fetch(_ context.Context, from, to time.Time) error {
	f.calls = append(f.calls, call{"fetch", from, to})
	return f.fetchErr
}

func (f *fakeSource) Process(ctx context.Context, from, to time.Time) (bool, error) {
	f.calls = append(f.calls, call{"process", from, to})
	if f.onProcess != nil {
		f.onProcess()
	}
	if f.block {
		<-ctx.Done()
		return false, ctx.Err()
	}
	return !f.incomplete, f.processErr
}

func (f *fakeSource) count(op string) int {
	n := 0
	for _, c := range f.calls {
		if c.op == op {
			n++
		}
	}
	return n
}

func running(id int64, kind string, acct int64, reached, floor float64) db.HistoryBackfill {
	return db.HistoryBackfill{ID: id, SourceKind: kind, AccountID: acct, FloorTS: floor,
		UpperTS: reached, ReachedTS: reached, Status: "running"}
}

func newRunner(st *fakeStore, srcs ...Source) *Runner {
	return &Runner{
		Store:   st,
		Sources: srcs,
		Account: func(string, int64) AccountState { return AccountOK },
		Budget:  5 * time.Minute,
		Now:     func() time.Time { return time.Unix(1_000_000_000, 0) },
		Logger:  log.New(io.Discard, "", 0),
	}
}

func ts(f float64) time.Time { return time.Unix(int64(f), 0).UTC() }

func TestRunner_NewestChunkFirst(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "slack", 1, 30*day, 0)}}
	src := &fakeSource{kind: "slack", id: 1}
	require.NoError(t, newRunner(st, src).Step(context.Background()))
	require.Len(t, src.calls, 2)
	assert.Equal(t, call{"fetch", ts(28 * day), ts(30 * day)}, src.calls[0])
	assert.Equal(t, call{"process", ts(28 * day), ts(30 * day)}, src.calls[1])
	assert.Equal(t, 28*day, st.rows[0].ReachedTS)
	assert.Equal(t, "running", st.rows[0].Status)
}

func TestRunner_OneChunkPerSourcePerStep(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{
		running(1, "slack", 1, 30*day, 0),
		running(2, "gmail", 7, 20*day, 0),
	}}
	a, b := &fakeSource{kind: "slack", id: 1}, &fakeSource{kind: "gmail", id: 7}
	require.NoError(t, newRunner(st, a, b).Step(context.Background()))
	assert.Equal(t, 1, a.count("process"))
	assert.Equal(t, 1, b.count("process"))
	assert.Equal(t, 28*day, st.rows[0].ReachedTS)
	assert.Equal(t, 18*day, st.rows[1].ReachedTS)
}

func TestRunner_FinishesAtFloor(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "gmail", 1, 5*day, 5*day)}}
	src := &fakeSource{kind: "gmail", id: 1}
	require.NoError(t, newRunner(st, src).Step(context.Background()))
	assert.Empty(t, src.calls)
	assert.Equal(t, "done", st.rows[0].Status)
}

func TestRunner_ThreeFailuresSkipChunk(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "gmail", 1, 30*day, 0)}}
	src := &fakeSource{kind: "gmail", id: 1, processErr: errors.New("boom")}
	r := newRunner(st, src)
	var buf bytes.Buffer
	r.Logger = log.New(&buf, "", 0)
	for i := 1; i <= 2; i++ {
		require.NoError(t, r.Step(context.Background()))
		assert.Equal(t, 30*day, st.rows[0].ReachedTS)
		assert.Equal(t, i, st.rows[0].ChunkFailures)
		assert.Equal(t, "process: boom", st.rows[0].LastError)
	}
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, 28*day, st.rows[0].ReachedTS)
	assert.Equal(t, 0, st.rows[0].ChunkFailures)
	assert.Equal(t, "running", st.rows[0].Status)
	assert.Contains(t, buf.String(), "SKIPPING gmail account 1 chunk ["+
		ts(28*day).Format(time.RFC3339)+", "+ts(30*day).Format(time.RFC3339)+") after 3 failures: process: boom")
	assert.Equal(t, "skipped "+ts(28*day).Format(time.RFC3339)+".."+ts(30*day).Format(time.RFC3339)+": process: boom",
		st.rows[0].LastError, "R23: the skip leaves a trace until the next successful chunk")

	src.processErr = nil
	require.NoError(t, r.Step(context.Background()))
	assert.Empty(t, st.rows[0].LastError, "the next successful chunk clears the trace")
}

// R23: a source's ErrHold (a Slack rate limit) holds the chunk like the
// budget deadline: no strike, no advance, the Step ends.
func TestRunner_FetchHoldIsNotAFailure(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "slack", 1, 30*day, 0), running(2, "imap", 1, 30*day, 0)}}
	a := &fakeSource{kind: "slack", id: 1, fetchErr: fmt.Errorf("search: %w", ErrHold)}
	b := &fakeSource{kind: "imap", id: 1}
	r := newRunner(st, a, b)
	var buf bytes.Buffer
	r.Logger = log.New(&buf, "", 0)
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, 0, a.count("process"))
	assert.Equal(t, 0, st.failures)
	assert.Equal(t, 0, st.rows[0].ChunkFailures)
	assert.Empty(t, st.rows[0].LastError)
	assert.Equal(t, 30*day, st.rows[0].ReachedTS)
	assert.Empty(t, b.calls, "the hold stops the Step")
	assert.Equal(t, 1, strings.Count(buf.String(), "\n"), "one log line")
	assert.Contains(t, buf.String(), "slack account 1")
}

func TestRunner_FetchFailureRecorded(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "imap", 1, 30*day, 0)}}
	src := &fakeSource{kind: "imap", id: 1, fetchErr: errors.New("net")}
	require.NoError(t, newRunner(st, src).Step(context.Background()))
	assert.Equal(t, 0, src.count("process"))
	assert.Equal(t, 30*day, st.rows[0].ReachedTS)
	assert.Equal(t, 1, st.rows[0].ChunkFailures)
}

func TestRunner_CanceledContextRecordsNoFailure(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "gmail", 1, 30*day, 0)}}
	ctx, cancel := context.WithCancel(context.Background())
	src := &fakeSource{kind: "gmail", id: 1, processErr: context.Canceled, onProcess: cancel}
	err := newRunner(st, src).Step(ctx)
	assert.ErrorIs(t, err, context.Canceled)
	assert.Equal(t, 0, st.failures)
	assert.Equal(t, 30*day, st.rows[0].ReachedTS)
}

func TestRunner_PlanGateHoldsChunk(t *testing.T) {
	st := &fakeStore{
		rows: []db.HistoryBackfill{running(1, "slack", 1, 30*day, 0), running(2, "gmail", 1, 30*day, 0)},
		plan: &db.PlanUsageStatus{State: "ok",
			LimitsJSON: `[{"key":"session","projection":{"state":"will_hit"}}]`},
	}
	a, b := &fakeSource{kind: "slack", id: 1}, &fakeSource{kind: "gmail", id: 1}
	r := newRunner(st, a, b)
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, 1, a.count("fetch"))
	assert.Equal(t, 0, a.count("process"))
	assert.Equal(t, 30*day, st.rows[0].ReachedTS)
	assert.Equal(t, "plan_limit", st.rows[0].Waiting)
	assert.Empty(t, b.calls, "the gate stops the whole Step")

	st.plan.LimitsJSON = `[{"key":"session","projection":{"state":"safe"}}]`
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, 1, a.count("process"))
	assert.Equal(t, 28*day, st.rows[0].ReachedTS)
	assert.Equal(t, "", st.rows[0].Waiting)
	assert.Equal(t, 1, b.count("process"))
}

func TestRunner_PlanGateClearsWaitingBeforeFailedProcess(t *testing.T) {
	r0 := running(1, "gmail", 1, 30*day, 0)
	r0.Waiting = "plan_limit"
	st := &fakeStore{rows: []db.HistoryBackfill{r0}}
	src := &fakeSource{kind: "gmail", id: 1, processErr: errors.New("boom")}
	require.NoError(t, newRunner(st, src).Step(context.Background()))
	assert.Equal(t, "", st.rows[0].Waiting)
}

// F6: waiting=plan_limit means "the plan gate holds this row"; a row that is
// paused, has no source wired, or whose fetch failed never reached the gate,
// so it must not keep claiming that.
func TestRunner_WaitingClearedWhenTheGateIsNotWhatHolds(t *testing.T) {
	waitingRow := func(id int64, kind string) db.HistoryBackfill {
		r := running(id, kind, id, 30*day, 0)
		r.Waiting = "plan_limit"
		return r
	}
	t.Run("revoked", func(t *testing.T) {
		st := &fakeStore{rows: []db.HistoryBackfill{waitingRow(1, "gmail")}}
		r := newRunner(st, &fakeSource{kind: "gmail", id: 1})
		r.Account = func(string, int64) AccountState { return AccountRevoked }
		require.NoError(t, r.Step(context.Background()))
		assert.Equal(t, "paused", st.rows[0].Status)
		assert.Equal(t, "", st.rows[0].Waiting)
	})
	t.Run("already paused", func(t *testing.T) {
		row := waitingRow(1, "gmail")
		row.Status = "paused"
		st := &fakeStore{rows: []db.HistoryBackfill{row}}
		r := newRunner(st, &fakeSource{kind: "gmail", id: 1})
		r.Account = func(string, int64) AccountState { return AccountRevoked }
		require.NoError(t, r.Step(context.Background()))
		assert.Equal(t, "", st.rows[0].Waiting)
	})
	t.Run("no source", func(t *testing.T) {
		st := &fakeStore{rows: []db.HistoryBackfill{waitingRow(1, "imap")}}
		require.NoError(t, newRunner(st).Step(context.Background()))
		assert.Equal(t, "", st.rows[0].Waiting)
	})
	t.Run("fetch fails", func(t *testing.T) {
		st := &fakeStore{rows: []db.HistoryBackfill{waitingRow(1, "imap")}}
		src := &fakeSource{kind: "imap", id: 1, fetchErr: errors.New("net")}
		require.NoError(t, newRunner(st, src).Step(context.Background()))
		assert.Equal(t, 1, st.rows[0].ChunkFailures)
		assert.Equal(t, "", st.rows[0].Waiting)
	})
}

func TestRunner_IncompleteProcessHolds(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "slack", 1, 30*day, 0), running(2, "gmail", 1, 30*day, 0)}}
	a := &fakeSource{kind: "slack", id: 1, incomplete: true}
	b := &fakeSource{kind: "gmail", id: 1}
	require.NoError(t, newRunner(st, a, b).Step(context.Background()))
	assert.Equal(t, 30*day, st.rows[0].ReachedTS)
	assert.Equal(t, 0, st.failures)
	assert.Empty(t, b.calls, "an incomplete chunk stops the Step")
}

func TestRunner_RevokedPausesAndResumes(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "gmail", 3, 30*day, 0)}}
	src := &fakeSource{kind: "gmail", id: 3}
	r := newRunner(st, src)
	state := AccountRevoked
	r.Account = func(kind string, id int64) AccountState {
		assert.Equal(t, "gmail", kind)
		assert.Equal(t, int64(3), id)
		return state
	}
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, "paused", st.rows[0].Status)
	assert.Empty(t, src.calls)

	state = AccountOK
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, "running", st.rows[0].Status)
	assert.Equal(t, 1, src.count("fetch"))
}

func TestRunner_RemovedAccountTurnsOff(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "slack", 1, 30*day, 0)}}
	src := &fakeSource{kind: "slack", id: 1}
	r := newRunner(st, src)
	r.Account = func(string, int64) AccountState { return AccountGone }
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, "off", st.rows[0].Status)
	assert.Empty(t, src.calls)
}

func TestRunner_BudgetStopsStep(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "slack", 1, 30*day, 0), running(2, "gmail", 1, 30*day, 0)}}
	now := time.Unix(1_000_000_000, 0)
	a := &fakeSource{kind: "slack", id: 1, onProcess: func() { now = now.Add(6 * time.Minute) }}
	b := &fakeSource{kind: "gmail", id: 1}
	r := newRunner(st, a, b)
	r.Now = func() time.Time { return now }
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, 1, a.count("process"))
	assert.Empty(t, b.calls)
	assert.Equal(t, 30*day, st.rows[1].ReachedTS)
}

func withStatus(b db.HistoryBackfill, status string) db.HistoryBackfill {
	b.Status = status
	return b
}

// recordHook installs an OnSlackDone that records each floor it is called with.
func recordHook(r *Runner, err error) *[]time.Time {
	var floors []time.Time
	r.OnSlackDone = func(_ context.Context, floor time.Time) error {
		floors = append(floors, floor)
		return err
	}
	return &floors
}

func TestRunner_SlackDoneHookEveryStep(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{
		withStatus(running(1, "slack", 1, 10*day, 10*day), "done"),
		running(2, "slack", 2, 4*day, 3*day),
		running(3, "gmail", 1, 30*day, 0),
	}}
	r := newRunner(st, &fakeSource{kind: "slack", id: 2}, &fakeSource{kind: "gmail", id: 1})
	floors := recordHook(r, nil)

	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, "done", st.rows[1].Status)
	assert.Equal(t, []time.Time{ts(3 * day)}, *floors)

	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, []time.Time{ts(3 * day), ts(3 * day)}, *floors, "the daemon owns run-once")
}

func TestRunner_SlackDoneHookCountsOffRows(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{
		withStatus(running(1, "slack", 1, 0, 0), "off"),
		withStatus(running(2, "slack", 2, 5*day, 5*day), "done"),
	}}
	r := newRunner(st)
	floors := recordHook(r, nil)
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, []time.Time{ts(5 * day)}, *floors, "floor = min over the done rows only")
}

func TestRunner_SlackDoneHookErrorIsLoggedOnly(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{withStatus(running(1, "slack", 1, 0, 0), "done")}}
	r := newRunner(st)
	var buf bytes.Buffer
	r.Logger = log.New(&buf, "", 0)
	floors := recordHook(r, errors.New("inbox down"))
	require.NoError(t, r.Step(context.Background()))
	assert.Len(t, *floors, 1)
	assert.Contains(t, buf.String(), "inbox down")
}

func TestRunner_SlackDoneHookNotCalled(t *testing.T) {
	cases := map[string]struct {
		rows    []db.HistoryBackfill
		account AccountState
	}{
		"a slack row running": {rows: []db.HistoryBackfill{
			withStatus(running(1, "slack", 1, 0, 0), "done"),
			running(2, "slack", 2, 30*day, 0),
		}},
		"a slack row paused": {rows: []db.HistoryBackfill{
			withStatus(running(1, "slack", 1, 0, 0), "done"),
			withStatus(running(2, "slack", 2, 30*day, 0), "paused"),
		}, account: AccountRevoked},
		"every slack row off": {rows: []db.HistoryBackfill{withStatus(running(1, "slack", 1, 0, 0), "off")}},
		"no slack rows":       {rows: []db.HistoryBackfill{withStatus(running(1, "gmail", 1, 0, 0), "done")}},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			st := &fakeStore{rows: tc.rows}
			r := newRunner(st) // no sources: a running row stays running
			r.Account = func(string, int64) AccountState { return tc.account }
			floors := recordHook(r, nil)
			require.NoError(t, r.Step(context.Background()))
			assert.Empty(t, *floors)
		})
	}
}

// R21: the hook runs under the Step's budget deadline, and not at all once
// the rows used the budget up.
func TestRunner_SlackDoneHookRunsUnderBudget(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{withStatus(running(1, "slack", 1, 0, 0), "done")}}
	r := newRunner(st)
	var hasDeadline bool
	r.OnSlackDone = func(ctx context.Context, _ time.Time) error {
		_, hasDeadline = ctx.Deadline()
		return nil
	}
	require.NoError(t, r.Step(context.Background()))
	assert.True(t, hasDeadline, "the hook gets the budget ctx")

	st = &fakeStore{rows: []db.HistoryBackfill{
		withStatus(running(1, "slack", 1, 0, 0), "done"),
		running(2, "gmail", 1, 30*day, 0),
	}}
	r = newRunner(st, &fakeSource{kind: "gmail", id: 1, block: true})
	r.Budget = 50 * time.Millisecond
	floors := recordHook(r, nil)
	require.NoError(t, r.Step(context.Background()))
	assert.Empty(t, *floors, "the budget is spent: the hook waits for the next Step")
}

func TestRunner_SlackDoneHookSkippedOnCanceledContext(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{withStatus(running(1, "slack", 1, 0, 0), "done")}}
	r := newRunner(st)
	floors := recordHook(r, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_ = r.Step(ctx)
	assert.Empty(t, *floors)
}

func TestRunner_BudgetDeadlineHoldsChunk(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "gmail", 1, 30*day, 0), running(2, "imap", 1, 30*day, 0)}}
	a := &fakeSource{kind: "gmail", id: 1, block: true}
	b := &fakeSource{kind: "imap", id: 1}
	r := newRunner(st, a, b)
	r.Budget = 50 * time.Millisecond
	require.NoError(t, r.Step(context.Background()))
	assert.Equal(t, 1, a.count("process"))
	assert.Equal(t, 0, st.failures)
	assert.Equal(t, 30*day, st.rows[0].ReachedTS)
	assert.Empty(t, b.calls, "the deadline stops the Step")
}

func TestRunner_NoSourceWiredSkips(t *testing.T) {
	st := &fakeStore{rows: []db.HistoryBackfill{running(1, "imap", 9, 30*day, 0)}}
	other := &fakeSource{kind: "imap", id: 8}
	require.NoError(t, newRunner(st, other).Step(context.Background()))
	assert.Empty(t, other.calls)
	assert.Equal(t, running(1, "imap", 9, 30*day, 0), st.rows[0])
}
