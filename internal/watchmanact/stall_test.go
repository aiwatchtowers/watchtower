package watchmanact

import (
	"context"
	"database/sql"
	"errors"
	"sync"
	"testing"
	"time"

	"watchtower/internal/askanswer"
	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// stallPort is a session host for the stall watch: every live session's run
// began an hour before t0; Deliver answers outcome (submitted by default),
// or fails with deliverErr.
type stallPort struct {
	mu         sync.Mutex
	live       map[int64]bool
	liveErr    error
	startedAt  time.Time
	outcome    string
	deliverErr error
	lines      []string
	holds      []bool // each request's HoldIfPromptText
}

func (p *stallPort) Live(_ context.Context, id int64) (askanswer.LiveRun, bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.liveErr != nil {
		return askanswer.LiveRun{}, false, p.liveErr
	}
	if !p.live[id] {
		return askanswer.LiveRun{}, false, nil
	}
	return askanswer.LiveRun{SessionID: id, Run: 1, Agent: "claude", StartedAt: p.startedAt}, true, nil
}

func (p *stallPort) Deliver(_ context.Context, r askanswer.DeliverRequest) (askanswer.DeliverResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.lines = append(p.lines, r.Text)
	p.holds = append(p.holds, r.HoldIfPromptText)
	if p.deliverErr != nil {
		return askanswer.DeliverResult{}, p.deliverErr
	}
	out := p.outcome
	if out == "" {
		out = askanswer.DeliverSubmitted
	}
	return askanswer.DeliverResult{Outcome: out}, nil
}

func (p *stallPort) set(outcome string, err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.outcome, p.deliverErr = outcome, err
}

func (p *stallPort) delivered() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.lines...)
}

var stallT0 = time.Date(2026, 11, 21, 10, 0, 0, 0, time.UTC)

// stallEnv is one armed live session on a target, the twin over a fake
// clock, the stallPort and a scripted worktree HEAD.
type stallEnv struct {
	t                   *testing.T
	db                  *db.DB
	port                *stallPort
	wb, session, target int64
	mu                  sync.Mutex
	now                 time.Time
	head                string
	headErr             error
	onHead              func()
	answerer            *askanswer.Answerer
	twin                *Twin
}

func newStallEnv(t *testing.T) *stallEnv {
	t.Helper()
	e := &stallEnv{t: t, db: db.OpenTestDB(t), port: &stallPort{live: map[int64]bool{}, startedAt: stallT0.Add(-time.Hour)},
		now: stallT0, head: "c0ffee"}
	wb, err := e.db.CreateWorkbench("acme", t.TempDir())
	e.must(err)
	e.wb = wb
	res, err := e.db.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end, source_type, project_id)
		VALUES ('Ship the export', 'custom', 'project', '2026-11-21', '2026-11-21', 'chat', ?)`, wb)
	e.must(err)
	e.target, _ = res.LastInsertId()
	res, err = e.db.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, target_id)
		VALUES (?, 'claude', 'New session', '/tmp/acme', 'uuid', ?)`, wb, e.target)
	e.must(err)
	e.session, _ = res.LastInsertId()
	e.port.live[e.session] = true
	e.arm()
	e.answerer = askanswer.New(askanswer.Deps{DB: e.db, Sessions: e.port, Clock: e.clock})
	e.twin = e.newTwin()
	return e
}

// newTwin is a twin over e's database, port and clock (a restarted daemon
// builds a new one).
func (e *stallEnv) newTwin() *Twin {
	return NewTwin(TwinDeps{
		DB: e.db, Answerer: e.answerer, Live: e.port.Live, Clock: e.clock,
		Head: func(_ context.Context, folder string) (string, error) {
			e.mu.Lock()
			head, err, hook := e.head, e.headErr, e.onHead
			e.mu.Unlock()
			if folder != "/tmp/acme" {
				e.t.Errorf("Head read %q, want the session's folder", folder)
			}
			if hook != nil {
				hook()
			}
			return head, err
		},
	})
}

func (e *stallEnv) must(err error) {
	e.t.Helper()
	if err != nil {
		e.t.Fatal(err)
	}
}

func (e *stallEnv) clock() time.Time {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.now
}

