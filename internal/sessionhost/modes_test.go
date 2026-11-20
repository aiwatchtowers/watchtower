package sessionhost

import (
	"bytes"
	"strconv"
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

// viewer models the keyboard side of a SwiftTerm terminal: kitty keyboard
// state per screen (Terminal.swift handleKittyKeyboardProtocol), buffer
// switches on 47/1047/1049 and RIS. It reuses the tracker, whose parse is the
// code under test only for the stream the agent wrote; Replay's output is
// checked by feeding it to a fresh one.
func viewerState(stream ...[]byte) ([2]keyboardMode, bool) {
	var v ModeTracker
	for _, b := range stream {
		v.Observe(b)
	}
	return v.keyboard, v.alt
}

func sameKeyboard(a, b [2]keyboardMode) bool {
	for i := range a {
		if a[i].flags != b[i].flags || len(a[i].stack) != len(b[i].stack) {
			return false
		}
		for j := range a[i].stack {
			if a[i].stack[j] != b[i].stack[j] {
				return false
			}
		}
	}
	return true
}

// Claude Code switches the kitty keyboard protocol on at start (CSI > 5 u,
// after its CSI ? u query is answered); a viewer attaching later must end in
// the same keyboard state as the agent's terminal, or Shift+Return reaches
// the agent as a plain Return — and must stay in step through the agent's
// later pop, whether the push is still in the replayed tail or not.
func TestModeTracker_ReplayKeyboardMatchesAgent(t *testing.T) {
	cases := []struct {
		name         string
		before, tail string // before: output gone from the ring; tail: what Snapshot returns
	}{
		{"push in the tail", "", "\x1b[?u\x1b[>0q\x1b[>5u\x1b[?2004hprompt"},
		{"push aged out", "\x1b[>5u\x1b[?2004h", "prompt"},
		{"pop in the tail, push aged out", "\x1b[>1u\x1b[>5u", "x\x1b[<u"},
		{"set modes", "\x1b[=1u", "\x1b[=4;2u\x1b[>8u\x1b[=1;3u"},
		{"RIS in the tail", "\x1b[>1u", "a\x1bcb\x1b[>5u"},
		{"alt screen, both stacks", "\x1b[>1u\x1b[?1049h", "\x1b[>5uz"},
		{"alt entered with 1049, left with 47", "\x1b[?1049h\x1b[>5u", "\x1b[?47l\x1b[>3u"},
		{"alt entered with 1049, left with 47, aged out", "\x1b[?1049h\x1b[>5u\x1b[?47l", "\x1b[>3u"},
		{"RIS in the tail on the alt screen", "\x1b[>1u", "\x1bc\x1b[>2u\x1b[?1049h\x1b[>5u"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var m ModeTracker
			m.Observe([]byte(c.before))
			m.Observe([]byte(c.tail))
			wantKB, wantAlt := viewerState([]byte(c.before + c.tail))
			if !wantAlt {
				// An inactive alternate screen's state is not restored.
				wantKB[1] = keyboardMode{}
			}
			replay := m.Replay([]byte(c.tail))
			gotKB, gotAlt := viewerState(replay)
			if gotAlt != wantAlt || !sameKeyboard(gotKB, wantKB) {
				t.Fatalf("replay %q: viewer %+v alt=%v, agent %+v alt=%v", replay, gotKB, gotAlt, wantKB, wantAlt)
			}
			// The agent pops everything it pushed: the viewer follows.
			pop := []byte("\x1b[<16u")
			m.Observe(pop)
			agentKB, _ := viewerState([]byte(c.before+c.tail), pop)
			viewKB, _ := viewerState(replay, pop)
			if viewKB[m.screen()].flags != agentKB[m.screen()].flags {
				t.Fatalf("after the pop: viewer %+v, agent %+v", viewKB, agentKB)
			}
		})
	}
}

