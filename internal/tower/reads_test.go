package tower

import (
	"context"
	"database/sql"
	"encoding/json"
	"runtime"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// answerTurns bounds how many scheduler turns a read gets to answer while
// the write pool is held: a count, not a clock. A read that queued behind
// the pool never answers; one on its own handle answers in a few turns.
const answerTurns = 10_000_000

// answeredWithin waits up to turns scheduler turns (runtime.Gosched) for one
// response on answers; false when none came.
func answeredWithin(answers <-chan api.Response, turns int) (api.Response, bool) {
	for range turns {
		select {
		case r := <-answers:
			return r, true
		default:
			runtime.Gosched()
		}
	}
	return api.Response{}, false
}

// callAsync runs the call on its own goroutine; the response arrives on the
// returned channel. Cancelling ctx unblocks a call queued for a connection.
func callAsync(ctx context.Context, tw *Tower, command string) <-chan api.Response {
	answers := make(chan api.Response, 1)
	go func() {
		answers <- tw.Call(ctx, api.Request{V: api.EnvelopeVersion, ID: "c1", Command: command, Params: json.RawMessage(`{}`)},
			Origin{Transport: "socket"})
	}()
	return answers
}

func TestReads_AnswerWhileAnotherConnectionHoldsAWriteTransaction(t *testing.T) {
	f := newFixture(t)
	reads, err := OpenReads(context.Background(), f.d)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reads.Close() })
	f.opts.ReadDB = reads
	f.tower = New(f.d, f.opts)
	wantStatus(t, f.call("test.guarded", write("g1", "committed")), api.StatusOK)

	// The daemon's pool has one connection: this write transaction holds it
	// and the file's write lock, as a running sync cycle would.
	tx, err := f.d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`INSERT INTO test_rows (note) VALUES ('uncommitted')`); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	answers := callAsync(ctx, f.tower, "test.read")
	r, ok := answeredWithin(answers, answerTurns)
	if !ok {
		cancel() // unblock the queued read before failing
		<-answers
		t.Fatal("test.read queued behind the held write pool instead of answering on its own handle")
	}
	wantStatus(t, r, api.StatusOK)
	var got readResult
	if err := json.Unmarshal(r.Result, &got); err != nil {
		t.Fatal(err)
	}
	if got.Rows != 1 {
		t.Fatalf("rows = %d, want 1 (the committed row only)", got.Rows)
	}
	if f.runs["test.read"] != 1 {
		t.Fatalf("test.read ran %d times", f.runs["test.read"])
	}
}

// Writes stay on the daemon's pool: the read handle is query_only, so a
// write command that ran on it would fail.
func TestReads_WritesStayOnTheWriteHandle(t *testing.T) {
	f := newFixture(t)
	reads, err := OpenReads(context.Background(), f.d)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reads.Close() })
	f.opts.ReadDB = reads
	f.tower = New(f.d, f.opts)
	wantStatus(t, f.call("test.guarded", write("g1", "a")), api.StatusOK)
	wantStatus(t, f.call("test.once", write("o1", "b")), api.StatusOK)
	if f.rows() != 2 {
		t.Fatalf("rows = %d, want 2", f.rows())
	}
}

// An in-memory database has no file to open a second handle on: OpenReads
// fails, and a Tower without ReadDB still answers reads on its own handle.
func TestReads_NoFileFailsAndReadsFallBack(t *testing.T) {
	mem, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = mem.Close() })
	if r, err := OpenReads(context.Background(), mem); err == nil {
		_ = r.Close()
		t.Fatal("OpenReads of an in-memory database: want an error")
	}
	var reg Registry
	RegisterBuiltins(&reg)
	tw := New(mem, Options{Registry: &reg, Build: "1"})
	r := tw.Call(context.Background(), api.Request{V: api.EnvelopeVersion, ID: "c1", Command: "tower.hello", Params: json.RawMessage(`{}`)},
		Origin{Transport: "socket"})
	wantStatus(t, r, api.StatusOK)
}

// The read handle keeps every connection warm: as many idle as open, none
// idle-closed.
func TestReads_HandleKeepsItsConnectionsWarm(t *testing.T) {
	f := newFixture(t)
	reads, err := OpenReads(context.Background(), f.d)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reads.Close() })
	ctx := context.Background()
	var conns []*sql.Conn
	for range readConns {
		c, err := reads.Conn(ctx)
		if err != nil {
			t.Fatal(err)
		}
		conns = append(conns, c)
	}
	for _, c := range conns {
		_ = c.Close()
	}
	if s := reads.Stats(); s.MaxOpenConnections != readConns || s.Idle != readConns {
		t.Fatalf("stats %+v: want %d open, all idle", s, readConns)
	}
}
