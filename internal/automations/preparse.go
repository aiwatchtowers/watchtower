package automations

import "strings"

// syncOnlyWords are the identifiers a script may not use: the SDK is
// synchronous and no job queue or timer runs (spec §4).
var syncOnlyWords = map[string]bool{
	"async": true, "await": true, "Promise": true, "setTimeout": true, "setInterval": true,
}

// PreParse refuses a script that uses async, await, Promise, setTimeout or
// setInterval with "the script API is synchronous" (a *PreParseError). It is
// a lexical check: words inside strings, template text and comments, property
// names after a dot (`x.async`), object keys (`{async: 1}`) and `typeof`
// probes (`typeof setTimeout`) are allowed; a
// word inside a regular-expression literal is not told apart and is refused.
func PreParse(script string) error {
	s := &jsScan{src: script, line: 1}
	for s.i < len(s.src) {
		if word, line := s.next(); word != "" {
			return &PreParseError{Word: word, Line: line}
		}
	}
	return nil
}

// jsScan walks JavaScript source just far enough to tell code from strings,
// template text and comments.
type jsScan struct {
	src       string
	i, line   int
	braces    int
	templates []int // the brace depth at each open template ${
}

// next consumes one token; it returns a refused word and its line, or "".
func (s *jsScan) next() (string, int) {
	c := s.src[s.i]
	rest := s.src[s.i:]
	switch {
	case strings.HasPrefix(rest, "//"):
		s.skipTo("\n")
	case strings.HasPrefix(rest, "/*"):
		s.i += 2
		s.skipTo("*/")
		s.i = min(s.i+2, len(s.src))
	case c == '\'' || c == '"':
		s.skipString(c)
	case c == '`':
		s.i++
		s.skipTemplate()
	case c == '{':
		s.braces++
		s.i++
	case c == '}':
		s.closeBrace()
	case isIdentByte(c) && !isDigit(c):
		return s.word()
	default:
		s.advance()
	}
	return "", 0
}

// advance consumes one byte, counting lines.
func (s *jsScan) advance() {
	if s.src[s.i] == '\n' {
		s.line++
	}
	s.i++
}

// skipTo consumes up to (not including) the next marker, or to the end.
func (s *jsScan) skipTo(marker string) {
	for s.i < len(s.src) && !strings.HasPrefix(s.src[s.i:], marker) {
		s.advance()
	}
}

// skipString consumes a quoted string from its opening quote.
func (s *jsScan) skipString(quote byte) {
	s.i++
	for s.i < len(s.src) {
		c := s.src[s.i]
		switch {
		case c == '\\' && s.i+1 < len(s.src):
			s.i++
			s.advance()
		case c == quote:
			s.i++
			return
		case c == '\n': // unterminated: the parser will refuse it
			return
		default:
			s.i++
		}
	}
}

// skipTemplate consumes template text up to the closing backtick or the
// next ${ (whose code the main loop then scans).
func (s *jsScan) skipTemplate() {
	for s.i < len(s.src) {
		switch {
		case s.src[s.i] == '\\' && s.i+1 < len(s.src):
			s.i++
			s.advance()
		case s.src[s.i] == '`':
			s.i++
			return
		case strings.HasPrefix(s.src[s.i:], "${"):
			s.i += 2
			s.templates = append(s.templates, s.braces)
			return
		default:
			s.advance()
		}
	}
}

// closeBrace ends a block or a template's ${ … } expression.
func (s *jsScan) closeBrace() {
	s.i++
	if n := len(s.templates); n > 0 && s.templates[n-1] == s.braces {
		s.templates = s.templates[:n-1]
		s.skipTemplate()
		return
	}
	s.braces--
}

// word consumes an identifier and reports it when it is refused.
func (s *jsScan) word() (string, int) {
	start := s.i
	for s.i < len(s.src) && isIdentByte(s.src[s.i]) {
		s.i++
	}
	w := s.src[start:s.i]
	if !syncOnlyWords[w] || s.afterDot(start) || s.afterTypeof(start) || s.beforeColon() {
		return "", 0
	}
	return w, s.line
}

// afterDot reports a property access (`x.async`), not a spread (`...x`).
func (s *jsScan) afterDot(start int) bool {
	p := start - 1
	for p >= 0 && isSpace(s.src[p]) {
		p--
	}
	return p >= 0 && s.src[p] == '.' && (p == 0 || s.src[p-1] != '.')
}

// afterTypeof reports `typeof setTimeout`: probing for a name is not using it.
func (s *jsScan) afterTypeof(start int) bool {
	p := start
	for p > 0 && isSpace(s.src[p-1]) {
		p--
	}
	if !strings.HasSuffix(s.src[:p], "typeof") {
		return false
	}
	q := p - len("typeof")
	return q == 0 || !isIdentByte(s.src[q-1])
}

// beforeColon reports an object key (`{async: 1}`).
func (s *jsScan) beforeColon() bool {
	p := s.i
	for p < len(s.src) && isSpace(s.src[p]) {
		p++
	}
	return p < len(s.src) && s.src[p] == ':'
}

func isIdentByte(c byte) bool {
	return c == '_' || c == '$' || c >= 0x80 || isDigit(c) || (c|0x20 >= 'a' && c|0x20 <= 'z')
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }
