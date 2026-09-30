package confluenceedit

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	r14Centred = `<p style="text-align:center">Centred</p>`
	r14Code    = `<ac:structured-macro ac:name="code"><ac:parameter ac:name="title">T</ac:parameter><ac:plain-text-body><![CDATA[x := 1]]></ac:plain-text-body></ac:structured-macro>`
	r14Wide    = `<table data-layout="wide"><tbody><tr><th>h</th></tr><tr><td>1</td></tr></tbody></table>`
	r14BrRich  = `<p style="text-align:center">a<br/><br/>b</p>`
	r14BrPlain = `<p>a<br/><br/>b</p>`
)

// Ruling R14: a replace_section never deletes a block markdown cannot
// carry faithfully while a changed block of its kind is anywhere in the
// section — however the merge paired or reordered the blocks. Each case
// here moved AND changed a rich block (or changed one of two same-text
// blocks); before R14 each one wrote the plain re-rendering and silently
// dropped the formatting.
func TestEXT05_SectionRewriteNeverDropsRichBlockSilently(t *testing.T) {
	for name, tc := range map[string]struct{ src, body, want string }{
		"move+edit centred, rich first": {
			`<h2>S</h2>` + r14Centred + `<p>Plain</p>`, "Plain\n\nCentred edited",
			`paragraph "Centred"`,
		},
		"move+edit centred, rich last": {
			`<h2>S</h2><p>Plain</p>` + r14Centred, "Centred edited\n\nPlain",
			`paragraph "Centred"`,
		},
		"move+edit code with title": {
			`<h2>S</h2>` + r14Code + `<p>Plain</p>`, "Plain\n\n```\nx := 2\n```",
			"code block parameters such as a title",
		},
		"move+edit wide table": {
			`<h2>S</h2>` + r14Wide + `<p>Plain</p>`, "Plain\n\n| h |\n| --- |\n| 2 |",
			"table layout or cell attributes",
		},
		"duplicate text: move mid, edit one Note": {
			`<h2>S</h2><p style="text-align:center">Note</p><p>mid</p><p>Note</p>`, "mid\n\nNote\n\n" + "Note edited",
			`paragraph "Note"`,
		},
		"duplicate rich text, edit one": {
			`<h2>S</h2><p style="text-align:center">N</p><p>mid</p><p style="text-align:right">N</p>`, "mid\n\nN\n\nN2",
			`paragraph "N"`,
		},
		"br paragraph moved and split into edited paragraphs": {
			`<h2>S</h2>` + r14BrRich + `<p>Plain</p>`, "Plain\n\na\n\nb2",
			`paragraph "a"`,
		},
		"rich deleted, same kind changed across a kept block": {
			`<h2>S</h2>` + r14Centred + `<p>Mid</p><p>Tail</p>`, "Mid\n\nTail edited",
			`paragraph "Centred"`,
		},
	} {
		t.Run(name, func(t *testing.T) {
			_, _, err := Apply(mustParse(t, tc.src), []Edit{sectionEdit("S", tc.body)})
			require.Error(t, err)
			assert.Contains(t, err.Error(), "cannot be rewritten without losing formatting")
			assert.Contains(t, err.Error(), tc.want)
		})
	}
}

// R14 leaves pure moves, in-place kept blocks and unambiguous deletions
// alone: each succeeds, keeping every rich block's bytes it keeps.
func TestSectionRewriteR14AllowsFaithfulRewrites(t *testing.T) {
	for name, tc := range map[string]struct{ src, body, want string }{
		"pure move of a rich paragraph": {
			`<h2>S</h2>` + r14Centred + `<p>Plain</p>`, "Plain\n\nCentred",
			`<h2>S</h2><p>Plain</p>` + r14Centred,
		},
		"swap two rich blocks": {
			`<h2>S</h2>` + r14Centred + r14Wide, "| h |\n| --- |\n| 1 |\n\nCentred",
			`<h2>S</h2>` + r14Wide + r14Centred,
		},
		"duplicate text, plain move": {
			`<h2>S</h2><p style="text-align:center">Note</p><p>mid</p><p>Note</p>`, "mid\n\nNote\n\n" + "Note",
			`<h2>S</h2><p>mid</p><p style="text-align:center">Note</p><p>Note</p>`,
		},
		"moved rich + new paragraph": {
			`<h2>S</h2><p>A</p>` + r14Centred + `<p>B</p>`, "B\n\nCentred\n\nNew",
			`<h2>S</h2><p>B</p>` + r14Centred + `<p>New</p>`,
		},
		"kept rich in place, plain edited": {
			`<h2>S</h2>` + r14Centred + `<p>Plain</p>`, "Centred\n\nPlain edited",
			`<h2>S</h2>` + r14Centred + `<p>Plain edited</p>`,
		},
		"plain paragraph deleted and another added": {
			`<h2>S</h2><p>A</p><p>B</p>`, "B\n\nC",
			`<h2>S</h2><p>B</p><p>C</p>`,
		},
		"rich deleted with no changed block of its kind": {
			`<h2>S</h2>` + r14Centred + `<p>Plain</p>`, "Plain\n\n- item",
			`<h2>S</h2><p>Plain</p><ul><li>item</li></ul>`,
		},
	} {
		t.Run(name, func(t *testing.T) {
			out, _ := applyOK(t, tc.src, sectionEdit("S", tc.body))
			assert.Equal(t, tc.want, out)
		})
	}
}

// A paragraph whose two <br/>s read back as two blocks, moved whole, is a
// move (findMoves' run pairing): it keeps its bytes at the new place and
// is never re-rendered as two plain paragraphs — before or after a match.
func TestSectionRewriteMovedBrParagraphKeepsBytes(t *testing.T) {
	for _, br := range []string{r14BrRich, r14BrPlain} {
		out, _ := applyOK(t, `<h2>S</h2>`+br+`<p>Plain</p>`, sectionEdit("S", "Plain\n\na\n\nb"))
		assert.Equal(t, `<h2>S</h2><p>Plain</p>`+br, out)
		out, _ = applyOK(t, `<h2>S</h2><p>Plain</p>`+br, sectionEdit("S", "a\n\nb\n\nPlain"))
		assert.Equal(t, `<h2>S</h2>`+br+`<p>Plain</p>`, out)
		out, _ = applyOK(t, `<h2>S</h2>`+br+`<p>Plain</p><p>Tail</p>`, sectionEdit("S", "Plain\n\na\n\nb\n\nTail edited"))
		assert.Equal(t, `<h2>S</h2><p>Plain</p>`+br+`<p>Tail edited</p>`, out)
	}
}
