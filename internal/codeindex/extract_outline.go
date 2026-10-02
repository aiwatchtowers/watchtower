package codeindex

import (
	"bytes"
	"encoding/json"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// Config-file outlines (spec §6.3): the top-level keys of YAML, TOML and
// JSON, kind field, flagged outline so they show in the jump bar and stay
// out of Open Quickly's Symbols scope. Each is a scanner, not a grammar:
// only the top level is read, and a scanner works in every build (cgo or
// not) and keeps going past what a parser would reject (a Helm template's
// `{{ }}` lines, a tsconfig's comments and trailing commas).

// noSymbols is the scan of a language indexed for its name only (HTML,
// CSS, SCSS, Dockerfile in the POC).
func noSymbols([]byte) []Symbol { return nil }

// srcLines splits src into lines without their `\r\n` or `\n`; a final
// newline does not start another line.
func srcLines(src []byte) []string {
	lines := strings.Split(string(src), "\n")
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	for i, l := range lines {
		lines[i] = strings.TrimSuffix(l, "\r")
	}
	return lines
}

// outlineField is the top-level key name on lines[i], its text starting
// at byte nameAt of the line: an outline field whose signature is the
// line.
func outlineField(name string, lines []string, i, nameAt int, doc string) Symbol {
	return Symbol{
		Name:      name,
		Kind:      KindField,
		Line:      i + 1,
		Col:       utf16Col([]byte(lines[i]), nameAt),
		EndLine:   i + 1,
		Signature: clip(lines[i]),
		Doc:       doc,
		Outline:   true,
	}
}

// hashDoc is the first sentence of the column-0 `#` comment lines
// directly above line i (no blank line between). An indented comment
// belongs to the value above it (a commented-out nested key, a line of a
// block scalar), not to the next top-level key.
func hashDoc(lines []string, i int) string {
	var parts []string
	for j := i - 1; j >= 0 && strings.HasPrefix(lines[j], "#"); j-- {
		parts = append(parts, commentText(lines[j]))
	}
	slices.Reverse(parts)
	return firstSentence(strings.Join(parts, " "))
}

// skipQuoted is the index just past the string literal opening at s[i]
// (a `"` or `'`), with backslash escapes when escapes; an unterminated
// one ends at its line's end.
func skipQuoted[T string | []byte](s T, i int, escapes bool) int {
	q := s[i]
	for j := i + 1; j < len(s); j++ {
		switch {
		case s[j] == '\n':
			return j
		case escapes && s[j] == '\\':
			j++
		case s[j] == q:
			return j + 1
		}
	}
	return len(s)
}

// unquote is a quoted key's text: a double-quoted one with its escapes
// decoded (when they decode), a single-quoted one as written.
func unquote(lit string) string {
	if strings.HasPrefix(lit, `"`) {
		if s, err := strconv.Unquote(lit); err == nil {
			return s
		}
	}
	if len(lit) >= 2 {
		return lit[1 : len(lit)-1]
	}
	return lit
}

// YAML

// yamlDocScalar is a `---` line opening a document that is one block
// scalar (`--- |`): its lines may start at column 0 without being keys.
var yamlDocScalar = regexp.MustCompile(`^---\s.*[|>][-+0-9]*\s*$`)

// yamlKeys lists a YAML file's top-level mapping keys: the lines at
// column 0 that are `key:` (plain, or quoted), in every document of the
// file. A key's end_line is the last indented line of its value; column-0
// comments, sequence items and document markers do not continue it.
func yamlKeys(src []byte) []Symbol {
	lines := srcLines(src)
	var syms []Symbol
	open := -1
	inScalar := false
	for i, line := range lines {
		if line == "---" || line == "..." || strings.HasPrefix(line, "--- ") || strings.HasPrefix(line, "... ") {
			open, inScalar = -1, yamlDocScalar.MatchString(line)
			continue
		}
		if inScalar || strings.TrimSpace(line) == "" {
			continue
		}
		if line[0] == ' ' || line[0] == '\t' {
			if open >= 0 {
				syms[open].EndLine = i + 1
			}
			continue
		}
		open = -1
		if name, at, ok := yamlKey(line); ok {
			syms = append(syms, outlineField(name, lines, i, at, hashDoc(lines, i)))
			open = len(syms) - 1
		}
	}
	return syms
}

// yamlKey reads a column-0 line as a mapping key: a quoted key followed by
// `:`, or plain text up to the first `:` that ends it (followed by a space
// or the line's end, so `http://x` is not a key).
func yamlKey(line string) (name string, at int, ok bool) {
	if c := line[0]; c == '"' || c == '\'' {
		return yamlQuotedKey(line, c)
	}
	if yamlNotKey(line) {
		return "", 0, false
	}
	for i := 1; i < len(line); i++ {
		if line[i] == '#' && (line[i-1] == ' ' || line[i-1] == '\t') {
			break
		}
		if line[i] == ':' && yamlColonAt(line[i:]) {
			return strings.TrimRight(line[:i], " \t"), 0, true
		}
	}
	return "", 0, false
}

// yamlQuotedKey reads a line opening with quote q as a quoted key: the
// literal, then `:`.
func yamlQuotedKey(line string, q byte) (name string, at int, ok bool) {
	end := skipQuoted(line, 0, q == '"')
	for q == '\'' && end < len(line) && line[end] == '\'' {
		end = skipQuoted(line, end, false) // '' is a quote inside
	}
	if end < 2 || line[end-1] != q || !yamlColonAt(strings.TrimLeft(line[end:], " \t")) {
		return "", 0, false
	}
	name = unquote(line[:end])
	if q == '\'' {
		name = strings.ReplaceAll(name, "''", "'")
	}
	return name, 1, true
}

// yamlNotKey reports a line that opens something other than a plain key:
// a comment, a sequence item, a complex key, a flow collection, an anchor,
// a tag, a block scalar or a directive.
func yamlNotKey(line string) bool {
	if strings.IndexByte("#[]{},&*!|>%@`", line[0]) >= 0 || yamlColonAt(line) {
		return true
	}
	for _, ind := range []string{"-", "?"} {
		if line == ind || strings.HasPrefix(line, ind+" ") {
			return true
		}
	}
	return false
}

// yamlColonAt reports s starting with a mapping colon: `:` then a space,
// a tab or the end.
func yamlColonAt(s string) bool {
	return s == ":" || strings.HasPrefix(s, ": ") || strings.HasPrefix(s, ":\t")
}

// TOML

// tomlValue tracks a value that spans lines: an open multi-line string, or
// open brackets and braces (an array, a TOML 1.1 inline table).
type tomlValue struct {
	multi string // the open multi-line string's delimiter, `"""` or `'''`
	depth int
}

func (v tomlValue) open() bool { return v.multi != "" || v.depth > 0 }

// scan advances over one line of value text.
func (v *tomlValue) scan(text string) {
	for i := 0; i < len(text); {
		if v.multi == "" {
			i = v.token(text, i)
			continue
		}
		j := strings.Index(text[i:], v.multi)
		if j < 0 {
			return
		}
		i += j + len(v.multi)
		for i < len(text) && text[i] == v.multi[0] {
			i++ // `""""` closes after a quote of the string's own
		}
		v.multi = ""
	}
}

// token reads the value token at text[i] and returns the index after it.
func (v *tomlValue) token(text string, i int) int {
	switch c := text[i]; c {
	case '#':
		return len(text)
	case '"', '\'':
		if q := text[i : i+1]; strings.HasPrefix(text[i:], q+q+q) {
			v.multi = q + q + q
			return i + 3
		}
		return skipQuoted(text, i, c == '"')
	case '[', '{':
		v.depth++
	case ']', '}':
		v.depth = max(0, v.depth-1)
	}
	return i + 1
}

// tomlOutline is the state of a TOML scan.
type tomlOutline struct {
	lines []string
	syms  []Symbol
	seen  map[string]bool
	open  int // the listed entry the current lines belong to, -1 none
}

// tomlKeys lists a TOML file's top-level names: the keys before the first
// table header, and each table header (`[name]`, `[[name]]`), by their
// first key segment (`a.b = 1` and `[a.b]` list a). A name is listed once:
// a repeat right after it (`[[items]]` again, `[a.c]` after `[a.b]`)
// extends it, a later one is not listed again. Keys inside a table and the
// lines of a multi-line value only extend the entry's end_line.
func tomlKeys(src []byte) []Symbol {
	t := tomlOutline{lines: srcLines(src), seen: map[string]bool{}, open: -1}
	var value tomlValue
	inTable := false
	for i, line := range t.lines {
		trimmed := strings.TrimSpace(line)
		switch {
		case value.open():
			t.extend(i)
			value.scan(line)
		case trimmed == "" || trimmed[0] == '#':
		case trimmed[0] == '[':
			inTable = true
			start := len(line) - len(strings.TrimLeft(line, " \t["))
			if name, at, _, ok := tomlSegment(line, start); ok {
				t.add(name, i, at)
			}
		default:
			name, at, end, ok := tomlSegment(line, 0)
			eq := tomlEquals(line, end)
			if !ok || eq < 0 {
				continue
			}
			if inTable {
				t.extend(i)
			} else {
				t.add(name, i, at)
			}
			value.scan(line[eq:])
		}
	}
	return t.syms
}

func (t *tomlOutline) extend(i int) {
	if t.open >= 0 {
		t.syms[t.open].EndLine = i + 1
	}
}

// add lists name at line i, unless it is the open entry (extended) or one
// listed before (not listed again, and nothing is open after it).
func (t *tomlOutline) add(name string, i, at int) {
	switch {
	case t.open >= 0 && t.syms[t.open].Name == name:
		t.extend(i)
	case t.seen[name]:
		t.open = -1
	default:
		t.seen[name] = true
		t.syms = append(t.syms, outlineField(name, t.lines, i, at, hashDoc(t.lines, i)))
		t.open = len(t.syms) - 1
	}
}

// tomlSegment reads the key segment at line[i:] (after spaces): a bare
// key or a quoted one, returning its text, where that text starts and
// where the segment ends.
func tomlSegment(line string, i int) (name string, at, end int, ok bool) {
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i++
	}
	if i < len(line) && (line[i] == '"' || line[i] == '\'') {
		end = skipQuoted(line, i, line[i] == '"')
		return unquote(line[i:end]), i + 1, end, end-i >= 2 && line[end-1] == line[i]
	}
	end = i
	for end < len(line) && isBareKeyByte(line[end]) {
		end++
	}
	return line[i:end], i, end, end > i
}