func (e *stallEnv) arm() {
	e.must(e.db.UpsertWatchmanArming(db.WatchmanArming{Scope: "session", RefID: e.session, ArmedAt: stallT0.Add(-2 * time.Hour), ArmedBy: "cli"}))
}

func (e *stallEnv) setHead(h string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.head = h
}

// state writes the session's hook state at time `at`, background cleared.
func (e *stallEnv) state(state string, at time.Time) {
	e.t.Helper()
	_, err := e.db.Exec(`UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ?, agent_background = NULL,
		agent_background_at = NULL, agent_background_shells = NULL WHERE id = ?`, state, db.AgentStateStamp(at), e.session)
	e.must(err)
}

// stop ends the agent's turn at time `at` with nothing in the background.
func (e *stallEnv) stop(at time.Time) { e.state("waiting", at) }

// background sets the Stop's background report: agents and shells at at.
func (e *stallEnv) background(agents, shells int, at time.Time) {
	e.t.Helper()
	_, err := e.db.Exec(`UPDATE terminal_sessions SET agent_background = ?, agent_background_shells = ?, agent_background_at = ?
		WHERE id = ?`, agents, shells, db.AgentStateStamp(at), e.session)
	e.must(err)
}

// check runs one tick at time `at` and returns how many lines were delivered so far.
func (e *stallEnv) check(at time.Time) int {
	e.mu.Lock()
	e.now = at
	e.mu.Unlock()
	e.twin.CheckStalls(context.Background())
	return len(e.port.delivered())
}

func (e *stallEnv) row() *db.WatchmanStallRow {
	e.t.Helper()
	st, err := e.db.WatchmanStall(e.session)
	e.must(err)
	return st
}

func (e *stallEnv) stallItems() []db.WatchmanItem {
	e.t.Helper()
	rows, err := e.db.Query(`SELECT state, outcome, park_reason, unsure, ref_kind, ref_id, session_id, target_id, workbench_id
		FROM watchman_items WHERE kind = 'stall'`)
	e.must(err)
	defer rows.Close()
	var out []db.WatchmanItem
	for rows.Next() {
		var it db.WatchmanItem
		var unsure int
		e.must(rows.Scan(&it.State, &it.Outcome, &it.ParkReason, &unsure, &it.RefKind, &it.RefID, &it.SessionID, &it.TargetID, &it.WorkbenchID))
		it.Unsure = unsure == 1
		out = append(out, it)
	}
	e.must(rows.Err())
	return out
}

// pingCycle stops the agent at `at` and checks StallAfter later: the ping
// the stop earns (or not). It returns the time of the check.
func (e *stallEnv) pingCycle(at time.Time) time.Time {
	e.stop(at)
	e.check(at.Add(StallAfter))
	return at.Add(StallAfter)
}

// parkAfterThreePings drives three pings and the stop after them to the
// park, from start.
func (e *stallEnv) parkAfterThreePings(start time.Time) time.Time {
	e.t.Helper()
	at := start
	for i := 1; i <= StallMaxPings; i++ {
		at = e.pingCycle(at.Add(time.Second))
		if n := len(e.port.delivered()); n != i {
			e.t.Fatalf("after cycle %d: %d pings, want %d", i, n, i)
		}
	}
	at = e.pingCycle(at.Add(time.Second))
	if n := len(e.port.delivered()); n != StallMaxPings {
		e.t.Fatalf("a 4th ping went (%d)", n)
	}
	if items := e.stallItems(); len(items) != 1 {
		e.t.Fatalf("stall items = %d, want 1", len(items))
	}
	return at
}

func TestStall_NotPingedWhileAgentsWork(t *testing.T) {
	e := newStallEnv(t)
	e.stop(stallT0)
	e.background(1, 0, stallT0)
	for _, after := range []time.Duration{StallAfter, 10 * time.Minute, 3 * time.Hour} {
		if n := e.check(stallT0.Add(after)); n != 0 {
			t.Fatalf("pinged %d times %v after the stop while a sub-agent runs", n, after)
		}
	}
	if e.row() != nil {
		t.Fatal("a stall row for a working session")
	}
}

