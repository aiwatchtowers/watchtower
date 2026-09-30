package confluenceedit

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func text(old, repl string) Edit { return Edit{Kind: KindReplaceText, Old: old, New: repl} }

func sectionEdit(heading, body string) Edit {
	return Edit{Kind: KindReplaceSection, Heading: heading, NewBody: body}
}

func mustParse(t *testing.T, src string) *Doc {
	t.Helper()
	d, err := Parse(src)
	require.NoError(t, err)
	return d
}

func applyOK(t *testing.T, src string, edits ...Edit) (string, []Change) {
	t.Helper()
	out, changes, err := Apply(mustParse(t, src), edits)
	require.NoError(t, err)
	require.Len(t, changes, len(edits))
	return out, changes
}

func applyErr(t *testing.T, src string, edits ...Edit) *EditError {
	t.Helper()
	out, changes, err := Apply(mustParse(t, src), edits)
	require.Error(t, err)
	assert.Empty(t, out)
	assert.Nil(t, changes)
	var ee *EditError
	require.ErrorAs(t, err, &ee)
	return ee
}

// pElement returns the [start,end) of the first <p> element whose content
// contains needle.
func pElement(t *testing.T, src, needle string) (int, int) {
	t.Helper()
	i := strings.Index(src, needle)
	require.GreaterOrEqual(t, i, 0)
	start := strings.LastIndex(src[:i], "<p>")
	end := i + strings.Index(src[i:], "</p>") + len("</p>")
	return start, end
}

// TestApplyParagraphEditTouchesOnlyThatParagraph is the block-locality
// guard (review focus 1): one edit in a paragraph full of rich inline
// content re-serialises that paragraph alone — every other byte of the
// page, macros and layouts included, is unchanged — and inside it every
// untouched element (bold, italic, the link with its escaped query, inline
// code, the status macro, the emoticon) comes back byte for byte.
func TestApplyParagraphEditTouchesOnlyThatParagraph(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	out, changes := applyOK(t, src, text("on budget", "under budget"))

	start, end := pElement(t, src, "We ship")
	want := src[start:end]
	want = strings.Replace(want, "<em>on budget</em>", "<em>under budget</em>", 1)
	assert.Equal(t, src[:start]+want+src[end:], out)

	require.Len(t, changes, 1)
	assert.Equal(t, KindReplaceText, changes[0].Kind)
	assert.Equal(t, "text in Release plan", changes[0].Locator)
	assert.Contains(t, changes[0].Before, "_on budget_")
	assert.Contains(t, changes[0].After, "_under budget_")
	assert.Empty(t, changes[0].Removed)
}

// TestApplyEditDiffStaysInsideOneParagraph: for a paragraph whose rewrite
// is not byte-identical outside the change (an inline-comment marker, a
// line break), the Render diff still starts and ends inside that <p>.
func TestApplyEditDiffStaysInsideOneParagraph(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	out, _ := applyOK(t, src, text("by the team", "by the whole team"))
	start, end := pElement(t, src, "Reviewed")
	pre, suf := commonAffixes(src, out)
	assert.GreaterOrEqual(t, pre, start+len("<p>"))
	assert.LessOrEqual(t, len(src)-suf, end-len("</p>"))
	assert.Equal(t, src[:start]+`<p>Reviewed <ac:inline-comment-marker ac:ref="c0ffee00-0000-0000-0000-000000000001">last week</ac:inline-comment-marker> by the whole team.<br/>Second line.</p>`+src[end:], out)
}

func commonAffixes(a, b string) (pre, suf int) {
	for pre < len(a) && pre < len(b) && a[pre] == b[pre] {
		pre++
	}
	for suf < len(a)-pre && suf < len(b)-pre && a[len(a)-1-suf] == b[len(b)-1-suf] {
		suf++
	}
	return pre, suf
}

