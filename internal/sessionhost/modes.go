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
	1004: false, 1006: false, 1047: false, 1049: false, 2004: false,
}

// ModeTracker follows DEC private mode changes (CSI ? Pm h|l) in an output
// stream so a fresh terminal can be put back into the same state.
type ModeTracker struct {
	state   map[int]bool
	pending []byte
}

// Observe feeds output bytes to the tracker.
func (m *ModeTracker) Observe(p []byte) {
	if m.state == nil {
		m.state = map[int]bool{}
	}
	data := append(m.pending, p...) //nolint:gocritic // pending is reassigned below
	m.pending = nil
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
	if s[2] != '?' {
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
	for _, f := range bytes.Split(s[3:j], []byte{';'}) {
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

// ReplayPrefix returns the escape sequences that restore every tracked mode
// that differs from its default, alternate-screen modes first.
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
