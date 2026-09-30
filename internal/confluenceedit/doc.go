// Package confluenceedit converts Confluence storage-format XHTML into an
// editable-text view the assistant can read and edit, and back (spec
// docs/superpowers/specs/2026-09-30-confluence-page-editing-design.md §3).
// It is a pure package: no DB, no network.
//
// The model is byte-oriented. Parse never rebuilds the document: it locates
// the editable "units" (the inner content of a heading, a paragraph, a list
// item's text, a plain table cell, a code macro's body) as byte spans of the
// source, and everything outside those spans is kept as the original bytes.
// Render reassembles the source from those spans, so the round-trip law
// Render(Parse(x)) == x holds for every input byte for byte (canonical form
// == original; there is no normalisation step to justify). Anything the
// editable text cannot express — mentions, macros, images, emoticons, rich
// tables, ... — becomes a marker ⟦k:label⟧ whose Raw is the element's exact
// source slice.
package confluenceedit

import (
	"errors"
	"strconv"
)

// Marker syntax: ⟦k:label⟧, k a per-page ordinal starting at 1.
const (
	markerOpen  = "⟦"
	markerClose = "⟧"
)

// maxDepth bounds element nesting, matching golang.org/x/net/html's own
// open-element cap. It keeps every recursive walk in this package bounded.
const maxDepth = 512

// ErrTooDeep is returned by Parse for storage nested deeper than maxDepth
// elements. Such a page is not editable; there is no useful partial model.
var ErrTooDeep = errors.New("confluenceedit: storage nests deeper than 512 elements")

// Marker is one rich element the editable text cannot express, shown in
// Doc.Text() as ⟦Ordinal:Label⟧. Raw is the element's exact storage bytes.
type Marker struct {
	Ordinal int
	Label   string
	Raw     string
}

// token is the marker as it appears in the editable text.
func (m Marker) token() string {
	return markerOpen + strconv.Itoa(m.Ordinal) + ":" + m.Label + markerClose
}

// Doc is a parsed storage document.
type Doc struct {
	src     string
	blocks  []*block // top-level blocks in document order (layouts flattened)
	units   []*unit  // every editable unit, sorted by span, non-overlapping
	markers []Marker // ordinal k at index k-1
}

// Markers returns a copy of the document's markers in ordinal order.
func (d *Doc) Markers() []Marker {
	return append([]Marker(nil), d.markers...)
}

type blockKind int

const (
	blockParagraph blockKind = iota // a <p> or a top-level run of inline content
	blockHeading
	blockList
	blockTable // a plain table, rendered as a pipe table
	blockCode  // a code/noformat macro with a plain-text body
	blockMarker
)

// block is one top-level unit of layout in the editable text. Which fields
// are set depends on kind.
type block struct {
	kind   blockKind
	level  int        // blockHeading: 1..6
	lang   string     // blockCode: the language parameter, may be ""
	unit   *unit      // blockParagraph, blockHeading, blockCode
	items  []listItem // blockList, flattened in document order
	rows   [][]*unit  // blockTable; a nil cell is an empty self-closed cell
	marker int        // blockMarker: the ordinal
}

// listItem is one <li>, flattened with its nesting depth.
type listItem struct {
	depth  int
	bullet string  // "-" or "N."
	paras  []*unit // the item's own text: first line, then continuation lines
}

type unitKind int

const (
	unitInline unitKind = iota // inline markdown with markers
	unitCode                   // verbatim code (a CDATA body in storage)
)

// unit is one editable span of the source. [start,end) is the span that a
// rewrite replaces; everything around it (the enclosing tag and its
// attributes included) keeps its bytes.
type unit struct {
	kind       unitKind
	start, end int
	text       string // the editable text of the span

	// out is the seam for edits (Task 3): when non-nil, Render emits *out in
	// place of src[start:end]. Parse never sets it.
	out *string
}