func TestApplyDoesNotModifyTheDoc(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	d := mustParse(t, src)
	before := d.Text()
	_, _, err := Apply(d, []Edit{text("on budget", "x"), sectionEdit("Scope", "new")})
	require.NoError(t, err)
	assert.Equal(t, src, d.Render())
	assert.Equal(t, before, d.Text())
}

func TestApplyTableCell(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	out, changes := applyOK(t, src, text("Ann Lee", "Bob Stone"))
	assert.Equal(t, strings.Replace(src, "<td><p>Ann Lee</p></td>", "<td><p>Bob Stone</p></td>", 1), out)
	assert.Equal(t, "text in Scope", changes[0].Locator)
	assert.Equal(t, "Ann Lee", changes[0].Before)
	assert.Equal(t, "Bob Stone", changes[0].After)
}

func TestApplyListItems(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	out, _ := applyOK(t, src, text("Desktop", "Desktop app"), text("Nested with", "Nested under"))
	want := strings.Replace(src, "<li><p>Desktop</p></li>", "<li><p>Desktop app</p></li>", 1)
	want = strings.Replace(want, `<p>Nested with <a href="https://example.com/a">a link</a></p>`, `<p>Nested under <a href="https://example.com/a">a link</a></p>`, 1)
	assert.Equal(t, want, out)

	out, _ = applyOK(t, src, text("Second\n   continued", "Second,\n   continued"))
	assert.Contains(t, out, "<li>Second,<br/>continued</li>", "old quoted as Text shows it; the break survives, the indent does not")
	out, _ = applyOK(t, src, text("Second continued", "Second, continued"))
	assert.Contains(t, out, "<li>Second, continued</li>", "whitespace-normalised old matches across the break; new text decides")
}

func TestApplyCodeBlockBodyKeepsCDATASplit(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	out, _ := applyOK(t, src, text(`return "]]>"`, `return "]]>" // end`))
	assert.Contains(t, out, `<ac:plain-text-body><![CDATA[if a > b && c < d {`+"\n\t"+`return "]]]]><![CDATA[>" // end`+"\n}]]></ac:plain-text-body>")
	assert.Contains(t, mustParse(t, out).Text(), "return \"]]>\" // end")
}

func TestApplyRemovedMarkerIsReported(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	d := mustParse(t, src)
	owner := d.Markers()[1]
	out, changes, err := Apply(d, []Edit{text("Owner: "+owner.token()+", tracked", "Owner: TBD, tracked")})
	require.NoError(t, err)
	assert.Equal(t, []string{owner.token()}, changes[0].Removed)
	assert.NotContains(t, out, owner.Raw)
	assert.Contains(t, out, d.Markers()[2].Raw, "the jira macro after the edit is kept")
}

func TestApplyMarkerMovesWithinTheReplacedText(t *testing.T) {
	src := `<p>a <ac:emoticon ac:name="smile"/> b c</p>`
	out, changes := applyOK(t, src, text("a ⟦1:emoticon smile⟧ b", "b ⟦1:emoticon smile⟧ a"))
	assert.Equal(t, `<p>b <ac:emoticon ac:name="smile"/> a c</p>`, out)
	assert.Empty(t, changes[0].Removed)
}

