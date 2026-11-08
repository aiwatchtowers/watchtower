package db

import (
	"database/sql"
	"testing"
	"time"
)

// seedCodexWatchRow is a codex (or kind) row of a new workbench reading state.
func seedCodexWatchRow(t *testing.T, d *DB, kind, state string) (row, wb int64) {
	t.Helper()
	wb, err := d.CreateWorkbench("acme-watch-"+kind+"-"+state, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var st any
	if state != "" {
		st = state
	}
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, agent_state, agent_state_at)
		VALUES (?, ?, 'Watch', '/work', 'sid', ?, '2026-11-05T10:00:00.000Z')`, wb, kind, st)
	if err != nil {
		t.Fatal(err)
	}
	row, err = res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return row, wb
}

// testWatchKinds is the production sessionagent.RolloutWatchKinds() (the
// db package cannot import it; cmd's TestProj11_WatchKindsArePulledKinds
// pins the two together).
var testWatchKinds = []string{"codex"}

// seenRow is row as the watch reads it before a give-up.
func seenRow(t *testing.T, d *DB, row int64) CodexWatchRow {
	t.Helper()
	r, err := d.GetCodexWatchRow(row)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func watchIssueOf(t *testing.T, d *DB, row int64) (issue, at sql.NullString) {
	t.Helper()
	if err := d.QueryRow(`SELECT agent_watch_issue, agent_watch_issue_at FROM terminal_sessions WHERE id = ?`, row).
		Scan(&issue, &at); err != nil {
		t.Fatal(err)
	}
	return issue, at
}

func TestMigration00175_AddsNullableColumns(t *testing.T) {
	d := openTestDB(t)
	row, _ := seedCodexWatchRow(t, d, "codex", "working")
	issue, at := watchIssueOf(t, d, row)
	if issue.Valid || at.Valid {
		t.Fatalf("a new row reads issue %v at %v; want both NULL", issue, at)
	}
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_watch_issue = 'bogus' WHERE id = ?`, row); err == nil {
		t.Fatal("agent_watch_issue took a value outside missing/permission/compressed/unreadable")
	}
	if err := gooseDownTo(d.DB, "migrations", 174); err != nil {
		t.Fatal(err)
	}
	ok, err := d.HasColumns("terminal_sessions", "agent_watch_issue")
	if err != nil || ok {
		t.Fatalf("after Down agent_watch_issue present = %v (%v); want gone", ok, err)
	}
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM terminal_sessions WHERE id = ?`, row).Scan(&n); err != nil || n != 1 {
		t.Fatalf("the row after Down: %d, %v; want kept", n, err)
	}
}

// The kinds a mark may land on are the caller's (the db package names no
// agent): a row of a listed kind takes it, an empty list takes nothing.
func TestProj11_WatchIssueKindsAreTheCallers(t *testing.T) {
	d := openTestDB(t)
	row, _ := seedCodexWatchRow(t, d, "claude", "working")
	if ok, err := d.SetAgentWatchIssue(seenRow(t, d, row), "missing", time.Now(), nil); err != nil || ok {
		t.Fatalf("no kinds: %v, %v; want false", ok, err)
	}
	if ok, err := d.SetAgentWatchIssue(seenRow(t, d, row), "missing", time.Now(), []string{"codex", "claude"}); err != nil || !ok {
		t.Fatalf("a listed kind: %v, %v; want true", ok, err)
	}
}

func TestProj11_WatchIssueOnlyOverWorkingCodexRow(t *testing.T) {
	d := openTestDB(t)
	at := time.Date(2026, 11, 5, 10, 0, 30, 0, time.UTC)
	for _, c := range []struct {
		kind, state string
		want        bool
	}{
		{"codex", "working", true},
		{"codex", "waiting", false},
		{"codex", "approval", false},
		{"codex", "", false},
		{"claude", "working", false},
	} {
		row, _ := seedCodexWatchRow(t, d, c.kind, c.state)
		ok, err := d.SetAgentWatchIssue(seenRow(t, d, row), "missing", at, testWatchKinds)
		if err != nil {
			t.Fatal(err)
		}
		if ok != c.want {
			t.Errorf("%s/%q: SetAgentWatchIssue = %v; want %v", c.kind, c.state, ok, c.want)
		}
		issue, stamp := watchIssueOf(t, d, row)
		if c.want && (issue.String != "missing" || stamp.String != AgentStateStamp(at)) {
			t.Errorf("%s/%q: stored %v at %v", c.kind, c.state, issue, stamp)
		}
		if !c.want && issue.Valid {
			t.Errorf("%s/%q: stored %v; want none", c.kind, c.state, issue)
		}
	}

	row, _ := seedCodexWatchRow(t, d, "codex", "working")
	if _, err := d.Exec(`UPDATE terminal_sessions SET finished_at = '2026-11-05T10:00:01.000Z' WHERE id = ?`, row); err != nil {
		t.Fatal(err)
	}
	if ok, _ := d.SetAgentWatchIssue(seenRow(t, d, row), "missing", at, testWatchKinds); ok {
		t.Error("a finished row took a watch issue")
	}

	row, _ = seedCodexWatchRow(t, d, "codex", "working")
	if ok, _ := d.SetAgentWatchIssue(seenRow(t, d, row), "permission", at, testWatchKinds); !ok {
		t.Fatal("first issue not written")
	}
	if ok, _ := d.SetAgentWatchIssue(seenRow(t, d, row), "permission", at.Add(time.Second), testWatchKinds); ok {
		t.Error("the same issue again wrote: one log line per row and issue needs a false repeat")
	}
	if _, err := d.SetAgentWatchIssue(seenRow(t, d, row), "bogus", at, testWatchKinds); err == nil {
		t.Error("an unknown issue class was accepted")
	}
}

func TestProj11_FailureWinsOverWatchIssue(t *testing.T) {
	d := openTestDB(t)
	row, _ := seedCodexWatchRow(t, d, "codex", "working")
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_failed_at = agent_state_at, agent_error = 'overloaded' WHERE id = ?`, row); err != nil {
		t.Fatal(err)
	}
	if ok, _ := d.SetAgentWatchIssue(seenRow(t, d, row), "unreadable", time.Now(), testWatchKinds); ok {
		t.Fatal("a row carrying a failure took a watch issue")
	}
}

