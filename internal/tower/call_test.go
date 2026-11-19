package tower

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

var fixedNow = time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)

// testParams is the request of the test write commands.
type testParams struct {
	api.WriteParams
	Note   string `json:"note"`
	Fail   bool   `json:"fail"`   // fn returns a fault after its insert
	Refuse bool   `json:"refuse"` // fn refuses with CodeChanged after its insert
}

type testResult struct {
	RowID int64  `json:"row_id"`
	Note  string `json:"note"`
}

type readResult struct {
	Rows int `json:"rows"`
}

// fixture is a Tower over a temp database with three test commands:
// test.read (Read), test.guarded (idempotent, one Write) and test.once
// (non-idempotent, one Write).
type fixture struct {
	t        *testing.T
	d        *db.DB
	tower    *Tower
	runs     map[string]int
	changed  [][]string
	seenOnce string // the ledger state test.once saw before acting
	path     string
	opts     Options // what the Tower was built with
	// beforeWrite runs in the write handlers just before c.Write.
	beforeWrite func()
	onChange    func()
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	return newFixtureWith(t, nil)
}

// newFixtureWith is newFixture with extra applied to the registry and the
// options before the Tower is built (more commands, a workspace, a watch).
func newFixtureWith(t *testing.T, extra func(r *Registry, o *Options)) *fixture {
	t.Helper()
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if _, err := d.Exec(`CREATE TABLE test_rows (id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	f := &fixture{t: t, d: d, path: path, runs: map[string]int{}}
	r := &Registry{}
	RegisterBuiltins(r)
	insert := func(ctx context.Context, c *Ctx, p testParams) (testResult, error) {
		if f.beforeWrite != nil {
			f.beforeWrite()
		}
		res, err := c.Write(ctx, func(tx *sql.Tx) (any, error) {
			out, err := tx.Exec(`INSERT INTO test_rows (note) VALUES (?)`, p.Note)
			if err != nil {
				return nil, err
			}
			if p.Fail {
				return nil, errors.New("fault after the insert")
			}
			if p.Refuse {
				return nil, Refuse(api.CodeChanged, "This card changed — look again")
			}
			id, err := out.LastInsertId()
			return testResult{RowID: id, Note: p.Note}, err
		})
		if err != nil {
			return testResult{}, err
		}
		return res.(testResult), nil
	}
	Register(r, "test.read", func(ctx context.Context, c *Ctx, _ struct{}) (readResult, error) {
		f.runs["test.read"]++
		var n int
		err := c.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM test_rows`).Scan(&n)
		return readResult{Rows: n}, err
	}, Spec{Read: true, ChangeTables: []string{"test_rows"}})
	Register(r, "test.guarded", func(ctx context.Context, c *Ctx, p testParams) (testResult, error) {
		f.runs["test.guarded"]++
		return insert(ctx, c, p)
	}, Spec{Idempotent: true, ChangeTables: []string{"test_rows"}})
	Register(r, "test.once", func(ctx context.Context, c *Ctx, p testParams) (testResult, error) {
		f.runs["test.once"]++
		row, err := c.DB.GetTowerRequest(ctx, p.RequestID)
		if err != nil {
			return testResult{}, err
		}
		if row != nil {
			f.seenOnce = row.State
		}
		return insert(ctx, c, p)
	}, Spec{ChangeTables: []string{"test_rows"}})
	o := Options{
		Registry: r,
		Build:    "1.2.3",
		Now:      func() time.Time { return fixedNow },
		Changed: func(tables []string) {
			if f.onChange != nil {
				f.onChange()
			}
			f.changed = append(f.changed, tables)
		},
	}
	if extra != nil {
		extra(r, &o)
	}
	f.opts = o
	f.tower = New(d, o)
	return f
}

func (f *fixture) call(command string, params any) api.Response {
	f.t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		f.t.Fatal(err)
	}
	return f.tower.Call(context.Background(), api.Request{V: api.EnvelopeVersion, ID: "c1", Command: command, Params: raw},
		Origin{Transport: "socket"})
}

func (f *fixture) rows() int {
	f.t.Helper()
	var n int
	if err := f.d.QueryRow(`SELECT COUNT(*) FROM test_rows`).Scan(&n); err != nil {
		f.t.Fatal(err)
	}
	return n
}

func (f *fixture) ledger(id string) *db.TowerRequest {
	f.t.Helper()
	row, err := f.d.GetTowerRequest(context.Background(), id)
	if err != nil {
		f.t.Fatal(err)
	}
	return row
}