func TestStall_NotPingedWhileShellsRun(t *testing.T) {
	e := newStallEnv(t)
	e.stop(stallT0)
	e.background(0, 1, stallT0)
	for _, after := range []time.Duration{StallAfter, 30 * time.Minute, 2*time.Hour - time.Second} {
		if n := e.check(stallT0.Add(after)); n != 0 {
			t.Fatalf("pinged %v after the stop while a background shell runs", after)
		}
	}
}

// A shell reported over BackgroundShellCap ago (a dev server) no longer
// counts: the session is stopped from then on and pinged StallAfter later.
func TestStall_ShellsPastCapIsStopped(t *testing.T) {
	e := newStallEnv(t)
	e.stop(stallT0)
	e.background(0, 1, stallT0)
	capEnd := stallT0.Add(2 * time.Hour)
	if n := e.check(capEnd.Add(StallAfter - time.Second)); n != 0 {
		t.Fatal("pinged before 3 minutes past the shell cap")
	}
	if n := e.check(capEnd.Add(StallAfter)); n != 1 {
		t.Fatalf("pings = %d, want 1 once the shell is past its cap", n)
	}
}

func TestStall_NeedsApprovalNotPinged(t *testing.T) {
	e := newStallEnv(t)
	e.state("approval", stallT0)
	if n := e.check(stallT0.Add(time.Hour)); n != 0 {
		t.Fatal("pinged into a permission prompt")
	}
}

func TestStall_PingAfter3Min(t *testing.T) {
	e := newStallEnv(t)
	e.stop(stallT0)
	if n := e.check(stallT0.Add(StallAfter - time.Second)); n != 0 {
		t.Fatal("pinged at 2:59")
	}
	if e.row() != nil {
		t.Fatal("a row before the first ping")
	}
	if n := e.check(stallT0.Add(StallAfter)); n != 1 {
		t.Fatalf("pings at 3:00 = %d, want 1", n)
	}
	if got := e.port.delivered()[0]; got != StallPing {
		t.Fatalf("ping = %q", got)
	}
	st := e.row()
	if st == nil || st.Pings != 1 || st.LastPingAt == nil || !st.LastPingAt.Equal(stallT0.Add(StallAfter)) ||
		!st.StoppedAt.Equal(stallT0) || st.Head != "c0ffee" || st.AsksSeen != 0 || st.ParkedAt != nil {
		t.Fatalf("row = %+v", st)
	}
	// No new stop since the ping: nothing more, however long.
	if n := e.check(stallT0.Add(time.Hour)); n != 1 {
		t.Fatal("pinged again with no stop after the ping")
	}
}

func TestStall_ThreePingsThenParked(t *testing.T) {
	e := newStallEnv(t)
	at := e.parkAfterThreePings(stallT0)
	items := e.stallItems()
	it := items[0]
	if it.State != "done" || it.Outcome != "parked" || it.ParkReason != "The agent stopped and did not go on after 3 pings" ||
		!it.Unsure || it.RefKind != "session" || it.RefID != e.session || it.SessionID != e.session ||
		it.TargetID != e.target || it.WorkbenchID != e.wb {
		t.Fatalf("stall item = %+v", it)
	}
	if st := e.row(); st.Pings != StallMaxPings || st.ParkedAt == nil {
		t.Fatalf("row = %+v, want parked at 3 pings", st)
	}
	// Parked: further stops ping nothing and journal nothing more.
	for i := 0; i < 3; i++ {
		at = e.pingCycle(at.Add(time.Minute))
	}
	if n := len(e.port.delivered()); n != StallMaxPings {
		t.Fatalf("pings while parked: %d", n-StallMaxPings)
	}
	if n := len(e.stallItems()); n != 1 {
		t.Fatalf("stall items = %d, want 1", n)
	}
}