func TestModeTracker_ReplayDropsTailKeyboardSequences(t *testing.T) {
	var m ModeTracker
	tail := "a\x1b[>5ub\x1b[<uc\x1b[=1;1ud\x1b[>0qe\x1b[31mf"
	m.Observe([]byte(tail))
	got := string(m.Replay([]byte(tail)))
	if want := "ab\x1b[=1;1u"; strings.Contains(got, "\x1b[>5u") || !strings.HasPrefix(got, "abcd\x1b[>0qe\x1b[31mf") || !strings.HasSuffix(got, "\x1b[=1;1u") {
		t.Fatalf("got %q (the tail drawn without its keyboard sequences, then the state; not %q)", got, want)
	}
}

// An unfinished sequence the tracker holds stays at the very end, so the
// next live bytes complete it; the keyboard state goes before it.
func TestModeTracker_ReplayKeepsUnfinishedSequenceLast(t *testing.T) {
	var m ModeTracker
	tail := "\x1b[>5ux\x1b[3"
	m.Observe([]byte(tail))
	if got, want := string(m.Replay([]byte(tail))), "x\x1b[>5u\x1b[3"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestModeTracker_KeyboardSplitSequence(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b["))
	m.Observe([]byte(">5"))
	m.Observe([]byte("u"))
	if m.keyboard[0].flags != 5 || len(m.keyboard[0].stack) != 1 {
		t.Fatalf("keyboard = %+v", m.keyboard[0])
	}
}

func TestModeTracker_KeyboardInvalidSetModeIgnored(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b[=5;1u\x1b[=1;7u"))
	if m.keyboard[0].flags != 5 {
		t.Fatalf("flags = %d", m.keyboard[0].flags)
	}
}

// The stack keeps its newest entries: the oldest goes first, as in SwiftTerm.
func TestModeTracker_KeyboardStackBounded(t *testing.T) {
	var m ModeTracker
	for i := 1; i <= maxKeyboardStack+3; i++ {
		m.Observe([]byte("\x1b[>" + strconv.Itoa(i) + "u"))
	}
	k := m.keyboard[0]
	if len(k.stack) != maxKeyboardStack || k.stack[0] != 3 || k.stack[len(k.stack)-1] != maxKeyboardStack+2 {
		t.Fatalf("stack = %v", k.stack)
	}
}

func TestUnfinishedTail(t *testing.T) {
	for in, want := range map[string]int{
		"":                 0,
		"abc":              3,
		"ab\x1b":           2,
		"ab\x1b[":          2,
		"ab\x1b[?20":       2,
		"ab\x1b[31m":       7,
		"ab\x1b]0;title":   2,
		"ab\x1b]0;t\x07cd": 10,
		"ab\x1b(":          2,
		"ab\x1b(B":         5,
		"ab\xe2\x94":       2,
		"ab\xe2\x94\x80":   5,
		"\xf0\x9f\x98":     0,
		"\x1b[1mab\x1b[1;": 6,
	} {
		if got := unfinishedTail([]byte(in)); got != want {
			t.Errorf("unfinishedTail(%q) = %d, want %d", in, got, want)
		}
	}
}

// An abandoned CSI leaves the ESC that cancels it for the next sequence.
func TestModeTracker_CancelledSequenceKeepsNext(t *testing.T) {
	var m ModeTracker
	m.Observe([]byte("\x1b[?25\x1b[?2004h\x1b[>\x1b[>5u"))
	if !m.On(bracketedPasteMode) || m.keyboard[0].flags != 5 {
		t.Fatalf("2004 = %v, keyboard = %+v", m.On(bracketedPasteMode), m.keyboard[0])
	}
}

// A title the tail ends in the middle of stays last; the keyboard state
// goes before it.
func TestModeTracker_ReplayKeepsOpenTitleLast(t *testing.T) {
	var m ModeTracker
	tail := "\x1b[>5ux\x1b]0;half a ti"
	m.Observe([]byte(tail))
	if got, want := string(m.Replay([]byte(tail))), "x\x1b[>5u\x1b]0;half a ti"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}
