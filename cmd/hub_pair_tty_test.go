package cmd

import (
	"strings"
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
		{"line and paragraph separators", "a\u2028b\u2029c", "abc"},
		{"zero-width space and joiner", "a\u200bb\u200cc\u200dd\u2060e", "abcde"},
		{"byte order mark, soft hyphen, Mongolian vowel separator", "\ufeffa\u00adb\u180ec", "abc"},
		{"tag characters", "a\U000E0001\U000E0041\U000E007Fb", "ab"},
		{"combining marks capped at two per base", "e\u0301\u0302\u0303\u0304x\u0300", "e\u0301\u0302x\u0300"},
		{"Zalgo flood", "Z" + strings.Repeat("\u0336", 5000) + "a", "Z\u0336\u0336a"},
		{"64 runes kept as is", strings.Repeat("ж", 64), strings.Repeat("ж", 64)},
		{"10 000-rune name cut with an ellipsis", strings.Repeat("ж", 10000), strings.Repeat("ж", 63) + "…"},
		{"dropped runes do not count toward the cap", strings.Repeat("\u200b", 100) + "ab", "ab"},
		{"empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			require.Equal(t, c.want, sanitizeForTerminal(c.in))
		})
	}
}
