package ideas

import (
	"strings"
	"unicode/utf8"
)

// knowledgePrefixes maps an owner's chat prefix (lower case) to the kind of
// knowledge it records.
var knowledgePrefixes = []struct{ prefix, kind string }{
	{"решили:", "decision"},
	{"decided:", "decision"},
	{"факт:", "note"},
	{"fact:", "note"},
}

// ParseKnowledgePrefix reports whether text starts (after leading space,
// case-insensitively) with a knowledge prefix and returns its kind
// ("decision" or "note") and the rest trimmed, newlines kept. ok with an empty
// body is valid; the caller reports it as empty. Unicode handling mirrors
// instructions.ParseRemember (a Swift twin shares the fixture).
func ParseKnowledgePrefix(text string) (kind, body string, ok bool) {
	t := strings.TrimLeftFunc(text, isKnowledgeSpace)
	for _, p := range knowledgePrefixes {
		n := utf8.RuneCountInString(p.prefix)
		head, rest := splitKnowledgeRunes(t, n)
		if utf8.RuneCountInString(head) == n && strings.ToLower(head) == p.prefix {
			return p.kind, strings.TrimFunc(rest, isKnowledgeSpace), true
		}
	}
	return "", "", false
}

func isKnowledgeSpace(r rune) bool { return strings.TrimSpace(string(r)) == "" }

// splitKnowledgeRunes splits s after its first n runes (fewer when s is shorter).
func splitKnowledgeRunes(s string, n int) (head, rest string) {
	for i := range s {
		if n == 0 {
			return s[:i], s[i:]
		}
		n--
	}
	return s, ""
}
