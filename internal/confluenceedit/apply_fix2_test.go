package confluenceedit

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// Ruling R7: the skeleton is ordered, with each element's visible text, so
// a lost tag and a gained tag of the same kind (or a permutation) cannot
// cancel out.
func TestApplyOrderedSkeletonRefusesCancellingChanges(t *testing.T) {
	for name, src := range map[string]string{
		"lost em, gained em":          `<p>a<em>b</em>c and _d_ here</p>`,
		"lost strong, gained strong":  `<p>**a <strong>b</strong> c** here</p>`,
		"same tags, different order":  `<p>_x_ <strong>x</strong> a<em>x</em>b here</p>`,
		"lost link, gained same href": `<p><a href="https://example.com/a">a</a> [b](https://example.com/a) here</p>`,
	} {
		t.Run(name, func(t *testing.T) {
			ee := applyErr(t, src, text("here", "there"))
			assert.Contains(t, ee.Msg, "characters that read as formatting")
		})
	}
}

func TestApplyOrderedSkeletonKeepsOrdinaryParagraphsEditable(t *testing.T) {
	for name, src := range map[string]string{
		"bold link code with _":    `<p><strong>b</strong> <a href="https://example.com/a_b_c?x=1_2">l_x</a> <code>a_b_c</code> here</p>`,
		"stars as math":            `<p>2 * 3 * 4 here</p>`,
		"constant":                 `<p>MAX_RETRY_COUNT here</p>`,
		"snake case":               `<p>foo_bar_baz here</p>`,
		"power and intraword star": `<p>2 * 3 ** 4 and a**b here</p>`,
		"bold in heading":          `<h2>A <strong>b</strong> here</h2>`,
		"bold in table cell":       `<table><tbody><tr><td><p><strong>b</strong> here</p></td></tr></tbody></table>`,
		"bold in nested list item": `<ul><li>x<ul><li><strong>b</strong> here</li></ul></li></ul>`,
		"nested emphasis":          `<p><strong>a <em>b</em> c</strong> <s>d</s> here</p>`,
		"multi-line inline code":   "<p><code>make\napp</code> here</p>",
	} {
		t.Run(name, func(t *testing.T) {
			_, _, err := Apply(mustParse(t, src), []Edit{text("here", "there")})
			assert.NoError(t, err)
		})
	}
}

// R7 item 2: edge NBSP inside emphasis — the editor's common bold label
// "<strong>Label:&nbsp;</strong>value" — moves outside the delimiters in
// the editable text, so such a paragraph round-trips and stays editable.
// A rewrite writes the NBSP just outside the tag; the page renders the
// same.
func TestApplyBoldLabelWithNBSPIsEditable(t *testing.T) {
	d := mustParse(t, `<p><strong>Label:&nbsp;</strong>value here</p>`)
	assert.Equal(t, "**Label:** value here", d.Text())
	out, _ := applyOK(t, `<p><strong>Label:&nbsp;</strong>value here</p>`, text("here", "there"))
	assert.Equal(t, "<p><strong>Label:</strong> value there</p>", out)

	out, _ = applyOK(t, `<p><strong>&nbsp;x</strong> y <em>z&#8195;</em>w here</p>`, text("here", "there"))
	assert.Equal(t, "<p> <strong>x</strong> y <em>z</em> w there</p>", out)

	out, _ = applyOK(t, `<p>a <strong>&nbsp;</strong> b here</p>`, text("here", "there"))
	assert.Equal(t, "<p>a   b there</p>", out, "NBSP-only emphasis is empty, like space-only")
}
