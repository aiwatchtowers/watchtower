package slices_test

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
)

// changeRig is the publish-on-change loop over the real workbench_target
// source: a database file written through the daemon's pool (d) and watched
// on a dedicated connection, a sidecar, a keyring and a fake relay. The
// publisher and the watch each run on their own fake clock, stepped
// together.
type changeRig struct {
	t      *testing.T
	d      *db.DB
	tr     *saveLog
	pub    *slices.Publisher
	pubFT  *slices.FakeTime
	watch  *slices.ChangeWatch
	watFT  *slices.FakeTime
	target int64
}

// saveLog is the fake relay with the fake time of each Save (one per kind).
type saveLog struct {
	*memfake.Fake
	now func() time.Time

	mu    sync.Mutex
	saves []time.Time
}

func (s *saveLog) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	s.mu.Lock()
	s.saves = append(s.saves, s.now())
	s.mu.Unlock()
	return s.Fake.Save(ctx, items)
}

func (s *saveLog) times() []time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]time.Time(nil), s.saves...)
}

func newChangeRig(t *testing.T) *changeRig {
	t.Helper()
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	res, err := d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/hubtest-acme')`)
	if err != nil {
		t.Fatal(err)
	}
	project, _ := res.LastInsertId()
	res, err = d.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end, status, priority, ownership, source_type, project_id)