// TestApplySectionReplaceWithTableListCodeAndMarker replaces the Scope
// section of rich.xhtml: its body runs to the layout (R5), carrying two
// lists, two tables, an image, a code block and a panel. The new body keeps
// one block marker, drops two, and writes a paragraph, a nested list, a
// pipe table and fenced code holding "]]>".
func TestApplySectionReplaceWithTableListCodeAndMarker(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	d := mustParse(t, src)
	ms := d.Markers()
	body := "Intro with [the docs](https://example.com/docs?a=1&b=2).\n\n" +
		"- one\n  - two\n1. first\n\n" +
		"| A | B |\n| --- | --- |\n| x & y | z |\n\n" +
		ms[6].token() + "\n\n" +
		"```go\nfmt.Println(\"]]>\")\n```"
	out, changes, err := Apply(d, []Edit{sectionEdit("## Scope", body)})
	require.NoError(t, err)

	i := headingIndex(t, d, "Scope")
	region, err := d.sectionRegion(i)
	require.NoError(t, err)
	assert.True(t, strings.HasPrefix(out, src[:region.start]), "everything before the section body is untouched")
	assert.True(t, strings.HasSuffix(out, src[region.end:]), "everything after it (the layout) is untouched")
	assert.True(t, strings.HasPrefix(src[region.end:], "<ac:layout>"))

	newBody := out[region.start : len(out)-len(src[region.end:])]
	assert.Equal(t, "\n"+
		`<p>Intro with <a href="https://example.com/docs?a=1&amp;b=2">the docs</a>.</p>`+
		`<ul><li>one<ul><li>two</li></ul></li></ul><ol><li>first</li></ol>`+
		`<table><tbody><tr><th>A</th><th>B</th></tr><tr><td>x &amp; y</td><td>z</td></tr></tbody></table>`+
		ms[6].Raw+
		`<ac:structured-macro ac:name="code" ac:schema-version="1"><ac:parameter ac:name="language">go</ac:parameter><ac:plain-text-body><![CDATA[fmt.Println("]]]]><![CDATA[>")]]></ac:plain-text-body></ac:structured-macro>`+
		"\n", newBody)

	require.Len(t, changes, 1)
	c := changes[0]
	assert.Equal(t, KindReplaceSection, c.Kind)
	assert.Equal(t, "Scope", c.Locator)
	assert.Equal(t, []string{ms[7].token(), ms[8].token()}, c.Removed)
	assert.Contains(t, c.Before, "- Backend ~~draft~~ API")
	assert.Contains(t, c.Before, ms[8].token())
	assert.Equal(t, "Intro with [the docs](https://example.com/docs?a=1&b=2).\n\n- one\n  - two\n\n1. first\n\n| A | B |\n| --- | --- |\n| x & y | z |\n\n"+ms[6].token()+"\n\n```go\nfmt.Println(\"]]>\")\n```", c.After)

	re := mustParse(t, out)
	assert.Contains(t, re.Text(), "## Scope\n\nIntro with [the docs](https://example.com/docs?a=1&b=2).\n\n- one\n  - two\n\n1. first\n\n| A | B |\n| --- | --- |\n| x & y | z |\n\n⟦")
	assert.Contains(t, re.Text(), "```go\nfmt.Println(\"]]>\")\n```\n\n### Риски")
}

func TestApplySectionLastSectionAndNestedHeading(t *testing.T) {
	out, changes := applyOK(t, sectionsSrc, sectionEdit("Next", "fresh"))
	assert.Equal(t, strings.TrimSuffix(sectionsSrc, "<p>n</p>\n")+"<p>fresh</p>\n", out)
	assert.Equal(t, "n", changes[0].Before)

	out, changes = applyOK(t, sectionsSrc, sectionEdit("Mid", "### Deeper\n\nbody"))
	assert.Contains(t, out, "<h2>Mid</h2>\n<h3>Deeper</h3><p>body</p>\n<h2>Next</h2>")
	assert.Equal(t, []string{"⟦1:table 1x1⟧", "⟦2:emoticon smile⟧"}, changes[0].Removed,
		"the nested h3's opaque table and the emoticon go with the section")
}

func TestApplyEmptySectionBody(t *testing.T) {
	out, changes := applyOK(t, sectionsSrc, sectionEdit("Next", ""))
	assert.Equal(t, strings.TrimSuffix(sectionsSrc, "<p>n</p>\n")+"\n", out)
	assert.Equal(t, "", changes[0].After)
}

func TestApplyTwoEditsSameBlockAndChained(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	out, changes := applyOK(t, src, text("on time", "early"), text("on budget", "cheap"))
	assert.Contains(t, out, "We ship <strong>early</strong> and <em>cheap</em>, see")
	assert.Contains(t, changes[1].Before, "**early**", "the second edit sees the first one's result")

	out, _ = applyOK(t, src, text("Sync", "Sync engine"), text("Sync engine", "Sync core"))
	assert.Contains(t, out, "<td><p>Sync core</p></td>", "a later edit may target text an earlier one created")
}

