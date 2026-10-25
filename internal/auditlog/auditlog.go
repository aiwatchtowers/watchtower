// Package auditlog writes one content-free line per company-data read to the
// macOS unified log (subsystem com.watchtower.audit, category read), so a
// company's EDR or MDM collects it on its own; Watchtower sends nothing
// anywhere (READ-02, docs/superpowers/specs/2026-10-25-bulk-read-limits-design.md
// §3). Off darwin the sink does nothing.
//
// A line names the tool, the surface, the session and the counts — never an
// argument value, message text, subject, name, email, Slack/Jira id or path.
package auditlog

import (
	"encoding/json"
	"sync"
	"sync/atomic"
)

// Result values of Event.Result.
const (
	ResultOK           = "ok"
	ResultLimitReached = "limit_reached"
	ResultTooLarge     = "too_large"
	ResultError        = "error"
)

// Event is one audited read. Filters holds the names of the arguments that
// were set, never their values.
type Event struct {
	Proc      string   `json:"proc"`
	Surface   string   `json:"surface"`
	Session   string   `json:"session"`
	Workbench int64    `json:"workbench,omitempty"`
	Agent     string   `json:"agent,omitempty"`
	Tool      string   `json:"tool"`
	Filters   []string `json:"filters"`
	Rows      int      `json:"rows"`
	Bytes     int      `json:"bytes"`
	Calls     int      `json:"calls"`
	RowsTotal int      `json:"rows_total"`
	Result    string   `json:"result"`
}

// wire puts the format version first; the embedded Event's keys follow in
// its field order (the pinned order).
type wire struct {
	V int `json:"v"`
	Event
}

// process is the role SetProcess recorded; an Event with no Proc takes it.
var process atomic.Pointer[string]

// SetProcess records this process's role ("daemon", "mcp", "cli:<path>"),
// once at start-up.
func SetProcess(proc string) { process.Store(&proc) }

var (
	sinkMu sync.RWMutex
	sink   = osLog
)

// Line is e as one-line JSON in the pinned key order, starting `{"v":1,`,
// without a trailing newline. A nil Filters is written as [].
func Line(e Event) string {
	if e.Filters == nil {
		e.Filters = []string{}
	}
	b, err := json.Marshal(wire{V: 1, Event: e})
	if err != nil {
		// Only strings and ints: Marshal cannot fail. Keep the line valid.
		return `{"v":1,"result":"error"}`
	}
	return string(b)
}

// Read writes e's line to the unified log. It never fails and never waits on
// anything but the system logger.
func Read(e Event) {
	if e.Proc == "" {
		if p := process.Load(); p != nil {
			e.Proc = *p
		}
	}
	line := Line(e)
	sinkMu.RLock()
	f := sink
	sinkMu.RUnlock()
	f(line)
}

// SetSinkForTest replaces the unified-log sink and returns the restore.
func SetSinkForTest(f func(string)) (restore func()) {
	sinkMu.Lock()
	prev := sink
	sink = f
	sinkMu.Unlock()
	return func() {
		sinkMu.Lock()
		sink = prev
		sinkMu.Unlock()
	}
}
