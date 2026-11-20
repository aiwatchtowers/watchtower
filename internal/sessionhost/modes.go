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

// ModeTracker is not safe for concurrent use. It follows DEC private mode changes (CSI ? Pm h|l), the kitty
// keyboard protocol (CSI > n u, CSI < n u, CSI = n;m u — kept per screen, as terminals do) and xterm's
// modifyOtherKeys (CSI > 4;n m) in an output stream so a fresh terminal can be put back into the same state.
// Without the keyboard modes a viewer that attaches after the agent switched them on sends Shift+Return as a
// plain Return.
type ModeTracker struct {
	state           map[int]bool
	pending         []byte
	keyboard        [2]keyboardMode // [0] the normal screen, [1] the alternate one
	modifyOtherKeys int
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
	if s[1] != '[' {
		return 1, true
	}
	if len(s) < 3 {
		return 0, false
	}
	switch s[2] {
	case '?':
	case '>', '<', '=':
		return m.parseKeyboard(s)
	default:
		return 2, true
	}
	j := 3
	for j < len(s) && (s[j] >= '0' && s[j] <= '9' || s[j] == ';') {
		j++
	}
	if j >= len(s) {
		return 0, false
	}
	if s[j] != 'h' && s[j] != 'l' {
		return j, true
	}
	on := s[j] == 'h'
	for f := range bytes.SplitSeq(s[3:j], []byte{';'}) {
		n, err := strconv.Atoi(string(f))
		if err != nil {
			continue
		}
		if _, ok := trackedModes[n]; ok {
			m.state[n] = on
		}
	}
	return j + 1, true
}

// parseKeyboard reads a CSI sequence with a >, < or = prefix (s[2]): the
// kitty keyboard protocol's push, pop and set, and modifyOtherKeys.
func (m *ModeTracker) parseKeyboard(s []byte) (int, bool) {
	j := 3
	for j < len(s) && (s[j] >= '0' && s[j] <= '9' || s[j] == ';') {
		j++
	}
	if j >= len(s) {
		return 0, false
	}
	var pars []int
	if j > 3 {
		for f := range bytes.SplitSeq(s[3:j], []byte{';'}) {
			n, _ := strconv.Atoi(string(f)) // an empty field reads as 0
			pars = append(pars, n)
		}
	}
	par := func(i, def int) int {
		if i < len(pars) {
			return pars[i]
		}
		return def
	}
	switch {
	case s[j] == 'u':
		m.keyboardSequence(s[2], par(0, 0), par(1, 1))
	case s[j] == 'm' && s[2] == '>' && (len(pars) == 0 || pars[0] == 4):
		// CSI > 4 ; n m sets modifyOtherKeys; CSI > 4 m and CSI > m reset it.
		m.modifyOtherKeys = par(1, 0)
	}
	return j + 1, true
}

// keyboardSequence applies one kitty keyboard protocol sequence to the
// current screen's state, the way SwiftTerm does.
func (m *ModeTracker) keyboardSequence(prefix byte, first, mode int) {
	k := &m.keyboard[m.screen()]
	switch prefix {
	case '>':
		if len(k.stack) >= maxKeyboardStack {
			k.stack = k.stack[1:]
		}
		k.stack = append(k.stack, k.flags)
		k.flags = first
	case '<':
		n := max(first, 1)
		if n > len(k.stack) {
			*k = keyboardMode{}
			return
		}
		k.flags = k.stack[len(k.stack)-n]
		k.stack = k.stack[:len(k.stack)-n]
	case '=':
		switch mode {
		case 1:
			k.flags = first
		case 2:
			k.flags |= first
		case 3:
			k.flags &^= first
		}
	}
}

// screen is 1 while an alternate screen mode is on, else 0.
func (m *ModeTracker) screen() int {
	if m.state[47] || m.state[1047] || m.state[1049] {
		return 1
	}
	return 0
}

// appendKeyboard appends the sequences that rebuild k on a screen whose
// state is still the power-on one: a set for the bottom of the stack, then
// one push per level above it.
func appendKeyboard(out []byte, k keyboardMode) []byte {
	levels := append(append([]int(nil), k.stack...), k.flags)
	if levels[0] != 0 {
		out = append(out, "\x1b[="...)
		out = strconv.AppendInt(out, int64(levels[0]), 10)
		out = append(out, ";1u"...)
	}
	for _, f := range levels[1:] {
		out = append(out, "\x1b[>"...)
		out = strconv.AppendInt(out, int64(f), 10)
		out = append(out, 'u')
	}
	return out
}

// On reports whether a tracked mode is set, its power-on default until the
// output changed it. An untracked mode reads as off.
func (m *ModeTracker) On(mode int) bool {
	if v, ok := m.state[mode]; ok {
		return v
	}
	return trackedModes[mode]
}

// ReplayPrefix returns the escape sequences that restore every tracked mode
// that differs from its default: the normal screen's keyboard modes, then the
// alternate-screen modes and, on the alternate screen, its keyboard modes,
// then the other DEC modes and modifyOtherKeys. A push still inside the ring
// replays once more after this prefix; the flags in force stay the same.
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
	out := appendKeyboard(nil, m.keyboard[0])
	out = m.appendModes(out, alt)
	if m.screen() == 1 {
		out = appendKeyboard(out, m.keyboard[1])
	}
	out = m.appendModes(out, rest)
	if m.modifyOtherKeys != 0 {
		out = append(out, "\x1b[>4;"...)
		out = strconv.AppendInt(out, int64(m.modifyOtherKeys), 10)
		out = append(out, 'm')
	}
	return out
}

// appendModes appends a CSI ? n h|l for each of modes.
func (m *ModeTracker) appendModes(out []byte, modes []int) []byte {
	for _, n := range modes {
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
