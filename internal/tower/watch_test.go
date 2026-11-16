package tower

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"slices"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// watchFixture is a fixture whose Tower publishes into a Changes polling
// every poll, with test.watch (a watch over test_rows) registered.
func watchFixture(t *testing.T, poll time.Duration) (*fixture, *Changes) {
	t.Helper()
	var ch *Changes
	f := newFixtureWith(t, func(r *Registry, o *Options) {
		Register(r, "test.watch", func(context.Context, *Ctx, struct{}) (struct{}, error) {
			return struct{}{}, nil
		}, Spec{Watch: true, ChangeTables: []string{"test_rows"}})
	})
	ch = NewChanges(f.d, poll)
	f.tower = New(f.d, Options{Registry: f.opts.Registry, Now: f.opts.Now, Changes: ch})
	return f, ch
}

// recvNow returns the event waiting on events, failing when there is none.
func recvNow(t *testing.T, events <-chan api.ChangedEvent, what string) api.ChangedEvent {
	t.Helper()
	select {
	case ev := <-events:
		return ev
	default:
		t.Fatalf("no event: %s", what)
		return api.ChangedEvent{}
	}
}

func requireNoEvent(t *testing.T, events <-chan api.ChangedEvent, what string) {
	t.Helper()
	select {
	case ev := <-events:
		t.Fatalf("unexpected event %+v: %s", ev, what)
	default:
	}
}

func TestWatch_OwnWriteEmitsAtCommit(t *testing.T) {
	f, ch := watchFixture(t, PollInterval)
	synctest.Test(t, func(t *testing.T) {
		events, cancel := ch.Subscribe(nil)
		defer cancel()
		synctest.Wait() // the poll took its baseline
		if r := f.call("test.guarded", testParams{WriteParams: api.WriteParams{RequestID: "g1"}, Note: "a"}); r.Status != api.StatusOK {
			t.Fatalf("write: %+v", r)
		}
		// Delivered before Call returned: no clock moved since.
		ev := recvNow(t, events, "an own write")
		if ev.Event != api.EventChanged || !slices.Equal(ev.Tables, []string{"test_rows"}) {
			t.Fatalf("event %+v", ev)
		}
	})
}

func TestWatch_ForeignWriteWithinHalfSecond(t *testing.T) {
	f, ch := watchFixture(t, PollInterval)
	other, err := db.Open(f.path) // another process's handle
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = other.Close() })
	synctest.Test(t, func(t *testing.T) {
		events, cancel := ch.Subscribe([]string{"test_rows"})
		defer cancel()
		synctest.Wait()
		requireNoEvent(t, events, "before any write")
		if _, err := other.Exec(`INSERT INTO test_rows (note) VALUES ('foreign')`); err != nil {
			t.Fatal(err)
		}
		time.Sleep(2 * PollInterval)
		synctest.Wait()
		ev := recvNow(t, events, "a foreign write within 500 ms")
		if ev.Event != api.EventChanged || len(ev.Tables) != 0 {
			t.Fatalf("event %+v, want changed with no tables", ev)
		}
	})
}

func TestWatch_FilterKeepsOnlyMatchingOrUnlabelled(t *testing.T) {
	_, ch := watchFixture(t, time.Hour)
	events, cancel := ch.Subscribe([]string{"inbox_items", "outputs"})
	defer cancel()
	all, cancelAll := ch.Subscribe(nil)
	defer cancelAll()

	ch.Publish([]string{"ideas"})
	requireNoEvent(t, events, "a table outside the filter")
	if ev := recvNow(t, all, "an unfiltered watch gets every event"); !slices.Equal(ev.Tables, []string{"ideas"}) {
		t.Fatalf("unfiltered event %+v", ev)
	}

	ch.Publish([]string{"ideas", "outputs"})
	if ev := recvNow(t, events, "one table in the filter"); !slices.Equal(ev.Tables, []string{"ideas", "outputs"}) {
		t.Fatalf("matching event %+v", ev)
	}
	ch.Publish(nil)
	if ev := recvNow(t, events, "an unlabelled event"); len(ev.Tables) != 0 {
		t.Fatalf("unlabelled event %+v", ev)
	}
	requireNoEvent(t, events, "one event per publish")
}

func TestWatch_PollStopsWithTheLastWatch(t *testing.T) {
	_, ch := watchFixture(t, PollInterval)
	var reads atomic.Int64
	read := ch.readVersion
	ch.readVersion = func(ctx context.Context, c *sql.Conn) (int64, error) {
		reads.Add(1)
		return read(ctx, c)
	}
	synctest.Test(t, func(t *testing.T) {
		time.Sleep(10 * time.Second)
		synctest.Wait()
		if n := reads.Load(); n != 0 {
			t.Fatalf("%d data_version reads with no watch open", n)
		}
		_, cancelA := ch.Subscribe(nil)
		_, cancelB := ch.Subscribe(nil)
		time.Sleep(time.Second)
		synctest.Wait()
		if n := reads.Load(); n < 4 {
			t.Fatalf("%d reads in a second of an open watch, want a read every %s", n, PollInterval)
		}
		cancelA()
		before := reads.Load()
		time.Sleep(time.Second)
		synctest.Wait()
		if reads.Load() == before {
			t.Fatal("the poll stopped while a watch is still open")
		}
		cancelB()
		after := reads.Load()
		time.Sleep(10 * time.Second)
		synctest.Wait()
		if n := reads.Load() - after; n != 0 {
			t.Fatalf("%d data_version reads after the last watch closed", n)
		}
	})
}

func TestWatch_SocketStreamsEvents(t *testing.T) {
	// An hour's poll: only the baseline read runs, so the one event is the
	// own write's.
	f, _ := watchFixture(t, time.Hour)
	path := filepath.Join(shortDir(t), "tower.sock")
	serve(t, path, f)
	w := dialTower(t, path)
	w.send("w1", "test.watch", nil)
	if r := w.response(); r.Status != api.StatusOK || r.ID != "w1" {
		t.Fatalf("watch answered %+v", r)
	}
	c := dialTower(t, path)
	c.send("g1", "test.guarded", testParams{WriteParams: api.WriteParams{RequestID: "g1"}, Note: "a"})
	if r := c.response(); r.Status != api.StatusOK {
		t.Fatalf("write: %+v", r)
	}
	b, err := w.line()
	if err != nil {
		t.Fatal(err)
	}
	var ev api.ChangedEvent
	if err := json.Unmarshal(b, &ev); err != nil {
		t.Fatal(err)
	}
	if ev.ID != "w1" || ev.Event != api.EventChanged || !slices.Equal(ev.Tables, []string{"test_rows"}) {
		t.Fatalf("event frame %s", b)
	}
	// The watching connection still answers calls.
	if r := w.ping("p"); r.Status != api.StatusOK || r.ID != "p" {
		t.Fatalf("ping on the watching connection: %+v", r)
	}
}

func TestWatch_WithoutChangesIsRefused(t *testing.T) {
	f := newFixtureWith(t, func(r *Registry, _ *Options) {
		Register(r, "test.watch", func(context.Context, *Ctx, struct{}) (struct{}, error) {
			return struct{}{}, nil
		}, Spec{Watch: true})
	})
	path := filepath.Join(shortDir(t), "tower.sock")
	serve(t, path, f)
	c := dialTower(t, path)
	c.send("w", "test.watch", nil)
	if r := c.response(); r.Status != api.StatusRefused || r.Refusal.Code != api.CodeUnsupported {
		t.Fatalf("a watch with no change watch: %+v", r)
	}
}
