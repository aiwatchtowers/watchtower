package db

import (
	"database/sql"
	"errors"
	"testing"
	"time"
)

// codexOtherUUID is a second placeholder Codex session id.
const codexOtherUUID = "01890a5d-ac96-7a3b-8c4d-000000000001"

// agentWrite is one guarded write of an agent row, reduced to "did it
// write": id, workbench and the session id the hook reported.
type agentWrite func(d *DB, id, workbench int64, sessionID string, at time.Time) (bool, error)

func writeState(d *DB, id, wb int64, sid string, at time.Time) (bool, error) {
	return d.SetTerminalAgentState(id, wb, sid, "working", at, "", nil, true, AgentOrder{})
}

func writeRunMark(d *DB, id, wb int64, sid string, at time.Time) (bool, error) {
	return d.MarkTerminalAgentRun(id, wb, sid, at)
}

func writeClearState(d *DB, id, wb int64, sid string, _ time.Time) (bool, error) {
	return d.ClearTerminalAgentState(id, wb, sid)
}

func writeLowerBackground(d *DB, id, wb int64, sid string, at time.Time) (bool, error) {
	one := int64(1)
	return d.LowerTerminalBackground(id, wb, sid, at, &one)
}

func writeEndBackground(d *DB, id, wb int64, sid string, at time.Time) (bool, error) {
	return d.EndTerminalBackground(id, wb, sid, AgentStateStamp(at.Add(-time.Minute)))
}

func writeTurnEnd(d *DB, id, wb int64, sid string, _ time.Time) (bool, error) {
	return d.SetTerminalTurnEnd(id, wb, sid, 4096)
}

func writeAgentTurn(d *DB, id, wb int64, sid string, at time.Time) (bool, error) {
	turns, err := d.RecordTerminalAgentTurn(id, wb, sid, "agent-1", true, at)
	return turns != nil, err
}

func writeChatQuestion(d *DB, id, wb int64, sid string, at time.Time) (bool, error) {
	err := d.SetChatQuestion(id, wb, sid, sampleChatQuestion("Which DB?"), at)
	if errors.Is(err, ErrChatQuestionNotRecorded) {
		return false, nil
	}
	return err == nil, err
}

func writeClearChatQuestion(d *DB, id, wb int64, sid string, at time.Time) (bool, error) {
	if err := d.ClearChatQuestionBefore(id, wb, sid, at); err != nil {
		return false, err
	}
	var q sql.NullString
	err := d.QueryRow(`SELECT chat_question FROM terminal_sessions WHERE id = ?`, id).Scan(&q)
	return !q.Valid, err
}

func writeTranscriptPath(d *DB, id, wb int64, sid string, _ time.Time) (bool, error) {
	return d.SetTerminalTranscriptPath(id, wb, sid, "/Users/example/.codex/sessions/rollout.jsonl")
}

func writeMoveID(d *DB, id, wb int64, sid string, _ time.Time) (bool, error) {
	// The switch path moves the id: "another id" is its normal input, so
	// here the reported id is the new one and the guard is the workbench.
	return d.SetTerminalClaudeSessionID(id, wb, sid+"-moved")
}

