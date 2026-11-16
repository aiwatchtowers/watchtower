// Package chatstore holds the chat's stored-data helpers that the hub shares
// with the Desktop's Swift code. ParseArtifacts is the Go twin of
// ArtifactParser.swift (WatchtowerChatText), pinned by the shared fixture
// internal/chat/testdata/artifact_parse_cases.json.
package chatstore

import (
	"strings"
	"unicode"

	"github.com/rivo/uniseg"
)

// ParsedArtifact is one complete artifact block of an assistant message.
type ParsedArtifact struct {
	Key     string
	Kind    string
	Title   string
	Content string
	Meta    map[string]string
}

const artifactOpener = ":::artifact"

var knownArtifactKinds = map[string]bool{
	"document": true, "table": true, "email": true, "slack": true,
	"event": true, "code": true, "html": true,
}

// ParseArtifacts follows ArtifactParser.swift line by line. final=false holds
// back a half-written opener line and drops a block that is still open;
// final=true keeps an unterminated block as complete content. A fence inside
// a ``` / ~~~ code block is literal text. The last block of a key wins (it
// replaces the earlier one in place, so keys keep their first-seen order).
func ParseArtifacts(text string, final bool) []ParsedArtifact {
	m := &artifactMachine{final: final}
	lines, terminated := splitArtifactLines(text)
	for i, line := range lines {
		trailingPartial := i == len(lines)-1 && !terminated[i]
		if !m.consume(line, trailingPartial) {
			break
		}
	}
	return m.finish()
}

// splitArtifactLines splits on "\n" and "\r\n" only (a lone "\r" is content,
// as in Swift). terminated[i] reports whether line i ended with a newline.
func splitArtifactLines(text string) (lines []string, terminated []bool) {
	if text == "" {
		return nil, nil
	}
	parts := strings.Split(text, "\n")
	endsWithNewline := strings.HasSuffix(text, "\n")
	if endsWithNewline {
		parts = parts[:len(parts)-1]
	}
	for i, p := range parts {
		// A "\r" before a "\n" belongs to the separator, not to the line.
		if i < len(parts)-1 || endsWithNewline {
			p = strings.TrimSuffix(p, "\r")
		}
		lines = append(lines, p)
		terminated = append(terminated, endsWithNewline || i < len(parts)-1)
	}
	return lines, terminated
}

// isSwiftWhitespace mirrors Character.isWhitespace for single runes.
func isSwiftWhitespace(r rune) bool { return unicode.IsSpace(r) }

// trimInlineSpace mirrors trimmingCharacters(in: .whitespaces): tab and the
// Unicode space separators, not newlines.
func trimInlineSpace(s string) string {
	return strings.TrimFunc(s, func(r rune) bool { return r == '\t' || unicode.Is(unicode.Zs, r) })
}

func dropLeading(s string, pred func(byte) bool) string {
	i := 0
	for i < len(s) && pred(s[i]) {
		i++
	}
	return s[i:]
}

// swiftIsLetterOrNumber classifies a grapheme cluster the way Swift's
// Character.isLetter / isNumber do: by its FIRST scalar only (isLetter =
// Alphabetic, which takes in Indic vowel signs; isNumber = has a numeric type).
func swiftIsLetterOrNumber(first rune) bool {
	return unicode.IsLetter(first) || unicode.IsNumber(first) || unicode.Is(unicode.Other_Alphabetic, first)
}

// swiftLower mirrors String.lowercased(): full case mapping per scalar, no
// context (so a final sigma stays σ). The only unconditional full mapping that
// differs from the simple one is U+0130 -> "i" + U+0307.
func swiftLower(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r == 0x130 {
			b.WriteString("i\u0307")
			continue
		}
		b.WriteRune(unicode.ToLower(r))
	}
	return b.String()
}

// artifactSlug walks grapheme clusters like Swift's Character loop: the 64 cap
// counts clusters and appends the whole cluster.
func artifactSlug(title string) string {
	var out strings.Builder
	count := 0
	pendingDash := false
	g := uniseg.NewGraphemes(swiftLower(title))
	for g.Next() {
		runes := g.Runes()
		if swiftIsLetterOrNumber(runes[0]) {
			if pendingDash && count > 0 {
				out.WriteByte('-')
				count++
			}
			pendingDash = false
			out.WriteString(g.Str())
			count++
			if count >= 64 {
				break
			}
		} else {
			pendingDash = true
		}
	}
	if count == 0 {
		return "artifact"
	}
	return out.String()
}

func isOpenerLine(trimmed string) bool {
	if !strings.HasPrefix(trimmed, artifactOpener) {
		return false
	}
	rest := trimmed[len(artifactOpener):]
	if rest == "" {
		return true
	}
	for _, r := range rest {
		return isSwiftWhitespace(r)
	}
	return true
}

func isOpenerPrefix(trimmed string) bool {
	return trimmed != "" && strings.HasPrefix(artifactOpener, trimmed)
}

type artifactDraft struct {
	ParsedArtifact
}

