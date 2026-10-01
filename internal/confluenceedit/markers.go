package confluenceedit

import (
	"fmt"
	"regexp"
	"sort"
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
	case known && c.inSpan[k]:
		return true, nil
	case strings.Contains(c.literal, tok):
		return false, nil // literal text already on the page
	case known && !c.present[k]:
		return true, nil // e.g. put back after an earlier edit removed it
	case known:
		return false, fmt.Errorf("duplicate marker %s: it already appears elsewhere on the page, and each marker can appear only once", tok)
	}
	return false, a.unknownMarker(tok)
}

func (a *applier) unknownMarker(tok string) error {
	if tok == LayoutBoundary {
		return errBoundaryInText
	}
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

// blocksLinks merges the original link tags of bs's units, and lists the
// hrefs whose links carry different start tags (see unit.clashes).
func blocksLinks(bs []*block) (map[string]string, map[string]bool) {
	out, clashes := map[string]string{}, map[string]bool{}
	for _, bl := range bs {
		for _, u := range bl.editUnits() {
			for href := range u.clashes {
				clashes[href] = true
			}
			for href, tag := range u.links {
				if first, ok := out[href]; !ok {
					out[href] = tag
				} else if first != tag {
					clashes[href] = true
				}
			}
		}
	}
	return out, clashes
}

// linkClashErr refuses a rewrite of text linking to href, one of the
// addresses whose links carry different start tags.
func linkClashErr(href string) error {
	return fmt.Errorf("this passage has two links to %s with different link settings (e.g. one shown as a card); a rewrite cannot keep them apart — keep it unchanged, or edit it in Confluence", href)
}

// firstClash is the first href of clashes (sorted, for a stable message)
// that text links to, or "".
func firstClash(text string, clashes map[string]bool) string {
	hrefs := make([]string, 0, len(clashes))
	for href := range clashes {
		hrefs = append(hrefs, href)
	}
	sort.Strings(hrefs)
	for _, href := range hrefs {
		if strings.Contains(text, "]("+href+")") {
			return href
		}
	}
	return ""
}