func (f *fixture) seed(fn func(tx *sql.Tx) error) {
	f.t.Helper()
	tx, err := f.d.Begin()
	if err != nil {
		f.t.Fatal(err)
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		f.t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		f.t.Fatal(err)
	}
}

func write(id, note string) testParams {
	return testParams{WriteParams: api.WriteParams{RequestID: id}, Note: note}
}

func wantStatus(t *testing.T, r api.Response, s api.Status) {
	t.Helper()
	if r.Status != s {
		t.Fatalf("status = %q (refusal %+v), want %q", r.Status, r.Refusal, s)
	}
	if r.ID != "c1" {
		t.Fatalf("response id = %q, want the request's", r.ID)
	}
}

func wantRefusal(t *testing.T, r api.Response, code api.RefusalCode) {
	t.Helper()
	wantStatus(t, r, api.StatusRefused)
	if r.Refusal == nil || r.Refusal.Code != code || r.Refusal.Sentence == "" {
		t.Fatalf("refusal = %+v, want code %q with a sentence", r.Refusal, code)
	}
}

func TestCall_UnknownCommandIsUnsupported(t *testing.T) {
	f := newFixture(t)
	wantRefusal(t, f.call("test.nope", struct{}{}), api.CodeUnsupported)
}

func TestCall_WrongEnvelopeVersionIsUnsupported(t *testing.T) {
	f := newFixture(t)
	r := f.tower.Call(context.Background(), api.Request{V: 2, ID: "c1", Command: "test.read"}, Origin{})
	wantRefusal(t, r, api.CodeUnsupported)
	if f.runs["test.read"] != 0 {
		t.Fatal("the handler ran for an envelope of another version")
	}
}

func TestCall_WriteWithoutRequestIDIsUnsupported(t *testing.T) {
	f := newFixture(t)
	for _, cmd := range []string{"test.guarded", "test.once"} {
		wantRefusal(t, f.call(cmd, write("", "a")), api.CodeUnsupported)
	}
	if f.runs["test.guarded"]+f.runs["test.once"] != 0 || f.rows() != 0 {
		t.Fatal("a write without request_id ran")
	}
}

func TestCall_ReadNeedsNoRequestID(t *testing.T) {
	f := newFixture(t)
	r := f.call("test.read", struct{}{})
	wantStatus(t, r, api.StatusOK)
	if string(r.Result) != `{"rows":0}` {
		t.Fatalf("result = %s", r.Result)
	}
	var n int
	if err := f.d.QueryRow(`SELECT COUNT(*) FROM tower_requests`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("a read wrote %d ledger rows (%v)", n, err)
	}
}

func TestCall_GuardedDoneRowCommitsWithTheWrite(t *testing.T) {
	f := newFixture(t)
	r := f.call("test.guarded", write("g1", "a"))
	wantStatus(t, r, api.StatusOK)
	row := f.ledger("g1")
	if f.rows() != 1 || row == nil || row.State != "done" || row.Command != "test.guarded" {
		t.Fatalf("after ok: rows=%d ledger=%+v", f.rows(), row)
	}
	if row.ResultJSON != string(r.Result) {
		t.Fatalf("stored %s, answered %s", row.ResultJSON, r.Result)
	}

	p := write("g2", "b")
	p.Fail = true
	wantRefusal(t, f.call("test.guarded", p), api.CodeUnsupported)
	if f.rows() != 1 || f.ledger("g2") != nil {
		t.Fatalf("after a fault: rows=%d ledger=%+v", f.rows(), f.ledger("g2"))
	}
}

func TestCall_GuardedRepeatOfDoneReturnsTheStoredResult(t *testing.T) {
	f := newFixture(t)
	first := f.call("test.guarded", write("g1", "a"))
	second := f.call("test.guarded", write("g1", "a"))
	wantStatus(t, second, api.StatusOK)
	if string(first.Result) != string(second.Result) {
		t.Fatalf("repeat answered %s, first %s", second.Result, first.Result)
	}
	if f.runs["test.guarded"] != 1 || f.rows() != 1 {
		t.Fatalf("runs=%d rows=%d, want 1 and 1", f.runs["test.guarded"], f.rows())
	}
}

