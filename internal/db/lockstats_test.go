package db

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"watchtower/internal/db/lockmetrics"
)

// configureLockSink points the process-wide lockmetrics sink beside dbPath for the
// test and switches it off again afterwards; the returned func reads back the
// events written so far.
func configureLockSink(t *testing.T, dbPath string) func() []lockmetrics.Event {
	t.Helper()
	lockmetrics.Configure(dbPath)
	t.Cleanup(func() { lockmetrics.Configure("") })
	sink := filepath.Join(filepath.Dir(dbPath), lockmetrics.FileName)
	return func() []lockmetrics.Event {
		t.Helper()
		f, err := os.Open(sink)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = f.Close() }()
		var events []lockmetrics.Event
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			var e lockmetrics.Event
			if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
				t.Fatalf("bad line %q: %v", sc.Text(), err)
			}
			events = append(events, e)
		}
		if err := sc.Err(); err != nil {
			t.Fatal(err)
		}
		return events
	}
}

func eventsOfKind(events []lockmetrics.Event, kind string) []lockmetrics.Event {
	var out []lockmetrics.Event
	for _, e := range events {
		if e.Kind == kind {
			out = append(out, e)
		}
	}
	return out
}

var checkpointFormat = regexp.MustCompile(`^busy=-?\d+ log=-?\d+ ckpt=-?\d+$`)

func TestSampleLockStats_WALEventWithoutPoolWait(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	database, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	if _, err := database.CreateWorkbench("acme", t.TempDir()); err != nil {
		t.Fatal(err) // a write, so the WAL file holds frames
	}
	events := configureLockSink(t, path)

	walInfo, err := os.Stat(path + "-wal")
	if err != nil {
		t.Fatal(err)
	}
	next := database.SampleLockStats(context.Background(), database.Stats())

	got := events()
	wal := eventsOfKind(got, lockmetrics.KindWAL)
	if len(wal) != 1 {
		t.Fatalf("want one wal event, got %+v", got)
	}
	if wal[0].WALBytes != walInfo.Size() || wal[0].WALBytes <= 0 {
		t.Errorf("wal_bytes = %d, want the -wal size %d", wal[0].WALBytes, walInfo.Size())
	}
	if !checkpointFormat.MatchString(wal[0].Checkpoint) {
		t.Errorf("checkpoint = %q, want busy=<a> log=<b> ckpt=<c>", wal[0].Checkpoint)
	}
	if wal[0].Err != "" {
		t.Errorf("err = %q, want none", wal[0].Err)
	}
	if pw := eventsOfKind(got, lockmetrics.KindPoolWait); len(pw) != 0 {
		t.Errorf("no pool wait since prev, want no pool_wait event, got %+v", pw)
	}
	if next.MaxOpenConnections != 1 {
		t.Errorf("want the pool's current stats returned, got %+v", next)
	}
}

func TestSampleLockStats_PoolWaitDelta(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	database, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	events := configureLockSink(t, path)
	ctx := context.Background()

	prev := database.Stats()
	// The pool holds one connection: a query issued while it is checked
	// out waits for the pool until the holder returns it.
	conn, err := database.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	released := make(chan struct{})
	go func() {
		defer close(released)
		time.Sleep(30 * time.Millisecond)
		_ = conn.Close()
	}()
	if _, err := database.ExecContext(ctx, `SELECT 1`); err != nil {
		t.Fatal(err)
	}
	<-released

	next := database.SampleLockStats(ctx, prev)
	pw := eventsOfKind(events(), lockmetrics.KindPoolWait)
	if len(pw) != 1 {
		t.Fatalf("want one pool_wait event, got %+v", pw)
	}
	wantMS := (next.WaitDuration - prev.WaitDuration).Milliseconds()
	if pw[0].WaitMS != wantMS || pw[0].WaitMS < 1 {
		t.Errorf("wait_ms = %d, want the delta %d (≥ 1)", pw[0].WaitMS, wantMS)
	}

	// Nothing waited since: the next sample writes no new pool_wait line.
	database.SampleLockStats(ctx, next)
	if pw := eventsOfKind(events(), lockmetrics.KindPoolWait); len(pw) != 1 {
		t.Errorf("a zero delta must not add a pool_wait event, got %+v", pw)
	}
	if wal := eventsOfKind(events(), lockmetrics.KindWAL); len(wal) != 2 {
		t.Errorf("want a wal event per sample, got %+v", wal)
	}
}

func TestSampleLockStats_DisabledSinkWritesNothing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	database, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	lockmetrics.Configure("")

	got := database.SampleLockStats(context.Background(), sql.DBStats{})
	if got.MaxOpenConnections != 1 {
		t.Errorf("the pool stats are still returned, got %+v", got)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(path), lockmetrics.FileName)); !os.IsNotExist(err) {
		t.Errorf("no sink configured, want no %s, stat err = %v", lockmetrics.FileName, err)
	}
}

func TestSampleLockStats_InMemoryDBHasNoWALEvent(t *testing.T) {
	database := OpenTestDB(t)
	events := configureLockSink(t, filepath.Join(t.TempDir(), "watchtower.db"))

	database.SampleLockStats(context.Background(), database.Stats())
	if wal := eventsOfKind(events(), lockmetrics.KindWAL); len(wal) != 0 {
		t.Errorf("an in-memory DB has no WAL file, want no wal event, got %+v", wal)
	}
}
