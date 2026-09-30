package confluenceedit

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Review round 1, finding 1 (carry (e)): a NUL inside page <code> never
// reaches unit text, so it can neither crash the rewrite (an index out of
// range on the marker table) nor forge a hole that duplicates a real
// marker.
func TestApplyNULInPageCodeIsNotAMarkerHole(t *testing.T) {
	var out string
	assert.NotPanics(t, func() {
		out, _ = applyOK(t, "<p>a <code>x\x005\x00y</code> b</p>", text("b", "c"))
	})
	assert.Equal(t, "<p>a <code>x�5�y</code> c</p>", out)

	out, _ = applyOK(t, "<p><ac:emoticon ac:name=\"s\"/> <code>x\x001\x00y</code> b</p>", text("b", "c"))
	assert.Equal(t, 1, strings.Count(out, `<ac:emoticon ac:name="s"/>`), "no duplicated marker")
	assert.Contains(t, out, "<code>x�1�y</code>")
}

func TestInlineHoleIsBoundsChecked(t *testing.T) {
	a := newApplier(mustParse(t, `<p><ac:emoticon ac:name="s"/></p>`))
	p := &inlineParser{a: a, failedLink: map[int]bool{}}
	assert.Equal(t, "�99� �0� �x&lt;� �", p.parse("\x0099\x00 \x000\x00 \x00x<\x00 \x00", 0, 0))
	assert.Equal(t, `<ac:emoticon ac:name="s"/>`, p.parse("\x001\x00", 0, 0))
}

// Ruling R6 (finding 2): page text that reads as markdown would silently
// turn into formatting in the untouched part of a rewritten unit; such a
// unit is refused.
func TestApplyRefusesPassageThatReadsAsFormatting(t *testing.T) {
	for name, src := range map[string]string{
		"dunder and powers": `<p>call __init__ and 2**10 vs 3**4 here</p>`,
		"literal link":      `<p>see [1](2) here</p>`,
		"intraword italic":  `<p>a<em>b</em>c here</p>`,
		"literal code":      "<p>use `x` here</p>",
		"literal strike":    `<p>~~old~~ here</p>`,
	} {
		t.Run(name, func(t *testing.T) {
			ee := applyErr(t, src, text("here", "there"))
			assert.Contains(t, ee.Msg, "characters that read as formatting")
			assert.Contains(t, ee.Msg, "replace_section")
		})
	}
}

func TestApplyAllowsFormattedParagraph(t *testing.T) {
	src := `<p>x <b>bold</b> <i>it</i> <del>d</del> <code>c</code> <a href="https://example.com/l">l</a> <span>s</span> here</p>`
	out, _ := applyOK(t, src, text("here", "there"))
	assert.Equal(t, `<p>x <strong>bold</strong> <em>it</em> <s>d</s> <code>c</code> <a href="https://example.com/l">l</a> s there</p>`, out)

	out, _ = applyOK(t, `<p>a <strong></strong> b <em> </em> here</p>`, text("here", "there"))
	assert.Equal(t, `<p>a b there</p>`, out, "empty emphasis has no text form either way; not a mismatch")

	out, _ = applyOK(t, `<p>x y here</p>`, text("here", "**there**"), text("x", "_z_"))
	assert.Equal(t, `<p><em>z</em> y <strong>there</strong></p>`, out,
		"formatting an earlier edit wrote is intent, not page text at risk")
}

// Finding 3: model text is made storable.
func TestApplyCleansXMLIllegalModelText(t *testing.T) {
	out, _ := applyOK(t, `<p>b</p>`, text("b", "c\x01d\x0Be\xffg\x00h\tz"))
	assert.Equal(t, "<p>c�d�e�g�h\tz</p>", out)
	out, _ = applyOK(t, sectionsSrc, sectionEdit("Next", "a\x02b\n\n```\nc\x1fd\xfe\n```"))
	assert.Contains(t, out, "<p>a�b</p>")
	assert.Contains(t, out, "<![CDATA[c�d�]]>")
}

// Finding 4: only http, https, mailto, relative and fragment hrefs become
// new links; the page's own links keep their tags whatever the scheme.
func TestApplyHrefSchemeAllowlist(t *testing.T) {
	for href, link := range map[string]bool{
		"https://example.com/a": true, "http://example.com": true, "mailto:a@example.com": true,
		"/wiki/page": true, "page?x=1": true, "#top": true,
		"javascript:alert(1)": false, " JavaScript:alert(1)": false, "data:text/html,x": false,
		"vbscript:x": false, "file:///etc/passwd": false,
	} {
		out, _ := applyOK(t, `<p>b</p>`, text("b", "[x]("+href+")"))
		if link {
			assert.Equal(t, `<p><a href="`+attrEscaper.Replace(href)+`">x</a></p>`, out, href)
		} else {
			assert.NotContains(t, out, "<a", href)
			assert.Equal(t, "<p>"+textEscaper.Replace("[x]("+href+")")+"</p>", out, href)
		}
	}
	out, _ := applyOK(t, `<p><a href="tel:+100">call</a> here</p>`, text("here", "there"))
	assert.Equal(t, `<p><a href="tel:+100">call</a> there</p>`, out)
}

// Finding 5 (carry (a)): a literal token stays literal even after an
// earlier edit removed the real marker it names.
func TestApplyLiteralTokenNotResurrectedAfterRemoval(t *testing.T) {
	src := `<p>x ⟦1:emoticon smile⟧ y</p><p><ac:emoticon ac:name="smile"/> z</p>`
	out, changes := applyOK(t, src,
		text("⟦1:emoticon smile⟧ z", "z"),
		text("x ⟦1:emoticon smile⟧ y", "w ⟦1:emoticon smile⟧ y"))
	assert.Equal(t, `<p>w ⟦1:emoticon smile⟧ y</p><p>z</p>`, out)
	assert.Equal(t, []string{"⟦1:emoticon smile⟧"}, changes[0].Removed)
	assert.Empty(t, changes[1].Removed)
}

// Finding 6: a marker deleted by one edit and put back by a later one was
// moved, not removed.
func TestApplyMovedMarkerIsNotReportedRemoved(t *testing.T) {
	src := `<p>a <ac:emoticon ac:name="s"/> b</p><p>c</p>`
	out, changes := applyOK(t, src, text("a ⟦1:emoticon s⟧ b", "a b"), text("c", "c ⟦1:emoticon s⟧"))
	assert.Equal(t, `<p>a b</p><p>c <ac:emoticon ac:name="s"/></p>`, out)
	require.Len(t, changes, 2)
	assert.Empty(t, changes[0].Removed)
	assert.Empty(t, changes[1].Removed)

	_, changes = applyOK(t, sectionsSrc, sectionEdit("Mid", "x"), sectionEdit("Next", "⟦2:emoticon smile⟧"))
	assert.Equal(t, []string{"⟦1:table 1x1⟧"}, changes[0].Removed, "the table is gone; the emoticon moved")
}

// Finding 7: a heading swallowed by an earlier replace_section names that
// edit.
func TestApplySubsumedHeadingNamesTheEdit(t *testing.T) {
	src := `<h1>H</h1><p>a</p><h2>S</h2><p>b</p>`
	ee := applyErr(t, src, sectionEdit("H", "new"), sectionEdit("S", "x"))
	assert.Equal(t, 1, ee.Index)
	assert.Contains(t, ee.Msg, "inside the section replaced by edits[0]")
}
