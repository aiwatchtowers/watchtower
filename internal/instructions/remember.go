package instructions

import (
	"strings"
	"unicode/utf8"
)

// rememberPrefixes are checked in order, so "remember this:" is never read
// as a shorter prefix. All lower case.
var rememberPrefixes = []string{"remember this:", "remember:", "запомни:"}

// ParseRemember reports whether text starts (after leading space,
// case-insensitively) with a remember prefix and returns the rest with every
// whitespace run collapsed to one space. ok with an empty line is valid; the
// caller reports it as empty.
func ParseRemember(text string) (line string, ok bool) {
	t := strings.TrimLeftFunc(text, isSpace)
	for _, p := range rememberPrefixes {
		n := utf8.RuneCountInString(p)
		head, rest := splitRunes(t, n)
		if utf8.RuneCountInString(head) == n && strings.ToLower(head) == p {
			return strings.Join(strings.Fields(rest), " "), true
		}
	}
	return "", false
}

func isSpace(r rune) bool { return strings.TrimSpace(string(r)) == "" }

// splitRunes splits s after its first n runes (fewer when s is shorter).
func splitRunes(s string, n int) (head, rest string) {
	for i := range s {
		if n == 0 {
			return s[:i], s[i:]
		}
		n--
	}
	return s, ""
}
