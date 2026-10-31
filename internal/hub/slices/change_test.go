package slices

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
)

// watchDB is a database file with two handles: the daemon's pool and the
// watch's dedicated read connection.
func watchDB(t *testing.T) (*db.DB, *sql.Conn) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	r, err := db.OpenExisting(path, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = r.Close() })
	conn, err := r.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return d, conn
}

func TestPollIs250msWhileAPhoneWasInTouchElse1s(t *testing.T) {
	if ActivePoll != 250*time.Millisecond || IdlePoll != time.Second || ActiveWindow != 10*time.Minute {
		t.Fatalf("poll constants = %v / %v / %v", ActivePoll, IdlePoll, ActiveWindow)
	}
	now := time.Unix(1_800_000_000, 0).UTC()
	for _, tc := range []struct {
		name    string
		touched time.Time
		want    time.Duration
	}{
		{"never", time.Time{}, IdlePoll},
		{"a minute ago", now.Add(-time.Minute), ActivePoll},
		{"just inside the window", now.Add(-ActiveWindow + time.Second), ActivePoll},
		{"the window over", now.Add(-ActiveWindow), IdlePoll},
		{"an hour ago", now.Add(-time.Hour), IdlePoll},
	} {
		w := NewChangeWatch(nil, nil, func() time.Time { return tc.touched }, func() time.Time { return now })
		if got := w.Interval(); got != tc.want {
			t.Errorf("%s: interval %v, want %v", tc.name, got, tc.want)
		}
	}

	// Run asks its timer for that interval, and switches when the touch
	// ages out.
	_, conn := watchDB(t)
	var mu sync.Mutex
	touched := now.Add(-time.Minute)
	ft := newFakeTime()
	w := NewChangeWatch(conn, map[string][]Kind{"targets": {"workbench_target"}},
		func() time.Time { mu.Lock(); defer mu.Unlock(); return touched }, ft.Now)
	var asked []time.Duration
	w.timer = func(d time.Duration) (<-chan time.Time, func()) {
		mu.Lock()
		asked = append(asked, d)
		mu.Unlock()
		return ft.Timer(d)
	}
	runWatch(t, w, func(...Kind) {})
	waitArmed(t, ft, 0)
	mu.Lock()
	touched = time.Time{}
	mu.Unlock()
	n := ft.armedCount()
	ft.advance(ActivePoll)
	waitArmed(t, ft, n)
	mu.Lock()
	defer mu.Unlock()
	if len(asked) < 2 || asked[0] != ActivePoll || asked[1] != IdlePoll {
		t.Fatalf("Run waited %v, want [%v %v]", asked, ActivePoll, IdlePoll)
	}
}

// runWatch runs w until the test ends.
func runWatch(t *testing.T, w *ChangeWatch, dirty func(...Kind)) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- w.Run(ctx, dirty) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; !errors.Is(err, context.Canceled) {
			t.Errorf("watch Run = %v", err)
		}
	})
}

// waitArmed waits (bounded) until more than n timers were armed on ft.
func waitArmed(t *testing.T, ft *fakeTime, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for ft.armedCount() <= n {
		if time.Now().After(deadline) {
			t.Fatal("the loop never went back to sleep")
		}
		time.Sleep(time.Millisecond)
	}
}

// Every database-backed kind is marked once per change, deduplicated, and
// the first read is only the baseline.
func TestAChangeMarksEveryDatabaseKind(t *testing.T) {
	d, conn := watchDB(t)
	w := NewChangeWatch(conn, map[string][]Kind{
		"targets":       {"workbench_target", "workbench"},
		"owner_asks":    {"owner_ask", KindAskAlert, "workbench"},
		"calendar_none": nil,
	}, nil, nil)
	ctx := context.Background()
	if changed, err := w.poll(ctx); err != nil || changed {
		t.Fatalf("baseline = %v, %v", changed, err)
	}
	if changed, err := w.poll(ctx); err != nil || changed {
		t.Fatalf("no write = %v, %v", changed, err)
	}
	if _, err := d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')`); err != nil {
		t.Fatal(err)
	}
	if changed, err := w.poll(ctx); err != nil || !changed {
		t.Fatalf("after a write = %v, %v", changed, err)
	}
	want := fmt.Sprint([]Kind{"workbench", "workbench_target", "owner_ask", KindAskAlert})
	if got := fmt.Sprint(w.Kinds()); got != want {
		t.Fatalf("kinds = %s, want %s (AllKinds order, once each)", got, want)
	}
}

