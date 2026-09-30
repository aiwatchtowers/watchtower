package confluenceedit

import (
	"slices"
	"strings"
	"unicode"
)

// The formatting-skeleton guard (rulings R6, R7). A rewrite re-serialises a
// whole unit from its editable text, and that text is not escaped: page
// text that merely looks like markdown ("__init__", "2**10 vs 3**4",
// "[1](2)") would silently turn into formatting in the untouched part of
// the unit, and an intraword <em> would go flat — changes the approval
// card's text diff cannot show. So before a unit is rewritten, its
// ORIGINAL editable text is round-tripped through the same markdown→XHTML
// path, and the formatting skeleton of the result must equal the skeleton
// of the unit's actual storage.
//
// The skeleton is ORDERED (R7): the sequence, in document order, of every
// formatting element as (canonical tag — strong/em/s/code, with b→strong,
// i→em, del/strike→s — or "a"+href; its flattened visible text). A count
// would let a lost tag and a gained tag of the same kind cancel out
// ("a<em>b</em>c and _d_" → "a_b_c and <em>d</em>"); the sequence cannot.
//
// The original text is the right input: what an earlier edit in the same
// call wrote is the model's intent, not page text at risk.

// roundTrips reports whether u (a working-clone unit) may be rewritten.
// Code units and units Apply built from markdown have nothing to lose.
func (a *applier) roundTrips(u *unit) bool {
	o := a.origOf[u]
	if o == nil || o.kind != unitInline {
		return true
	}
	ok, seen := a.faithful[o]
	if !seen {
		want := skeletonOf(a.orig.src[o.start:o.end])
		got := skeletonOf(a.inlineXHTML(o.text, o.marks, o.links))
		ok = want != nil && got != nil && slices.Equal(want, got)
		a.faithful[o] = ok
	}
	return ok
}

// skeletonOf is the ordered formatting skeleton of an inline XHTML
// fragment, or nil when it nests too deep to parse.
func skeletonOf(xhtml string) []string {
	root, err := parseTree(xhtml)
	if err != nil {
		return nil
	}
	acc := []string{}
	skeleton(root.children, &acc)
	return acc
}

var emphasisTag = map[string]string{
	"strong": "strong", "b": "strong", "em": "em", "i": "em",
	"s": "s", "del": "s", "strike": "s",
}

// skeleton mirrors the inliner's reading: emphasis with visible content,
// a text-only <code> with content, an <a href> with visible text, and the
// content of an attribute-less <span> count; every other element is a
// marker whose inside is kept verbatim and so is not looked into.
func skeleton(ns []*node, acc *[]string) {
	for _, n := range ns {
		if n.typ == nodeElement {
			skeletonElement(n, acc)
		}
	}
}

func skeletonElement(n *node, acc *[]string) {
	switch {
	case emphasisTag[n.name] != "":
		if visible(n) {
			*acc = append(*acc, emphasisTag[n.name]+"\x00"+flatVisible(n))
		}
		skeleton(n.children, acc)
	case n.name == "code":
		if onlyText(n) && codeLines.Replace(plainText(n)) != "" {
			*acc = append(*acc, "code\x00"+flatVisible(n))
		}
	case n.name == "a":
		if href := n.attr("href"); href != "" && visible(n) {
			*acc = append(*acc, "a "+noNUL.Replace(href)+"\x00"+flatVisible(n))
			skeleton(n.children, acc)
		}
	case n.name == "span" && len(n.attrs) == 0:
		skeleton(n.children, acc)
	}
}

// flatVisible is n's text with whitespace collapsed and trimmed (the
// inliner moves edge whitespace out of emphasis, and a code span's line
// break reads as a space) and NUL read as U+FFFD, as the inliner reads it;
// a marker inside counts as one opaque unit.
func flatVisible(n *node) string {
	var b strings.Builder
	flatInto(n, &b)
	return strings.Join(strings.FieldsFunc(noNUL.Replace(b.String()), unicode.IsSpace), " ")
}

func flatInto(n *node, b *strings.Builder) {
	for _, ch := range n.children {
		switch {
		case ch.typ == nodeText || ch.typ == nodeCDATA:
			b.WriteString(ch.text)
		case ch.typ != nodeElement:
		case ch.name == "br":
			b.WriteByte(' ')
		case emphasisTag[ch.name] != "" || ch.name == "span" || ch.name == "a" || ch.name == "code":
			flatInto(ch, b)
		default:
			b.WriteString(" \x01 ")
		}
	}
}

// visible reports content that renders as something in the editable text.
func visible(n *node) bool {
	for _, ch := range n.children {
		switch {
		case ch.typ == nodeText || ch.typ == nodeCDATA:
			if strings.TrimFunc(asciiSpace.Replace(ch.text), unicode.IsSpace) != "" {
				return true
			}
		case ch.typ != nodeElement || ch.name == "br":
		case emphasisTag[ch.name] != "" || ch.name == "span" && len(ch.attrs) == 0:
			if visible(ch) {
				return true
			}
		default:
			return true
		}
	}
	return false
}