func TestStall_ProgressResets(t *testing.T) {
	for _, c := range []struct {
		name     string
		progress func(e *stallEnv, at time.Time)
	}{
		{"new ask", func(e *stallEnv, _ time.Time) {
			e.must(e.db.WithTx(func(tx *sql.Tx) error {
				_, _, err := e.db.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: e.wb,
					SessionID: sql.NullInt64{Int64: e.session, Valid: true}, Kind: asks.KindQuestion, Title: "Which store?",
					Payload: oneQuestion})
				return err
			}))
			// The ask is answered at once (by the owner); it still counts.
			_, err := e.db.Exec(`UPDATE owner_asks SET status = 'answered', answer = '{"answers":[]}' WHERE session_id = ?`, e.session)
			e.must(err)
		}},
		{"finish", func(e *stallEnv, at time.Time) {
			// The finish drops the session from the watch; a resumed run
			// starts counting from zero.
			_, err := e.db.Exec(`UPDATE terminal_sessions SET finished_at = ? WHERE id = ?`, db.AgentStateStamp(at), e.session)
			e.must(err)
			_, err = e.db.PruneWatchmanStalls() // the daemon's upkeep
			e.must(err)
			if e.row() != nil {
				e.t.Fatal("a finished session kept its count")
			}
			_, err = e.db.Exec(`UPDATE terminal_sessions SET finished_at = NULL WHERE id = ?`, e.session)
			e.must(err)
		}},
		{"HEAD moved", func(e *stallEnv, _ time.Time) { e.setHead("beef00") }},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newStallEnv(t)
			at := e.parkAfterThreePings(stallT0)
			c.progress(e, at)
			at = e.pingCycle(at.Add(time.Minute))
			if n := len(e.port.delivered()); n != StallMaxPings+1 {
				t.Fatalf("pings after progress = %d, want %d", n, StallMaxPings+1)
			}
			if st := e.row(); st.Pings != 1 || st.ParkedAt != nil {
				t.Fatalf("row = %+v, want 1 ping, not parked", st)
			}
			// Three more without progress park again: the open item stays one.
			for i := 0; i < StallMaxPings; i++ {
				at = e.pingCycle(at.Add(time.Second))
			}
			if st := e.row(); st.Pings != StallMaxPings || st.ParkedAt == nil {
				t.Fatalf("row = %+v, want parked again", st)
			}
			if n := len(e.stallItems()); n != 1 {
				t.Fatalf("stall items = %d, want 1 open", n)
			}
		})
	}
}

// The owner's Mark done on the stall item lifts the park: the count starts
// again and a new stall gets its own item.
func TestStall_MarkDoneResumesPings(t *testing.T) {
	e := newStallEnv(t)
	at := e.parkAfterThreePings(stallT0)
	_, err := e.db.Exec(`UPDATE watchman_items SET owner_done_at = ? WHERE kind = 'stall'`, at.Format(time.RFC3339))
	e.must(err)
	at = e.pingCycle(at.Add(time.Minute))
	if n := len(e.port.delivered()); n != StallMaxPings+1 {
		t.Fatalf("pings after Mark done = %d", n)
	}
	for i := 0; i < StallMaxPings; i++ {
		at = e.pingCycle(at.Add(time.Second))
	}
	items := e.stallItems()
	if len(items) != 1 {
		t.Fatalf("stall items = %d, want the new one only", len(items))
	}
	var done sql.NullString
	e.must(e.db.QueryRow(`SELECT owner_done_at FROM watchman_items WHERE kind = 'stall'`).Scan(&done))
	if done.Valid {
		t.Fatal("the new stall item is marked done")
	}
}

// The owner's draft in the prompt: the host holds the ping instead of
// pasting it beside the draft. Nothing is sent or queued (DeliverHeld types
// nothing later), nothing counts, and the next tick offers it again.
func TestStall_DraftHoldsPing(t *testing.T) {
	e := newStallEnv(t)
	e.port.set(askanswer.DeliverHeld, nil)
	e.stop(stallT0)
	if n := e.check(stallT0.Add(StallAfter)); n != 1 {
		t.Fatalf("offers = %d, want 1", n)
	}
	e.port.mu.Lock()
	hold := e.port.holds[0]
	e.port.mu.Unlock()
	if !hold {
		t.Fatal("the ping did not ask the host to hold beside a draft")
	}
	if st := e.row(); st != nil {
		t.Fatalf("a held ping counted: %+v", st)
	}
	e.port.set("", nil)
	e.answerer.DeliverHeld(context.Background())
	if n := len(e.port.delivered()); n != 1 {
		t.Fatal("the held ping was queued and sent later")
	}
	if n := e.check(stallT0.Add(StallAfter + time.Minute)); n != 2 {
		t.Fatalf("offers = %d, want the ping offered again", n)
	}
	if st := e.row(); st == nil || st.Pings != 1 {
		t.Fatalf("row = %+v, want 1 ping once submitted", st)
	}
}

