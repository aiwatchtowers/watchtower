package confluenceedit

import (
	"fmt"
	"regexp"
	"strings"
)

// tokenRe finds token-shaped strings: ⟦ ... ⟧ with no bracket inside.
var tokenRe = regexp.MustCompile(markerOpen + "[^" + markerOpen + markerClose + "]*" + markerClose)

// classifyCtx is what deciding the markers of new text needs to know.
type classifyCtx struct {
	inSpan  map[int]bool // markers inside the text being replaced
	present map[int]bool // markers anywhere in the evolving document
	literal string       // the replaced content with its real markers blanked out
}

// classify finds the real markers in new text. A token is a marker only
// when it is exactly one of the page's tokens (ordinal AND label), and the
// marker is being replaced or is absent from the page. Anything else
// token-shaped is literal page text only if the replaced content already
// carried it as literal text — so a "⟦n:x⟧" someone typed on the page is
// never mistaken for a marker, and a mistyped marker is an error instead
// of a silent deletion.
func (a *applier) classify(text string, c classifyCtx) ([]mark, error) {
	var marks []mark
	seen := map[int]bool{}
	for _, loc := range tokenRe.FindAllStringIndex(text, -1) {
		tok := text[loc[0]:loc[1]]
		k, known := a.tokens[tok]
		isMarker, err := a.decide(tok, k, known, c)
		if err != nil {
			return nil, err
		}
		if !isMarker {
			continue
		}
		if seen[k] {
			return nil, fmt.Errorf("duplicate marker %s: each marker can appear only once", tok)
		}
		seen[k] = true
		marks = append(marks, mark{at: loc[0], k: k})
	}
	return marks, nil
}

func (a *applier) decide(tok string, k int, known bool, c classifyCtx) (bool, error) {
	switch {
	case known && (c.inSpan[k] || !c.present[k]):
		return true, nil
	case strings.Contains(c.literal, tok):
		return false, nil // literal text already on the page
	case known:
		return false, fmt.Errorf("duplicate marker %s: it already appears elsewhere on the page, and each marker can appear only once", tok)
	}
	return false, a.unknownMarker(tok)
}

func (a *applier) unknownMarker(tok string) error {
	if k := tokenOrdinal(tok); k >= 1 && k <= len(a.orig.markers) {
		return fmt.Errorf("unknown marker %s; copy marker tokens exactly, e.g. %s", tok, a.orig.markers[k-1].token())
	}
	return fmt.Errorf("unknown marker %s; markers can only be kept or removed, never invented", tok)
}

// literalView is text with its real marker tokens blanked out, leaving
// only what is literal page text.
func literalView(text string, marks []mark, markers []Marker) string {
	if len(marks) == 0 {
		return text
	}
	var b strings.Builder
	prev := 0
	for _, m := range marks {
		b.WriteString(text[prev:m.at])
		b.WriteByte(0)
		prev = m.at + len(markers[m.k-1].token())
	}
	b.WriteString(text[prev:])
	return b.String()
}

// blocksLiteral is the literal view of every unit of bs.
func blocksLiteral(bs []*block, markers []Marker) string {
	var parts []string
	for _, bl := range bs {
		for _, u := range bl.editUnits() {
			if u.kind == unitInline {
				parts = append(parts, literalView(u.text, u.marks, markers))
			}
		}
	}
	return strings.Join(parts, "\x00")
}

// blocksLinks merges the original link tags of bs's units.
func blocksLinks(bs []*block) map[string]string {
	out := map[string]string{}
	for _, bl := range bs {
		for _, u := range bl.editUnits() {
			for href, tag := range u.links {
				if _, ok := out[href]; !ok {
					out[href] = tag
				}
			}
		}
	}
	return out
}
