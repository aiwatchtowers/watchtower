package codeindex

import (
	"bytes"
	"slices"
	"strings"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"
)

// textLimit caps a signature and a doc, in characters.
const textLimit = 200

// clip collapses whitespace and caps s at textLimit characters. It reads
// s only as far as the cap.
func clip(s string) string {
	var b strings.Builder
	n := 0         // characters in b
	space := false // a space is due before the next character
	for _, r := range s {
		if unicode.IsSpace(r) {
			space = n > 0
			continue
		}
		if space {
			if n == textLimit {
				return strings.TrimSpace(trimLastRune(b.String())) + "…"
			}
			b.WriteByte(' ')
			n++
			space = false
		}
		if n == textLimit {
			return strings.TrimSpace(trimLastRune(b.String())) + "…"
		}
		b.WriteRune(r)
		n++
	}
	return b.String()
}

// trimLastRune drops s's last character.
func trimLastRune(s string) string {
	_, size := utf8.DecodeLastRuneInString(s)
	return s[:len(s)-size]
}

// utf16Col is the 1-based UTF-16 column of byte offset off in src. It
// scans back to the line's start: for one offset per line (a scanner's
// line), not for many on one line — see columns.
func utf16Col(src []byte, off int) int {
	start := bytes.LastIndexByte(src[:off], '\n') + 1
	return utf16Len(src[start:off]) + 1
}

// utf16Len is the length of b in UTF-16 units; an invalid UTF-8 byte
// counts one.
func utf16Len(b []byte) int {
	n := 0
	for _, r := range string(b) {
		n += utf16.RuneLen(r)
	}
	return n
}

// columns turns byte offsets of one source into 1-based UTF-16 columns,
// carrying the column forward from the previous offset: offsets asked for
// in document order cost the distance between them, so a file written on
// one line (a minified bundle) is linear, not quadratic, in its symbols.
// An offset before the previous one rescans from its line's start.
type columns struct {
	src []byte
	// off is the previous offset, col its 0-based column.
	off, col int
}

func (c *columns) at(off int) int {
	if off < c.off {
		c.off = bytes.LastIndexByte(c.src[:off], '\n') + 1
		c.col = 0
	}
	gap := c.src[c.off:off]
	if nl := bytes.LastIndexByte(gap, '\n'); nl >= 0 {
		gap, c.col = gap[nl+1:], 0
	}
	c.col += utf16Len(gap)
	c.off = off
	return c.col + 1
}

// sigWindow bounds the source a signature is cut from, so a definition on
// a megabyte line costs a bounded copy; clip keeps far fewer characters.
const sigWindow = 4 << 10

// window is src[start:end], cut to at most sigWindow bytes at a character
// boundary.
func window(src []byte, start, end int) string {
	if end-start > sigWindow {
		end = start + sigWindow
		for end > start && !utf8.RuneStart(src[end]) {
			end--
		}
	}
	return string(src[start:end])
}

// firstSentence is the text up to and including the first period that
// ends a sentence (followed by a space or the end), or all of it.
func firstSentence(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	for i := 0; i < len(s); i++ {
		if s[i] == '.' && (i+1 == len(s) || s[i+1] == ' ') {
			return clip(s[:i+1])
		}
	}
	return clip(s)
}

// blockComments are the block comment delimiters, opener and closer:
// C's, OCaml's and Elm's/Haskell's.
var blockComments = [][3]string{{"/*", "/*!", "*/"}, {"(*", "(*", "*)"}, {"{-", "{-|", "-}"}}

// commentText strips comment markers from one comment's source: line
// prefixes (`///`, `//`, `---`, `#'`, `##`, `#`, `%%`, `;;`…) and block
// delimiters with their leading `*`.
func commentText(c string) string {
	c = strings.TrimSpace(c)
	for _, b := range blockComments {
		if !strings.HasPrefix(c, b[0]) {
			continue
		}
		c = strings.TrimSuffix(strings.TrimLeft(c, b[1]), b[2])
		lines := strings.Split(c, "\n")
		for i, l := range lines {
			lines[i] = strings.TrimPrefix(strings.TrimSpace(l), "*")
		}
		return strings.Join(lines, " ")
	}
	for _, p := range []string{"///", "//!", "//", "---", "--", "#'", "##", "#", "%%%", "%%", "%", ";;;", ";;"} {
		if strings.HasPrefix(c, p) {
			return strings.TrimPrefix(c, p)
		}
	}
	return c
}

