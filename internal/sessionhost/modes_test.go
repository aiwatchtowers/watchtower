package sessionhost

import (
	"bytes"
	"strings"
	"testing"
)

func TestModeTracker_ReplayPrefixRestoresBracketedPaste(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b[?2004h"))
	m.Observe([]byte(strings.Repeat("x", 3<<20)))
	if !bytes.Contains(m.ReplayPrefix(), []byte("\x1b[?2004h")) {
		t.Fatalf("prefix = %q", m.ReplayPrefix())
	}
}

func TestModeTracker_SplitSequence(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b[?10"))
	m.Observe([]byte("49h"))
	if !bytes.Contains(m.ReplayPrefix(), []byte("\x1b[?1049h")) {
		t.Fatalf("prefix = %q", m.ReplayPrefix())
	}
}

func TestModeTracker_DefaultsEmitNothing(t *testing.T) {
	var m ModeTracker
	if len(m.ReplayPrefix()) != 0 {
		t.Fatal("expected empty prefix")
	}
	m.Observe([]byte("\x1b[?25l"))
	if got := string(m.ReplayPrefix()); got != "\x1b[?25l" {
		t.Fatalf("got %q", got)
	}
	m.Observe([]byte("\x1b[?25h"))
	if len(m.ReplayPrefix()) != 0 {
		t.Fatalf("got %q", m.ReplayPrefix())
	}
}

func TestModeTracker_MultiModeAltFirst(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("a\x1b[?2004;1049hb\x1b[31m\x1b[?9999h"))
	if got := string(m.ReplayPrefix()); got != "\x1b[?1049h\x1b[?2004h" {
		t.Fatalf("got %q", got)
	}
}

func TestModeTracker_OversizedPendingDropped(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b[?" + strings.Repeat("1;", 20)))
	if len(m.pending) != 0 {
		t.Fatalf("pending = %d", len(m.pending))
	}
	m.Observe([]byte("2004h"))
	if len(m.ReplayPrefix()) != 0 {
		t.Fatalf("got %q", m.ReplayPrefix())
	}
}
