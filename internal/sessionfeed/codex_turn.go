package sessionfeed

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"
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
	// Error is the failure's codex_error_info: the string, or the key of an
	// object form; "" when unreadable.
	Error string
	// At is the failed task_complete line's timestamp; zero when unreadable.
	At time.Time
}

// CodexLastTurn reads the end of the Codex rollout at path and reports
// whether its last turn (the last task_started, task_complete or
// turn_aborted event) failed. A running, finished, aborted or compressed
// rollout is not failed; only a read failure is an error.
func CodexLastTurn(path string) (CodexTurn, error) {
	// The magic is at the file's start, which a long rollout's tail does not hold.
	head, err := readHead(path, len(zstdMagic))
	if err != nil {
		return CodexTurn{}, fmt.Errorf("reading the codex rollout: %w", err)
	}
	if bytes.Equal(head, zstdMagic) {
		return CodexTurn{}, nil
	}
	tail, err := readTail(path, codexTurnTailBytes)
	if err != nil {
		return CodexTurn{}, fmt.Errorf("reading the codex rollout: %w", err)
	}
	// Only newline-terminated records are committed to a rollout.
	if last := bytes.LastIndexByte(tail, '\n'); last >= 0 {
		tail = tail[:last]
	} else {
		tail = nil
	}
	var turn CodexTurn
	for _, line := range bytes.Split(tail, []byte{'\n'}) {
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
		case "task_started", "turn_aborted":
			turn = CodexTurn{}
		case "task_complete":
			turn = failedCodexTurn(l.Timestamp, ev.Error)
		}
	}
	return turn, nil
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
	if at, err := time.Parse(time.RFC3339Nano, timestamp); err == nil {
		turn.At = at.UTC()
	}
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

// readHead returns the first n bytes of path, fewer for a shorter file.
func readHead(path string, n int) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	buf := make([]byte, n)
	m, err := io.ReadFull(f, buf)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return nil, err
	}
	return buf[:m], nil
}
