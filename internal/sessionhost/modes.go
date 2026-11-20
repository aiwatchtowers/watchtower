package sessionhost

import (
	"bytes"
	"sort"
	"strconv"
)

// maxPendingSeq bounds the unfinished sequence kept between Observe calls.
const maxPendingSeq = 32

// trackedModes maps each tracked DEC private mode to its power-on default.
var trackedModes = map[int]bool{
	1: false, 25: true, 47: false, 1000: false, 1002: false, 1003: false,
	1004: false, 1006: false, 1047: false, 1049: false, bracketedPasteMode: false,
}

// bracketedPasteMode is DEC private mode 2004: bracketed paste.
const bracketedPasteMode = 2004

// maxKeyboardStack bounds a screen's kitty keyboard flag stack; the oldest
// entry goes first, as in SwiftTerm.
const maxKeyboardStack = 16

// keyboardMode is one screen's kitty keyboard protocol state: the current
// flags and the stack pushes saved them on. A fresh terminal starts at zero.
type keyboardMode struct {
	flags int
	stack []int
}

// ModeTracker is not safe for concurrent use. It follows an output stream's DEC private mode changes
// (CSI ? Pm h|l) and its kitty keyboard protocol state (CSI > n u, CSI < n u, CSI = n;m u — kept per
// screen, as SwiftTerm keeps it) so a fresh terminal can be put back into the same state (Replay). Without
// the keyboard state a viewer that attaches after the agent switched the protocol on sends Shift+Return as
// a plain Return.
type ModeTracker struct {
	state    map[int]bool
	pending  []byte
	keyboard [2]keyboardMode // [0] the normal screen, [1] the alternate one
	alt      bool            // the alternate screen is active
}

// Observe feeds output bytes to the tracker.
func (m *ModeTracker) Observe(p []byte) {
	if m.state == nil {
		m.state = map[int]bool{}
	}
	data := p
	if len(m.pending) > 0 {
		data = append(m.pending, p...)
		m.pending = nil
	}
	i := 0
	for i < len(data) {
		esc := bytes.IndexByte(data[i:], 0x1b)
		if esc < 0 {
			return
		}
		i += esc
		end, complete := m.parse(data[i:])
		if !complete {
			if len(data)-i <= maxPendingSeq {
				m.pending = append([]byte(nil), data[i:]...)
			}
			return
		}
		i += end
	}
}

// parse reads one candidate sequence at the start of s (s[0] is ESC). It
// returns how many bytes to consume and false when s ends mid-sequence.
func (m *ModeTracker) parse(s []byte) (int, bool) {
	if len(s) < 2 {
		return 0, false
	}
	if s[1] == 'c' { // RIS: the terminal goes back to its power-on state
		clear(m.state)
		m.keyboard = [2]keyboardMode{}
		m.alt = false
		return 2, true
	}
	if s[1] != '[' {
		return 1, true
	}
	if len(s) < 3 {
		return 0, false
	}
	switch s[2] {
	case '?':
	case '>', '<', '=':
		n, pars, final, complete := csiParams(s)
		if complete && final == 'u' {
			m.keyboardSequence(s[2], pars)
		}
		return n, complete
	default:
		return 2, true
	}
	n, pars, final, complete := csiParams(s)
	if !complete || final != 'h' && final != 'l' {
		return n, complete
	}
	on := final == 'h'
	for _, p := range pars {
		if _, ok := trackedModes[p]; !ok {
			continue
		}
		if p == 47 || p == 1047 || p == 1049 {
			// SwiftTerm switches buffers on any of the three, so only the
			// one that switched last reads as set.
			m.state[47], m.state[1047], m.state[1049] = false, false, false
			m.alt = on
		}
		m.state[p] = on
	}
	return n, true
}

// csiParams reads a CSI sequence with a one-byte prefix (s[2]): its length,
// its numeric parameters (an empty field reads as 0, a field that is not a
// number is skipped) and its final byte; false when s ends mid-sequence.
// Anything other than a digit or ; ends the parameters; when that is not a
// final byte (0x40–0x7E) the sequence is abandoned there, final is 0 and the
// byte is not consumed.
func csiParams(s []byte) (n int, pars []int, final byte, complete bool) {
	j := 3
	for j < len(s) && (s[j] >= '0' && s[j] <= '9' || s[j] == ';') {
		j++
	}
	if j >= len(s) {
		return 0, nil, 0, false
	}
	if s[j] < 0x40 || s[j] > 0x7e {
		// Not a final byte (an ESC that cancels the sequence, say): leave it
		// for the next scan.
		return j, nil, 0, true
	}
	if j > 3 {
		for f := range bytes.SplitSeq(s[3:j], []byte{';'}) {
			v, err := strconv.Atoi(string(f))
			if len(f) > 0 && err != nil {
				continue
			}
			pars = append(pars, v)
		}
	}
	return j + 1, pars, s[j], true
}

// keyboardSequence applies one kitty keyboard protocol sequence to the
// current screen's state, the way SwiftTerm does.
func (m *ModeTracker) keyboardSequence(prefix byte, pars []int) {
	par := func(i, def int) int {
		if i < len(pars) {
			return pars[i]
		}
		return def
	}
	k := &m.keyboard[m.screen()]
	switch prefix {
	case '>':
		if len(k.stack) >= maxKeyboardStack {
			k.stack = k.stack[1:]
		}
		k.stack = append(k.stack, k.flags)
		k.flags = par(0, 0)
	case '<':
		n := max(par(0, 1), 1)
		if n > len(k.stack) {
			*k = keyboardMode{}
			return
		}
		k.flags = k.stack[len(k.stack)-n]
		k.stack = k.stack[:len(k.stack)-n]
	case '=':
		switch par(1, 1) {
		case 1:
			k.flags = par(0, 0)
		case 2:
			k.flags |= par(0, 0)
		case 3:
			k.flags &^= par(0, 0)
		}
	}
}

