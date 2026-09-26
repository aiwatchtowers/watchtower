package kb

import (
	"strings"
	"unicode"
)

// ftsKeywords are FTS5 query operators; a query word equal to one of them is
// dropped rather than quoted (spec §8).
var ftsKeywords = map[string]bool{"AND": true, "OR": true, "NOT": true, "NEAR": true}

// BuildMatch turns one free-text query into two safe FTS5 MATCH strings: and
// (every term) and or (any term). Every term is a quoted phrase made only of
// letters, digits and inner '-', '_', '.', so no user text can reach the FTS5
// query syntax; a trailing '*' on a word becomes a prefix operator on its last
// term. A query with no usable term yields "", "".
func BuildMatch(query string) (and, or string) {
	var terms []string
	for _, word := range strings.Fields(query) {
		word = Normalize(word)
		prefix := strings.HasSuffix(word, "*")
		pieces := strings.FieldsFunc(word, func(r rune) bool {
			return !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '-' && r != '_' && r != '.'
		})
		var kept []string
		for _, p := range pieces {
			p = strings.Trim(p, "-_.")
			if p == "" || ftsKeywords[strings.ToUpper(p)] {
				continue
			}
			kept = append(kept, `"`+p+`"`)
		}
		if prefix && len(kept) > 0 {
			kept[len(kept)-1] += "*"
		}
		terms = append(terms, kept...)
	}
	if len(terms) == 0 {
		return "", ""
	}
	return strings.Join(terms, " "), strings.Join(terms, " OR ")
}
