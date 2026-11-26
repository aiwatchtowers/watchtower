package sessioncleanup

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"watchtower/internal/db"
)

// storeFixture is a database with one workbench and one claude session of
// it, created at 2026-10-12T09:30:00Z.
func storeFixture(t *testing.T) (DBStore, int64, int64) {
	t.Helper()
	d := db.OpenTestDB(t)
	wb, err := d.CreateWorkbench("acme", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, created_at)
		VALUES (?, 'claude', 'one', '/tmp/example', 'c1', '2026-10-12T09:30:00Z')`, wb)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return DBStore{DB: d}, wb, id
}

func TestDBStore_CleanupSessionReadsWorkbenchAndStart(t *testing.T) {
	s, wb, id := storeFixture(t)
	got, err := s.CleanupSession(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	want := SessionInfo{ID: id, WorkbenchID: wb, CreatedAt: time.Date(2026, 10, 12, 9, 30, 0, 0, time.UTC)}
	if got.ID != want.ID || got.WorkbenchID != want.WorkbenchID || !got.CreatedAt.Equal(want.CreatedAt) {
		t.Fatalf("CleanupSession = %+v, want %+v", got, want)
	}
	if _, err := s.CleanupSession(context.Background(), id+100); !errors.Is(err, db.ErrTerminalSessionNotFound) {
		t.Fatalf("missing session = %v, want ErrTerminalSessionNotFound", err)
	}
}

// A row being deleted carries its delete_requested_at as Ended: when its
// terminal had ended (auto cleanup spec 2026-11-10 §2a); none, or one that
// does not parse, bounds nothing.
func TestDBStore_CleanupSessionReadsEnded(t *testing.T) {
	s, _, id := storeFixture(t)
	got, err := s.CleanupSession(context.Background(), id)
	if err != nil || !got.Ended.IsZero() {
		t.Fatalf("CleanupSession = %+v, %v; want no Ended", got, err)
	}
	for stamp, want := range map[string]time.Time{
		"2026-10-12T10:00:00Z": time.Date(2026, 10, 12, 10, 0, 0, 0, time.UTC),
		"yesterday":            {},
	} {
		if _, err := s.DB.Exec(`UPDATE terminal_sessions SET delete_requested_at = ? WHERE id = ?`, stamp, id); err != nil {
			t.Fatal(err)
		}
		got, err := s.CleanupSession(context.Background(), id)
		if err != nil || !got.Ended.Equal(want) {
			t.Fatalf("delete_requested_at %q: Ended = %v, %v; want %v", stamp, got.Ended, err, want)
		}
	}
}

// An unparsable created_at fails the read (and so the plan, which keeps
// everything): it never becomes a zero start that makes everything young.
func TestDBStore_UnparsableStartIsAnError(t *testing.T) {
	s, _, id := storeFixture(t)
	if _, err := s.DB.Exec(`UPDATE terminal_sessions SET created_at = 'yesterday' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	if got, err := s.CleanupSession(context.Background(), id); err == nil {
		t.Fatalf("CleanupSession = %+v, want an error", got)
	}
}

func TestDBStore_StandaloneSessionIsRefused(t *testing.T) {
	s, _, _ := storeFixture(t)
	res, err := s.DB.Exec(`INSERT INTO terminal_sessions (kind, title, folder_path) VALUES ('shell', 'sh', '/tmp/example')`)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	if got, err := s.CleanupSession(context.Background(), id); !errors.Is(err, ErrStandaloneSession) {
		t.Fatalf("standalone session = %+v, %v; want ErrStandaloneSession", got, err)
	}
}