VALUES ('Feature', 'custom', 'project', '2026-09-29', '2026-09-29', 'todo', 'medium', 'mine', 'chat', ?)`, project)
	if err != nil {
		t.Fatal(err)
	}
	target, _ := res.LastInsertId()

	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	pubFT, watFT := slices.NewFakeTime(), slices.NewFakeTime()
	kr, err := identity.NewKeyring(id, st, pubFT.Now)
	if err != nil {
		t.Fatal(err)
	}
	tr := &saveLog{Fake: memfake.New(transport.KindRelay, pubFT.Now), now: pubFT.Now}
	pub := slices.NewPublisher(slices.Config{
		Store: st, Transport: tr, Sealer: secure.NewSealer(kr), DataZone: "data/hubtest-acme", Clock: pubFT.Now,
		Sources: []slices.Source{sources.WorkbenchTargets(d, pubFT.Now)},
	})
	slices.SetRunClock(pub, pubFT.Now, pubFT.Timer)

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
	// A phone is in touch: the active poll.
	watch := slices.NewChangeWatch(conn, sources.ChangeTables, watFT.Now, watFT.Now)
	slices.SetWatchTimer(watch, watFT.Timer)
	return &changeRig{t: t, d: d, tr: tr, pub: pub, pubFT: pubFT, watch: watch, watFT: watFT, target: target}
}

// run starts the publisher and the watch; the watch's dirty marks the kinds
// and waits until the publisher took the nudge.
func (r *changeRig) run() {
	r.t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	wg.Add(2)
	go func() { defer wg.Done(); errs <- r.pub.Run(ctx) }()
	waitArmed(r.t, r.pubFT, 0) // the start cycle is done
	go func() {
		defer wg.Done()
		errs <- r.watch.Run(ctx, func(kinds ...slices.Kind) {
			n := r.pubFT.Armed()
			r.pub.PublishSoon(kinds...)
			waitArmed(r.t, r.pubFT, n)
		})
	}()
	waitArmed(r.t, r.watFT, 0) // the baseline read is done
	r.t.Cleanup(func() {
		cancel()
		wg.Wait()
		close(errs)
		for err := range errs {
			if !errors.Is(err, context.Canceled) {
				r.t.Errorf("Run = %v", err)
			}
		}
	})
}

// step moves both clocks by d and lets the loops handle what fell due: the
// watch first (its poll may nudge the publisher), then the publisher.
func (r *changeRig) step(d time.Duration) {
	r.t.Helper()
	if n := r.watFT.Armed(); r.watFT.Advance(d) {
		waitArmed(r.t, r.watFT, n)
	}
	if n := r.pubFT.Armed(); r.pubFT.Advance(d) {
		waitArmed(r.t, r.pubFT, n)
	}
}

// write changes the target through the daemon's pool, as another
// connection would.
func (r *changeRig) write(text string) {
	r.t.Helper()
	if _, err := r.d.Exec(`UPDATE targets SET text = ? WHERE id = ?`, text, r.target); err != nil {
		r.t.Fatal(err)
	}
}

func waitArmed(t *testing.T, ft *slices.FakeTime, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for ft.Armed() <= n {
		if time.Now().After(deadline) {
			t.Fatal("the loop never went back to sleep")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestAWriteByAnotherConnectionPublishesWithinOnePoll(t *testing.T) {
	r := newChangeRig(t)
	r.run()
	if n := len(r.tr.times()); n != 1 {
		t.Fatalf("start saved %d times", n)
	}
	r.write("Renamed")
	start := r.pubFT.Now()
	for range 20 { // one active poll, then the debounce
		r.step(25 * time.Millisecond)
		if len(r.tr.times()) == 2 {
			break
		}
	}
	saves := r.tr.times()
	if len(saves) != 2 {
		t.Fatalf("the write was not published within one poll and the debounce (%d saves)", len(saves))
	}
	if took := saves[1].Sub(start); took > slices.ActivePoll+slices.Debounce {
		t.Fatalf("published after %v, more than a poll (%v) plus the debounce", took, slices.ActivePoll)
	}
}

// TestNudgeAfterApplyPublishesTheMappedKinds: a board write applied by the
// hub's own handler is published by the nudge its NudgeTable entry names,
// within the debounce and without waiting for a poll.
func TestNudgeAfterApplyPublishesTheMappedKinds(t *testing.T) {
	r := newChangeRig(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- r.pub.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })
	waitArmed(t, r.pubFT, 0)
	if _, err := r.d.Exec(`UPDATE targets SET status = 'in_progress' WHERE id = ?`, r.target); err != nil {
		t.Fatal(err)
	}
	kinds := handlers.NudgeTable["board_target_status"]
	n := r.pubFT.Armed()
	r.pub.PublishSoon(kinds...)
	waitArmed(t, r.pubFT, n)
	if n := r.pubFT.Armed(); r.pubFT.Advance(slices.Debounce) {
		waitArmed(t, r.pubFT, n)
	}
	if got := len(r.tr.times()); got != 2 {
		t.Fatalf("the nudge for %v saved %d times, want the start and the change", kinds, got)
	}
}

func TestContinuousWritesStillPublishWithinOneSecond(t *testing.T) {
	r := newChangeRig(t)
	r.run()
	last := r.pubFT.Now()
	seen := len(r.tr.times())
	cycles := 0
	for i := range 30 { // a write every 100 ms for 3 s
		r.write("Text " + string(rune('a'+i%26)))
		r.step(100 * time.Millisecond)
		if n := len(r.tr.times()); n > seen {
			seen, cycles, last = n, cycles+1, r.pubFT.Now()
		}
		if gap := r.pubFT.Now().Sub(last); gap > slices.MaxDebounceWait {
			t.Fatalf("a dirty kind waited %v, more than %v", gap, slices.MaxDebounceWait)
		}
	}
	if cycles < 3 {
		t.Fatalf("%d published cycles in 3 s of writes, want one at least every %v", cycles, slices.MaxDebounceWait)
	}
}

// TestAKindIsSavedAtMostOncePerSpacing over the real source and the
// data_version watch (the 1a publisher test of the same name drives a fake
// source): two saves of workbench_target are never closer than the relay's
// spacing, however fast the writes come.
func TestAKindIsSavedAtMostOncePerSpacing(t *testing.T) {
	r := newChangeRig(t)
	r.run()
	for i := range 40 { // a write every 40 ms for 1.6 s, and a handler's nudge on every third
		r.write("Fast " + string(rune('a'+i%26)))
		if i%3 == 0 {
			n := r.pubFT.Armed()
			r.pub.PublishSoon("workbench_target")
			waitArmed(t, r.pubFT, n)
		}
		r.step(40 * time.Millisecond)
	}
	r.step(time.Second)
	saves := r.tr.times()
	if len(saves) < 3 {
		t.Fatalf("%d saves", len(saves))
	}
	for i := 1; i < len(saves); i++ {
		if gap := saves[i].Sub(saves[i-1]); gap < slices.RelaySpacing {
			t.Fatalf("saves %d and %d are %v apart, less than %v", i-1, i, gap, slices.RelaySpacing)
		}
	}
}
