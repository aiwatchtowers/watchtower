package sessionfeed

import (
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/rollout"
)

// codexTurnTailBytes is how much of a rollout's end CodexLastTurn reads: a
// failed turn ends the file with its task_complete, so the tail holds it; a
// turn whose last lifecycle event is further back is still running, which
// reads as not failed.
const codexTurnTailBytes = 256 << 10

// CodexTurn is how the last turn of a Codex rollout ended.
type CodexTurn struct {
	// Failed: the last turn lifecycle event is a task_complete carrying an
	// error (Codex has no StopFailure hook, and its Stop does not fire on a
	// failed turn: board #959).
	Failed bool
	// Aborted: the last turn lifecycle event is a turn_aborted (the owner's
	// Esc): the pull twin of the Interrupt hook.
	Aborted bool
	// Error is the failure's codex_error_info: the string, or the key of an
	// object form; "" when unreadable.
	Error string
	// At is the failed task_complete's or the turn_aborted's timestamp;
	// zero when unreadable.
	At time.Time
	// TailUndecodable: the last committed line is not JSON. An unterminated
	// last line is never counted: codex is still writing it.
	TailUndecodable bool
}

// WatchIssueError is a rollout CodexLastTurn could not read, by class
// (db.WatchIssue*): missing (no file), permission (EACCES/EPERM), compressed
// (a zstd rollout that does not decode or is over the cap) or unreadable
// (any other read failure). Error() names the class only, never the path
// (FILES-01); Unwrap gives the cause.
type WatchIssueError struct {
	Issue string
	Err   error
}

func (e *WatchIssueError) Error() string { return "codex rollout " + e.Issue }
func (e *WatchIssueError) Unwrap() error { return e.Err }

// CodexLastTurn reads the end of the Codex rollout at path and reports how
// its last turn (the last task_started, task_complete or turn_aborted event)
// ended, plain or zstd-compressed. A running or finished rollout is neither
// failed nor aborted. A read failure (a corrupt frame included) is a
// *WatchIssueError naming its class.
func CodexLastTurn(path string) (CodexTurn, error) {
	// readTail decompresses a zstd rollout in memory (internal/rollout), so a
	// compressed rollout's failed turn is seen like a plain one's.
	tail, err := readTail(path, codexTurnTailBytes)
	if err != nil {
		return CodexTurn{}, &WatchIssueError{Issue: watchIssueOf(path, err), Err: err}
	}
	// Only newline-terminated records are committed to a rollout.
	if last := bytes.LastIndexByte(tail, '\n'); last >= 0 {
		tail = tail[:last]
	} else {
		tail = nil
	}
	var turn CodexTurn
	lines := bytes.Split(tail, []byte{'\n'})
	for _, line := range lines {
		var l codexLine
		if json.Unmarshal(line, &l) != nil || l.Type != "event_msg" {
			continue
		}
		var ev struct {
			Type  string          `json:"type"`
			Error json.RawMessage `json:"error"`
		}
		if json.Unmarshal(l.Payload, &ev) != nil {
			continue
		}
		switch ev.Type {
		case "task_started":
			turn = CodexTurn{}
		case "turn_aborted":
			turn = CodexTurn{Aborted: true, At: stampOf(l.Timestamp)}
		case "task_complete":
			turn = failedCodexTurn(l.Timestamp, ev.Error)
		}
	}
	if last := lines[len(lines)-1]; len(tail) > 0 && !json.Valid(last) {
		turn.TailUndecodable = true
	}
	return turn, nil
}

// watchIssueOf classes a read failure of the rollout at path.
func watchIssueOf(path string, err error) string {
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return db.WatchIssueMissing
	case errors.Is(err, fs.ErrPermission):
		return db.WatchIssuePermission
	}
	if z, zerr := rollout.Compressed(path); zerr == nil && z {
		return db.WatchIssueCompressed
	}
	return db.WatchIssueUnreadable
}

// stampOf parses a rollout line's timestamp; zero when it does not parse.
func stampOf(timestamp string) time.Time {
	if at, err := time.Parse(time.RFC3339Nano, timestamp); err == nil {
		return at.UTC()
	}
	return time.Time{}
}

// failedCodexTurn is a task_complete's outcome: failed when it carries a
// non-null error.
func failedCodexTurn(timestamp string, raw json.RawMessage) CodexTurn {
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return CodexTurn{}
	}
	turn := CodexTurn{Failed: true}
	var e struct {
		Info json.RawMessage `json:"codex_error_info"`
	}
	if json.Unmarshal(raw, &e) == nil {
		turn.Error = codexErrorType(e.Info)
	}
	turn.At = stampOf(timestamp)
	return turn
}

// codexErrorType is codex_error_info as one word: the string, or the only
// key of the object form; "" otherwise.
func codexErrorType(info json.RawMessage) string {
	var s string
	if json.Unmarshal(info, &s) == nil {
		return s
	}
	var m map[string]json.RawMessage
	if json.Unmarshal(info, &m) == nil && len(m) == 1 {
		for k := range m {
			return k
		}
	}
	return ""
}
