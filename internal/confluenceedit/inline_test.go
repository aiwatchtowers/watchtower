package confluenceedit

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestAnchorWithoutHrefDoesNotOrphanChildMarker: an <a> with no href is a
// marker whose Raw covers its children, so no marker may be minted for a
// child first (its token would never appear in Text()).
func TestAnchorWithoutHrefDoesNotOrphanChildMarker(t *testing.T) {
	src := `<p>x <a name="top"><ac:emoticon ac:name="a"/></a> y</p>`
	d, err := Parse(src)
	require.NoError(t, err)
	require.Len(t, d.Markers(), 1)
	assert.Equal(t, `<a name="top"><ac:emoticon ac:name="a"/></a>`, d.Markers()[0].Raw)
	assert.Equal(t, "x ⟦1:anchor top⟧ y", d.Text())
	assertMarkerInvariants(t, d)
}

func TestLinkWithHrefKeepsChildMarker(t *testing.T) {
	d, err := Parse(`<p><a href="https://example.com/x"><ac:emoticon ac:name="a"/> go</a></p>`)
	require.NoError(t, err)
	assert.Equal(t, "[⟦1:emoticon a⟧ go](https://example.com/x)", d.Text())
	assertMarkerInvariants(t, d)
}

func TestCodeSpanWhitespaceVerbatim(t *testing.T) {
	d, err := Parse("<p>a   <code>x  \t y </code>   b</p>")
	require.NoError(t, err)
	assert.Equal(t, "a `x  \t y ` b", d.Text(), "code-span spaces survive; only prose collapses")
}

func TestCodeSpanPaddedWhenSpacesBothEnds(t *testing.T) {
	d, err := Parse("<p><code> x </code></p>")
	require.NoError(t, err)
	assert.Equal(t, "`  x  `", d.Text(), "CommonMark strips one space each side, so pad one")
}

func TestCodeSpanLineTerminatorsBecomeSpaces(t *testing.T) {
	d, err := Parse("<p><code>a\nb</code></p>")
	require.NoError(t, err)
	assert.Equal(t, "`a b`", d.Text())
}

func TestNULInTextCannotForgeACodeHole(t *testing.T) {
	d, err := Parse("<p>\x000\x00 <code>c</code></p>")
	require.NoError(t, err)
	assert.Equal(t, "�0� `c`", d.Text())
}

// TestInvalidUTF8LabelMatchesItsToken is the fuzz finding of fix round 1:
// the unit text is rebuilt rune by rune, so a label must be valid UTF-8
// or its token never appears in Text().
func TestInvalidUTF8LabelMatchesItsToken(t *testing.T) {
	d, err := Parse("<h1 ><C>\xbb")
	require.NoError(t, err)
	assert.Equal(t, "# ⟦1:c �⟧", d.Text())
	assertMarkerInvariants(t, d)
}

func TestOrderedListStart(t *testing.T) {
	d, err := Parse(`<ol start="5"><li>a</li><li>b</li></ol><ol start="x"><li>c</li></ol><ul start="3"><li>d</li></ul>`)
	require.NoError(t, err)
	assert.Equal(t, "5. a\n6. b\n\n1. c\n\n- d", d.Text())
}
