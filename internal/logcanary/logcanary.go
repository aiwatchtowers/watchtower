// Package logcanary is the FILES-01 test harness: tests seed synced fields
// with canary strings, route every log writer into a Sink, and assert that no
// canary reached it. Test code only; production code never imports it.
package logcanary

import (
	"bytes"
	"log"
	"strings"
	"sync"
	"testing"
)

// Marker starts every canary string.
const Marker = "zqcanary-"

// Text returns the canary for one synced field, e.g. Text("channel.name").
func Text(field string) string { return Marker + field + "-7f3a" }

// Sink collects log output for a test. Safe for concurrent writers.
type Sink struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

// Write implements io.Writer.
func (s *Sink) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

// String returns everything written so far.
func (s *Sink) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

// Logger returns a logger that writes into the sink, for code that takes its
// own *log.Logger instead of the std one.
func (s *Sink) Logger() *log.Logger { return log.New(s, "", log.LstdFlags) }

// Capture routes the std log package into a new Sink for the test and
// restores the previous output and flags in t.Cleanup.
func Capture(t testing.TB) *Sink {
	t.Helper()
	s := &Sink{}
	prevOut, prevFlags, prevPrefix := log.Writer(), log.Flags(), log.Prefix()
	log.SetOutput(s)
	t.Cleanup(func() {
		log.SetOutput(prevOut)
		log.SetFlags(prevFlags)
		log.SetPrefix(prevPrefix)
	})
	return s
}

// AssertClean fails the test and names every captured line that carries a
// canary.
func (s *Sink) AssertClean(t testing.TB) {
	t.Helper()
	for _, line := range strings.Split(s.String(), "\n") {
		if strings.Contains(line, Marker) {
			t.Errorf("FILES-01: company content reached the log: %s", line)
		}
	}
}
