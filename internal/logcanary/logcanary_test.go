package logcanary

import (
	"fmt"
	"log"
	"strings"
	"testing"
)

// recorder is a fake testing.TB that records Errorf calls.
type recorder struct {
	testing.TB
	errs []string
}

func (r *recorder) Helper() {}
func (r *recorder) Errorf(format string, args ...any) {
	r.errs = append(r.errs, fmt.Sprintf(format, args...))
}

func TestSink_AssertCleanFlagsMarker(t *testing.T) {
	s := Capture(t)
	log.Printf("channel %s:%s synced", "acme", "C1")
	log.Printf("leak %s", Text("x"))
	s.Logger().Printf("second %s", Text("y"))

	r := &recorder{TB: t}
	s.AssertClean(r)
	if len(r.errs) != 2 {
		t.Fatalf("errors = %d (%v), want 2", len(r.errs), r.errs)
	}
	if !strings.Contains(r.errs[0], Text("x")) || !strings.Contains(r.errs[1], Text("y")) {
		t.Errorf("errors do not name the lines: %v", r.errs)
	}
}

func TestSink_AssertCleanPassesCleanLog(t *testing.T) {
	s := Capture(t)
	log.Printf("user 1/2: acme:U1")
	r := &recorder{TB: t}
	s.AssertClean(r)
	if len(r.errs) != 0 {
		t.Errorf("unexpected errors: %v", r.errs)
	}
}
