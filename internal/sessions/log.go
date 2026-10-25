package sessions

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
)

// SessionEvent records a single session acquire/release cycle.
type SessionEvent struct {
	Timestamp  string `json:"ts"`
	SessionID  string `json:"session_id"`
	Action     string `json:"action"`      // "created" or "reused"
	Source     string `json:"source"`      // caller label (e.g. "digest.channel", "analysis.user")
	DurationMS int64  `json:"duration_ms"` // how long the session was held
}

// MaxLogSize is the size past which the session log is renamed to
// "<path>.1" (replacing the previous copy) before the next append, the cap
// the other workspace logs have. A var so tests can shrink it.
var MaxLogSize int64 = 20 << 20

// SessionLog appends structured events to a JSON-lines file.
type SessionLog struct {
	path string
	mu   sync.Mutex
}

// NewSessionLog creates a logger that writes to the given file path.
func NewSessionLog(path string) *SessionLog {
	return &SessionLog{path: path}
}

// Log appends a session event to the log file.
func (sl *SessionLog) Log(event SessionEvent) {
	sl.mu.Lock()
	defer sl.mu.Unlock()

	data, err := json.Marshal(event)
	if err != nil {
		return
	}

	// Best effort, like the append itself: a failed rename keeps appending.
	// Not coordinated across processes: two writers past the cap may both
	// rename, and the second rename then replaces sessions.log.1.
	if info, err := os.Stat(sl.path); err == nil && info.Size() > MaxLogSize {
		_ = os.Rename(sl.path, sl.path+".1")
	}

	f, err := os.OpenFile(sl.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer f.Close()

	fmt.Fprintf(f, "%s\n", data)
}