func TestApplyLaterEditWhoseTargetWasRemovedFails(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	ee := applyErr(t, src, text("on budget", "cheaply"), text("on budget", "x"))
	assert.Equal(t, 1, ee.Index)
	assert.Contains(t, ee.Msg, "not found")

	ee = applyErr(t, src, sectionEdit("Scope", "gone"), text("Ann Lee", "x"))
	assert.Equal(t, 1, ee.Index, "a replaced section's old text is gone")
	assert.Contains(t, ee.Msg, "not found")
}

func TestApplyEditsInsideAReplacedSection(t *testing.T) {
	out, changes := applyOK(t, sectionsSrc, sectionEdit("Mid", "one two\n\n### Sub\n\nthree"), text("two", "2"))
	assert.Contains(t, out, "<h2>Mid</h2>\n<p>one 2</p><h3>Sub</h3><p>three</p>\n<h2>Next</h2>")
	assert.Equal(t, "text in Mid", changes[1].Locator)

	ee := applyErr(t, sectionsSrc, sectionEdit("Mid", "### Sub\n\nx"), sectionEdit("Sub", "y"))
	assert.Equal(t, 1, ee.Index)
	assert.Contains(t, ee.Msg, "inside the section replaced by edits[0]")

	ee = applyErr(t, sectionsSrc, sectionEdit("Mid", "x"), sectionEdit("Deep", "y"))
	assert.Equal(t, 1, ee.Index)
	assert.Contains(t, ee.Msg, "inside the section replaced by edits[0]", "the nested heading died with the outer section (finding 7)")
}

// TestApplyTextEditThenEnclosingSection: a unit rewritten by an earlier
// edit and then swallowed by a replace_section must not be rewritten
// inside the spliced region (carry (e)) — the section wins, no panic.
func TestApplyTextEditThenEnclosingSection(t *testing.T) {
	out, _ := applyOK(t, sectionsSrc, text("m1", "M1"), text("Deep", "Deeper"), sectionEdit("Mid", "new"))
	assert.Equal(t, strings.Replace(sectionsSrc, sectionsSrc[strings.Index(sectionsSrc, "\n<p>m1"):strings.Index(sectionsSrc, "<h2>Next")], "\n<p>new</p>\n", 1), out)

	out, changes := applyOK(t, sectionsSrc, sectionEdit("Deep", "d2"), sectionEdit("Mid", "all new"))
	assert.Contains(t, out, "<h2>Mid</h2>\n<p>all new</p>\n<h2>Next</h2>")
	assert.Contains(t, changes[1].Before, "### Deep\n\nd2", "the outer section's before shows the nested rewrite")

	out, changes = applyOK(t, sectionsSrc, sectionEdit("Next", "v1"), sectionEdit("Next", "v2"))
	assert.Contains(t, out, "<h2>Next</h2>\n<p>v2</p>\n")
	assert.Equal(t, "v1", changes[1].Before)

	out, _ = applyOK(t, sectionsSrc, text("Mid", "Middle"), sectionEdit("Middle", "z"))
	assert.Contains(t, out, "<h2>Middle</h2>\n<p>z</p>\n<h2>Next</h2>", "a renamed heading's unit and its section splice coexist")
}

func TestApplyCyrillicQuotesAndNBSP(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	out, changes := applyOK(t, src, text(`Текст "в кавычках" и неразрывный`, "Текст «в скобках» и обычный"))
	assert.Contains(t, out, "<p>Текст «в скобках» и обычный пробел.</p>")
	assert.Equal(t, "Текст «в кавычках» и неразрывный пробел.", changes[0].Before)
	assert.Equal(t, "text in Риски", changes[0].Locator)

	out, _ = applyOK(t, `<p>Он сказал: “привет”  —  и ушёл</p>`, text(`сказал: "привет" — и ушёл`, "молчал"))
	assert.Equal(t, `<p>Он молчал</p>`, out)
}