// docstringText strips a Python string literal's prefix and quotes.
func docstringText(s string) string {
	s = strings.TrimLeft(strings.TrimSpace(s), "rRuUbBfF")
	for _, q := range []string{`"""`, `'''`, `"`, `'`} {
		if strings.HasPrefix(s, q) && strings.HasSuffix(s, q) && len(s) >= 2*len(q) {
			return s[len(q) : len(s)-len(q)]
		}
	}
	return s
}

// span is a symbol with the byte range of its definition, for assigning
// containers.
type span struct {
	sym        Symbol
	start, end uint
}

// assignContainers sets each symbol's container to the innermost
// container-kind symbol whose definition encloses it, unless the language
// already set one (a Go method's receiver).
func assignContainers(spans []span) []Symbol {
	slices.SortStableFunc(spans, func(a, b span) int {
		if a.start != b.start {
			return int(a.start) - int(b.start)
		}
		return int(b.end) - int(a.end)
	})
	var stack []span
	out := make([]Symbol, 0, len(spans))
	for _, s := range spans {
		for len(stack) > 0 && stack[len(stack)-1].end <= s.start {
			stack = stack[:len(stack)-1]
		}
		if s.sym.Container == "" {
			for i := len(stack) - 1; i >= 0; i-- {
				if stack[i].end >= s.end {
					s.sym.Container = stack[i].sym.Name
					break
				}
			}
		}
		if containerKinds[s.sym.Kind] {
			stack = append(stack, s)
		}
		out = append(out, s.sym)
	}
	slices.SortStableFunc(out, func(a, b Symbol) int {
		if a.Line != b.Line {
			return a.Line - b.Line
		}
		return a.Col - b.Col
	})
	return out
}

// markdownHeadings is the Markdown outline from a line scan (no grammar):
// every ATX heading outside a fenced code block, kind module, its
// container the nearest heading above it of a higher level, and its
// end_line the line before the next heading of the same or a higher
// level.
func markdownHeadings(src []byte) []Symbol {
	type heading struct {
		sym   Symbol
		level int
	}
	var out []heading
	var fence string
	lines := bytes.Split(src, []byte("\n"))
	for i, raw := range lines {
		line := strings.TrimRight(string(raw), "\r")
		trimmed := strings.TrimLeft(line, " ")
		if indent := len(line) - len(trimmed); indent > 3 {
			continue
		}
		if fence != "" {
			if strings.HasPrefix(trimmed, fence) {
				fence = ""
			}
			continue
		}
		if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
			fence = trimmed[:3]
			continue
		}
		level := len(trimmed) - len(strings.TrimLeft(trimmed, "#"))
		if level < 1 || level > 6 || (len(trimmed) > level && trimmed[level] != ' ' && trimmed[level] != '\t') {
			continue
		}
		text := strings.TrimSpace(trimmed[level:])
		if t := strings.TrimRight(text, "#"); t == "" || strings.HasSuffix(t, " ") {
			text = strings.TrimSpace(t)
		}
		if text == "" {
			continue
		}
		textAt := len(line) - len(strings.TrimLeft(line[strings.Index(line, "#")+level:], " \t"))
		out = append(out, heading{level: level, sym: Symbol{
			Name:      text,
			Kind:      KindModule,
			Line:      i + 1,
			Col:       utf16Col([]byte(line), textAt),
			Signature: clip(trimmed),
			Outline:   true,
		}})
	}
	last := len(lines)
	if last > 0 && len(lines[last-1]) == 0 {
		last-- // a trailing newline does not start another line
	}
	syms := make([]Symbol, len(out))
	for i := range out {
		end := last
		for j := i + 1; j < len(out); j++ {
			if out[j].level <= out[i].level {
				end = out[j].sym.Line - 1
				break
			}
		}
		out[i].sym.EndLine = end
		for j := i - 1; j >= 0; j-- {
			if out[j].level < out[i].level {
				out[i].sym.Container = out[j].sym.Name
				break
			}
		}
		syms[i] = out[i].sym
	}
	return syms
}
