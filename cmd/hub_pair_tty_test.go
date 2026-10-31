package cmd

import (
	"testing"

	"github.com/stretchr/testify/require"
)

// TestHubPairEscapesThePhoneName is Review Focus 4 at the function level: the
// phone names itself, and the terminal prints that name before the SAS
// prompt. An OSC title sequence, its BEL terminator and a right-to-left
// override must not reach the terminal; the printable rest stays.
func TestHubPairEscapesThePhoneName(t *testing.T) {
	require.Equal(t, "acme]0;x", sanitizeForTerminal("acme\x1b]0;x\x07\u202e"))
}

func TestSanitizeForTerminal(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"plain", "Colleague A's iPhone", "Colleague A's iPhone"},
		{"non-latin kept", "Айфон 15 — 📱", "Айфон 15 — 📱"},
		{"C0 controls", "a\x00b\tc\nd\re\x1bf", "abcdef"},
		{"DEL", "a\x7fb", "ab"},
		{"C1 controls (CSI, OSC as code points)", "a\u009b31mb\u009dc\u0080d\u009fe", "a31mbcde"},
		{"raw 8-bit C1 byte (invalid UTF-8)", "a\x9b31mb", "a31mb"},
		{"invalid UTF-8 dropped", "a\xff\xfeb", "ab"},
		{"embedding and override controls", "a\u202ab\u202bc\u202cd\u202de\u202ef", "abcdef"},
		{"isolate controls", "a\u2066b\u2067c\u2068d\u2069e", "abcde"},
		{"bidi marks", "a\u200eb\u200fc\u061cd", "abcd"},
		{"CSI clear screen", "x\x1b[2Jy", "x[2Jy"},
		{"empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			require.Equal(t, c.want, sanitizeForTerminal(c.in))
		})
	}
}