func TestDBStore_AllSessionActivityCarriesTheAgentCwd(t *testing.T) {
	s, wb, id := storeFixture(t)
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	if _, err := s.DB.Exec(`UPDATE terminal_sessions SET agent_cwd = '/tmp/example/wt', agent_cwd_at = '2026-10-12T12:00:00.000Z',
		agent_state_at = '2026-10-12T12:00:00.000Z', last_active_at = 'garbage' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	got, err := s.AllSessionActivity(context.Background())
	if err != nil || len(got) != 1 {
		t.Fatalf("AllSessionActivity = %+v, %v; want one row", got, err)
	}
	a := got[0]
	if a.ID != id || a.WorkbenchID != wb || a.AgentCwd != "/tmp/example/wt" || a.Finished {
		t.Fatalf("activity = %+v", a)
	}
	if !a.ReportedAt.Equal(time.Date(2026, 10, 12, 12, 0, 0, 0, time.UTC)) {
		t.Fatalf("ReportedAt = %v", a.ReportedAt)
	}
	// An unreadable stamp reads as now: the session counts as active.
	if !a.LastActive.Equal(now) {
		t.Fatalf("unreadable last_active_at = %v, want now", a.LastActive)
	}
}

// addFolderRow adds a folder row to workbench wb; removed marks it as
// having left the bench.
func addFolderRow(t *testing.T, s DBStore, wb int64, path string, position int, removed bool) int64 {
	t.Helper()
	var removedAt any
	if removed {
		removedAt = "2026-11-18T10:00:00Z"
	}
	res, err := s.DB.Exec(`INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, removed_at, name)
		VALUES (?, ?, ?, 'owner', ?, ?)`, wb, path, position, removedAt, filepath.Base(path))
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return id
}

// TestProj18_StoreCoversEveryFolder: WorkbenchFolders is every folder of
// every bench, the removed ones included; BenchFolders is the bench's live
// folders, home first; a session carries the folder it was started for and
// whether that folder left the bench (#2003).
func TestProj18_StoreCoversEveryFolder(t *testing.T) {
	s, wb, id := storeFixture(t)
	ctx := context.Background()
	home, err := s.WorkbenchFolder(ctx, wb)
	if err != nil {
		t.Fatal(err)
	}
	hub := addFolderRow(t, s, wb, "/tmp/example/hub", 1, false)
	gone := addFolderRow(t, s, wb, "/tmp/example/gone", 2, true)
	_, err = s.DB.CreateWorkbench("other", "/tmp/example/other")
	if err != nil {
		t.Fatal(err)
	}

	all, err := s.WorkbenchFolders(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{home, "/tmp/example/hub", "/tmp/example/gone", "/tmp/example/other"} {
		if !slices.Contains(all, want) {
			t.Fatalf("WorkbenchFolders = %v, missing %s", all, want)
		}
	}
	bench, err := s.BenchFolders(ctx, wb)
	if err != nil || !slices.Equal(bench, []string{home, "/tmp/example/hub"}) {
		t.Fatalf("BenchFolders = %v, %v; want [%s /tmp/example/hub]", bench, err, home)
	}

	for _, c := range []struct {
		folder  any
		path    string
		removed bool
	}{{nil, "", false}, {hub, "/tmp/example/hub", false}, {gone, "/tmp/example/gone", true}} {
		if _, err := s.DB.Exec(`UPDATE terminal_sessions SET workbench_folder_id = ? WHERE id = ?`, c.folder, id); err != nil {
			t.Fatal(err)
		}
		got, err := s.CleanupSession(ctx, id)
		if err != nil || got.Folder != c.path || got.FolderRemoved != c.removed {
			t.Fatalf("folder %v: CleanupSession = %+v, %v; want %q removed=%v", c.folder, got, err, c.path, c.removed)
		}
	}
}

func TestDBStore_NeverReportedIsZero(t *testing.T) {
	s, _, _ := storeFixture(t)
	got, err := s.AllSessionActivity(context.Background())
	if err != nil || len(got) != 1 {
		t.Fatalf("AllSessionActivity = %+v, %v", got, err)
	}
	if !got[0].ReportedAt.IsZero() || got[0].AgentCwd != "" {
		t.Fatalf("a session that never reported = %+v", got[0])
	}
}

// TestDBStore_AllSessionActivityReadsWholeSecondAgentState: an
// agent_state_at in whole seconds reads as that time, not as "now" (which
// would keep a quiet session's work and skip it every pass).
func TestDBStore_AllSessionActivityReadsWholeSecondAgentState(t *testing.T) {
	s, _, id := storeFixture(t)
	now := time.Date(2026, 10, 13, 8, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	if _, err := s.DB.Exec(`UPDATE terminal_sessions SET agent_state_at = '2026-10-10T12:00:00Z' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	got, err := s.AllSessionActivity(context.Background())
	if err != nil || len(got) != 1 || !got[0].ReportedAt.Equal(time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)) {
		t.Fatalf("got %+v, %v", got, err)
	}
}

// TestDBStore_SessionActivityOf reads one session by id with the same stamp
// rule as AllSessionActivity; a missing row is reported as absent.
func TestDBStore_SessionActivityOf(t *testing.T) {
	s, _, id := storeFixture(t)
	if _, err := s.DB.Exec(`UPDATE terminal_sessions SET agent_state_at = '2026-10-10T12:00:00Z' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	all, err := s.AllSessionActivity(context.Background())
	if err != nil || len(all) != 1 {
		t.Fatalf("all %+v, %v", all, err)
	}
	got, ok, err := s.SessionActivityOf(context.Background(), id)
	if err != nil || !ok || got != all[0] {
		t.Fatalf("got %+v, %v, %v; want %+v", got, ok, err, all[0])
	}
	if _, ok, err := s.SessionActivityOf(context.Background(), id+100); ok || err != nil {
		t.Fatalf("missing row: ok %v, err %v", ok, err)
	}
}

// TestDBWorkbenches_ListsEveryWorkbench: the repository pass covers the
// folders of every workbench.
func TestDBWorkbenches_ListsEveryWorkbench(t *testing.T) {
	s, wb, _ := storeFixture(t)
	other, err := s.DB.CreateWorkbench("other", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ids, err := DBWorkbenches(s.DB)(context.Background())
	if err != nil || !slices.Equal(ids, []int64{wb, other}) {
		t.Fatalf("ids %v, err %v", ids, err)
	}
}
