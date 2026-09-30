package confluenceedit

import (
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Edit kinds (spec §3).
const (
	KindReplaceText    = "replace_text"
	KindReplaceSection = "replace_section"
)

// MaxEdits caps the edits of one Apply call.
const MaxEdits = 20

// Edit is one change to a page. replace_text uses Old and New;
// replace_section uses Heading and NewBody (markdown).
type Edit struct {
	Kind    string
	Old     string
	New     string
	Heading string
	NewBody string
}

// Change describes what one edit did, for the approval card: Before and
// After are the editable text of the touched unit or section body, and
// Removed lists the ⟦k:label⟧ tokens of the markers the edit deleted.
type Change struct {
	Kind    string
	Locator string
	Before  string
	After   string
	Removed []string
}

// EditError is an edit Apply refused; Index is the edit's position in the
// call and Msg says what to do about it.
type EditError struct {
	Index int
	Msg   string
}

func (e *EditError) Error() string {
	return fmt.Sprintf("edits[%d]: %s", e.Index, e.Msg)
}

// section is the new body a replace_section put under a heading: it
// replaces the heading's section region, whose original blocks are dead.
type section struct {
	region span
	body   []*block
	index  int               // the edit that wrote it (for render errors)
	links  map[string]string // link tags of the replaced content, reused by href
}

// Apply runs edits in order against the evolving document — each edit sees
// the text the previous ones produced — and returns the new storage XHTML
// with one Change per edit. d itself is never modified. Any refusal is an
// *EditError naming the edit; nothing is partially applied.
//
// Only content an edit touches is re-serialised: a unit whose text an edit
// changed (its enclosing tag and every other byte of the page are kept),
// or a replaced section body. A unit edited back to its original text is
// not re-emitted at all.
func Apply(d *Doc, edits []Edit) (string, []Change, error) {
	switch {
	case len(edits) == 0:
		return "", nil, &EditError{Index: 0, Msg: "no edits given"}
	case len(edits) > MaxEdits:
		return "", nil, &EditError{Index: MaxEdits, Msg: fmt.Sprintf("too many edits (%d); at most %d per call", len(edits), MaxEdits)}
	}
	a := newApplier(d)
	changes := make([]Change, 0, len(edits))
	for i, e := range edits {
		a.index = i
		c, err := a.apply(e)
		if err != nil {
			return "", nil, &EditError{Index: i, Msg: err.Error()}
		}
		changes = append(changes, c)
	}
	out, err := a.render()
	if err != nil {
		return "", nil, err
	}
	return out, changes, nil
}

// applier holds the evolving state: a working clone of the Doc whose units
// carry their current text and marks, and whose heading blocks carry the
// section bodies written so far.
type applier struct {
	orig    *Doc
	d       *Doc
	index   int
	tokens  map[string]int // marker token -> ordinal
	isBlock map[int]bool   // markers that are whole blocks (tables, macros, ...)
}

func newApplier(d *Doc) *applier {
	a := &applier{orig: d, d: d.clone(), tokens: map[string]int{}, isBlock: map[int]bool{}}
	for _, m := range d.markers {
		a.tokens[m.token()] = m.Ordinal
	}
	for _, bl := range d.blocks {
		if bl.kind == blockMarker {
			a.isBlock[bl.marker] = true
		}
	}
	return a
}

func (a *applier) apply(e Edit) (Change, error) {
	switch e.Kind {
	case KindReplaceText:
		return a.replaceText(e.Old, e.New)
	case KindReplaceSection:
		return a.replaceSection(e.Heading, e.NewBody)
	}
	return Change{}, fmt.Errorf("unknown edit kind %q; use %q or %q", e.Kind, KindReplaceText, KindReplaceSection)
}

// clone copies the Doc deeply enough for Apply to mutate units and blocks:
// src, containers and markers are shared read-only.
func (d *Doc) clone() *Doc {
	nd := *d
	nd.splices = nil
	units := make(map[*unit]*unit, len(d.units))
	nd.units = make([]*unit, len(d.units))
	for i, u := range d.units {
		c := *u
		c.marks = append([]mark(nil), u.marks...)
		c.out = nil
		nd.units[i] = &c
		units[u] = &c
	}
	nd.blocks = make([]*block, len(d.blocks))
	for i, bl := range d.blocks {
		nd.blocks[i] = bl.cloneWith(units)
	}
	return &nd
}

func (bl *block) cloneWith(units map[*unit]*unit) *block {
	c := *bl
	c.unit = units[bl.unit]
	c.items = make([]listItem, len(bl.items))
	for i, it := range bl.items {
		c.items[i] = listItem{depth: it.depth, bullet: it.bullet, paras: mapUnits(it.paras, units)}
	}
	c.rows = make([][]*unit, len(bl.rows))
	for i, row := range bl.rows {
		c.rows[i] = mapUnits(row, units)
	}
	return &c
}

func mapUnits(us []*unit, units map[*unit]*unit) []*unit {
	out := make([]*unit, len(us))
	for i, u := range us {
		out[i] = units[u]
	}
	return out
}

// editUnits lists a block's editable units in document order.
func (bl *block) editUnits() []*unit {
	var out []*unit
	add := func(u *unit) {
		if u != nil {
			out = append(out, u)
		}
	}
	add(bl.unit)
	for _, it := range bl.items {
		for _, u := range it.paras {
			add(u)
		}
	}
	for _, row := range bl.rows {
		for _, u := range row {
			add(u)
		}
	}
	return out
}

// expand lists the live blocks of bs in evolving-document order: dead
// blocks dropped, each rewritten section's body right after its heading.
func expand(bs []*block) []*block {
	var out []*block
	for _, bl := range bs {
		if bl.dead {
			continue
		}
		out = append(out, bl)
		if bl.section != nil {
			out = append(out, bl.section.body...)
		}
	}
	return out
}

// slot is one editable unit of the evolving document with the heading it
// sits under ("" before the first heading).
type slot struct {
	u       *unit
	heading string
}

func (a *applier) slots() []slot {
	var out []slot
	heading := ""
	for _, bl := range expand(a.d.blocks) {
		if bl.kind == blockHeading {
			heading = unitText(bl.unit)
		}
		for _, u := range bl.editUnits() {
			out = append(out, slot{u: u, heading: heading})
		}
	}
	return out
}

// text is the evolving document's editable text (Doc.Text of the result).
func (a *applier) text() string {
	return a.blocksText(expand(a.d.blocks))
}

func (a *applier) blocksText(bs []*block) string {
	parts := make([]string, 0, len(bs))
	for _, bl := range bs {
		if s := a.d.blockText(bl); s != "" {
			parts = append(parts, s)
		}
	}
	return strings.Join(parts, "\n\n")
}

// present lists every marker currently in the evolving document.
func (a *applier) present() map[int]bool {
	return blockMarks(expand(a.d.blocks))
}

// blockMarks lists the markers carried by bs: marker blocks and the real
// markers of their units.
func blockMarks(bs []*block) map[int]bool {
	out := map[int]bool{}
	for _, bl := range bs {
		if bl.kind == blockMarker {
			out[bl.marker] = true
		}
		for _, u := range bl.editUnits() {
			for _, m := range u.marks {
				out[m.k] = true
			}
		}
	}
	return out
}

// removedTokens lists, in ordinal order, the tokens of the markers in
// before that are not in after.
func (a *applier) removedTokens(before, after map[int]bool) []string {
	var ks []int
	for k := range before {
		if !after[k] {
			ks = append(ks, k)
		}
	}
	sort.Ints(ks)
	out := make([]string, len(ks))
	for i, k := range ks {
		out[i] = a.orig.markers[k-1].token()
	}
	return out
}

func locator(heading string) string {
	if heading == "" {
		return "text at the top of the page"
	}
	return "text in " + heading
}

// render assembles the result on the working clone: changed live units get
// their re-serialised XHTML, then every section body replaces its region.
// Unit rewrites are all set before any region is claimed, so replaceRegion
// sees them and refuses a conflict — returned as an *EditError, never the
// Render panic.
func (a *applier) render() (string, error) {
	orig := make(map[*unit]*unit, len(a.d.units))
	for i, u := range a.d.units {
		orig[u] = a.orig.units[i]
	}
	var sections []*section
	for _, bl := range a.d.blocks {
		if bl.dead {
			continue
		}
		for _, u := range bl.editUnits() {
			if o := orig[u]; o != nil && unitChanged(o, u) {
				out := a.unitXHTML(u, u.links)
				u.out = &out
			}
		}
		if bl.section != nil {
			sections = append(sections, bl.section)
		}
	}
	for _, s := range sections {
		if err := a.d.replaceRegion(s.region, a.sectionXHTML(s)); err != nil {
			return "", &EditError{Index: s.index, Msg: "internal conflict writing the section: " + err.Error()}
		}
	}
	return a.d.Render(), nil
}

func unitChanged(o, u *unit) bool {
	if o.text != u.text || len(o.marks) != len(u.marks) {
		return true
	}
	for i := range o.marks {
		if o.marks[i] != u.marks[i] {
			return true
		}
	}
	return false
}

// sectionXHTML is a section body's storage, keeping the region's leading
// and trailing whitespace so the bytes around it read as before.
func (a *applier) sectionXHTML(s *section) string {
	src := a.d.src[s.region.start:s.region.end]
	lead := src[:len(src)-len(strings.TrimLeft(src, " \t\r\n"))]
	trail := ""
	if len(lead) < len(src) {
		trail = src[len(strings.TrimRight(src, " \t\r\n")):]
	}
	var b strings.Builder
	b.WriteString(lead)
	for _, bl := range s.body {
		b.WriteString(a.blockXHTML(bl, s.links))
	}
	b.WriteString(trail)
	return b.String()
}

var errEmpty = errors.New("empty edit")

// tokenOrdinal is the ordinal a token-shaped string claims ("⟦12:..." → 12),
// or 0.
func tokenOrdinal(tok string) int {
	body := strings.TrimPrefix(tok, markerOpen)
	digits := body[:len(body)-len(strings.TrimLeft(body, "0123456789"))]
	k, err := strconv.Atoi(digits)
	if err != nil {
		return 0
	}
	return k
}
