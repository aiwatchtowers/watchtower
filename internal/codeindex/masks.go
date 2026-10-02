package codeindex

import (
	"bytes"
	"regexp"
)

var (
	// sqlTriggerHead is a CREATE TRIGGER up to the trigger's name.
	sqlTriggerHead = regexp.MustCompile(`(?i)\bCREATE\s+(?:TEMP\s+|TEMPORARY\s+)?TRIGGER\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"[^"\n]+"|[\w.]+)`)
	// sqlBodyOpen is what follows a trigger's head: the end of a
	// PostgreSQL trigger (`;`) or the BEGIN of a SQLite one.
	sqlBodyOpen = regexp.MustCompile(`(?i);|\bBEGIN\b`)
	// sqlBodyEnd is a SQLite trigger's closing END.
	sqlBodyEnd = regexp.MustCompile(`(?i)\bEND\b\s*(?:;|$)`)
	// sqlTriggerFiller is the PostgreSQL trigger tail the grammar parses,
	// written in place of a SQLite trigger's events and body.
	sqlTriggerFiller = [][]byte{
		[]byte("AFTER"), []byte("INSERT"), []byte("ON"), []byte("t"), []byte("FOR"), []byte("EACH"),
		[]byte("ROW"), []byte("EXECUTE"), []byte("FUNCTION"), []byte("f()"),
	}
)

// maskSQLiteTriggers is src with each SQLite trigger's `… BEGIN … END`
// (everything after the trigger's name) rewritten as a PostgreSQL trigger
// tail the grammar parses, right-aligned so the statement still ends at
// END. The copy has src's length and newlines, so every position is
// unchanged; the grammar otherwise fails on BEGIN and the error swallows
// the statements after it. A CREATE TRIGGER that does not start its line
// (one in a comment) is left alone.
func maskSQLiteTriggers(src []byte) []byte {
	var out []byte
	for _, m := range sqlTriggerHead.FindAllIndex(src, -1) {
		lineStart := bytes.LastIndexByte(src[:m[0]], '\n') + 1
		if len(bytes.TrimSpace(src[lineStart:m[0]])) != 0 {
			continue
		}
		open := sqlBodyOpen.FindIndex(src[m[1]:])
		if open == nil || src[m[1]+open[0]] == ';' {
			continue // a PostgreSQL trigger: it parses as is
		}
		end := sqlBodyEnd.FindIndex(src[m[1]+open[1]:])
		if end == nil {
			continue
		}
		stop := m[1] + open[1] + end[0] + len("END")
		if out == nil {
			out = bytes.Clone(src)
		}
		fillTrigger(out[m[1]:stop])
	}
	if out == nil {
		return src
	}
	return out
}

// fillTrigger blanks region (newlines kept) and writes the filler tokens
// into it from the end, each whole on one line; a region too small for
// them is left as it was.
func fillTrigger(region []byte) {
	filled := bytes.Clone(region)
	blank(filled)
	pos := len(filled)
	for i := len(sqlTriggerFiller) - 1; i >= 0; i-- {
		tok := sqlTriggerFiller[i]
		for {
			if pos-len(tok) < 1 {
				return // no room: leave the trigger unparsed
			}
			if nl := bytes.LastIndexByte(filled[pos-len(tok):pos], '\n'); nl >= 0 {
				pos = pos - len(tok) + nl
				continue
			}
			copy(filled[pos-len(tok):pos], tok)
			pos -= len(tok) + 1
			break
		}
	}
	copy(region, filled)
}

var (
	// groovyImplements is a class header's `implements` clause, which the
	// grammar does not know (it then takes the interface for the class's
	// name). The header starts its line (after annotations and modifiers),
	// and neither it nor the clause crosses a comment opener or a quote, so
	// prose in a comment or a string ("a class that implements X") is not
	// a header.
	groovyImplements = regexp.MustCompile(`(?m)^[ \t]*(?:(?:@\w+|public|protected|private|abstract|final|static)[ \t]+)*(?:class|interface|trait)\s+\w+[^{\n;/"']*?(\bimplements\b[^{;/"']*)`)
	// groovyTrait is a trait's keyword, which the grammar does not know.
	groovyTrait = regexp.MustCompile(`(?m)^[ \t]*(?:(?:@\w+|public|protected|private|abstract|final|static)[ \t]+)*(trait)\b`)
)

// maskGroovy is src with each class header's `implements …` blanked and
// each `trait` keyword spelled `class` (same length, newlines kept), so
// the grammar parses both as a class with its own name.
func maskGroovy(src []byte) []byte {
	impl := groovyImplements.FindAllSubmatchIndex(src, -1)
	trait := groovyTrait.FindAllSubmatchIndex(src, -1)
	if impl == nil && trait == nil {
		return src
	}
	out := bytes.Clone(src)
	for _, m := range impl {
		blank(out[m[2]:m[3]])
	}
	for _, m := range trait {
		copy(out[m[2]:m[3]], "class")
	}
	return out
}

// objcEnumMacro is a Foundation enum macro: `NS_ENUM(NSInteger, Shape)`,
// the name its second argument.
var objcEnumMacro = regexp.MustCompile(`\b(?:NS_ENUM|NS_OPTIONS|NS_CLOSED_ENUM|NS_ERROR_ENUM|CF_ENUM|CF_OPTIONS)\s*\(\s*[^,()]+,\s*(\w+)\s*\)`)

// maskObjC is src with each Foundation enum macro spelled as a plain C
// enum, its name left where it is (`NS_ENUM(NSInteger, Shape)` becomes
// `enum               Shape `), which the grammar parses.
func maskObjC(src []byte) []byte {
	ms := objcEnumMacro.FindAllSubmatchIndex(src, -1)
	if ms == nil {
		return src
	}
	out := bytes.Clone(src)
	for _, m := range ms {
		blank(out[m[0]:m[2]])
		blank(out[m[3]:m[1]])
		copy(out[m[0]:], "enum")
	}
	return out
}

// blank turns every byte of b but a newline into a space.
func blank(b []byte) {
	for i := range b {
		if b[i] != '\n' {
			b[i] = ' '
		}
	}
}
