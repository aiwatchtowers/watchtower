package confluenceedit

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

// A section never reaches past a layout element (R4/R5), so Text must show
// where one starts and ends: without the edge, a paragraph in the next
// layout cell reads as part of the section above it.
func TestTextMarksLayoutBoundaries(t *testing.T) {
	assert.Equal(t,
		"# Top\n\nt\n\n"+LayoutBoundary+"\n\n## Left\n\nl\n\n### Sub\n\ns\n\n"+LayoutBoundary+
			"\n\n## Right\n\nr\n\n"+LayoutBoundary+"\n\nafter",
		mustParse(t, layoutSrc).Text())

	emptyLayout := `<h2>H</h2><p>a</p><ac:layout><ac:layout-section ac:type="single"><ac:layout-cell><p></p></ac:layout-cell></ac:layout-section></ac:layout><p>b</p>`
	assert.Equal(t, "## H\n\na\n\n"+LayoutBoundary+"\n\nb", mustParse(t, emptyLayout).Text(),
		"an empty layout between two body paragraphs still ends the section")

	assert.Equal(t, "## Goals\n\ng1", mustParse(t, `<ac:layout><ac:layout-section ac:type="single"><ac:layout-cell><h2>Goals</h2><p>g1</p></ac:layout-cell></ac:layout-section></ac:layout>`).Text(),
		"no edge before the first or after the last block")
}

// layoutSpill pages are the two shapes where a heading's section (its
// region) ends at a layout edge while the text after the edge would read,
// without the edge, as more of the section.
var layoutSpill = map[string]struct{ src, rewritten string }{
	"next layout cell": {
		src:       `<ac:layout><ac:layout-section ac:type="two_equal"><ac:layout-cell><h2>Goals</h2><p>g1</p></ac:layout-cell><ac:layout-cell><p>g2</p></ac:layout-cell></ac:layout-section></ac:layout>`,
		rewritten: `<ac:layout><ac:layout-section ac:type="two_equal"><ac:layout-cell><h2>Goals</h2><p>g1 changed</p></ac:layout-cell><ac:layout-cell><p>g2</p></ac:layout-cell></ac:layout-section></ac:layout>`,
	},
	"layout after a body heading": {
		src:       `<h2>Goals</h2><p>g1</p><ac:layout><ac:layout-section ac:type="single"><ac:layout-cell><p>g2</p></ac:layout-cell></ac:layout-section></ac:layout>`,
		rewritten: `<h2>Goals</h2><p>g1 changed</p><ac:layout><ac:layout-section ac:type="single"><ac:layout-cell><p>g2</p></ac:layout-cell></ac:layout-section></ac:layout>`,
	},
}

// TestEXT05_SectionNeverWritesPastALayoutBoundary: a replace_section whose
// new body carries text from across a layout edge is refused, never applied
// as a copy of that text inside the section while the original stays where
// it is (the page would hold the paragraph twice, and the diff would show
// it as a plain addition).
func TestEXT05_SectionNeverWritesPastALayoutBoundary(t *testing.T) {
	for name, tc := range layoutSpill {
		t.Run(name, func(t *testing.T) {
			assert.Equal(t, "## Goals\n\ng1\n\n"+LayoutBoundary+"\n\ng2", mustParse(t, tc.src).Text())

			ee := applyErr(t, tc.src, sectionEdit("Goals", "g1 changed\n\ng2"))
			assert.Contains(t, ee.Error(), `"g2"`)
			assert.Contains(t, ee.Error(), LayoutBoundary)

			ee = applyErr(t, tc.src, sectionEdit("Goals", "g1 changed\n\n"+LayoutBoundary+"\n\ng2"))
			assert.Contains(t, ee.Error(), LayoutBoundary+" marks the edge of a page layout")

			ee = applyErr(t, tc.src, text("g1\n\n"+LayoutBoundary+"\n\ng2", "x"))
			assert.Contains(t, ee.Error(), "spans more than one block")

			ee = applyErr(t, tc.src, text("g1", "g1 "+LayoutBoundary))
			assert.Contains(t, ee.Error(), LayoutBoundary+" marks the edge of a page layout")

			out, changes := applyOK(t, tc.src, sectionEdit("Goals", "g1 changed"))
			assert.Equal(t, tc.rewritten, out)
			assert.Equal(t, 1, strings.Count(out, "<p>g2</p>"))
			assert.Equal(t, "g1", changes[0].Before, "the diff shows the section's real body")
		})
	}
}

// Text past the edge that the section ALSO holds is the section's own: the
// merge keeps it, nothing is refused.
func TestSectionMayRepeatTextItAlreadyHolds(t *testing.T) {
	src := `<h2>Goals</h2><p>same</p><p>g1</p><ac:layout><ac:layout-section ac:type="single"><ac:layout-cell><p>same</p></ac:layout-cell></ac:layout-section></ac:layout>`
	out, _ := applyOK(t, src, sectionEdit("Goals", "same\n\ng1 changed"))
	assert.Equal(t, `<h2>Goals</h2><p>same</p><p>g1 changed</p><ac:layout><ac:layout-section ac:type="single"><ac:layout-cell><p>same</p></ac:layout-cell></ac:layout-section></ac:layout>`, out)
}

// Text past the next same-or-higher heading is not read as the section's,
// so repeating it is an ordinary new paragraph.
func TestSectionRepeatOfTextUnderTheNextHeadingIsAllowed(t *testing.T) {
	src := `<ac:layout><ac:layout-section ac:type="two_equal"><ac:layout-cell><h2>Goals</h2><p>g1</p></ac:layout-cell><ac:layout-cell><h2>Other</h2><p>o</p></ac:layout-cell></ac:layout-section></ac:layout>`
	out, _ := applyOK(t, src, sectionEdit("Goals", "g1\n\no"))
	assert.Contains(t, out, `<h2>Goals</h2><p>g1</p><p>o</p></ac:layout-cell>`)
}