func isBareKeyByte(c byte) bool {
	return c == '_' || c == '-' || ('0' <= c && c <= '9') || ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
}

// tomlEquals is the index after a key line's `=`, looked for from the end
// of its first segment past the rest of a dotted key; -1 for no `=`.
func tomlEquals(line string, from int) int {
	for i := from; i < len(line); {
		switch line[i] {
		case '=':
			return i + 1
		case '"', '\'':
			i = skipQuoted(line, i, line[i] == '"')
		case '#':
			return -1
		default:
			i++
		}
	}
	return -1
}

// JSON

// jsonOutline is the state of a JSON scan.
type jsonOutline struct {
	src       []byte
	depth     int
	object    bool // the top-level value is an object
	expectKey bool // the next string at depth 1 is a key
	done      bool // the top-level value has closed
	syms      []Symbol
	open      int // the key whose value is being read, -1 none
	lastSig   int // offset of the last byte that is not space or comment
	// line counts the lines up to lineFrom, for lineOf's forward-only
	// lookups.
	line, lineFrom int
}

// jsonKeys lists the keys of a JSON file's top-level object, in order,
// with each key's end_line the last line of its value. Strings (either
// quote, escapes honoured) and `//` and `/* */` comments (JSONC) are
// skipped; only the first top-level value is read (a JSON Lines file
// lists its first record's keys); a top-level array or scalar lists none.
func jsonKeys(src []byte) []Symbol {
	s := jsonOutline{src: src, open: -1, lastSig: -1, line: 1}
	for i := 0; i < len(src) && !s.done; {
		i = s.step(i)
	}
	return s.syms
}

