package sessionhost

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/sessionfeed"
)

const (
	wTurnStarted = `{"timestamp":"2026-11-05T12:19:00.699Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}`
	wTurnFailed  = `{"timestamp":"2026-11-05T12:19:00.918Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1",` +
		`"last_agent_message":null,"error":{"message":"limit","codex_error_info":"usage_limit_exceeded"}}}`
	wTurnAborted = `{"timestamp":"2026-11-05T12:19:01.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}}`
	wSessionID   = "019a0000-0000-7000-8000-000000000001"
)

// fakeWatchStore is the database side of a watch: one row, the issues and
// turns written, and the guards SetAgentWatchIssue applies.
type fakeWatchStore struct {
	mu      sync.Mutex
	row     db.CodexWatchRow
	gone    bool
	issues  []string
	turns   []sessionfeed.CodexTurn
	reads   int
	closed  bool
	rowErrs int
}

func (s *fakeWatchStore) Row(int64) (db.CodexWatchRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.reads++
	if s.gone {
		return db.CodexWatchRow{}, db.ErrTerminalSessionNotFound
	}
	if s.rowErrs > 0 {
		s.rowErrs--
		return db.CodexWatchRow{}, fmt.Errorf("database is locked")
	}
	return s.row, nil
}

func (s *fakeWatchStore) RecordTurn(_ db.CodexWatchRow, turn sessionfeed.CodexTurn) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.turns = append(s.turns, turn)
	if s.row.State == "working" && (s.row.StateAt.IsZero() || turn.At.After(s.row.StateAt)) {
		s.row.State, s.row.StateAt, s.row.Failed = "waiting", turn.At, turn.Failed
	}
	return nil
}

func (s *fakeWatchStore) SetIssue(_ int64, issue string, _ time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.row.State != "working" || s.row.Failed || s.row.Finished || s.row.WatchIssue == issue {
		return false, nil
	}
	s.row.WatchIssue = issue
	s.issues = append(s.issues, issue)
	return true, nil
}

func (s *fakeWatchStore) Close() error { s.closed = true; return nil }

func (s *fakeWatchStore) set(f func(r *db.CodexWatchRow)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f(&s.row)
}

func (s *fakeWatchStore) snapshot() (issues []string, turns []sessionfeed.CodexTurn) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.issues...), append([]sessionfeed.CodexTurn(nil), s.turns...)
}

// watchFixture is one watch over a working codex row whose rollout is path
// (not created), on a fake clock at t0.
type watchFixture struct {
	t       *testing.T
	store   *fakeWatchStore
	w       *CodexWatch
	path    string
	now     time.Time
	locates int
	logs    bytes.Buffer
}

func newWatchFixture(t *testing.T) *watchFixture {
	t.Helper()
	dir := t.TempDir()
	f := &watchFixture{t: t, path: filepath.Join(dir, "rollout-2026-11-05T12-00-00-"+wSessionID+".jsonl"),
		now: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC)}
	f.store = &fakeWatchStore{row: db.CodexWatchRow{ID: 7, WorkbenchID: 1, Kind: "codex", State: "working",
		StateAt: f.now.Add(-time.Minute), SessionID: wSessionID, TranscriptPath: f.path}}
	f.w = NewCodexWatch(7, f.store, filepath.Join(dir, "codex-home"), func(format string, args ...any) {
		fmt.Fprintf(&f.logs, format+"\n", args...)
	})
	f.w.locate = func(home, sid, stored string) (string, bool) {
		f.locates++
		return sessionfeed.LocateCodex(home, sid, stored)
	}
	return f
}

func (f *watchFixture) write(lines ...string) {
	f.t.Helper()
	if err := os.WriteFile(f.path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		f.t.Fatal(err)
	}
}

// tick advances the clock by step and runs one tick; it reports done.
func (f *watchFixture) tick(step time.Duration) bool {
	f.now = f.now.Add(step)
	return f.w.Tick(f.now)
}

func TestCodexWatch_MissingGivesUpAfter30s(t *testing.T) {
	f := newWatchFixture(t)
	for i := 0; i < 14; i++ { // 28 s missing
		if f.tick(CodexWatchEvery) {
			t.Fatal("the watch stopped on a missing rollout")
		}
	}
	if issues, _ := f.store.snapshot(); len(issues) != 0 {
		t.Fatalf("gave up before 30 s: %v", issues)
	}
	f.tick(CodexWatchEvery)
	f.tick(CodexWatchEvery)
	issues, _ := f.store.snapshot()
	if len(issues) != 1 || issues[0] != db.WatchIssueMissing {
		t.Fatalf("issues = %v; want one missing after 30 s", issues)
	}
	if f.locates != 1 {
		t.Fatalf("LocateCodex ran %d times; want once", f.locates)
	}
}

