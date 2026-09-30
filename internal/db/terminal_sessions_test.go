package db

import (
	"errors"
	"testing"
)

func TestSetTerminalSessionAITitle_NeverOverwritesUserOrAI(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	for _, src := range []string{"auto", "ai", "user"} {
		res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, title_source, folder_path, claude_session_id)
			VALUES (?, 'claude', 'New session', ?, '/tmp/acme', 'uuid-'||?)`, pid, src, src)
		if err != nil {
			t.Fatal(err)
		}
		id, _ := res.LastInsertId()
		written, err := d.SetTerminalSessionAITitle(id, "Fix login")
		if err != nil {
			t.Fatal(err)
		}
		if want := src == "auto"; written != want {
			t.Fatalf("source %s: written=%v, want %v", src, written, want)
		}
	}
}

func TestGetTerminalSession_NotFound(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.GetTerminalSession(999); !errors.Is(err, ErrTerminalSessionNotFound) {
		t.Fatalf("err = %v", err)
	}
}
