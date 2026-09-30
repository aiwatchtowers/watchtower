package confluenceedit

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// judgeCases are the local-review judge's reproduction of F1: a section
// whose first block carries formatting the editable text cannot show, then
// a plain paragraph the edit changes.
var judgeCases = map[string]string{
	"centred paragraph":     `<h2>S</h2><p style="text-align:center">centered</p><p>edit me</p>`,
	"intraword italic":      `<h2>S</h2><p>a<em>b</em>c</p><p>edit me</p>`,
	"literal powers":        `<h2>S</h2><p>2**10 vs 3**4</p><p>edit me</p>`,
	"headerless wide table": `<h2>S</h2><table data-layout="wide"><colgroup><col/><col/></colgroup><tbody><tr><td>x</td><td>y</td></tr><tr><td>1</td><td>2</td></tr></tbody></table><p>edit me</p>`,
	"header-row table":      `<h2>S</h2><table><tbody><tr><th>h1</th><th>h2</th></tr><tr><td>1</td><td>2</td></tr></tbody></table><p>edit me</p>`,
	"multi-paragraph item":  `<h2>S</h2><ul><li><p>one</p><p>two</p></li></ul><p>edit me</p>`,
	"code with title":       `<h2>S</h2><ac:structured-macro ac:name="code"><ac:parameter ac:name="title">T</ac:parameter><ac:parameter ac:name="language">go</ac:parameter><ac:plain-text-body><![CDATA[x := 1]]></ac:plain-text-body></ac:structured-macro><p>edit me</p>`,
	"noformat":              `<h2>S</h2><ac:structured-macro ac:name="noformat"><ac:plain-text-body><![CDATA[raw]]></ac:plain-text-body></ac:structured-macro><p>edit me</p>`,
	"column-header table":   `<h2>S</h2><table><tbody><tr><th>k</th><td>v</td></tr><tr><th>k2</th><td>v2</td></tr></tbody></table><p>edit me</p>`,
	"attributed heading":    `<h1>S</h1><h2 style="color:red">Sub</h2><p>edit me</p>`,
	"list with attributes":  `<h2>S</h2><ul class="x"><li data-a="1">i</li></ul><p>edit me</p>`,
	// Text shows this paragraph as "x\n\ny", which reads back as two
	// paragraphs: kept whole by the joined-text rule of a merge gap.
	"double line break": `<h2>S</h2><p>x<br/><br/>y</p>` + "\n" + `<p>edit me</p>`,
}

// sectionBody is the editable text of the section under heading S (or the
// only heading), as get_confluence_page would show it.
func sectionBody(t *testing.T, d *Doc) (string, string) {
	t.Helper()
	text := d.Text()
	head, body, ok := strings.Cut(text, "\n\n")
	require.True(t, ok, text)
	return strings.TrimLeft(head, "# "), body
}

// TestEXT05_SectionRewriteKeepsUntouchedBlocksByteExact is the F1/F3
// guard: a replace_section that changes one paragraph re-emits every other
// block of the section — formatting the editable text cannot show
// included — byte for byte (ruling R11).
func TestEXT05_SectionRewriteKeepsUntouchedBlocksByteExact(t *testing.T) {
	for name, src := range judgeCases {
		t.Run(name, func(t *testing.T) {
			d := mustParse(t, src)
			heading, body := sectionBody(t, d)
			if heading != "S" {
				heading = "S"
				body = strings.TrimPrefix(d.Text(), "# S\n\n")
			}
			require.Contains(t, body, "edit me")
			out, changes, err := Apply(d, []Edit{sectionEdit(heading, strings.Replace(body, "edit me", "edited", 1))})
			require.NoError(t, err)
			assert.Equal(t, strings.Replace(src, "<p>edit me</p>", "<p>edited</p>", 1), out)
			assert.Empty(t, changes[0].Removed)
		})
	}
}

// TestSectionRewriteRefusesChangingAnUnfaithfulBlock: when the edit
// changes the rich block itself, it is refused with a message naming the
// block and what would be lost — never re-rendered lossily (R11).
func TestSectionRewriteRefusesChangingAnUnfaithfulBlock(t *testing.T) {
	for name, tc := range map[string]struct{ src, from, to, want string }{
		"centred paragraph":    {judgeCases["centred paragraph"], "centered", "centred", `paragraph "centered"`},
		"intraword italic":     {judgeCases["intraword italic"], "a_b_c", "a_b_c!", "characters that read as formatting"},
		"literal powers":       {judgeCases["literal powers"], "2**10 vs 3**4", "2**10 vs 3**5", "characters that read as formatting"},
		"table with widths":    {`<h2>S</h2><table data-layout="wide"><colgroup><col/></colgroup><tbody><tr><th>h</th></tr><tr><td>1</td></tr></tbody></table>`, "| 1 |", "| 2 |", "column widths"},
		"table with layout":    {`<h2>S</h2><table data-layout="wide"><tbody><tr><th>h</th></tr><tr><td>1</td></tr></tbody></table>`, "| 1 |", "| 2 |", "table layout or cell attributes"},
		"multi-paragraph item": {judgeCases["multi-paragraph item"], "  two", "  2", "several paragraphs"},
		"code with title":      {judgeCases["code with title"], "x := 1", "x := 2", "parameters such as a title"},
		"noformat":             {judgeCases["noformat"], "raw", "cooked", "a noformat block"},
		"attributed heading":   {judgeCases["attributed heading"], "## Sub", "## Sub2", `heading "## Sub"`},
		"list with attributes": {judgeCases["list with attributes"], "- i", "- j", "list attributes"},
		"comment in paragraph": {`<h2>S</h2><p>a <!-- c --> b</p>`, "a b", "a c", "an HTML comment"},
		"heading-like text":    {`<h2>S</h2><p># not a heading</p>`, "# not a heading", "# not a heading!", "reads as different markdown structure"},
	} {
		t.Run(name, func(t *testing.T) {
			d := mustParse(t, tc.src)
			text := d.Text()
			head, body, _ := strings.Cut(text, "\n\n")
			heading := strings.TrimLeft(head, "# ")
			if heading != "S" {
				heading, body = "S", strings.TrimPrefix(text, "# S\n\n")
			}
			require.Contains(t, body, tc.from)
			ee := applyErr(t, tc.src, sectionEdit(heading, strings.Replace(body, tc.from, tc.to, 1)))
			assert.Contains(t, ee.Msg, tc.want)
			assert.Contains(t, ee.Msg, "the section's ")
			assert.Contains(t, ee.Msg, "keep that block exactly as it is in new_body, or edit it in Confluence")
		})
	}
}

// TestSectionRewriteMayDeleteOrAddAroundRichBlocks: deleting a rich block
// or adding new blocks next to one is allowed — the text diff shows both.
func TestSectionRewriteMayDeleteOrAddAroundRichBlocks(t *testing.T) {
	src := judgeCases["centred paragraph"]
	out, _ := applyOK(t, src, sectionEdit("S", "edit me"))
	assert.Equal(t, `<h2>S</h2><p>edit me</p>`, out)

	out, _ = applyOK(t, src, sectionEdit("S", "intro\n\n- new\n\ncentered\n\nedit me"))
	assert.Equal(t, `<h2>S</h2><p>intro</p><ul><li>new</li></ul><p style="text-align:center">centered</p><p>edit me</p>`, out)

	out, _ = applyOK(t, `<h2>S</h2><p>a</p><p></p><p>b</p>`, sectionEdit("S", "a\n\nc"))
	assert.Equal(t, `<h2>S</h2><p>a</p><p></p><p>c</p>`, out, "an empty spacing paragraph is never deleted")
}

// TestSectionRewriteKeepsLaterUnitEditsOfKeptBlocks: a block kept by a
// section rewrite stays editable, and a later replace_text rewrites just
// its unit inside the original bytes.
func TestSectionRewriteKeepsLaterUnitEditsOfKeptBlocks(t *testing.T) {
	src := `<h2>S</h2><p style="text-align:center">centered <strong>b</strong></p><p>edit me</p>`
	out, _ := applyOK(t, src, sectionEdit("S", "centered **b**\n\nedited"), text("centered", "centred"))
	assert.Equal(t, `<h2>S</h2><p style="text-align:center">centred <strong>b</strong></p><p>edited</p>`, out)

	out, _ = applyOK(t, src, sectionEdit("S", "centered **b**\n\nv1"), sectionEdit("S", "centered **b**\n\nv2"))
	assert.Equal(t, `<h2>S</h2><p style="text-align:center">centered <strong>b</strong></p><p>v2</p>`, out,
		"a second rewrite of the same section still merges against the original bytes")
}

// R11 (d): a pipe table always has a header row, so a table without one —
// headerless, or with a header column — is one opaque marker, never shown
// with a header row the page lacks.
func TestTextTableWithoutHeaderRowIsAMarker(t *testing.T) {
	for _, src := range []string{
		`<table><tbody><tr><td>x</td><td>y</td></tr><tr><td>1</td><td>2</td></tr></tbody></table>`,
		`<table><tbody><tr><th>k</th><td>v</td></tr><tr><th>k2</th><td>v2</td></tr></tbody></table>`,
		`<table><tbody><tr><th>h</th></tr><tr><th>again</th></tr></tbody></table>`,
	} {
		d := mustParse(t, src)
		assert.Equal(t, "⟦1:table 2x"+map[bool]string{true: "1", false: "2"}[strings.Contains(src, "again")]+"⟧", d.Text(), src)
		assert.NotContains(t, d.Text(), "---")
	}
	d := mustParse(t, `<table><thead><tr><th>h</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>`)
	assert.Equal(t, "| h |\n| --- |\n| 1 |", d.Text())
}