func TestClearAgentWatchIssue(t *testing.T) {
	d := openTestDB(t)
	row, _ := seedCodexWatchRow(t, d, "codex", "working")
	if ok, _ := d.SetAgentWatchIssue(seenRow(t, d, row), "compressed", time.Now(), testWatchKinds); !ok {
		t.Fatal("not set")
	}
	ok, err := d.ClearAgentWatchIssue(row)
	if err != nil || !ok {
		t.Fatalf("ClearAgentWatchIssue = %v, %v; want true", ok, err)
	}
	if issue, at := watchIssueOf(t, d, row); issue.Valid || at.Valid {
		t.Fatalf("after clear: %v at %v", issue, at)
	}
	if ok, _ := d.ClearAgentWatchIssue(row); ok {
		t.Fatal("clearing nothing reported a change")
	}
}

// A verdict read off one snapshot never lands on another (spec §3.5's
// re-arm): a new session id, a new transcript path or a new state stamp
// between the watch's read and its write holds the write back.
func TestProj11_WatchIssueRefusedOnAChangedSnapshot(t *testing.T) {
	d := openTestDB(t)
	for _, change := range []string{
		`claude_session_id = 'sid-2'`,
		`agent_transcript_path = '/work/rollout-2.jsonl'`,
		`agent_state_at = '2026-11-05T10:00:05.000Z'`,
	} {
		row, _ := seedCodexWatchRow(t, d, "codex", "working")
		seen := seenRow(t, d, row)
		if _, err := d.Exec(`UPDATE terminal_sessions SET `+change+` WHERE id = ?`, row); err != nil {
			t.Fatal(err)
		}
		if ok, err := d.SetAgentWatchIssue(seen, "missing", time.Now(), testWatchKinds); err != nil || ok {
			t.Errorf("after %s: SetAgentWatchIssue = %v, %v; want false", change, ok, err)
		}
		if ok, _ := d.SetAgentWatchIssue(seenRow(t, d, row), "missing", time.Now(), testWatchKinds); !ok {
			t.Errorf("after %s: the fresh snapshot's verdict was refused", change)
		}
	}
}