// A ping pasted but not submitted (typed) counts as an attempt: it reached
// the prompt and is never submitted or cleared by Watchman. While no later
// ping gets through and the session stays stopped, it is parked
// StallStuckAfter (9 min) after that attempt — with no new stop, and with a
// new stop whose offers are all held behind the typed line.
func TestStall_TypedThenStuckParks(t *testing.T) {
	for _, newStop := range []bool{false, true} {
		name := "no new stop"
		if newStop {
			name = "offers held"
		}
		t.Run(name, func(t *testing.T) {
			e := newStallEnv(t)
			e.port.set(askanswer.DeliverTyped, nil)
			e.stop(stallT0)
			typed := stallT0.Add(StallAfter)
			e.check(typed)
			if st := e.row(); st == nil || st.Pings != 1 || st.LastPingAt == nil || !st.LastPingAt.Equal(typed) {
				t.Fatalf("row = %+v, want the typed ping counted", st)
			}
			e.port.set(askanswer.DeliverHeld, nil)
			since := typed // the stuck clock: the later of the attempt and the stop
			if newStop {
				since = typed.Add(30 * time.Second) // the owner's own turn
				e.stop(since)
			}
			for m := 1; m < 9; m++ {
				e.check(since.Add(time.Duration(m) * time.Minute))
				if st := e.row(); st.ParkedAt != nil {
					t.Fatalf("parked %d min in", m)
				}
			}
			e.check(since.Add(StallStuckAfter))
			st := e.row()
			if st.ParkedAt == nil || st.Pings != 1 {
				t.Fatalf("row = %+v, want parked after 9 min", st)
			}
			items := e.stallItems()
			if len(items) != 1 || items[0].ParkReason != StallStuckReason {
				t.Fatalf("stall items = %+v, want one with the stuck reason", items)
			}
			n := len(e.port.delivered())
			e.check(since.Add(StallStuckAfter + 5*time.Minute))
			if len(e.port.delivered()) != n || len(e.stallItems()) != 1 {
				t.Fatal("offers or items after the park")
			}
		})
	}
}

// Mark done on a parked row, then a held offer: the stuck clock starts at
// the reset, so it is not re-parked; the next submitted ping counts from 1.
func TestStall_MarkDoneThenHeldOfferNotReparked(t *testing.T) {
	e := newStallEnv(t)
	at := e.parkAfterThreePings(stallT0)
	_, err := e.db.Exec(`UPDATE watchman_items SET owner_done_at = ? WHERE kind = 'stall'`, at.Format(time.RFC3339))
	e.must(err)
	e.port.set(askanswer.DeliverHeld, nil)
	reset := at.Add(StallStuckAfter) // the stop is long past 9 min
	e.check(reset)
	st := e.row()
	if st.ParkedAt != nil || st.Pings != 0 || st.ResetAt == nil || !st.ResetAt.Equal(reset) {
		t.Fatalf("row = %+v, want reset and not parked", st)
	}
	e.port.set("", nil)
	e.check(reset.Add(time.Minute))
	if st := e.row(); st.Pings != 1 || st.ParkedAt != nil {
		t.Fatalf("row = %+v, want normal counting", st)
	}
	var done sql.NullString
	e.must(e.db.QueryRow(`SELECT owner_done_at FROM watchman_items WHERE kind = 'stall'`).Scan(&done))
	if !done.Valid {
		t.Fatal("the marked-done item was replaced")
	}
}

// HEAD moving on a parked row resets it on the next tick, with no new stop.
func TestStall_HeadMovedOnParkedRowResets(t *testing.T) {
	e := newStallEnv(t)
	at := e.parkAfterThreePings(stallT0)
	e.setHead("beef00")
	e.check(at.Add(StallAfter))
	st := e.row()
	if st.ParkedAt != nil || st.ResetAt == nil || st.Head != "beef00" {
		t.Fatalf("row = %+v, want reset by the HEAD move", st)
	}
	if st.Pings != 1 {
		t.Fatalf("pings = %d, want the same stop pinged once after the reset", st.Pings)
	}
}

