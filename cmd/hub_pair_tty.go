package cmd

import (
	"strings"
	"unicode/utf8"
)

// sanitizeForTerminal makes a phone-supplied string (its name, a refusal
// reason) safe to print in the owner's terminal during `hub pair` (go-hub
// plan 2 Task 6, Review Focus 4): it drops the C0 controls, DEL, the C1
// controls (including CSI U+009B and OSC U+009D), every Unicode bidi control
// (U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069) and every byte
// that is not valid UTF-8, since a raw 0x9B byte is CSI to an 8-bit
// terminal. Escape sequences lose their ESC and so print as plain text.
func sanitizeForTerminal(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		i += size
		if r == utf8.RuneError && size <= 1 {
			continue
		}
		if dropForTerminal(r) {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

func dropForTerminal(r rune) bool {
	switch {
	case r < 0x20, r == 0x7f, r >= 0x80 && r <= 0x9f:
		return true
	case r == 0x061c, r == 0x200e, r == 0x200f:
		return true
	case r >= 0x202a && r <= 0x202e, r >= 0x2066 && r <= 0x2069:
		return true
	}
	return false
}
