package hub

import (
	"context"
	"testing"

	"watchtower/internal/db"
)

// A session being deleted (delete_requested_at, #1716) leaves the state
// lane's facts as if it were gone, so the phone's slices republish without it.
func TestSessionFacts_LeaveOutDeletingRow(t *testing.T) {
	d := db.OpenTestDB(t)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := d.Exec(q, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`INSERT INTO projects(id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')`)
	exec(`INSERT INTO terminal_sessions(id, project_id, kind, title, folder_path, claude_session_id) VALUES (7, 1, 'claude', 't', '/tmp/acme', 'sid-7')`)
	exec(`INSERT INTO terminal_sessions(id, project_id, kind, title, folder_path, claude_session_id) VALUES (8, 1, 'claude', 't', '/tmp/acme', 'sid-8')`)
	exec(`UPDATE terminal_sessions SET delete_requested_at = '2026-11-10T12:00:00Z' WHERE id = 8`)
	facts, err := readSessionFacts(context.Background(), d.DB)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := facts[7]; !ok || len(facts) != 1 {
		t.Fatalf("facts = %v, want only session 7", facts)
	}
}
