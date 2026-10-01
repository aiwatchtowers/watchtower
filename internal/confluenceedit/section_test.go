package confluenceedit

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// headingIndex returns the block index of the heading whose text is text.
func headingIndex(t *testing.T, d *Doc, text string) int {
	t.Helper()
	for i, bl := range d.blocks {
		if bl.kind == blockHeading && unitText(bl.unit) == text {
			return i
		}
	}
	t.Fatalf("no heading %q", text)
	return -1
}

func region(t *testing.T, d *Doc, heading string) string {
	t.Helper()
	sp, err := d.sectionRegion(headingIndex(t, d, heading))
	require.NoError(t, err)
	return d.src[sp.start:sp.end]
}

const sectionsSrc = `<h1>Intro</h1>
<p>a</p>
<h2>Mid</h2>
<p>m1</p>
<h3>Deep</h3>
<p>d</p>
<table><tbody><tr><td><ac:link><ri:user ri:account-id="557058:00000000-0000-0000-0000-000000000009"/></ac:link></td></tr></tbody></table>
<p>see <ac:emoticon ac:name="smile"/></p>
<h2>Next</h2>
<p>n</p>
`

func TestSectionRegionMiddleIncludesNestedLevelsTablesAndMarkers(t *testing.T) {
	d, err := Parse(sectionsSrc)
	require.NoError(t, err)
	got := region(t, d, "Mid")
	assert.True(t, strings.HasPrefix(got, "\n<p>m1</p>\n<h3>Deep</h3>"), got)
	assert.True(t, strings.HasSuffix(got, "<p>see <ac:emoticon ac:name=\"smile\"/></p>\n"), got)
	assert.Contains(t, got, "<table>", "the section carries its rich table")
	for _, m := range d.Markers() {
		assert.Contains(t, got, m.Raw, "every marker of the section is inside its region")
	}
	assert.NotContains(t, got, "Next")
	assert.NotContains(t, got, "</h2>", "the region starts after the heading's end tag")
}

func TestSectionRegionNestedLevelEndsAtShallowerHeading(t *testing.T) {
	d, err := Parse(sectionsSrc)
	require.NoError(t, err)
	got := region(t, d, "Deep")
	assert.True(t, strings.HasPrefix(got, "\n<p>d</p>"), got)
	assert.True(t, strings.HasSuffix(got, "</p>\n"), got)
	assert.NotContains(t, got, "<h2>")
}

func TestSectionRegionLastSectionRunsToContainerEnd(t *testing.T) {
	d, err := Parse(sectionsSrc)
	require.NoError(t, err)
	assert.Equal(t, "\n<p>n</p>\n", region(t, d, "Next"))
	sp, err := d.sectionRegion(headingIndex(t, d, "Intro"))
	require.NoError(t, err)
	assert.Equal(t, len(sectionsSrc), sp.end, "an h1 with no later h1 runs to the body end")
}

const layoutSrc = `<h1>Top</h1><p>t</p><ac:layout><ac:layout-section ac:type="two_equal"><ac:layout-cell><h2>Left</h2><p>l</p><h3>Sub</h3><p>s</p></ac:layout-cell><ac:layout-cell><h2>Right</h2><p>r</p></ac:layout-cell></ac:layout-section></ac:layout><p>after</p>`

func TestSectionRegionClampedAtLayoutCellEnd(t *testing.T) {
	d, err := Parse(layoutSrc)
	require.NoError(t, err)
	assert.Equal(t, "<p>l</p><h3>Sub</h3><p>s</p>", region(t, d, "Left"),
		"the last section of a cell ends at the cell's content end, not in the next cell")
	assert.Equal(t, "<p>s</p>", region(t, d, "Sub"))
	assert.Equal(t, "<p>r</p>", region(t, d, "Right"))
}

func TestSectionRegionStopsBeforeANestedLayout(t *testing.T) {
	d, err := Parse(layoutSrc)
	require.NoError(t, err)
	assert.Equal(t, "<p>t</p>", region(t, d, "Top"),
		"a section never swallows a layout element")
}