func TestFullDiffEvery60sCatchesClockValues(t *testing.T) {
	if FullDiffEvery != 60*time.Second {
		t.Fatalf("FullDiffEvery = %v", FullDiffEvery)
	}
	r := newRig(t, transport.KindRelay)
	var ft *fakeTime
	// A clock-driven value (an age, a grace period running out): nothing
	// writes, nothing nudges, only the full diff sees it change.
	src := &clockSource{kind: "terminal_session", now: func() time.Time { return ft.Now() }}
	ru := r.runFakeWith(func(f *fakeTime) { ft = f }, src)
	saves := func() int { return len(r.tr.Frames()) } // the rig publishes this kind alone
	if saves() != 1 {
		t.Fatalf("start published %d", saves())
	}
	ru.step(FullDiffEvery - time.Second)
	if n := src.reads.Load(); n != 1 {
		t.Fatalf("read %d times before the full diff", n)
	}
	ru.step(time.Second)
	if n := src.reads.Load(); n != 2 {
		t.Fatalf("read %d times at the full diff", n)
	}
	if saves() != 2 {
		t.Fatalf("the new clock value was not saved (%d)", saves())
	}
}

// clockSource publishes the minute of its clock.
type clockSource struct {
	kind  Kind
	now   func() time.Time
	reads atomic.Int32
}

func (s *clockSource) Kind() Kind { return s.kind }

func (s *clockSource) Items(context.Context) ([]Item, error) {
	s.reads.Add(1)
	return []Item{{ID: "1", Payload: fmt.Appendf(nil, `{"minute":%d}`, s.now().Unix()/60)}}, nil
}

// runFakeWith is runFake with a hook that sees the fake clock first.
func (r *rig) runFakeWith(seen func(*fakeTime), sources ...Source) *runner {
	r.t.Helper()
	ft := newFakeTime()
	seen(ft)
	p := r.publisherWith(Config{Clock: ft.Now}, sources...)
	p.mono, p.timer = ft.Now, ft.Timer
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()
	r.t.Cleanup(func() {
		cancel()
		if err := <-done; !errors.Is(err, context.Canceled) {
			r.t.Errorf("Run = %v", err)
		}
	})
	ru := &runner{t: r.t, ft: ft, p: p}
	ru.settle(0)
	return ru
}

// blockingSaves holds every Save until released, telling when one starts.
type blockingSaves struct {
	*memfake.Fake
	started chan struct{}
	release chan struct{}
	saving  atomic.Bool
}

func (b *blockingSaves) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	b.saving.Store(true)
	defer b.saving.Store(false)
	b.started <- struct{}{}
	<-b.release
	return b.Fake.Save(ctx, items)
}

// TestNextItemsNeverOverlapsAnUpload: a source may delete at its next Items
// call the asset files it returned before (meeting_transcript's stale
// assets), so no Items call of a second cycle may run while the first
// cycle's Save is still uploading.
func TestNextItemsNeverOverlapsAnUpload(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	tr := &blockingSaves{Fake: r.tr, started: make(chan struct{}, 4), release: make(chan struct{})}
	var overlapped atomic.Bool
	src := &fakeSource{kind: "meeting_transcript"}
	src.during = func() {
		if tr.saving.Load() {
			overlapped.Store(true)
		}
	}
	src.set(item("1", `{"v":1}`))
	p := r.publisherWith(Config{Spacing: time.Nanosecond}, src)
	p.c.Transport = tr

	first := make(chan error, 1)
	go func() { _, err := p.Cycle(context.Background(), nil); first <- err }()
	<-tr.started // the first cycle uploads
	src.set(item("1", `{"v":2}`))
	second := make(chan error, 1)
	go func() {
		r.advance(time.Second)
		_, err := p.Cycle(context.Background(), []Kind{"meeting_transcript"})
		second <- err
	}()
	select {
	case <-second:
		t.Fatal("a second cycle ran while the first one's Save was in flight")
	case <-time.After(50 * time.Millisecond): // the second cycle is waiting
	}
	close(tr.release)
	if err := <-first; err != nil {
		t.Fatal(err)
	}
	if err := <-second; err != nil {
		t.Fatal(err)
	}
	if overlapped.Load() {
		t.Fatal("Items ran during an upload")
	}
	if n := len(src.readTimes()); n != 2 {
		t.Fatalf("source read %d times, want 2", n)
	}
}
