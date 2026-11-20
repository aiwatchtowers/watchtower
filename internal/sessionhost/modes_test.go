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

func TestModeTracker_OnReadsDefaultsAndChanges(t *testing.T) {
	var m ModeTracker
	if m.On(bracketedPasteMode) || !m.On(25) || m.On(9999) {
		t.Fatal("defaults: 2004 off, 25 on, untracked off")
	}
	m.Observe([]byte("\x1b[?20"))
	m.Observe([]byte("04h"))
	if !m.On(bracketedPasteMode) {
		t.Fatal("2004 set across a split sequence reads off")
	}
	m.Observe([]byte("\x1b[?2004l"))
	if m.On(bracketedPasteMode) {
		t.Fatal("2004 reset reads on")
	}
}

// Claude Code switches the kitty keyboard protocol and modifyOtherKeys on at
// start; a viewer attaching later must get both, or Shift+Return reaches the
// agent as a plain Return.
func TestModeTracker_ReplaysKeyboardModes(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b[?u\x1b[>0q\x1b[>5u\x1b[>4;2m"))
	m.Observe([]byte(strings.Repeat("x", 1<<20)))
	if got := string(m.ReplayPrefix()); got != "\x1b[>5u\x1b[>4;2m" {
		t.Fatalf("got %q", got)
	}
}

func TestModeTracker_KeyboardPopAndReset(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b[>5u\x1b[>4;2m"))
	m.Observe([]byte("\x1b[<u\x1b[>4m"))
	if got := m.ReplayPrefix(); len(got) != 0 {
		t.Fatalf("after pop and reset got %q", got)
	}
	m.Observe([]byte("\x1b[>1u\x1b[>3u\x1b[<5u"))
	if got := m.ReplayPrefix(); len(got) != 0 {
		t.Fatalf("pop past the stack got %q", got)
	}
}

func TestModeTracker_KeyboardSetModes(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b[=1u\x1b[=4;2u\x1b[>8u"))
	if got := string(m.ReplayPrefix()); got != "\x1b[=5;1u\x1b[>8u" {
		t.Fatalf("got %q", got)
	}
	m.Observe([]byte("\x1b[<u\x1b[=1;3u"))
	if got := string(m.ReplayPrefix()); got != "\x1b[=4;1u" {
		t.Fatalf("after pop and clear got %q", got)
	}
}

func TestModeTracker_KeyboardSplitSequence(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b[>"))
	m.Observe([]byte("5"))
	m.Observe([]byte("u"))
	if got := string(m.ReplayPrefix()); got != "\x1b[>5u" {
		t.Fatalf("got %q", got)
	}
}

// Each screen keeps its own keyboard state; the alternate screen's replays
// after the switch to it, the normal one's before.
func TestModeTracker_KeyboardPerScreen(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b[>1u\x1b[?1049h\x1b[>5u\x1b[?2004h"))
	if got := string(m.ReplayPrefix()); got != "\x1b[>1u\x1b[?1049h\x1b[>5u\x1b[?2004h" {
		t.Fatalf("on the alternate screen got %q", got)
	}
	m.Observe([]byte("\x1b[?1049l"))
	if got := string(m.ReplayPrefix()); got != "\x1b[>1u\x1b[?2004h" {
		t.Fatalf("back on the normal screen got %q", got)
	}
}

func TestModeTracker_KeyboardStackBounded(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte(strings.Repeat("\x1b[>1u", 3*maxKeyboardStack)))
	if n := len(m.keyboard[0].stack); n != maxKeyboardStack {
		t.Fatalf("stack = %d", n)
	}
}