// A submitted ping that starts a long turn: at the next stop a held offer
// never stuck-parks (the last counted ping was submitted), and in any case
// not before 9 minutes of this stop.
func TestStall_LongTurnThenHeldOfferNoEarlyPark(t *testing.T) {
	e := newStallEnv(t)
	e.stop(stallT0)
	ping := stallT0.Add(StallAfter)
	e.check(ping)
	e.state("working", ping.Add(time.Second))
	for m := 1; m < 15; m++ {
		e.check(ping.Add(time.Duration(m) * time.Minute))
	}
	stop := ping.Add(15 * time.Minute)
	e.stop(stop)
	e.port.set(askanswer.DeliverHeld, nil)
	for m := 3; m <= 20; m++ {
		e.check(stop.Add(time.Duration(m) * time.Minute))
		if st := e.row(); st.ParkedAt != nil {
			t.Fatalf("parked %d min into this stop", m)
		}
	}
	if st := e.row(); st.Pings != 1 {
		t.Fatalf("pings = %d", st.Pings)
	}
}

// Take back between the decision and the park: the park's own transaction
// re-reads the arming and writes nothing.
func TestStall_TakeBackBeforeParkNoItem(t *testing.T) {
	e := newStallEnv(t)
	at := stallT0
	for i := 1; i <= StallMaxPings; i++ {
		at = e.pingCycle(at.Add(time.Second))
	}
	e.onHead = func() {
		_, err := e.db.DeleteWatchmanArming("session", e.session)
		e.must(err)
	}
	e.pingCycle(at.Add(time.Second))
	if items := e.stallItems(); len(items) != 0 {
		t.Fatalf("stall items = %d after Take back", len(items))
	}
	if st := e.row(); st.ParkedAt != nil {
		t.Fatalf("row = %+v, parked after Take back", st)
	}
}

// The owner clears the typed line and the agent stops again: the next ping
// is submitted and counting goes on as usual.
func TestStall_TypedThenSubmittedCountsNormally(t *testing.T) {
	e := newStallEnv(t)
	e.port.set(askanswer.DeliverTyped, nil)
	e.stop(stallT0)
	typed := stallT0.Add(StallAfter)
	e.check(typed)
	e.port.set("", nil)
	stop := typed.Add(time.Minute)
	e.stop(stop)
	if n := e.check(stop.Add(StallAfter)); n != 2 {
		t.Fatalf("offers = %d, want 2", n)
	}
	if st := e.row(); st.Pings != 2 || st.ParkedAt != nil {
		t.Fatalf("row = %+v, want 2 pings, not parked", st)
	}
}

// Take back while a ping would have been held: nothing is ever delivered
// after it — no held queue, and the next ticks see the session unarmed.
func TestStall_TakeBackWhileHeldNoDelivery(t *testing.T) {
	e := newStallEnv(t)
	e.port.set(askanswer.DeliverHeld, nil)
	e.stop(stallT0)
	e.check(stallT0.Add(StallAfter))
	_, err := e.db.DeleteWatchmanArming("session", e.session)
	e.must(err)
	e.port.set("", nil)
	e.answerer.DeliverHeld(context.Background())
	for i := 1; i <= 5; i++ {
		e.check(stallT0.Add(StallAfter + time.Duration(i)*time.Minute))
	}
	if n := len(e.port.delivered()); n != 1 {
		t.Fatalf("offers = %d after Take back, want only the held one before it", n)
	}
}

