package confluenceedit

import (
	"errors"
	"sort"
	"strings"
)

// Render returns the document as storage XHTML. Every byte outside a
// rewrite is the original source, so an unedited Doc renders to exactly the
// input it was parsed from (the EXT-05 round-trip law). There are two
// rewrite seams for edits (Task 3): a unit's out replaces that unit's span,
// and replaceRegion replaces an arbitrary region (a section body). Nothing
// else moves.
func (d *Doc) Render() string {
	edits := d.rewrites()
	var b strings.Builder
	b.Grow(len(d.src))
	cur := 0
	for _, e := range edits {
		if e.start < cur {
			// replaceRegion refuses overlaps; reaching this means a unit's
			// out was set inside a replaced region after the fact.
			panic("confluenceedit: overlapping rewrites")
		}
		b.WriteString(d.src[cur:e.start])
		b.WriteString(e.out)
		cur = e.end
	}
	b.WriteString(d.src[cur:])
	return b.String()
}

// rewrites lists every pending rewrite (rewritten units and replaced
// regions) sorted by position.
func (d *Doc) rewrites() []splice {
	edits := append([]splice(nil), d.splices...)
	for _, u := range d.units {
		if u.out != nil {
			edits = append(edits, splice{span{u.start, u.end}, *u.out})
		}
	}
	sort.SliceStable(edits, func(i, j int) bool { return edits[i].start < edits[j].start })
	return edits
}

var (
	errRegionBounds  = errors.New("confluenceedit: region out of bounds")
	errRegionOverlap = errors.New("confluenceedit: region overlaps another rewrite")
)

// replaceRegion is the whole-region rewrite seam: Render emits out in place
// of src[sp.start:sp.end]. It refuses a region outside the source or one
// that overlaps (or, for an empty region, touches at the same point)
// another pending rewrite, so no two edits can claim the same bytes.
func (d *Doc) replaceRegion(sp span, out string) error {
	if sp.start < 0 || sp.end < sp.start || sp.end > len(d.src) {
		return errRegionBounds
	}
	for _, e := range d.rewrites() {
		if conflicts(sp, e.span) {
			return errRegionOverlap
		}
	}
	d.splices = append(d.splices, splice{sp, out})
	return nil
}

func conflicts(a, b span) bool {
	return a.start < b.end && b.start < a.end || a.start == b.start
}
