package actions

import (
	"context"
	"database/sql"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/wire"
)

// The hosted relay transport reads zone events itself: PassEvent narrows to it.
var _ EventPuller = (*relay.Transport)(nil)

// eventPuller is the puller that also reads events (as the hosted relay
// does), logging the zones each read was for; own is what OwnWrites says.
type eventPuller struct {
	*puller
	events, pulls []string
	own           bool
}

func (e *eventPuller) OwnWrites(transport.Event) bool { return e.own }

func (e *eventPuller) PullEvent(ctx context.Context, ev transport.Event, apply func(transport.Batch) error) error {
	e.events = append(e.events, ev.Zone)
	return e.puller.Pull(ctx, ev.Zone, apply)
}

func (e *eventPuller) Pull(ctx context.Context, zone string, apply func(transport.Batch) error) error {
	e.pulls = append(e.pulls, zone)
	return e.puller.Pull(ctx, zone, apply)
}

func (w *world) passEvent(zone string) PassReport {
	w.t.Helper()
	r, err := w.proc.PassEvent(w.ctx, transport.Event{Zone: zone})
	if err != nil {
		w.t.Fatalf("event pass: %v", err)
	}
	return r
}

// An event for one phone's mailbox reads that mailbox only; the backstop
// Pass reads the others.
func TestPassEventReadsOnlyTheEventsMailbox(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	ep := &eventPuller{puller: &puller{Fake: w.fake, tokens: map[string]uint64{}}}
	w.proc.cfg.Transport = ep
	other := w.addPhone()
	if _, err := other.Act("board_comment_add"); err != nil {
		t.Fatal(err)
	}
	w.act("test_noop")
	if r := w.passEvent(w.phone.Zone()); r.Applied != 1 || r.ControlsWritten != 1 {
		t.Fatalf("event pass %+v", r)
	}
	w.wantCalls("test_noop:1")
	if !slices.Equal(ep.events, []string{w.phone.Zone()}) || len(ep.pulls) != 0 {
		t.Fatalf("event reads %v, pulls %v", ep.events, ep.pulls)
	}
	w.pass()
	w.wantCalls("test_noop:1", "board_comment_add:1")
	if !slices.Contains(ep.pulls, other.Zone()) {
		t.Fatalf("the backstop pass did not read the other mailbox: %v", ep.pulls)
	}
}

// An event that names no linked phone's own mailbox, or one on a transport
// that does not read events, is a full pass.
func TestPassEventFallsBackToAFullPass(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	ep := &eventPuller{puller: &puller{Fake: w.fake, tokens: map[string]uint64{}}}
	w.proc.cfg.Transport = ep
	w.act("test_noop")
	if r := w.passEvent(transport.MailboxZone(hubRelayID, "unknown-phone")); r.Applied != 1 {
		t.Fatalf("event pass %+v", r)
	}
	if len(ep.events) != 0 || !slices.Equal(ep.pulls, []string{w.phone.Zone()}) {
		t.Fatalf("event reads %v, pulls %v", ep.events, ep.pulls)
	}
	w.proc.cfg.Transport = w.fake
	w.act("test_noop")
	if w.proc.ReadsEvents() {
		t.Fatal("memfake reads events")
	}
	if r := w.passEvent(w.phone.Zone()); r.Applied != 1 {
		t.Fatalf("event pass on memfake %+v", r)
	}
	w.wantCalls(noops(1, 2)...)
}

// countSaves logs each Save's wire names; before (when set) runs ahead of
// the n-th save (1-based).
type countSaves struct {
	*memfake.Fake
	saves  [][]string
	before func(n int)
}

func (c *countSaves) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	names := make([]string, len(items))
	for i, it := range items {
		names[i] = it.Record.WireName()
	}
	c.saves = append(c.saves, names)
	if c.before != nil {
		c.before(len(c.saves))
	}
	return c.Fake.Save(ctx, items)
}

// One mailbox's queued echoes go out in one Save, in queue order.
func TestQueuedEchoesOfAMailboxGoInOneSave(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		cs := &countSaves{Fake: w.fake}
		w.use(cs)
		seqs := []uint64{w.act("test_noop"), w.act("test_noop"), w.act("test_noop")}
		if r := w.pass(); r.Applied != 3 || r.ControlsWritten != 3 {
			t.Fatalf("pass %+v", r)
		}
		var want []string
		for _, s := range seqs {
			name, _ := w.phone.Sealed(s)
			want = append(want, name)
		}
		if len(cs.saves) != 1 || !slices.Equal(cs.saves[0], want) {
			t.Fatalf("saves %v, want one of %v", cs.saves, want)
		}
		w.sync(w.phone)
		for _, s := range seqs {
			w.wantEcho(s, wire.StatusApplied, "")
		}
		if w.pending() != 0 {
			t.Fatalf("%d rows still queued", w.pending())
		}
	})
}