func TestCall_GuardedBegunIsReRun(t *testing.T) {
	f := newFixture(t)
	f.seed(func(tx *sql.Tx) error { return db.BeginTowerRequestTx(tx, "g1", "test.guarded", fixedNow) })
	r := f.call("test.guarded", write("g1", "a"))
	wantStatus(t, r, api.StatusOK)
	if f.runs["test.guarded"] != 1 || f.rows() != 1 || f.ledger("g1").State != "done" {
		t.Fatalf("runs=%d rows=%d ledger=%+v", f.runs["test.guarded"], f.rows(), f.ledger("g1"))
	}
}

func TestCall_GuardedConcurrentDuplicateKeepsTheFirstResult(t *testing.T) {
	f := newFixture(t)
	// Another call with the same id commits after this one read the ledger
	// and before its write transaction: the write rolls back and the call
	// answers the stored result.
	f.beforeWrite = func() {
		f.seed(func(tx *sql.Tx) error {
			return db.FinishTowerRequestTx(tx, "g1", "test.guarded", `{"row_id":7,"note":"first"}`, fixedNow)
		})
	}
	r := f.call("test.guarded", write("g1", "second"))
	wantStatus(t, r, api.StatusOK)
	if string(r.Result) != `{"row_id":7,"note":"first"}` || f.rows() != 0 || len(f.changed) != 0 {
		t.Fatalf("result %s rows %d changed %v", r.Result, f.rows(), f.changed)
	}
}

func TestCall_NonIdempotentCommitsBegunBeforeActing(t *testing.T) {
	f := newFixture(t)
	r := f.call("test.once", write("o1", "a"))
	wantStatus(t, r, api.StatusOK)
	if f.seenOnce != "begun" {
		t.Fatalf("the handler saw ledger state %q, want begun", f.seenOnce)
	}
	row := f.ledger("o1")
	if row == nil || row.State != "done" || row.ResultJSON != string(r.Result) {
		t.Fatalf("ledger after ok = %+v", row)
	}
}

func TestCall_NonIdempotentRepeatOfBegunAnswersUnknown(t *testing.T) {
	f := newFixture(t)
	f.seed(func(tx *sql.Tx) error { return db.BeginTowerRequestTx(tx, "o1", "test.once", fixedNow) })
	r := f.call("test.once", write("o1", "a"))
	wantStatus(t, r, api.StatusUnknown)
	if f.runs["test.once"] != 0 {
		t.Fatal("the handler ran for a begun non-idempotent id")
	}
}

func TestCall_NonIdempotentFailureAfterBegunAnswersUnknown(t *testing.T) {
	f := newFixture(t)
	p := write("o1", "a")
	p.Fail = true
	wantStatus(t, f.call("test.once", p), api.StatusUnknown)
	if row := f.ledger("o1"); row == nil || row.State != "begun" {
		t.Fatalf("ledger = %+v, want begun", row)
	}
	wantStatus(t, f.call("test.once", write("o1", "a")), api.StatusUnknown)
	if f.runs["test.once"] != 1 {
		t.Fatalf("runs = %d, want 1", f.runs["test.once"])
	}
}

func TestCall_NonIdempotentRefusalResendAnswersTheSameRefusal(t *testing.T) {
	f := newFixture(t)
	p := write("o1", "a")
	p.Refuse = true
	first := f.call("test.once", p)
	wantRefusal(t, first, api.CodeChanged)
	row := f.ledger("o1")
	if row == nil || row.State != "done" || row.ResultJSON != "" || row.RefusalJSON == "" {
		t.Fatalf("ledger after a refusal = %+v, want done with the refusal", row)
	}
	// The reply was lost: the resend of the same id gets the same refusal,
	// not unknown, and does not run again.
	resend := f.call("test.once", p)
	wantRefusal(t, resend, api.CodeChanged)
	if *resend.Refusal != *first.Refusal || f.runs["test.once"] != 1 || f.rows() != 0 {
		t.Fatalf("resend refusal %+v (first %+v), runs=%d rows=%d", resend.Refusal, first.Refusal, f.runs["test.once"], f.rows())
	}
}

func TestCall_RequestIDOfAnotherCommandIsUnsupported(t *testing.T) {
	f := newFixture(t)
	wantStatus(t, f.call("test.guarded", write("x1", "a")), api.StatusOK)
	wantRefusal(t, f.call("test.once", write("x1", "a")), api.CodeUnsupported)
	if f.runs["test.once"] != 0 {
		t.Fatal("a request id of another command ran")
	}
}