func TestApplyNoOpEditIsAnError(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	ee := applyErr(t, src, text("on budget", "on budget"))
	assert.Equal(t, 0, ee.Index)
	assert.Contains(t, ee.Msg, "edit changes nothing")

	ee = applyErr(t, sectionsSrc, sectionEdit("Next", "n"))
	assert.Contains(t, ee.Msg, "edit changes nothing")
}

// TestApplyUnchangedUnitIsNotReEmitted (carry (d)): an edit reverted by a
// later edit leaves its unit's bytes alone — here the &nbsp; entity would
// otherwise come back as a raw NBSP.
func TestApplyUnchangedUnitIsNotReEmitted(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	out, _ := applyOK(t, src, text("неразрывный", "обычный"), text("обычный", "неразрывный"))
	assert.Equal(t, src, out)
}

// TestApplyMultiLineInlineCodeLoss pins the accepted known loss of carry
// (d): the editable text shows a code span's line break as a space, so
// rewriting another part of the paragraph writes the span back with a
// space.
func TestApplyMultiLineInlineCodeLoss(t *testing.T) {
	out, _ := applyOK(t, "<p>run <code>make\napp</code> now</p>", text("now", "later"))
	assert.Equal(t, "<p>run <code>make app</code> later</p>", out)
}

// TestApplyLiteralMarkerTextIsNotAMarker (carry (a)): a token typed on the
// page as text stays text through a rewrite, and copying it in new text
// keeps it literal instead of duplicating the real marker.
func TestApplyLiteralMarkerTextIsNotAMarker(t *testing.T) {
	src := `<p>Literal ⟦1:emoticon smile⟧ and <ac:emoticon ac:name="smile"/> end</p>`
	d := mustParse(t, src)
	require.Equal(t, "Literal ⟦1:emoticon smile⟧ and ⟦1:emoticon smile⟧ end", d.Text())

	out, _ := applyOK(t, src, text("end", "fin"))
	assert.Equal(t, `<p>Literal ⟦1:emoticon smile⟧ and <ac:emoticon ac:name="smile"/> fin</p>`, out)

	out, changes := applyOK(t, src, text("Literal ⟦1:emoticon smile⟧ and", "Typed ⟦1:emoticon smile⟧ and"))
	assert.Equal(t, `<p>Typed ⟦1:emoticon smile⟧ and <ac:emoticon ac:name="smile"/> end</p>`, out)
	assert.Empty(t, changes[0].Removed)

	out, changes = applyOK(t, src, text("and ⟦1:emoticon smile⟧ end", "done"))
	assert.Equal(t, `<p>Literal ⟦1:emoticon smile⟧ done</p>`, out, "the real marker is the one in the replaced span")
	assert.Equal(t, []string{"⟦1:emoticon smile⟧"}, changes[0].Removed)

	out, _ = applyOK(t, `<p>x ⟦9:ghost⟧ y</p>`, text("y", "z"))
	assert.Equal(t, `<p>x ⟦9:ghost⟧ z</p>`, out, "an unknown literal token outside the replaced text is untouched")
	out, _ = applyOK(t, `<p>x ⟦9:ghost⟧ y</p>`, text("x ⟦9:ghost⟧", "w ⟦9:ghost⟧"))
	assert.Equal(t, `<p>w ⟦9:ghost⟧ y</p>`, out, "a literal carried from the old text is allowed")
}

// TestApplyRefusesUnitWithComment (carry (b)).
func TestApplyRefusesUnitWithComment(t *testing.T) {
	for _, src := range []string{
		`<p>a <!-- keep me --> b</p>`,
		`<p>a </b> b</p>`,
		`<ac:structured-macro ac:name="code"><ac:plain-text-body><![CDATA[a]]><!-- c --><![CDATA[ b]]></ac:plain-text-body></ac:structured-macro>`,
	} {
		ee := applyErr(t, src, text("b", "c"))
		assert.Contains(t, ee.Msg, "cannot keep", src)
	}
	out, _ := applyOK(t, `<h1>T</h1><p>a <!-- c --> b</p><p>other</p>`, text("other", "else"))
	assert.Equal(t, `<h1>T</h1><p>a <!-- c --> b</p><p>else</p>`, out, "only the edited unit is refused")
}

