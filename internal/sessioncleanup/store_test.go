package sessioncleanup

import (
	"context"
	"errors"
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