func TestCall_RefusalCarriesCodeAndSentence(t *testing.T) {
	f := newFixture(t)
	p := write("g1", "a")
	p.Refuse = true
	r := f.call("test.guarded", p)
	wantRefusal(t, r, api.CodeChanged)
	if r.Refusal.Sentence != "This card changed — look again" {
		t.Fatalf("sentence = %q", r.Refusal.Sentence)
	}
	if f.ledger("g1") != nil || f.rows() != 0 {
		t.Fatal("a refused guarded call left a ledger row or its write")
	}
	// A resend may succeed later.
	wantStatus(t, f.call("test.guarded", write("g1", "a")), api.StatusOK)
}

func TestCall_SentenceOptionWordsAFault(t *testing.T) {
	f := newFixture(t)
	f.tower.opts.Sentence = func(command string, err error) string { return "Couldn't " + command + ": busy." }
	p := write("g1", "a")
	p.Fail = true
	r := f.call("test.guarded", p)
	wantRefusal(t, r, api.CodeUnsupported)
	if r.Refusal.Sentence != "Couldn't test.guarded: busy." {
		t.Fatalf("sentence = %q", r.Refusal.Sentence)
	}
}

func TestCall_ChangedFiresAfterCommitOnly(t *testing.T) {
	f := newFixture(t)
	// A second handle on the same file: it sees only committed rows.
	other, err := db.Open(f.path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = other.Close() })
	var committed int
	f.onChange = func() {
		if err := other.QueryRow(`SELECT COUNT(*) FROM test_rows`).Scan(&committed); err != nil {
			t.Error(err)
		}
	}
	wantStatus(t, f.call("test.guarded", write("g1", "a")), api.StatusOK)
	if len(f.changed) != 1 || len(f.changed[0]) != 1 || f.changed[0][0] != "test_rows" {
		t.Fatalf("changed = %v, want one [test_rows]", f.changed)
	}
	if committed != 1 {
		t.Fatalf("Changed fired with %d committed rows, want 1 (before the commit)", committed)
	}

	for _, p := range []testParams{
		{WriteParams: api.WriteParams{RequestID: "g2"}, Fail: true},
		{WriteParams: api.WriteParams{RequestID: "g3"}, Refuse: true},
	} {
		f.call("test.guarded", p)
	}
	if len(f.changed) != 1 {
		t.Fatalf("Changed fired on a rollback: %v", f.changed)
	}
}

// A fault with no Options.Sentence answers a fixed sentence, never the
// error's own text (which can carry paths or SQL).
func TestCall_FaultWithoutSentenceNeverLeaksTheErrorText(t *testing.T) {
	f := newFixture(t)
	p := write("g1", "a")
	p.Fail = true
	r := f.call("test.guarded", p)
	wantRefusal(t, r, api.CodeUnsupported)
	if r.Refusal.Sentence != FaultSentence || strings.Contains(r.Refusal.Sentence, "fault after the insert") {
		t.Fatalf("sentence = %q, want FaultSentence", r.Refusal.Sentence)
	}
	f.tower.opts.Sentence = func(string, error) string { return "worded" }
	if r := f.call("test.guarded", write("g2", "b")); r.Status != api.StatusOK {
		t.Fatalf("ok write: %+v", r)
	}
	p = write("g3", "c")
	p.Fail = true
	if r := f.call("test.guarded", p); r.Refusal == nil || r.Refusal.Sentence != "worded" {
		t.Fatalf("with a Sentence: %+v", r)
	}
}

func TestHello_ReturnsVersionBuildAndPause(t *testing.T) {
	f := newFixture(t)
	for _, paused := range []bool{false, true} {
		f.tower.opts.Paused = func() bool { return paused }
		f.tower.opts.NoSync = paused
		r := f.call("tower.hello", api.HelloRequest{})
		wantStatus(t, r, api.StatusOK)
		var h api.HelloResponse
		if err := json.Unmarshal(r.Result, &h); err != nil {
			t.Fatal(err)
		}
		want := api.HelloResponse{InterfaceVersion: InterfaceVersion, Build: "1.2.3", SyncPaused: paused, NoSync: paused}
		if h != want {
			t.Fatalf("hello = %+v, want %+v", h, want)
		}
	}
}

func TestPing_AnswersOK(t *testing.T) {
	f := newFixture(t)
	r := f.call("tower.ping", api.PingRequest{})
	wantStatus(t, r, api.StatusOK)
	if string(r.Result) != `{"at":"2026-11-16T09:00:00Z"}` {
		t.Fatalf("ping = %s", r.Result)
	}
}