func TestApplyKeepsLiteralDelimitersAndLinkAttributes(t *testing.T) {
	src := `<p>a_b_c snake_case tail_ and 2 * 3 ** 4 and x~~y <strong>bold</strong> <a href="https://example.com/p" data-card-appearance="inline">card</a> end</p>`
	out, _ := applyOK(t, src, text("end", "fin"))
	assert.Equal(t, strings.Replace(src, "end</p>", "fin</p>", 1), out)
}

func TestApplyInlineMarkdownInNewText(t *testing.T) {
	out, _ := applyOK(t, `<p>x</p>`, text("x", "**b** _i_ ~~s~~ `c<d` [l [1]](https://example.com/a?(b)&c=\"d\") <tag>\nnext"))
	assert.Equal(t, `<p><strong>b</strong> <em>i</em> <s>s</s> <code>c&lt;d</code> <a href="https://example.com/a?(b)&amp;c=&quot;d&quot;">l [1]</a> &lt;tag&gt;<br/>next</p>`, out)

	out, _ = applyOK(t, `<p>x</p>`, text("x", "**unclosed _half [no](link"))
	assert.Equal(t, `<p>**unclosed _half [no](link</p>`, out)
}

// TestApplyMarkdownListNesting (carry (c)): 2-space nested ordered lists
// and the CommonMark 3-space form both nest; a bullet change at the same
// depth starts a new list.
func TestApplyMarkdownListNesting(t *testing.T) {
	out, _ := applyOK(t, sectionsSrc, sectionEdit("Next", "1. a\n  1. b\n     more\n2. c\n   - d\n- e"))
	assert.Contains(t, out, `<h2>Next</h2>`+"\n"+`<ol><li>a<ol><li>b<br/>more</li></ol></li><li>c<ul><li>d</li></ul></li></ol><ul><li>e</li></ul>`+"\n")

	out, _ = applyOK(t, sectionsSrc, sectionEdit("Next", "3. x\n4. y"))
	assert.Contains(t, out, `<ol start="3"><li>x</li><li>y</li></ol>`)
}

// TestApplySectionBodyRoundTripsThroughText: a body written in Text's own
// form comes back as the same editable text.
func TestApplySectionBodyRoundTripsThroughText(t *testing.T) {
	body := "Para **b** _i_ [l](https://example.com/x)\nsecond line\n\n- a\n  - b\n    1. c\n\n| **H** | K |\n| --- | --- |\n| 1 | 2 |\n\n```\ncode ]]> here\n```\n\n#### Sub\n\nend ⟦2:emoticon smile⟧"
	out, changes := applyOK(t, sectionsSrc, sectionEdit("Mid", body))
	assert.Equal(t, body, changes[0].After)
	re := mustParse(t, out)
	want := "## Mid\n\n" + strings.ReplaceAll(body, "⟦2:", "⟦1:") + "\n\n## Next"
	assert.Contains(t, re.Text(), want, "ordinals renumber after the removed table")
}