func parseOpener(trimmed string) (artifactDraft, bool) {
	attrs, ok := parseArtifactAttributes(trimmed[len(artifactOpener):])
	if !ok {
		return artifactDraft{}, false
	}
	take := func(name string) string {
		v := attrs[name]
		delete(attrs, name)
		return v
	}
	rawKind := strings.ToLower(take("kind"))
	rawKey := trimInlineSpace(take("key"))
	rawTitle := trimInlineSpace(take("title"))
	key := rawKey
	if key == "" {
		key = artifactSlug(rawTitle)
	}
	title := rawTitle
	if title == "" {
		title = "Untitled"
		if rawKey != "" {
			title = rawKey
		}
	}
	kind := "document"
	if knownArtifactKinds[rawKind] {
		kind = rawKind
	}
	return artifactDraft{ParsedArtifact: ParsedArtifact{Key: key, Kind: kind, Title: title, Meta: attrs}}, true
}

// Attribute names, quotes and fence markers below are scanned per rune: a
// combining mark right after one (one Character in Swift) is not mirrored.
// parseArtifactAttributes reads `name="value"` pairs; `\"` and `\\` are
// escapes. ok=false on any syntax error (including an unterminated quote).
func parseArtifactAttributes(src string) (map[string]string, bool) {
	result := map[string]string{}
	rs := []rune(src)
	i := 0
	for {
		for i < len(rs) && isSwiftWhitespace(rs[i]) {
			i++
		}
		if i == len(rs) {
			return result, true
		}
		start := i
		for i < len(rs) && (unicode.IsLetter(rs[i]) || unicode.IsNumber(rs[i]) || rs[i] == '_' || rs[i] == '-') {
			i++
		}
		name := strings.ToLower(string(rs[start:i]))
		if name == "" || i >= len(rs) || rs[i] != '=' {
			return nil, false
		}
		i++
		if i >= len(rs) || rs[i] != '"' {
			return nil, false
		}
		i++
		var value []rune
		closed := false
		for i < len(rs) {
			c := rs[i]
			if c == '\\' && i+1 < len(rs) && (rs[i+1] == '"' || rs[i+1] == '\\') {
				value = append(value, rs[i+1])
				i += 2
				continue
			}
			if c == '"' {
				i++
				closed = true
				break
			}
			value = append(value, c)
			i++
		}
		if !closed {
			return nil, false
		}
		result[name] = string(value)
	}
}

type codeFence struct {
	marker byte
	length int
}

func openingFence(line string) (codeFence, bool) {
	stripped := dropLeading(line, func(b byte) bool { return b == ' ' })
	if len([]rune(line))-len([]rune(stripped)) > 3 || stripped == "" {
		return codeFence{}, false
	}
	marker := stripped[0]
	if marker != '`' && marker != '~' {
		return codeFence{}, false
	}
	run := len(stripped) - len(dropLeading(stripped, func(b byte) bool { return b == marker }))
	if run < 3 {
		return codeFence{}, false
	}
	if marker == '`' && strings.Contains(stripped[run:], "`") {
		return codeFence{}, false
	}
	return codeFence{marker: marker, length: run}, true
}

func (f codeFence) isClosedBy(line string) bool {
	stripped := dropLeading(line, func(b byte) bool { return b == ' ' })
	if len(line)-len(stripped) > 3 {
		return false
	}
	rest := dropLeading(stripped, func(b byte) bool { return b == f.marker })
	if len(stripped)-len(rest) < f.length {
		return false
	}
	for _, r := range rest {
		if !isSwiftWhitespace(r) {
			return false
		}
	}
	return true
}

type artifactMachine struct {
	final      bool
	outerFence *codeFence
	open       *artifactDraft
	innerFence *codeFence
	body       []string
	out        []ParsedArtifact
}

// consume returns false to stop: the rest of a still-streaming text is held back.
func (m *artifactMachine) consume(line string, trailingPartial bool) bool {
	if m.open != nil {
		m.consumeArtifactLine(line)
		return true
	}
	if m.outerFence != nil {
		if m.outerFence.isClosedBy(line) {
			m.outerFence = nil
		}
		return true
	}
	if fence, ok := openingFence(line); ok {
		m.outerFence = &fence
		return true
	}
	trimmed := dropLeading(line, func(b byte) bool { return b == ' ' || b == '\t' })
	candidate := isOpenerLine(trimmed)
	if trailingPartial && !m.final && (candidate || isOpenerPrefix(trimmed)) {
		return false
	}
	if candidate {
		if draft, ok := parseOpener(trimmed); ok {
			m.open = &draft
			m.innerFence = nil
			m.body = nil
		}
	}
	return true
}

func (m *artifactMachine) consumeArtifactLine(line string) {
	if m.innerFence == nil && trimInlineSpace(line) == ":::" {
		m.emit()
		return
	}
	// Raw kinds: a ``` line inside code or an html page is content, not a fence.
	if m.open.Kind != "code" && m.open.Kind != "html" {
		if m.innerFence != nil {
			if m.innerFence.isClosedBy(line) {
				m.innerFence = nil
			}
		} else if fence, ok := openingFence(line); ok {
			m.innerFence = &fence
		}
	}
	m.body = append(m.body, line)
}

func (m *artifactMachine) emit() {
	a := m.open.ParsedArtifact
	a.Content = strings.Join(m.body, "\n")
	for i := range m.out {
		if m.out[i].Key == a.Key {
			m.out[i] = a
			a = ParsedArtifact{}
			break
		}
	}
	if a.Key != "" {
		m.out = append(m.out, a)
	}
	m.open = nil
	m.body = nil
}

func (m *artifactMachine) finish() []ParsedArtifact {
	// An unterminated block is kept only for a final message.
	if m.open != nil && m.final {
		m.emit()
	}
	return m.out
}