// Ticks the host holds, around submitted pings, never push the count past
// three: three submitted pings, then the park, and nothing submitted after.
func TestStall_HeldTicksNeverExceedThreePings(t *testing.T) {
	e := newStallEnv(t)
	at := stallT0
	submitted := 0
	for cycle := 0; cycle < 6; cycle++ {
		e.stop(at)
		e.port.set(askanswer.DeliverHeld, nil)
		for i := 0; i < 3; i++ {
			e.check(at.Add(StallAfter + time.Duration(i)*time.Minute))
		}
		e.port.set("", nil)
		before := len(e.port.delivered())
		at = at.Add(StallAfter + 3*time.Minute)
		submitted += e.check(at) - before
		if st := e.row(); st != nil && st.Pings > StallMaxPings {
			t.Fatalf("cycle %d: pings = %d", cycle, st.Pings)
		}
		at = at.Add(time.Second)
	}
	if submitted != StallMaxPings {
		t.Fatalf("submitted pings = %d, want %d", submitted, StallMaxPings)
	}
	if st := e.row(); st == nil || st.Pings != StallMaxPings || st.ParkedAt == nil {
		t.Fatalf("row = %+v, want parked at 3 pings", st)
	}
	if items := e.stallItems(); len(items) != 1 {
		t.Fatalf("stall items = %d", len(items))
	}
}