func TestApplyErrors(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	d := mustParse(t, src)
	ms := d.Markers()
	many := make([]Edit, MaxEdits+1)
	cases := []struct {
		name  string
		src   string
		edits []Edit
		index int
		msg   string
	}{
		{"no edits", src, nil, 0, "no edits"},
		{"too many", src, many, MaxEdits, "too many edits (21)"},
		{"unknown kind", src, []Edit{{Kind: "delete"}}, 0, `unknown edit kind "delete"`},
		{"empty old", src, []Edit{text(" \n", "x")}, 0, "empty edit"},
		{"empty heading", src, []Edit{sectionEdit("## ", "x")}, 0, "empty edit"},
		{"not found", src, []Edit{text("nowhere", "x")}, 0, "not found"},
		{"ambiguous", `<p>a x</p><p>b x</p>`, []Edit{text("x", "y")}, 0, "ambiguous (2 matches)"},
		{"spans blocks", `<p>one</p><p>two</p>`, []Edit{text("one two", "x")}, 0, "spans more than one block"},
		{"list syntax", src, []Edit{text("- Desktop", "x")}, 0, "spans more than one block"},
		{"heading not found", src, []Edit{sectionEdit("Nope", "x")}, 0, "heading not found"},
		{"heading ambiguous", `<h2>A</h2><p>1</p><h2>A</h2><p>2</p>`, []Edit{sectionEdit("A", "x")}, 0, "heading is ambiguous (2 headings match)"},
		{"unknown marker", src, []Edit{text("Second line.", "Second ⟦3:jira⟧")}, 0, "unknown marker ⟦3:jira⟧; copy marker tokens exactly, e.g. " + ms[2].token()},
		{"invented marker", src, []Edit{text("Second line.", "⟦99:x⟧")}, 0, "unknown marker ⟦99:x⟧; markers can only be kept or removed"},
		{"duplicate elsewhere", src, []Edit{text("Second line.", "see "+ms[2].token())}, 0, "duplicate marker " + ms[2].token() + ": it already appears elsewhere"},
		{"duplicate in new text", `<p>a <ac:emoticon ac:name="x"/> b</p>`, []Edit{text("a ⟦1:emoticon x⟧ b", "⟦1:emoticon x⟧ ⟦1:emoticon x⟧")}, 0, "duplicate marker ⟦1:emoticon x⟧"},
		{"duplicate in section body", sectionsSrc, []Edit{sectionEdit("Mid", "⟦2:emoticon smile⟧\n\nx ⟦2:emoticon smile⟧")}, 0, "duplicate marker ⟦2:emoticon smile⟧"},
		{"section marker from elsewhere", src, []Edit{sectionEdit("Scope", ms[1].token())}, 0, "duplicate marker " + ms[1].token()},
		{"cuts marker", src, []Edit{text("tracked in ⟦3:jira", "x")}, 0, "cuts through the marker " + ms[2].token()},
		{"block marker inline", src, []Edit{sectionEdit("Scope", "see "+ms[6].token())}, 0, "is a block element"},
		{"line break in heading", src, []Edit{text("Release plan", "a\nb")}, 0, "cannot hold a line break"},
		{"line break in cell", src, []Edit{text("Ann Lee", "a\nb")}, 0, "cannot hold a line break"},
		{"second edit index", src, []Edit{text("Sync", "S"), text("nowhere", "x")}, 1, "not found"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ee := applyErr(t, tc.src, tc.edits...)
			assert.Equal(t, tc.index, ee.Index)
			assert.Contains(t, ee.Msg, tc.msg)
			assert.Contains(t, ee.Error(), "edits[")
		})
	}
}

// TestApplyRenderConflictIsAnEditErrorNotAPanic (carry (e)): Apply never
// sets a unit's out inside a replaced region, but should that invariant
// break, render reports the section's edit instead of reaching Render's
// overlap panic. The state is built by hand: a changed unit left alive
// inside a section region.
func TestApplyRenderConflictIsAnEditErrorNotAPanic(t *testing.T) {
	d := mustParse(t, sectionsSrc)
	a := newApplier(d)
	i := headingIndex(t, a.d, "Mid")
	region, err := a.d.sectionRegion(i)
	require.NoError(t, err)
	a.d.units[3].text = "changed" // "m1", inside Mid's region, not killed
	a.d.blocks[i].section = &section{region: region, index: 4}
	var out string
	assert.NotPanics(t, func() { out, err = a.render() })
	assert.Empty(t, out)
	var ee *EditError
	require.ErrorAs(t, err, &ee)
	assert.Equal(t, 4, ee.Index)
	assert.Contains(t, ee.Msg, "internal conflict")
}
