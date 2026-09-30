package confluenceedit

import "strings"

// Render returns the document as storage XHTML. Bytes outside the editable
// units are always the original source; an untouched unit re-emits its own
// source span, so an unedited Doc renders to exactly the input it was
// parsed from (the EXT-05 round-trip law). A unit rewritten through the
// out seam emits its replacement in place of its span and nothing else
// moves.
func (d *Doc) Render() string {
	var b strings.Builder
	b.Grow(len(d.src))
	cur := 0
	for _, u := range d.units {
		b.WriteString(d.src[cur:u.start])
		if u.out != nil {
			b.WriteString(*u.out)
		} else {
			b.WriteString(d.src[u.start:u.end])
		}
		cur = u.end
	}
	b.WriteString(d.src[cur:])
	return b.String()
}