// A rollout found under $CODEX_HOME/sessions by its session id is watched
// instead of the stale stored path.
func TestCodexWatch_MissingLocatesTheRolloutOnce(t *testing.T) {
	f := newWatchFixture(t)
	day := filepath.Join(f.w.codexHome, "sessions", "2026", "11", "05")
	if err := os.MkdirAll(day, 0o700); err != nil {
		t.Fatal(err)
	}
	moved := filepath.Join(day, filepath.Base(f.path))
	if err := os.WriteFile(moved, []byte(wTurnStarted+"\n"+wTurnFailed+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f.tick(CodexWatchEvery)
	f.tick(CodexWatchEvery)
	if _, turns := f.store.snapshot(); len(turns) != 1 || !turns[0].Failed {
		t.Fatalf("turns = %+v; want the located rollout's failure", turns)
	}
}

func TestCodexWatch_PermissionDeniedAtOnce(t *testing.T) {
	f := newWatchFixture(t)
	f.write(wTurnStarted)
	if err := os.Chmod(f.path, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(f.path, 0o600) })
	if _, err := os.ReadFile(f.path); err == nil {
		t.Skip("running as a user that reads mode 000 files")
	}
	f.tick(CodexWatchEvery)
	if issues, _ := f.store.snapshot(); len(issues) != 1 || issues[0] != db.WatchIssuePermission {
		t.Fatalf("issues = %v; want permission at once", issues)
	}
}

// A zstd rollout the reader cannot decode is `compressed` at once (before
// N1's reader every zstd rollout was).
func TestCodexWatch_CompressedAtOnceBeforeN1Reader(t *testing.T) {
	f := newWatchFixture(t)
	if err := os.WriteFile(f.path, append([]byte{0x28, 0xb5, 0x2f, 0xfd}, []byte(wTurnFailed)...), 0o600); err != nil {
		t.Fatal(err)
	}
	f.tick(CodexWatchEvery)
	if issues, _ := f.store.snapshot(); len(issues) != 1 || issues[0] != db.WatchIssueCompressed {
		t.Fatalf("issues = %v; want compressed at once", issues)
	}
}

func TestCodexWatch_TruncatedLastLineWaits(t *testing.T) {
	f := newWatchFixture(t)
	if err := os.WriteFile(f.path, []byte(wTurnStarted+"\n"+wTurnFailed[:50]), 0o600); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		f.tick(CodexWatchEvery)
	}
	if issues, turns := f.store.snapshot(); len(issues) != 0 || len(turns) != 0 {
		t.Fatalf("issues %v turns %+v; an unterminated line is left for the next tick", issues, turns)
	}
	f.write(wTurnStarted, wTurnFailed)
	f.tick(CodexWatchEvery)
	if _, turns := f.store.snapshot(); len(turns) != 1 || !turns[0].Failed || turns[0].Error != "usage_limit_exceeded" {
		t.Fatalf("turns = %+v; want the completed failure", turns)
	}
}

func TestCodexWatch_UnreadableAfterThreeTicks(t *testing.T) {
	f := newWatchFixture(t)
	f.write(wTurnStarted, `{garbage`)
	f.tick(CodexWatchEvery)
	f.tick(CodexWatchEvery)
	if issues, _ := f.store.snapshot(); len(issues) != 0 {
		t.Fatalf("gave up after two ticks: %v", issues)
	}
	f.tick(CodexWatchEvery)
	if issues, _ := f.store.snapshot(); len(issues) != 1 || issues[0] != db.WatchIssueUnreadable {
		t.Fatalf("issues = %v; want unreadable on the third tick", issues)
	}
	if strings.Contains(f.logs.String(), f.path) || strings.Contains(f.logs.String(), "rollout-") {
		t.Fatalf("the log names the path:\n%s", f.logs.String())
	}
}

// A decodable tail between undecodable ones restarts the count.
func TestCodexWatch_UnreadableCountsTicksInARow(t *testing.T) {
	f := newWatchFixture(t)
	f.write(wTurnStarted, `{garbage`)
	f.tick(CodexWatchEvery)
	f.tick(CodexWatchEvery)
	f.write(wTurnStarted, `{garbage`, wTurnStarted)
	f.tick(CodexWatchEvery)
	f.write(wTurnStarted, `{garbage`, wTurnStarted, `{garbage`)
	f.tick(CodexWatchEvery)
	if issues, _ := f.store.snapshot(); len(issues) != 0 {
		t.Fatalf("issues = %v; a clean tail in between restarts the count", issues)
	}
}

