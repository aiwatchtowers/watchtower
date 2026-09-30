package confluenceedit

import "errors"

var errNotHeading = errors.New("confluenceedit: block is not a heading")

// sectionRegion is the byte region a section rewrite replaces for the
// heading at d.blocks[i]: from the byte after the heading's end tag to the
// first of
//   - the start of the next heading block in the SAME container with a
//     level <= the heading's (a deeper heading belongs to the section),
//   - the start of the next layout element nested directly in that
//     container (a section never swallows or splits a layout: replacing it
//     would delete the layout's structure, which no edit is shown to do),
//   - the end of the container's content.
//
// It never crosses a container boundary: a heading in a layout cell has a
// section that ends at that cell's end, whatever follows in the next cell.
// Everything between (inter-block whitespace, tables, markers, ...) is in
// the region.
func (d *Doc) sectionRegion(i int) (span, error) {
	h := d.blocks[i]
	if h.kind != blockHeading {
		return span{}, errNotHeading
	}
	end := d.containers[h.container].content.end
	for _, bl := range d.blocks[i+1:] {
		if bl.container == h.container && bl.kind == blockHeading && bl.level <= h.level {
			end = min(end, bl.start)
			break
		}
	}
	for _, c := range d.containers {
		if c.parent == h.container && c.elemStart >= h.end {
			end = min(end, c.elemStart)
			break // containers are in document order
		}
	}
	return span{h.end, end}, nil
}