// screen is 1 while the alternate screen is active, else 0.
func (m *ModeTracker) screen() int {
	if m.alt {
		return 1
	}
	return 0
}

// On reports whether a tracked mode is set, its power-on default until the
// output changed it. An untracked mode reads as off.
func (m *ModeTracker) On(mode int) bool {
	if v, ok := m.state[mode]; ok {
		return v
	}
	return trackedModes[mode]
}

// Replay returns what a fresh terminal must be fed to show snapshot — the
// tail of the same output stream, ending where the tracker last observed —
// and end in the tracker's state: the DEC modes, then snapshot without its
// kitty keyboard sequences, then the active screen's keyboard state as it
// stands now.
//
// The keyboard sequences are stack operations, so replaying them from a tail
// would leave the viewer's stack off from the agent's (a push seen twice
// keeps a flag the agent's pop clears); they draw nothing, so the tail goes
// without them and the final state follows it, which also survives a RIS
// inside the tail. While the alternate screen is active the normal screen's
// state goes first (or just after the tail's last RIS), on a power-on normal
// screen: switching screens after the tail would clear the alternate one. An inactive alternate
// screen's state is not restored — programs set it after switching to it.
// An unfinished escape or CSI sequence at the end of snapshot stays last, so
// the stream's next bytes complete it.
func (m *ModeTracker) Replay(snapshot []byte) []byte {
	cut := unfinishedTail(snapshot)
	snapshot, tail := snapshot[:cut], snapshot[cut:]
	out := m.ReplayPrefix()
	body := stripKeyboard(snapshot)
	if m.alt {
		// The normal screen's state goes where the viewer is last on a
		// power-on normal screen: the start, or just after the tail's last
		// RIS.
		at := 0
		if i := bytes.LastIndex(body, []byte("\x1bc")); i >= 0 {
			at = i + 2
		} else {
			out = appendLevels(nil, m.keyboard[0])
			out = append(out, m.ReplayPrefix()...)
		}
		out = append(out, body[:at]...)
		if at > 0 {
			out = appendLevels(out, m.keyboard[0])
		}
		body = body[at:]
	}
	out = append(out, body...)
	out = appendLevels(out, m.keyboard[m.screen()])
	return append(out, tail...)
}

// unfinishedTail returns where an escape or CSI sequence that b ends in the
// middle of starts, or len(b): an ESC alone, ESC [ followed only by
// parameter and intermediate bytes (0x20–0x3F) up to the end, or a string
// sequence (OSC, DCS, APC, PM, SOS) with no terminator yet.
func unfinishedTail(b []byte) int {
	i := bytes.LastIndexByte(b, 0x1b)
	if i < 0 {
		return len(b)
	}
	rest := b[i+1:]
	if len(rest) == 0 {
		return i
	}
	switch rest[0] {
	case ']', 'P', '_', '^', 'X':
		// OSC, DCS, APC, PM, SOS: open until BEL or ST (ESC \, whose ESC
		// would be the last one).
		if bytes.IndexByte(rest, 0x07) < 0 {
			return i
		}
		return len(b)
	case '[':
	default:
		return len(b)
	}
	for _, c := range rest[1:] {
		if c < 0x20 || c > 0x3f {
			return len(b)
		}
	}
	return i
}

// stripKeyboard returns b without its complete kitty keyboard sequences
// (CSI >|<|= params u).
func stripKeyboard(b []byte) []byte {
	out := make([]byte, 0, len(b))
	for {
		i := bytes.Index(b, []byte("\x1b["))
		if i < 0 || i+2 >= len(b) {
			return append(out, b...)
		}
		out = append(out, b[:i]...)
		b = b[i:]
		if p := b[2]; p == '>' || p == '<' || p == '=' {
			if n, _, final, complete := csiParams(b); complete && final == 'u' {
				b = b[n:]
				continue
			}
		}
		out = append(out, b[:2]...)
		b = b[2:]
	}
}

// appendLevels appends what rebuilds k on a screen whose keyboard state is
// the power-on one: a set for the bottom of k's stack, then one push per
// level above it.
func appendLevels(out []byte, k keyboardMode) []byte {
	all := append(append([]int(nil), k.stack...), k.flags)
	if all[0] != 0 {
		out = append(out, "\x1b[="...)
		out = strconv.AppendInt(out, int64(all[0]), 10)
		out = append(out, ";1u"...)
	}
	for _, f := range all[1:] {
		out = append(out, "\x1b[>"...)
		out = strconv.AppendInt(out, int64(f), 10)
		out = append(out, 'u')
	}
	return out
}

// ReplayPrefix returns the escape sequences that restore every tracked DEC
// mode that differs from its default, alternate-screen modes first.
func (m *ModeTracker) ReplayPrefix() []byte {
	var alt, rest []int
	for n, v := range m.state {
		if v == trackedModes[n] {
			continue
		}
		if n == 47 || n == 1047 || n == 1049 {
			alt = append(alt, n)
		} else {
			rest = append(rest, n)
		}
	}
	sort.Ints(alt)
	sort.Ints(rest)
	var out []byte
	for _, n := range append(alt, rest...) {
		final := byte('l')
		if m.state[n] {
			final = 'h'
		}
		out = append(out, "\x1b[?"...)
		out = strconv.AppendInt(out, int64(n), 10)
		out = append(out, final)
	}
	return out
}
