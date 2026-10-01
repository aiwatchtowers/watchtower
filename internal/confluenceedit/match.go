package confluenceedit

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// normText is a match key: whitespace (NBSP and every Unicode space
// included) collapsed to one ASCII space and typographic quotes folded to
// ASCII, with, for every byte of the key, the source byte range of the rune
// it came from.
type normText struct {
	s          string
	start, end []int
}

// foldRune maps a rune to its match-key form.
func foldRune(r rune) rune {
	switch {
	case unicode.IsSpace(r):
		return ' '
	case strings.ContainsRune("“”„‟«»″", r):
		return '"'
	case strings.ContainsRune("‘’‚‛′", r):
		return '\''
	}
	return r
}

func normalize(s string) normText {
	var n normText
	var b strings.Builder
	prevSpace := false
	for i, r := range s {
		w := utf8.RuneLen(r)
		if r == utf8.RuneError {
			_, w = utf8.DecodeRuneInString(s[i:])
		}
		f := foldRune(r)
		if f == ' ' && prevSpace {
			n.end[len(n.end)-1] = i + w
			continue
		}
		prevSpace = f == ' '
		before := b.Len()
		b.WriteRune(f)
		for j := before; j < b.Len(); j++ {
			n.start = append(n.start, i)
			n.end = append(n.end, i+w)
		}
	}
	n.s = b.String()
	return n
}

// cleanModelText makes model-written text storable: invalid UTF-8 and
// every rune XML 1.0 forbids (NUL and the other C0 controls except tab,
// LF and CR, surrogates, U+FFFE/U+FFFF) become U+FFFD, so an edit can
// never produce storage Confluence rejects.
func cleanModelText(s string) string {
	return strings.Map(func(r rune) rune {
		if xmlChar(r) {
			return r
		}
		return utf8.RuneError
	}, strings.ToValidUTF8(s, "\uFFFD"))
}

func xmlChar(r rune) bool {
	switch {
	case r == '\t' || r == '\n' || r == '\r':
		return true
	case r < 0x20:
		return false
	case r >= 0xD800 && r <= 0xDFFF:
		return false
	}
	return r != 0xFFFE && r != 0xFFFF && r <= unicode.MaxRune
}

// matchKey is the key old text is looked up by.
func matchKey(s string) string {
	return strings.TrimSpace(normalize(s).s)
}

// findAll returns the source ranges in text of every occurrence of key (a
// matchKey), overlapping ones included: "aa" occurs twice in "aaa", so an
// edit quoting it is ambiguous, not the first match.
func findAll(text, key string) []span {
	if key == "" {
		return nil
	}
	n := normalize(text)
	var out []span
	for off := 0; ; {
		i := strings.Index(n.s[off:], key)
		if i < 0 {
			return out
		}
		i += off
		out = append(out, span{n.start[i], n.end[i+len(key)-1]})
		_, size := utf8.DecodeRuneInString(n.s[i:])
		off = i + size
	}
}

// stripStructure drops the block syntax of the editable text (heading
// hashes, list bullets, table pipes), for telling "spans blocks" from
// "not found".
func stripStructure(s string) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		l = strings.TrimLeft(l, " \t")
		l = strings.TrimLeft(l, "#")
		if m := itemRe.FindStringSubmatch(l); m != nil {
			l = m[4]
		}
		lines[i] = strings.ReplaceAll(l, "|", " ")
	}
	return strings.Join(lines, " ")
}

// stripEmphasis drops inline markdown delimiters, for a lenient heading
// comparison.
var stripEmphasis = strings.NewReplacer("**", "", "~~", "", "_", "", "`", "")
