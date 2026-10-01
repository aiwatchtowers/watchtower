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
	src         string
	blocks      []*block    // top-level blocks in document order (layouts flattened)
	containers  []container // container 0 is the page body; the rest are layout elements
	units       []*unit     // every editable unit, sorted by span, non-overlapping
	markers     []Marker    // ordinal k at index k-1
	markerSpans []span      // markerSpans[k-1] is where marker k's Raw sits in src
	splices     []splice    // whole-region rewrites (the replace-region seam)
}

// mark is one real marker inside a unit's text: the token for marker k
// starts at byte offset at.
type mark struct {
	at int
	k  int
}

// span is a [start,end) byte range of the source.
type span struct{ start, end int }

// container is a region blocks live in: the page body (id 0) or the content
// of one layout element (ac:layout, ac:layout-section, ac:layout-cell).
// Containers are numbered in document order; a section never leaves its
// heading's container.
type container struct {
	parent    int // -1 for the page body
	elemStart int // where the layout element's start tag begins (0 for the body)
	content   span
}

// splice replaces src[start:end] with out in Render.
type splice struct {
	span
	out string
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
	kind      blockKind
	span                 // the block's whole source bytes (a heading: its full element)
	container int        // index into Doc.containers
	level     int        // blockHeading: 1..6
	lang      string     // blockCode: the language parameter, may be ""
	unit      *unit      // blockParagraph, blockHeading, blockCode
	items     []listItem // blockList, flattened in document order
	rows      [][]*unit  // blockTable; a nil cell is an empty self-closed cell
	marker    int        // blockMarker: the ordinal

	// Edit state (Task 3), only ever set on Apply's working clone or on
	// blocks Apply builds from markdown.
	dead    bool     // inside a region a replace_section rewrote
	section *section // blockHeading: its body, rewritten by a replace_section
	header  bool     // a markdown table: the first row is a header row
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
	ctx        inlineCtx
	start, end int
	text       string // the editable text of the span

	// marks are the real markers inside text, by byte offset. A token-shaped
	// string in text that is not in marks is literal page text.
	marks []mark
	// other: the span holds a comment, stray end tag or other inert token
	// that a rewrite from text would drop, so the unit is not rewritable.
	other bool
	// links maps each link href in text to its original start tag, so a
	// rewrite keeps the link's other attributes.
	links map[string]string
	// clashes lists the hrefs of links whose start tags differ (a card and
	// a plain link to one address): links can keep only one tag per href,
	// so a rewrite would give every such link the first one's.
	clashes map[string]bool

	// out is the seam for edits (Task 3): when non-nil, Render emits *out in
	// place of src[start:end]. Parse never sets it.
	out *string
}
