package chatstore

import (
	"strings"
	"unicode"

	"github.com/rivo/uniseg"
)

// The stored/sent owner-turn format of Swift ChatTurnComposer:
//
//	Use skill <name>: load it with load_skill first.   ← optional
//
//	<the owner's text>
//
//	REFERENCED: person:<id> "Label"; jira:PROJ-1 "PROJ-1"   ← optional
//
// The phone composes no skill line and no references, but an edit keeps the
// original's (recompose), and owner text that merely looks like either marker
// is escaped with a zero-width space so displayParts never misreads it.
const (
	referencedPrefix = "REFERENCED: "
	skillLinePrefix  = "Use skill "
	skillLineSuffix  = ": load it with load_skill first."
	escapeMarker     = "\u200b"
)

// displayParts is ChatTurnComposer.displayParts: the skill name, the owner's
// body (markers stripped, trimmed) and the REFERENCED line as stored.
func displayParts(stored string) (skill, body, referencedLine string) {
	rest := stored
	firstLine := untilNewline(rest)
	if name, ok := skillNameInLine(firstLine); ok {
		skill = name
		rest = trimLeadingNewlineChars(rest[len(firstLine):])
	}
	if start, end, ok := referencedMarker(rest); ok {
		line := untilNewline(rest[end:])
		if strictReferences(line) {
			referencedLine = referencedPrefix + line
			rest = rest[:start]
		}
	}
	body = swiftTrim(strings.ReplaceAll(rest, escapeMarker, ""))
	return skill, body, referencedLine
}

// composeOwnerText is ChatTurnComposer.compose with no skill and no mentions.
func composeOwnerText(text string) string {
	return escapedBody(swiftTrim(text), false, false)
}

// recompose is ChatTurnComposer.recompose: an edited message keeps the
// original's skill line and REFERENCED line around its new body.
func recompose(stored, newBody string) string {
	skill, _, refLine := displayParts(stored)
	var out []string
	if skill != "" {
		out = append(out, skillLinePrefix+skill+skillLineSuffix)
	}
	if body := escapedBody(swiftTrim(newBody), skill != "", refLine != ""); body != "" {
		out = append(out, body)
	}
	if refLine != "" {
		out = append(out, refLine)
	}
	return strings.Join(out, "\n\n")
}

// escapedBody is ChatTurnComposer.escapedBody: a leading skill-line
// look-alike (no real skill) and every strict REFERENCED look-alike (no real
// references) get the zero-width marker in front.
func escapedBody(text string, hasSkill, hasReferences bool) string {
	body := text
	if !hasSkill {
		if _, ok := skillNameInLine(untilNewline(body)); ok {
			body = escapeMarker + body
		}
	}
	if !hasReferences {
		starts := referencedLookAlikeStarts(body)
		for i := len(starts) - 1; i >= 0; i-- {
			body = body[:starts[i]] + escapeMarker + body[starts[i]:]
		}
	}
	return body
}

func referencedLookAlikeStarts(text string) []int {
	var starts []int
	from := 0
	for {
		i := strings.Index(text[from:], referencedPrefix)
		if i < 0 {
			return starts
		}
		at := from + i
		from = at + len(referencedPrefix)
		if at != 0 && !strings.HasSuffix(text[:at], "\n\n") {
			continue
		}
		if strictReferences(untilNewline(text[from:])) {
			starts = append(starts, at)
		}
	}
}

// referencedMarker is the LAST "REFERENCED: " that starts the text or follows
// a blank line: [start, end) covers the blank line too, end is after the prefix.
func referencedMarker(text string) (start, end int, ok bool) {
	if i := strings.LastIndex(text, "\n\n"+referencedPrefix); i >= 0 {
		return i, i + 2 + len(referencedPrefix), true
	}
	if strings.HasPrefix(text, referencedPrefix) {
		return 0, len(referencedPrefix), true
	}
	return 0, 0, false
}

// strictReferences reports whether line is a REFERENCED line: every item a
// well-formed `<token> "<escaped label>"`; one malformed item fails it all.
func strictReferences(line string) bool {
	items := splitReferences(line)
	if len(items) == 0 {
		return false
	}
	for _, item := range items {
		sp := strings.IndexByte(item, ' ')
		if sp < 0 {
			return false
		}
		token, quoted := item[:sp], item[sp+1:]
		if token == "" || uniseg.GraphemeClusterCount(quoted) < 2 ||
			!strings.HasPrefix(quoted, `"`) || !strings.HasSuffix(quoted, `"`) {
			return false
		}
	}
	return true
}

// splitReferences splits on ";" outside quoted labels.
func splitReferences(line string) []string {
	var items []string
	var cur strings.Builder
	inQuotes, escaped := false, false
	for _, r := range line {
		switch {
		case escaped:
			cur.WriteRune(r)
			escaped = false
			continue
		case r == '\\' && inQuotes:
			cur.WriteRune(r)
			escaped = true
			continue
		case r == '"':
			inQuotes = !inQuotes
		case r == ';' && !inQuotes:
			items = append(items, trimSwiftWhitespaces(cur.String()))
			cur.Reset()
			continue
		}
		cur.WriteRune(r)
	}
	if last := trimSwiftWhitespaces(cur.String()); last != "" {
		items = append(items, last)
	}
	return items
}

// skillNameInLine is ChatTurnComposer.skillName(inLine:).
func skillNameInLine(line string) (string, bool) {
	if !strings.HasPrefix(line, skillLinePrefix) || !strings.HasSuffix(line, skillLineSuffix) ||
		len(line) < len(skillLinePrefix)+len(skillLineSuffix) {
		return "", false
	}
	name := line[len(skillLinePrefix) : len(line)-len(skillLineSuffix)]
	if name == "" || !(name[0] >= 'a' && name[0] <= 'z' || name[0] >= '0' && name[0] <= '9') {
		return "", false
	}
	for _, r := range name {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
			return "", false
		}
	}
	return name, true
}

// untilNewline is the text before the first "\n" character, as Swift counts
// characters: "\r\n" is one character, never a "\n".
func untilNewline(s string) string {
	g := uniseg.NewGraphemes(s)
	for g.Next() {
		if g.Str() == "\n" {
			start, _ := g.Positions()
			return s[:start]
		}
	}
	return s
}

// trimLeadingNewlineChars drops leading "\n" characters ("\r\n" is not one).
func trimLeadingNewlineChars(s string) string {
	g := uniseg.NewGraphemes(s)
	for g.Next() {
		if g.Str() != "\n" {
			start, _ := g.Positions()
			return s[start:]
		}
	}
	return ""
}

// swiftTrim is trimmingCharacters(in: .whitespacesAndNewlines).
func swiftTrim(s string) string { return strings.TrimFunc(s, unicode.IsSpace) }

// trimSwiftWhitespaces is trimmingCharacters(in: .whitespaces): spaces and
// tab, no newlines.
func trimSwiftWhitespaces(s string) string {
	return strings.TrimFunc(s, func(r rune) bool { return r == '\t' || unicode.Is(unicode.Zs, r) })
}
