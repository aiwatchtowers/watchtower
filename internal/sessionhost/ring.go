package sessionhost

import (
	"bytes"
	"sync"
)

// safePointWindow is how far past the trim point Snapshot looks for a place
// where an escape sequence or a line starts.
const safePointWindow = 4096

// Ring keeps the tail of a terminal output stream. Snapshot starts at an
// escape or a line start so a replay does not begin inside a sequence. The
// backing array may grow to about twice the capacity before it is compacted.
type Ring struct {
	mu      sync.Mutex
	cap     int
	buf     []byte
	trimmed bool // older data was dropped, so buf[0] may sit inside a sequence
}

// NewRing returns a ring that keeps about capacity bytes.
func NewRing(capacity int) *Ring {
	if capacity < 1 {
		capacity = 1
	}
	return &Ring{cap: capacity}
}

// Write appends p, dropping the oldest bytes beyond the capacity.
func (r *Ring) Write(p []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.buf = append(r.buf, p...)
	// Compact lazily so a busy stream does not copy the whole buffer per write.
	if len(r.buf) > 2*r.cap {
		n := copy(r.buf, r.buf[len(r.buf)-r.cap:])
		r.buf = r.buf[:n]
		r.trimmed = true
	}
}

// Snapshot returns a copy of the retained tail, starting at a safe point.
func (r *Ring) Snapshot() []byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	start := 0
	if r.trimmed || len(r.buf) > r.cap {
		start = max(len(r.buf)-r.cap, 0)
		end := min(start+safePointWindow, len(r.buf))
		window := r.buf[start:end]
		esc := bytes.IndexByte(window, 0x1b)
		nl := bytes.IndexByte(window, '\n')
		switch {
		case nl >= 0 && nl+1 < len(r.buf)-start && (esc < 0 || nl+1 < esc):
			start += nl + 1
		case esc >= 0:
			start += esc
		}
	}
	return append([]byte(nil), r.buf[start:]...)
}