// seedCountedWaiting puts row id in a counted `waiting` stamped a minute ago
// with a chat question, so every write has something to change.
func seedCountedWaiting(t *testing.T, d *DB, id int64, now time.Time) {
	t.Helper()
	earlier := AgentStateStamp(now.Add(-time.Minute))
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ?,
		agent_background = 2, agent_background_at = ?, chat_question = '{"question":"Q","options":[]}',
		chat_question_at = ? WHERE id = ?`, earlier, earlier, earlier, id); err != nil {
		t.Fatal(err)
	}
}

var guardedAgentWrites = []struct {
	name  string
	write agentWrite
}{
	{"SetTerminalAgentState", writeState},
	{"MarkTerminalAgentRun", writeRunMark},
	{"ClearTerminalAgentState", writeClearState},
	{"LowerTerminalBackground", writeLowerBackground},
	{"EndTerminalBackground", writeEndBackground},
	{"SetTerminalTurnEnd", writeTurnEnd},
	{"RecordTerminalAgentTurn", writeAgentTurn},
	{"SetChatQuestion", writeChatQuestion},
	{"ClearChatQuestionBefore", writeClearChatQuestion},
	{"SetTerminalTranscriptPath", writeTranscriptPath},
}

// PROJ-11 / spec I6: a codex row with a NULL id accepts no hook write but
// its first SessionStart, whatever session id the hook reports.
func TestProj11_CodexNullIDIgnoresStateWrites(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	now := time.Now().UTC().Truncate(time.Millisecond)
	id := newAgentStateRow(t, d, pid, "codex", nil)
	seedCountedWaiting(t, d, id, now)
	before := terminalRowSnapshot(t, d, id)
	for _, w := range guardedAgentWrites {
		for _, sid := range []string{codexTestUUID, ""} {
			written, err := w.write(d, id, pid, sid, now)
			if err != nil {
				t.Fatalf("%s(%q): %v", w.name, sid, err)
			}
			if written {
				t.Fatalf("%s(%q) wrote on a NULL-id codex row", w.name, sid)
			}
			if after := terminalRowSnapshot(t, d, id); after != before {
				t.Fatalf("%s(%q) changed the row\nbefore %s\nafter  %s", w.name, sid, before, after)
			}
		}
	}
}

// TestAgentGuardsAcceptCodex: every guarded write lands on a codex row that
// runs the reported id, and on none of another id or another workbench.
func TestAgentGuardsAcceptCodex(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	now := time.Now().UTC().Truncate(time.Millisecond)
	for _, w := range append(guardedAgentWrites, struct {
		name  string
		write agentWrite
	}{"SetTerminalClaudeSessionID", writeMoveID}) {
		id := newAgentStateRow(t, d, pid, "codex", codexTestUUID)
		seedCountedWaiting(t, d, id, now)
		before := terminalRowSnapshot(t, d, id)
		requireRefused(t, d, w.name+" from another workbench", w.write, id, other, codexTestUUID, now, before)
		if w.name != "SetTerminalClaudeSessionID" {
			requireRefused(t, d, w.name+" of another id", w.write, id, pid, codexOtherUUID, now, before)
		}
		if written, err := w.write(d, id, pid, codexTestUUID, now); err != nil || !written {
			t.Fatalf("%s on its own codex row: written=%v err=%v", w.name, written, err)
		}
	}
}

func requireRefused(t *testing.T, d *DB, name string, w agentWrite, id, wb int64, sid string, at time.Time, before string) {
	t.Helper()
	written, err := w(d, id, wb, sid, at)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	after := terminalRowSnapshot(t, d, id)
	if after != before {
		t.Fatalf("%s changed the row\nbefore %s\nafter  %s", name, before, after)
	}
	if written {
		t.Fatalf("%s wrote", name)
	}
}

func TestTakeChatQuestionAcceptsCodex(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	asked := time.Now().UTC().Truncate(time.Millisecond)
	id := newAgentStateRow(t, d, pid, "codex", codexTestUUID)
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ? WHERE id = ?`,
		AgentStateStamp(asked), id); err != nil {
		t.Fatal(err)
	}
	if err := d.SetChatQuestion(id, pid, codexTestUUID, sampleChatQuestion("Which DB?"), asked); err != nil {
		t.Fatal(err)
	}
	at := AgentStateStamp(asked)
	err := d.WithTx(func(tx *sql.Tx) error {
		_, err := d.TakeChatQuestion(tx, id, other, at)
		return err
	})
	if !errors.Is(err, ErrNotInWorkbench) {
		t.Fatalf("another workbench: err = %v, want ErrNotInWorkbench", err)
	}
	if q := takeChatQuestionInTx(t, d, id, pid, at); q == nil || q.Question != "Which DB?" {
		t.Fatalf("the codex row's question was not taken: %+v", q)
	}
}

func TestSetTerminalAgentSessionID_OnlyFromNull(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	now := time.Now().UTC().Truncate(time.Millisecond)
	codex := newAgentStateRow(t, d, pid, "codex", nil)
	claude := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	shell := newAgentStateRow(t, d, pid, "shell", nil)
	seedCountedWaiting(t, d, codex, now)
	const path = "/Users/example/.codex/sessions/rollout-a.jsonl"

	for _, tc := range []struct {
		name      string
		id, wb    int64
		sessionID string
	}{
		{"an empty id", codex, pid, ""},
		{"another workbench", codex, other, codexTestUUID},
		{"a claude row", claude, pid, codexTestUUID},
		{"a shell row", shell, pid, codexTestUUID},
		{"no such row", 999, pid, codexTestUUID},
	} {
		if written, err := d.SetTerminalAgentSessionID(tc.id, tc.wb, tc.sessionID, path); err != nil || written {
			t.Fatalf("%s: written=%v err=%v", tc.name, written, err)
		}
	}
	if s := storedSession(t, d, claude); s.ClaudeSessionID.String != agentStateUUID {
		t.Fatalf("a claude row's id moved to %q", s.ClaudeSessionID.String)
	}

	if written, err := d.SetTerminalAgentSessionID(codex, pid, codexTestUUID, path); err != nil || !written {
		t.Fatalf("the first SessionStart: written=%v err=%v", written, err)
	}
	s := storedSession(t, d, codex)
	if s.ClaudeSessionID.String != codexTestUUID || s.TranscriptPath.String != path {
		t.Fatalf("stored id %q path %q", s.ClaudeSessionID.String, s.TranscriptPath.String)
	}
	if s.Background.Valid || s.ChatQuestionAt != "" || s.AgentState.String != "waiting" {
		t.Fatalf("the id write keeps the state and clears the conversation's columns: %+v", s)
	}

	before := terminalRowSnapshot(t, d, codex)
	if written, err := d.SetTerminalAgentSessionID(codex, pid, codexOtherUUID, "/Users/example/b.jsonl"); err != nil || written {
		t.Fatalf("a second id: written=%v err=%v", written, err)
	}
	if after := terminalRowSnapshot(t, d, codex); after != before {
		t.Fatalf("a second id changed the row\nbefore %s\nafter  %s", before, after)
	}
}