func TestCodexWatch_RotationReopensAndNeverGivesUp(t *testing.T) {
	f := newWatchFixture(t)
	f.write(wTurnStarted, `{"type":"response_item","payload":{"text":"`+strings.Repeat("x", 4096)+`"}}`)
	f.tick(CodexWatchEvery)

	// Size shrink: the file was replaced by a shorter one (compact).
	f.write(wTurnStarted)
	f.tick(CodexWatchEvery)
	// Inode change: a new file under the same name.
	if err := os.Remove(f.path); err != nil {
		t.Fatal(err)
	}
	f.write(wTurnStarted, wTurnAborted)
	f.tick(CodexWatchEvery)
	if _, turns := f.store.snapshot(); len(turns) != 1 || !turns[0].Aborted {
		t.Fatalf("turns = %+v; want the replaced file's abort", turns)
	}

	// A new agent_transcript_path (resume or fork onto another file).
	other := filepath.Join(filepath.Dir(f.path), "rollout-2026-11-05T13-00-00-"+wSessionID+".jsonl")
	if err := os.WriteFile(other, []byte(wTurnStarted+"\n"+wTurnFailed+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f.store.set(func(r *db.CodexWatchRow) {
		r.State, r.StateAt, r.TranscriptPath = "working", time.Date(2026, 11, 5, 12, 19, 0, 0, time.UTC), other
	})
	for i := 0; i < 30; i++ {
		f.tick(CodexWatchEvery)
	}
	issues, turns := f.store.snapshot()
	if len(issues) != 0 {
		t.Fatalf("a rotation gave up: %v", issues)
	}
	if len(turns) != 2 || !turns[1].Failed {
		t.Fatalf("turns = %+v; want the new path's failure", turns)
	}
}

func TestCodexWatch_StopsAtFinishedDeletedOrNotWorking(t *testing.T) {
	for _, c := range []struct {
		name     string
		change   func(s *fakeWatchStore)
		wantDone bool
	}{
		{"finished", func(s *fakeWatchStore) { s.set(func(r *db.CodexWatchRow) { r.Finished = true }) }, false},
		{"waiting", func(s *fakeWatchStore) { s.set(func(r *db.CodexWatchRow) { r.State = "waiting" }) }, false},
		{"no state", func(s *fakeWatchStore) { s.set(func(r *db.CodexWatchRow) { r.State = "" }) }, false},
		{"already unwatched", func(s *fakeWatchStore) { s.set(func(r *db.CodexWatchRow) { r.WatchIssue = "missing" }) }, false},
		{"no path yet", func(s *fakeWatchStore) { s.set(func(r *db.CodexWatchRow) { r.TranscriptPath = "" }) }, false},
		{"deleted", func(s *fakeWatchStore) { s.mu.Lock(); s.gone = true; s.mu.Unlock() }, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := newWatchFixture(t)
			reads := 0
			f.w.read = func(p string) (sessionfeed.CodexTurn, error) {
				reads++
				return sessionfeed.CodexLastTurn(p)
			}
			c.change(f.store)
			var done bool
			for i := 0; i < 20; i++ { // 40 s: past the missing give-up
				done = f.tick(CodexWatchEvery)
				if done {
					break
				}
			}
			if done != c.wantDone {
				t.Fatalf("done = %v; want %v", done, c.wantDone)
			}
			if issues, turns := f.store.snapshot(); len(issues)+len(turns) != 0 || reads != 0 || f.locates != 0 {
				t.Fatalf("issues %v turns %v reads %d locates %d; want nothing read or written", issues, turns, reads, f.locates)
			}
		})
	}
}

// A working row again after a hook cleared the issue re-arms the watch from
// scratch: its missing clock starts over.
func TestCodexWatch_ClearedIssueRearms(t *testing.T) {
	f := newWatchFixture(t)
	for i := 0; i < 16; i++ {
		f.tick(CodexWatchEvery)
	}
	f.store.set(func(r *db.CodexWatchRow) { r.WatchIssue = "" }) // the next hook event cleared it
	f.write(wTurnStarted)
	f.tick(CodexWatchEvery)
	if err := os.Remove(f.path); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10; i++ {
		f.tick(CodexWatchEvery)
	}
	if issues, _ := f.store.snapshot(); len(issues) != 1 {
		t.Fatalf("issues = %v; the re-armed watch gave up again before its own 30 s", issues)
	}
}

func TestProj11_WatchIssueLogLineCarriesNoPath(t *testing.T) {
	f := newWatchFixture(t)
	for i := 0; i < 16; i++ {
		f.tick(CodexWatchEvery)
	}
	log := f.logs.String()
	if strings.Count(log, "\n") != 1 || !strings.Contains(log, "session 7") || !strings.Contains(log, "missing") {
		t.Fatalf("log = %q; want one line with the row id and the class", log)
	}
	for _, leak := range []string{f.path, filepath.Dir(f.path), wSessionID, "rollout-"} {
		if strings.Contains(log, leak) {
			t.Fatalf("the log line carries %q: %q", leak, log)
		}
	}
}

// PROJ-20: a hosted codex session keeps its watch whoever is attached — a
// client that drops and a later attach (the app's adoption) never stop it,
// and the store is closed once the session ends.
func TestCodexWatch_HostAdoptionRearms(t *testing.T) {
	dir := t.TempDir()
	rollout := filepath.Join(dir, "rollout-2026-11-05T12-00-00-"+wSessionID+".jsonl")
	if err := os.WriteFile(rollout, []byte(wTurnStarted+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	store := &fakeWatchStore{row: db.CodexWatchRow{ID: 1, WorkbenchID: 1, Kind: "codex", State: "working",
		StateAt: time.Date(2026, 11, 5, 12, 0, 0, 0, time.UTC), SessionID: wSessionID, TranscriptPath: rollout}}
	var opened []string
	var mu sync.Mutex
	path, _ := startHost(t, Options{codexWatchEvery: 20 * time.Millisecond, CodexWatch: func(dbPath string) (CodexWatchStore, error) {
		mu.Lock()
		opened = append(opened, dbPath)
		mu.Unlock()
		return store, nil
	}})
	c1 := dial(t, path)
	c1.send(Launch, LaunchReq{Row: 1, Run: "r1", Executable: "/bin/sh", Args: []string{"-c", "sleep 30"},
		Cwd: os.TempDir(), Cols: 80, Rows: 24, Watch: &WatchSpec{Agent: "codex", Database: "/work/watchtower.db"},
		Env: []string{"CODEX_HOME=" + filepath.Join(dir, "home")}})
	var info SessionInfo
	if err := json.Unmarshal(c1.expect(Launched), &info); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reap(t, info.Pid) })
	_ = c1.nc.Close()

	c2 := dial(t, path)
	c2.send(Attach, AttachReq{Row: 1, Run: "r1"})
	c2.expect(Attached)
	if err := os.WriteFile(rollout, []byte(wTurnStarted+"\n"+wTurnFailed+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(ioTimeout)
	for {
		if _, turns := store.snapshot(); len(turns) == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the watch never read the failure after the re-attach")
		}
		time.Sleep(10 * time.Millisecond)
	}
	mu.Lock()
	if len(opened) != 1 || opened[0] != "/work/watchtower.db" {
		t.Fatalf("stores opened = %v; want one for the launch's database", opened)
	}
	mu.Unlock()

	reap(t, info.Pid)
	deadline = time.Now().Add(ioTimeout)
	for {
		store.mu.Lock()
		closed := store.closed
		store.mu.Unlock()
		if closed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the store was not closed after the session ended")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Only a launch whose Watch names a rollout-watched agent and a database is
// watched; the hello says the host watches, so the app's bridge leaves its
// sessions alone.
func TestCodexWatch_OnlyCodexLaunchesWithADatabase(t *testing.T) {
	var opened int
	var mu sync.Mutex
	path, _ := startHost(t, Options{CodexWatch: func(string) (CodexWatchStore, error) {
		mu.Lock()
		opened++
		mu.Unlock()
		return &fakeWatchStore{}, nil
	}})
	c := dialRaw(t, path)
	c.send(Hello, HelloMsg{Version: ProtocolVersion})
	var hello HelloMsg
	if err := json.Unmarshal(c.expect(HelloOK), &hello); err != nil {
		t.Fatal(err)
	}
	if !hello.CodexWatch {
		t.Fatal("hello does not say the host watches codex rollouts")
	}
	c.launchAgent(1, "codex", "sleep 30") // no Watch
	for i, w := range []*WatchSpec{{Agent: "claude", Database: "/work/watchtower.db"}, {Agent: "codex"}} {
		ci := dial(t, path)
		ci.send(Launch, LaunchReq{Row: int64(i + 2), Run: "r1", Executable: "/bin/sh", Args: []string{"-c", "sleep 30"},
			Cwd: os.TempDir(), Cols: 80, Rows: 24, Watch: w})
		var info SessionInfo
		if err := json.Unmarshal(ci.expect(Launched), &info); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { reap(t, info.Pid) })
	}
	time.Sleep(50 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if opened != 0 {
		t.Fatalf("%d stores opened; want none", opened)
	}
}