// A conflict in the middle of a batch settles that row alone: the rows
// around it are written, the conflicting one (the phone wrote its action
// again meanwhile) leaves the queue and its new copy is answered as a repeat
// when read. Nothing is applied twice.
func TestBatchConflictInTheMiddleMapsPerRow(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		cs := &countSaves{Fake: w.fake}
		w.use(cs)
		seqs := []uint64{w.act("test_noop"), w.act("test_noop"), w.act("test_noop")}
		cs.before = func(n int) {
			if n == 1 {
				if err := w.phone.WriteCopy(seqs[1]); err != nil {
					t.Fatal(err)
				}
			}
		}
		if r := w.pass(); r.Applied != 3 || r.ControlsWritten != 3 {
			t.Fatalf("pass %+v", r)
		}
		if len(cs.saves) != 1 || len(cs.saves[0]) != 3 {
			t.Fatalf("saves %v, want one of three", cs.saves)
		}
		if w.pending() != 0 {
			t.Fatalf("%d rows still queued", w.pending())
		}
		cs.before = nil
		w.settle()
		w.wantCalls(noops(seqs...)...)
		for _, s := range seqs {
			w.wantEcho(s, wire.StatusApplied, "")
		}
		w.wantEmptyMailbox()
	})
}

// A batch the transport refuses as a whole may be partly written: the first
// row is marked failed, the rest wait, and the next pass writes them all
// (a row that did land meets its own echo and is written over it).
func TestBatchRefusedWholeIsRetriedNextPass(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		seqs := []uint64{w.act("test_noop"), w.act("test_noop")}
		w.fake.FailNext("save", transport.ErrRateLimited)
		if r := w.pass(); r.ControlsWritten != 0 {
			t.Fatalf("pass %+v", r)
		}
		rows, err := w.st.PendingControls(w.queue(w.phone))
		if err != nil || len(rows) != 2 || rows[0].Attempts != 1 || rows[1].Attempts != 0 {
			t.Fatalf("queue %+v, %v", rows, err)
		}
		w.settle()
		w.wantCalls(noops(seqs...)...)
		for _, s := range seqs {
			w.wantEcho(s, wire.StatusApplied, "")
		}
		w.wantEmptyMailbox()
	})
}

// lanePuller is an EventPuller safe to read from two goroutines at once (the
// runtime's event lane next to its backstop pass): it keeps the zone tokens
// itself, notes any token that went back (backward) and, when onePage is
// set, hands one record per page. hook, when set, runs as a read of zone is
// about to read its page n (applied false), and again once that page was
// applied, before its token is stored (applied true).
type lanePuller struct {
	*memfake.Fake
	onePage bool
	hook    func(zone string, n int, applied bool)

	mu       sync.Mutex
	tokens   map[string]uint64
	backward []string
}

func newLanePuller(f *memfake.Fake) *lanePuller {
	return &lanePuller{Fake: f, tokens: map[string]uint64{}}
}

func (l *lanePuller) token(zone string) uint64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tokens[zone]
}

func (l *lanePuller) setToken(zone string, seq uint64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if seq < l.tokens[zone] {
		l.backward = append(l.backward, fmt.Sprintf("%s %d→%d", zone, l.tokens[zone], seq))
	}
	l.tokens[zone] = seq
}

func (l *lanePuller) wantMonotonic(t *testing.T) {
	t.Helper()
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.backward) > 0 {
		t.Fatalf("a zone token went back: %v", l.backward)
	}
}

func (l *lanePuller) OwnWrites(transport.Event) bool { return false }

// PullEvent takes an inline record that continues the zone's token without
// a read (as the hosted relay does); an event already read reads nothing.
func (l *lanePuller) PullEvent(ctx context.Context, ev transport.Event, apply func(transport.Batch) error) error {
	if ev.Inline == nil {
		return l.Pull(ctx, ev.Zone, apply)
	}
	if ev.Seq <= l.token(ev.Zone) {
		return nil
	}
	if err := apply(*ev.Inline); err != nil {
		return err
	}
	l.setToken(ev.Zone, ev.Seq)
	return nil
}