// step reads the token at src[i] and returns the index after it.
func (s *jsonOutline) step(i int) int {
	switch c := s.src[i]; {
	case c == ' ' || c == '\t' || c == '\n' || c == '\r':
		return i + 1
	case c == '/' && i+1 < len(s.src) && (s.src[i+1] == '/' || s.src[i+1] == '*'):
		return skipJSONComment(s.src, i)
	case c == '"' || c == '\'':
		end := skipQuoted(s.src, i, true)
		if s.depth == 1 && s.expectKey {
			s.key(i, end)
		}
		s.lastSig = end - 1
		return end
	default:
		s.punct(c)
		s.lastSig = i
		return i + 1
	}
}

// punct tracks nesting: an opener enters a level, a closer leaves one (the
// top-level value's ends the scan), a comma at depth 1 ends a key's value.
func (s *jsonOutline) punct(c byte) {
	switch c {
	case '{', '[':
		s.depth++
		if s.depth == 1 {
			s.object = c == '{'
			s.expectKey = s.object
		}
	case '}', ']':
		s.depth--
		if s.depth <= 0 {
			s.closeKey()
			s.done = true
		}
	case ',':
		if s.depth == 1 {
			s.closeKey()
			s.expectKey = s.object
		}
	}
}

// key lists the key literal src[start:end].
func (s *jsonOutline) key(start, end int) {
	s.expectKey = false
	var name string
	if err := json.Unmarshal(s.src[start:end], &name); err != nil {
		name = unquote(string(s.src[start:end]))
	}
	lineEnd := bytes.IndexByte(s.src[start:], '\n')
	if lineEnd < 0 {
		lineEnd = len(s.src) - start
	}
	line := s.lineOf(start)
	s.syms = append(s.syms, Symbol{
		Name:      name,
		Kind:      KindField,
		Line:      line,
		Col:       utf16Col(s.src, start+1),
		EndLine:   line,
		Signature: clip(strings.TrimRight(strings.TrimSpace(string(s.src[start:start+lineEnd])), ",{[ \t")),
		Outline:   true,
	})
	s.open = len(s.syms) - 1
}