func TestSetTerminalAgentSessionID_EmptyPathStoresNull(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	codex := newAgentStateRow(t, d, pid, "codex", nil)
	if written, err := d.SetTerminalAgentSessionID(codex, pid, codexTestUUID, ""); err != nil || !written {
		t.Fatalf("written=%v err=%v", written, err)
	}
	if s := storedSession(t, d, codex); s.TranscriptPath.Valid {
		t.Fatalf("an empty path stored %q", s.TranscriptPath.String)
	}
}

func TestSetTerminalTranscriptPath_WritesOnChangeOnly(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	codex := newAgentStateRow(t, d, pid, "codex", codexTestUUID)
	claude := newAgentStateRow(t, d, pid, "claude", agentStateUUID)
	shell := newAgentStateRow(t, d, pid, "shell", nil)
	const path = "/Users/example/.codex/sessions/rollout-a.jsonl"
	for _, tc := range []struct {
		name string
		id   int64
		sid  string
		path string
		want bool
	}{
		{"an empty path", codex, codexTestUUID, "", false},
		{"a shell row", shell, codexTestUUID, path, false},
		{"its codex row", codex, codexTestUUID, path, true},
		{"the same path", codex, codexTestUUID, path, false},
		{"a claude row", claude, agentStateUUID, path, true},
	} {
		written, err := d.SetTerminalTranscriptPath(tc.id, pid, tc.sid, tc.path)
		if err != nil || written != tc.want {
			t.Fatalf("%s: written=%v err=%v, want %v", tc.name, written, err, tc.want)
		}
	}
	if s := storedSession(t, d, codex); s.TranscriptPath.String != path {
		t.Fatalf("path = %q", s.TranscriptPath.String)
	}
	var stored sql.NullString
	if err := d.QueryRow(`SELECT agent_transcript_path FROM terminal_sessions WHERE id = ?`, claude).Scan(&stored); err != nil ||
		stored.String != path {
		t.Fatalf("claude row path = %q err=%v", stored.String, err)
	}
	if s := storedSession(t, d, claude); s.TranscriptPath.Valid {
		t.Fatal("GetTerminalSession read the path of a claude row (Claude readers keep their own lookup)")
	}
}

// An id move (/clear, a switching resume) drops the old conversation's
// transcript path on either agent kind; the switch's SessionStart stores
// the new one.
func TestSetTerminalClaudeSessionID_ClearsTheTranscriptPath(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	for _, row := range []struct{ kind, uuid string }{{"codex", codexTestUUID}, {"claude", agentStateUUID}} {
		id := newAgentStateRow(t, d, pid, row.kind, row.uuid)
		if _, err := d.Exec(`UPDATE terminal_sessions SET agent_transcript_path = '/Users/example/old.jsonl' WHERE id = ?`, id); err != nil {
			t.Fatal(err)
		}
		if written, err := d.SetTerminalClaudeSessionID(id, pid, codexOtherUUID); err != nil || !written {
			t.Fatalf("%s: written=%v err=%v", row.kind, written, err)
		}
		var path sql.NullString
		var sid string
		if err := d.QueryRow(`SELECT agent_transcript_path, claude_session_id FROM terminal_sessions WHERE id = ?`, id).
			Scan(&path, &sid); err != nil {
			t.Fatal(err)
		}
		if path.Valid || sid != codexOtherUUID {
			t.Fatalf("%s: after the move path=%q id=%q", row.kind, path.String, sid)
		}
	}
}