// PROJ-11: a parent resting while a sub-session runs waits on it, not on
// the owner — no ping; once the child ends, the ping comes 3 minutes after
// it was last seen running.
func TestStall_LiveSubSessionNotPinged(t *testing.T) {
	e := newStallEnv(t)
	res, err := e.db.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, parent_session_id)
		VALUES (?, 'claude', 'Sub', '/tmp/acme', 'uuid-child', ?)`, e.wb, e.session)
	e.must(err)
	child, _ := res.LastInsertId()
	e.port.mu.Lock()
	e.port.live[child] = true
	e.port.mu.Unlock()
	e.stop(stallT0)
	for _, after := range []time.Duration{StallAfter, 30 * time.Minute} {
		if n := e.check(stallT0.Add(after)); n != 0 {
			t.Fatalf("pinged %v after the stop while a sub-session runs", after)
		}
	}
	e.port.mu.Lock()
	delete(e.port.live, child)
	e.port.mu.Unlock()
	// The first tick that sees no live child is when the stop counts from.
	firstFree := stallT0.Add(31 * time.Minute)
	for _, at := range []time.Time{firstFree, firstFree.Add(time.Minute), firstFree.Add(StallAfter - time.Second)} {
		if n := e.check(at); n != 0 {
			t.Fatalf("pinged %v after the first child-free tick", at.Sub(firstFree))
		}
	}
	if n := e.check(firstFree.Add(StallAfter)); n != 1 {
		t.Fatalf("pings = %d, want 1 three minutes after the first child-free tick", n)
	}
}

// The stall watch's memory of a session goes once it is no longer handed
// over.
func TestStall_MemoForgottenWhenTakenBack(t *testing.T) {
	e := newStallEnv(t)
	e.stop(stallT0)
	e.check(stallT0.Add(time.Minute))
	if _, ok := e.twin.stalls[e.session]; !ok {
		t.Fatal("no memo for the armed session")
	}
	_, err := e.db.DeleteWatchmanArming("session", e.session)
	e.must(err)
	e.check(stallT0.Add(2 * time.Minute))
	if _, ok := e.twin.stalls[e.session]; ok {
		t.Fatal("the memo outlived Take back")
	}
}

// A delivery that fails (no session, the host cannot type) is not counted
// and is tried again on the next tick.
func TestStall_DeliveryFailedNotCounted(t *testing.T) {
	for _, c := range []struct {
		name    string
		outcome string
		err     error
	}{
		{"no session", "", errors.New("session-host: no such session")},
		{"cannot type", askanswer.DeliverNoPasteMode, nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := newStallEnv(t)
			e.port.set(c.outcome, c.err)
			e.stop(stallT0)
			if n := e.check(stallT0.Add(StallAfter)); n != 1 {
				t.Fatalf("tries = %d, want 1", n)
			}
			if st := e.row(); st != nil && st.Pings != 0 {
				t.Fatalf("a failed delivery counted: %+v", st)
			}
			e.port.set("", nil)
			if n := e.check(stallT0.Add(StallAfter + time.Minute)); n != 2 {
				t.Fatalf("tries = %d, want a retry on the next tick", n)
			}
			if st := e.row(); st == nil || st.Pings != 1 {
				t.Fatalf("row = %+v, want 1 ping", st)
			}
		})
	}
}

func TestStall_StateReadErrorNoPing(t *testing.T) {
	t.Run("host", func(t *testing.T) {
		e := newStallEnv(t)
		e.stop(stallT0)
		e.port.mu.Lock()
		e.port.liveErr = errors.New("session-host unreachable")
		e.port.mu.Unlock()
		if n := e.check(stallT0.Add(StallAfter)); n != 0 {
			t.Fatal("pinged with the host unread")
		}
	})
	t.Run("state", func(t *testing.T) {
		e := newStallEnv(t)
		e.stop(stallT0)
		// The state read fails (a column it reads is gone); the arming read
		// does not use it.
		_, err := e.db.Exec(`ALTER TABLE terminal_sessions RENAME COLUMN agent_background_shells TO agent_background_shells_x`)
		e.must(err)
		if n := e.check(stallT0.Add(StallAfter)); n != 0 {
			t.Fatal("pinged with the state unread")
		}
		_, err = e.db.Exec(`ALTER TABLE terminal_sessions RENAME COLUMN agent_background_shells_x TO agent_background_shells`)
		e.must(err)
		if n := e.check(stallT0.Add(StallAfter + time.Minute)); n != 1 {
			t.Fatal("not pinged once the state reads again")
		}
	})
}

// The count lives in the database: a restarted daemon (a new Twin) goes on
// from it and parks after the third ping in all.
func TestStall_RestartKeepsCount(t *testing.T) {
	e := newStallEnv(t)
	at := e.pingCycle(stallT0)
	at = e.pingCycle(at.Add(time.Second))
	e.twin = e.newTwin()
	at = e.pingCycle(at.Add(time.Second))
	if n := len(e.port.delivered()); n != 3 {
		t.Fatalf("pings = %d, want 3", n)
	}
	e.twin = e.newTwin()
	e.pingCycle(at.Add(time.Second))
	if n := len(e.port.delivered()); n != 3 {
		t.Fatal("a 4th ping after the restart")
	}
	if st := e.row(); st.Pings != StallMaxPings || st.ParkedAt == nil {
		t.Fatalf("row = %+v, want parked", st)
	}
}

// Take back between the 3-minute check and the delivery: nothing goes
// (WATCHMAN-04: the arming is read again right before the ping).
func TestStall_DisarmBeforeDeliveryNoPing(t *testing.T) {
	e := newStallEnv(t)
	e.stop(stallT0)
	e.onHead = func() {
		_, err := e.db.DeleteWatchmanArming("session", e.session)
		e.must(err)
	}
	if n := e.check(stallT0.Add(StallAfter)); n != 0 {
		t.Fatal("pinged after Take back")
	}
	if st := e.row(); st != nil && st.Pings != 0 {
		t.Fatalf("row = %+v", st)
	}
}

// The stall watch stays off without a live-run reader.
func TestStall_NoLiveReaderIsOff(t *testing.T) {
	e := newStallEnv(t)
	e.twin = NewTwin(TwinDeps{DB: e.db, Answerer: e.answerer, Clock: e.clock})
	e.stop(stallT0)
	if n := e.check(stallT0.Add(time.Hour)); n != 0 {
		t.Fatal("pinged without a live-run reader")
	}
}

func TestGitHead_ReadsThroughRun(t *testing.T) {
	var gotDir string
	var gotArgs []string
	head := GitHead(func(_ context.Context, dir, name string, args ...string) ([]byte, error) {
		gotDir, gotArgs = dir, append([]string{name}, args...)
		return []byte("abc123\n"), nil
	})
	h, err := head(context.Background(), "/tmp/acme")
	if err != nil || h != "abc123" {
		t.Fatalf("head = %q, %v", h, err)
	}
	if gotDir != "/tmp/acme" || len(gotArgs) != 3 || gotArgs[0] != "git" || gotArgs[1] != "rev-parse" || gotArgs[2] != "HEAD" {
		t.Fatalf("ran %v in %q", gotArgs, gotDir)
	}
	failing := GitHead(func(context.Context, string, string, ...string) ([]byte, error) { return nil, errors.New("not a repo") })
	if _, err := failing(context.Background(), "/tmp/acme"); err == nil {
		t.Fatal("a failed read returned no error")
	}
}