// closeKey ends the open key's value at the last significant byte.
func (s *jsonOutline) closeKey() {
	if s.open >= 0 && s.lastSig >= 0 {
		s.syms[s.open].EndLine = s.lineOf(s.lastSig)
	}
	s.open = -1
}

// lineOf is the 1-based line of offset off, which must not be before the
// last offset asked for.
func (s *jsonOutline) lineOf(off int) int {
	if off > s.lineFrom {
		s.line += bytes.Count(s.src[s.lineFrom:off], []byte("\n"))
		s.lineFrom = off
	}
	return s.line
}

// skipJSONComment is the index past the comment at src[i]: a line comment
// to its newline, a block comment to its `*/` (or the end).
func skipJSONComment(src []byte, i int) int {
	if src[i+1] == '/' {
		if nl := bytes.IndexByte(src[i:], '\n'); nl >= 0 {
			return i + nl
		}
		return len(src)
	}
	if end := bytes.Index(src[i+2:], []byte("*/")); end >= 0 {
		return i + 2 + end + 2
	}
	return len(src)
}

// Vue and Svelte

var (
	// scriptBlock is a `<script …>…</script>` element: its attributes and
	// its contents.
	scriptBlock = regexp.MustCompile(`(?is)<script\b([^>]*)>(.*?)</script\s*>`)
	// scriptTS is a TypeScript lang attribute.
	scriptTS = regexp.MustCompile(`(?i)\blang\s*=\s*["']?(tsx|ts|typescript)\b`)
)

// scriptHost is the language a Vue or Svelte file is parsed as: its
// `<script>` blocks with the JavaScript query, or the TypeScript (TSX)
// one when a block says lang="ts" ("tsx"), everything outside the blocks
// masked to spaces so every symbol keeps its line and column in the file.
func scriptHost(src []byte) *langSpec {
	blocks := scriptBlock.FindAllSubmatchIndex(src, -1)
	id := "javascript"
	for _, b := range blocks {
		if m := scriptTS.FindSubmatch(src[b[2]:b[3]]); m != nil {
			id = "typescript"
			if strings.EqualFold(string(m[1]), "tsx") {
				id = "tsx"
			}
		}
	}
	host := *langByID[id]
	host.mask = func(in []byte) []byte {
		out := bytes.Clone(in)
		prev := 0
		for _, b := range blocks {
			blank(out[prev:b[4]])
			prev = b[5]
		}
		blank(out[prev:])
		return out
	}
	return &host
}