func (l *lanePuller) Pull(ctx context.Context, zone string, apply func(transport.Batch) error) error {
	since := l.token(zone)
	for n := 1; ; n++ {
		if l.hook != nil {
			l.hook(zone, n, false)
		}
		b, err := l.Changes(ctx, zone, since)
		if err != nil {
			return err
		}
		if l.onePage && len(b.Changed) > 1 {
			b.Changed, b.Deleted = b.Changed[:1], nil
			b.NewSeq, b.More = b.Changed[0].RecordSeq, true
		}
		if err := apply(b); err != nil {
			return err
		}
		if l.hook != nil {
			l.hook(zone, n, true)
		}
		l.setToken(zone, b.NewSeq)
		since = b.NewSeq
		if !b.More {
			return nil
		}
	}
}

// ledgerRows counts the ledger's rows.
func (w *world) ledgerRows() int {
	w.t.Helper()
	var n int
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT COUNT(*) FROM relay_processed`).Scan(&n)
	}); err != nil {
		w.t.Fatal(err)
	}
	return n
}

// awaitEvent waits until an event pass found its mailbox's lock held (it
// goes on once the lock is released) or ended (a pass that never waited read
// alongside the other one); collect then takes its result.
func awaitEvent(t *testing.T, waiting <-chan struct{}, done <-chan error) (collect func()) {
	t.Helper()
	var err error
	select {
	case <-waiting:
		return func() {
			t.Helper()
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		}
	case err = <-done:
	}
	return func() {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
}

// TestProcessor_NudgeBeforeFlush: a pass nudges the slice kinds it applied
// before its applied echo goes to the transport (live link R4), so the
// slices' save starts ahead of the echo's.
func TestProcessor_NudgeBeforeFlush(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	var order []string
	cs := &countSaves{Fake: w.fake, before: func(int) { order = append(order, "save") }}
	w.use(cs)
	w.disp.Register("ask_answer", w.recording(Outcome{Status: wire.StatusApplied}), KindOptions{Nudges: []string{"owner_ask"}})
	w.proc.cfg.Nudge = func(kinds []string) { order = append(order, "nudge "+strings.Join(kinds, ",")) }
	w.act("ask_answer")
	if r := w.pass(); r.Applied != 1 || r.ControlsWritten != 1 {
		t.Fatalf("pass %+v", r)
	}
	if want := []string{"nudge owner_ask", "save"}; !slices.Equal(order, want) {
		t.Fatalf("order %v, want %v", order, want)
	}
}

// TestProcessor_ConcurrentEventAndPassApplyOnce: a record the backstop pass
// is reading and an event carries inline at the same time is applied once:
// the event waits for the mailbox's lock, then finds it read.
func TestProcessor_ConcurrentEventAndPassApplyOnce(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	lp := newLanePuller(w.fake)
	w.use(lp)
	seq := w.act("test_noop")
	page, err := w.fake.Changes(w.ctx, w.phone.Zone(), 0)
	if err != nil || len(page.Changed) != 1 {
		t.Fatalf("the action's page: %d records, %v", len(page.Changed), err)
	}
	ev := transport.Event{Zone: w.phone.Zone(), Seq: page.NewSeq, Inline: &page}
	reading, release := make(chan struct{}), make(chan struct{})
	lp.hook = func(_ string, n int, applied bool) {
		if n == 1 && !applied {
			close(reading)
			<-release
		}
	}
	waiting := make(chan struct{})
	w.proc.boxWait = func(string) { close(waiting) }
	passed := make(chan error, 1)
	go func() { _, err := w.proc.Pass(w.ctx); passed <- err }()
	<-reading
	lp.hook = nil
	evDone := make(chan error, 1)
	go func() { _, err := w.proc.PassEvent(w.ctx, ev); evDone <- err }()
	collect := awaitEvent(t, waiting, evDone) // the event waits for the mailbox the pass is reading
	close(release)
	if err := <-passed; err != nil {
		t.Fatal(err)
	}
	collect()
	w.wantCalls(noops(seq)...)
	if n := w.ledgerRows(); n != 1 {
		t.Fatalf("%d ledger rows, want 1", n)
	}
	lp.wantMonotonic(t)
}

// TestProcessor_MailboxTokenMonotonicUnderConcurrentReaders: the event lane
// and the backstop pass reading one mailbox page by page never move its
// token back, and each action is applied once.
func TestProcessor_MailboxTokenMonotonicUnderConcurrentReaders(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	lp := newLanePuller(w.fake)
	lp.onePage = true
	w.use(lp)
	seqs := []uint64{w.act("test_noop"), w.act("test_noop"), w.act("test_noop"), w.act("test_noop")}
	between, release := make(chan struct{}), make(chan struct{})
	lp.hook = func(_ string, n int, applied bool) {
		if n == 2 && applied { // the second page applied, its token not stored yet
			close(between)
			<-release
		}
	}
	waiting := make(chan struct{})
	w.proc.boxWait = func(string) { close(waiting) }
	passed := make(chan error, 1)
	go func() { _, err := w.proc.Pass(w.ctx); passed <- err }()
	<-between
	lp.hook = nil
	evDone := make(chan error, 1)
	go func() { _, err := w.proc.PassEvent(w.ctx, transport.Event{Zone: w.phone.Zone()}); evDone <- err }()
	collect := awaitEvent(t, waiting, evDone)
	close(release)
	if err := <-passed; err != nil {
		t.Fatal(err)
	}
	collect()
	w.wantCalls(noops(seqs...)...)
	lp.wantMonotonic(t)
	if n := w.ledgerRows(); n != len(seqs) {
		t.Fatalf("%d ledger rows, want %d", n, len(seqs))
	}
}

// TestProcessor_OtherMailboxNotBlocked: while the backstop pass waits on a
// slow read of one phone's mailbox, an event for another phone's mailbox is
// read and applied, its echo written, before that read returns.
func TestProcessor_OtherMailboxNotBlocked(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	lp := newLanePuller(w.fake)
	w.use(lp)
	other := w.addPhone()
	slow := w.phone.Zone()
	reading, release := make(chan struct{}), make(chan struct{})
	lp.hook = func(zone string, n int, applied bool) {
		if zone == slow && n == 1 && !applied {
			close(reading)
			<-release
		}
	}
	passed := make(chan error, 1)
	go func() { _, err := w.proc.Pass(w.ctx); passed <- err }()
	<-reading
	seq, err := other.Act("board_comment_add")
	if err != nil {
		t.Fatal(err)
	}
	r, err := w.proc.PassEvent(w.ctx, transport.Event{Zone: other.Zone()})
	if err != nil || r.Applied != 1 || r.ControlsWritten != 1 {
		t.Fatalf("event pass %+v, %v", r, err)
	}
	w.wantCalls("board_comment_add:" + strconv.FormatUint(seq, 10))
	close(release)
	if err := <-passed; err != nil {
		t.Fatal(err)
	}
}

// TestProcessor_EventReadOnlyWhenTheEventReads: an event a pass already read
// (its seq at or below the stored token) reads nothing and records no
// event_read; an event that brings a new record does.
func TestProcessor_EventReadOnlyWhenTheEventReads(t *testing.T) {
	w := newWorld(t, transport.KindRelay)
	lp := newLanePuller(w.fake)
	w.use(lp)
	lat := &fakeLatency{}
	w.proc.cfg.Latency = lat
	inline := func() transport.Event { // the mailbox's last write, carried inline
		t.Helper()
		page, err := w.fake.Changes(w.ctx, w.phone.Zone(), lp.token(w.phone.Zone()))
		if err != nil || len(page.Changed) == 0 {
			t.Fatalf("the action's page: %d records, %v", len(page.Changed), err)
		}
		last := transport.Batch{Changed: page.Changed[len(page.Changed)-1:], NewSeq: page.NewSeq}
		return transport.Event{Zone: w.phone.Zone(), Seq: page.NewSeq, Inline: &last, ArrivedAt: w.clock()}
	}
	w.act("test_noop")
	late := inline()
	w.pass() // the backstop reads the record first
	if r, err := w.proc.PassEvent(w.ctx, late); err != nil || r.Read != 0 {
		t.Fatalf("event pass of a read record %+v, %v", r, err)
	}
	if len(lat.events) != 0 {
		t.Fatalf("an event already read was timed: %+v", lat.events)
	}
	w.act("test_noop")
	fresh := inline()
	if r, err := w.proc.PassEvent(w.ctx, fresh); err != nil || r.Applied != 1 {
		t.Fatalf("event pass %+v, %v", r, err)
	}
	if want := []eventReadCall{{"relay", fresh.ArrivedAt, w.clock()}}; !slices.Equal(lat.events, want) {
		t.Fatalf("event_read stamps %+v, want %+v", lat.events, want)
	}
}
