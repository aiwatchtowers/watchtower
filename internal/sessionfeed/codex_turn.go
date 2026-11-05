package sessionfeed

import (
	"bytes"
	"encoding/json"
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

type codexTurnEvent struct {
	Type  string          `json:"type"`
	Error json.RawMessage `json:"error"`
}

// CodexLastTurn reads the end of the Codex rollout at path and reports
// whether its last turn (the last task_started, task_complete or
// turn_aborted event) failed. A running, finished, aborted or compressed
// rollout is not failed; only a read failure is an error.
func CodexLastTurn(path string) (CodexTurn, error) {
	f, err := os.Open(path)
	if err != nil {
		return CodexTurn{}, fmt.Errorf("opening the codex rollout: %w", err)
	}
	defer f.Close()
	head := make([]byte, len(zstdMagic))
	if n, _ := io.ReadFull(f, head); n == len(zstdMagic) && bytes.Equal(head, zstdMagic) {
		return CodexTurn{}, nil
	}
	st, err := f.Stat()
	if err != nil {
		return CodexTurn{}, fmt.Errorf("reading the codex rollout: %w", err)
	}
	start := max(st.Size()-codexTurnTailBytes, 0)
	tail := make([]byte, st.Size()-start)
	if _, err := f.ReadAt(tail, start); err != nil && err != io.EOF {
		return CodexTurn{}, fmt.Errorf("reading the codex rollout: %w", err)
	}
	if start > 0 {
		// The first line is cut: skip to the next one.
		if i := bytes.IndexByte(tail, '\n'); i >= 0 {
			tail = tail[i+1:]
		} else {
			tail = nil
		}
	}
	// A line still being written has no newline yet: only complete lines.
	if i := bytes.LastIndexByte(tail, '\n'); i >= 0 {
		tail = tail[:i]
	} else {
		tail = nil
	}
	return lastCodexTurn(tail), nil
}

// lastCodexTurn walks complete lines from the end to the last turn
// lifecycle event.
func lastCodexTurn(lines []byte) CodexTurn {
	for len(lines) > 0 {
		var line []byte
		if i := bytes.LastIndexByte(lines, '\n'); i >= 0 {
			line, lines = lines[i+1:], lines[:i]
		} else {
			line, lines = lines, nil
		}
		var l codexLine
		if json.Unmarshal(line, &l) != nil || l.Type != "event_msg" {
			continue
		}
		var ev codexTurnEvent
		if json.Unmarshal(l.Payload, &ev) != nil {
			continue
		}
		switch ev.Type {
		case "task_started", "turn_aborted":
			return CodexTurn{}
		case "task_complete":
			return failedCodexTurn(l.Timestamp, ev.Error)
		}
	}
	return CodexTurn{}
}

func failedCodexTurn(timestamp string, raw json.RawMessage) CodexTurn {
	var e struct {
		Info json.RawMessage `json:"codex_error_info"`
	}
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return CodexTurn{}
	}
	turn := CodexTurn{Failed: true}
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