func TestSectionRegionRejectsNonHeading(t *testing.T) {
	d, err := Parse(`<p>x</p>`)
	require.NoError(t, err)
	_, err = d.sectionRegion(0)
	require.ErrorIs(t, err, errNotHeading)
}

func TestBlockSpansAndContainers(t *testing.T) {
	d, err := Parse(layoutSrc)
	require.NoError(t, err)
	top := d.blocks[headingIndex(t, d, "Top")]
	assert.Equal(t, "<h1>Top</h1>", d.src[top.start:top.end], "a heading's span is its full element")
	left := d.blocks[headingIndex(t, d, "Left")]
	right := d.blocks[headingIndex(t, d, "Right")]
	assert.Equal(t, 0, top.container)
	assert.NotEqual(t, 0, left.container)
	assert.NotEqual(t, left.container, right.container, "each layout cell is its own container")
	after := d.blocks[len(d.blocks)-1]
	assert.Equal(t, "<p>after</p>", d.src[after.start:after.end])
	assert.Equal(t, 0, after.container, "leaving a layout returns to the body container")
	cell := d.containers[left.container]
	assert.Equal(t, "<h2>Left</h2><p>l</p><h3>Sub</h3><p>s</p>", d.src[cell.content.start:cell.content.end])
}

func TestReplaceRegionChangesOnlyThatRegion(t *testing.T) {
	d, err := Parse(sectionsSrc)
	require.NoError(t, err)
	sp, err := d.sectionRegion(headingIndex(t, d, "Mid"))
	require.NoError(t, err)
	require.NoError(t, d.replaceRegion(sp, "\n<p>X</p>\n"))
	assert.Equal(t, sectionsSrc[:sp.start]+"\n<p>X</p>\n"+sectionsSrc[sp.end:], d.Render())
}

func TestReplaceRegionRefusesOverlapsAndBadBounds(t *testing.T) {
	d, err := Parse(sectionsSrc)
	require.NoError(t, err)
	sp, err := d.sectionRegion(headingIndex(t, d, "Mid"))
	require.NoError(t, err)

	inside := d.units[3] // "m1", inside Mid's region
	require.Equal(t, "m1", inside.text)
	x := "edited"
	inside.out = &x
	require.ErrorIs(t, d.replaceRegion(sp, ""), errRegionOverlap, "a rewritten unit inside the region")
	inside.out = nil

	require.NoError(t, d.replaceRegion(sp, ""))
	require.ErrorIs(t, d.replaceRegion(span{sp.start + 1, sp.end + 1}, ""), errRegionOverlap)
	require.ErrorIs(t, d.replaceRegion(span{sp.start, sp.start}, ""), errRegionOverlap)
	require.ErrorIs(t, d.replaceRegion(span{-1, 0}, ""), errRegionBounds)
	require.ErrorIs(t, d.replaceRegion(span{5, 4}, ""), errRegionBounds)
	require.ErrorIs(t, d.replaceRegion(span{0, len(sectionsSrc) + 1}, ""), errRegionBounds)
	require.NoError(t, d.replaceRegion(span{0, 0}, "<p>lead</p>"), "a disjoint insert is fine")
	assert.Equal(t, "<p>lead</p>"+sectionsSrc[:sp.start]+sectionsSrc[sp.end:], d.Render())
}

func TestRenderPanicsOnAUnitRewrittenInsideAReplacedRegion(t *testing.T) {
	d, err := Parse(sectionsSrc)
	require.NoError(t, err)
	sp, err := d.sectionRegion(headingIndex(t, d, "Mid"))
	require.NoError(t, err)
	require.NoError(t, d.replaceRegion(sp, ""))
	x := "edited"
	d.units[3].out = &x
	assert.Panics(t, func() { d.Render() }, "two rewrites claiming the same bytes is a programming error, never a silent drop")
}
