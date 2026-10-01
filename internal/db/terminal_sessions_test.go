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

func TestSetTerminalClaudeSessionID_OnlyThatProjectsClaudeRow(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	other := newTestProject(t, d)
	insert := func(project any, kind string, uuid any) int64 {
		t.Helper()
		res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
			VALUES (?, ?, 's', '/tmp/acme', ?)`, project, kind, uuid)
		if err != nil {
			t.Fatal(err)
		}
		id, _ := res.LastInsertId()
		return id
	}
	claude := insert(pid, "claude", "old")
	shell := insert(pid, "shell", nil)
	standalone := insert(nil, "claude", "old")
	for _, tc := range []struct {
		name    string
		id      int64
		project int64
		uuid    string
		want    bool
	}{
		{"its own claude row", claude, pid, "new", true},
		{"already current", claude, pid, "new", false},
		{"another project's session", claude, other, "newer", false},
		{"a shell row", shell, pid, "new", false},
		{"a standalone row", standalone, pid, "new", false},
		{"no such row", 999, pid, "new", false},
	} {
		written, err := d.SetTerminalClaudeSessionID(tc.id, tc.project, tc.uuid)
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if written != tc.want {
			t.Fatalf("%s: written=%v, want %v", tc.name, written, tc.want)
		}
	}
	s, err := d.GetTerminalSession(claude)
	if err != nil {
		t.Fatal(err)
	}
	if s.ClaudeSessionID.String != "new" {
		t.Fatalf("claude_session_id = %q, want new", s.ClaudeSessionID.String)
	}
	if s, _ := d.GetTerminalSession(shell); s.ClaudeSessionID.Valid {
		t.Fatal("a shell row gained a claude session id")
	}
}
