package confluenceedit

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var update = flag.Bool("update", false, "rewrite golden files")

// fixtures returns every storage fixture, failing the test if the set is
// empty or rich.xhtml (the one carrying every rich element kind in the
// self-closing forms real Confluence emits) is missing.
func fixtures(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob("testdata/*.xhtml")
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(files), 11)
	require.Contains(t, files, filepath.Join("testdata", "rich.xhtml"))
	return files
}

func readFixture(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	return string(raw)
}

// TestEXT05_RichElementsSurviveUntouched is the round-trip law of spec §3:
// Render(Parse(x)) == x byte for byte for every real-shape fixture, i.e.
// canonical == original (untouched blocks re-emit their exact source bytes).
// The identity-rewrite leg drives the Task 3 seam: every editable unit is
// replaced by its own original bytes, and the document still reassembles
// to the input — so unit spans partition the source with no gap, overlap or
// reordering. Every marker's Raw is the exact source slice of its element.
func TestEXT05_RichElementsSurviveUntouched(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(filepath.Base(f), func(t *testing.T) {
			src := readFixture(t, f)
			d, err := Parse(src)
			require.NoError(t, err)
			assert.Equal(t, src, d.Render(), "untouched render must be byte-identical")

			require.NotEmpty(t, d.units, "every fixture carries editable text")
			for _, u := range d.units {
				own := src[u.start:u.end]
				u.out = &own
			}
			assert.Equal(t, src, d.Render(), "identity rewrite of every unit must be byte-identical")

			require.Len(t, d.markerSpans, len(d.markers))
			for i, m := range d.Markers() {
				sp := d.markerSpans[i]
				assert.Equal(t, src[sp.start:sp.end], m.Raw, "marker %d raw must be its exact source span", m.Ordinal)
			}
		})
	}
}

func TestEXT05_RichFixtureKeepsEveryRichElement(t *testing.T) {
	src := readFixture(t, "testdata/rich.xhtml")
	d, err := Parse(src)
	require.NoError(t, err)
	var raws []string
	for _, m := range d.Markers() {
		raws = append(raws, m.Raw)
	}
	all := strings.Join(raws, "\n")
	for _, want := range []string{
		`<ac:structured-macro ac:name="toc" ac:schema-version="1" data-layout="default" ac:local-id="a1b2c3d4" ac:macro-id="toc-0001"/>`,
		`<ri:user ri:account-id="557058:00000000-0000-0000-0000-000000000001" ri:local-id="u-0001"/></ac:link>`,
		`<ac:parameter ac:name="key">PROJ-123</ac:parameter></ac:structured-macro>`,
		`<ac:parameter ac:name="title">ON TRACK</ac:parameter></ac:structured-macro>`,
		`<ac:emoticon ac:name="tick" ac:emoji-shortname=":check_mark:" ac:emoji-id="2705" ac:emoji-fallback="✅"/>`,
		`<ri:attachment ri:filename="diagram.png" ri:version-at-save="1"/><ac:caption><p>Architecture</p></ac:caption></ac:image>`,
		`<ac:structured-macro ac:name="panel"`,
		`<table data-table-width="760" data-layout="default" ac:local-id="t-0002">`,
		`<time datetime="2026-10-01" />`,
		`<ac:inline-comment-marker ac:ref="c0ffee00-0000-0000-0000-000000000001">last week</ac:inline-comment-marker>`,
	} {
		assert.Contains(t, all, want)
	}
}

func TestTextGolden(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(filepath.Base(f), func(t *testing.T) {
			d, err := Parse(readFixture(t, f))
			require.NoError(t, err)
			got := d.Text()
			golden := strings.TrimSuffix(f, ".xhtml") + ".text.golden"
			if *update {
				require.NoError(t, os.WriteFile(golden, []byte(got), 0o644))
			}
			want, err := os.ReadFile(golden)
			require.NoError(t, err)
			assert.Equal(t, string(want), got)
		})
	}
}

// TestTextRich pins the editable-text vocabulary of spec §3 explicitly
// (the golden pins the whole shape; this names each rule).
func TestTextRich(t *testing.T) {
	d, err := Parse(readFixture(t, "testdata/rich.xhtml"))
	require.NoError(t, err)
	text := d.Text()
	for _, want := range []string{
		"⟦1:macro toc⟧\n\n# Release plan",
		"Owner: ⟦2:@557058:00000000-0000-0000-0000-000000000001⟧, tracked in ⟦3:jira PROJ-123⟧.",
		"We ship **on time** and _on budget_, see [the docs](https://example.com/docs?a=1&b=2) and `make app`. Статус: ⟦4:status ON TRACK⟧ ⟦5:emoticon tick⟧",
		"Reviewed ⟦6:commented last week⟧ by the team.\nSecond line.",
		"## Scope",
		"- Backend ~~draft~~ API\n  - Nested with [a link](https://example.com/a)\n- Desktop",
		"1. First\n2. Second\n   continued",
		"| **Area** | Owner |\n| --- | --- |\n| Sync | Ann Lee |\n| Синхронизация |  |",
		"⟦7:table 2x2⟧",
		"⟦8:image diagram.png⟧",
		"```go\nif a > b && c < d {\n\treturn \"]]>\"\n}\n```",
		"⟦9:macro panel⟧",
		"### Риски\n\nТекст «в кавычках» и\u00a0неразрывный пробел.",
		"Right column ⟦10:date 2026-10-01⟧ date.",
	} {
		assert.Contains(t, text, want)
	}
	for _, leak := range []string{"<p", "<ac:", "<ri:", "</", "/>", "CDATA"} {
		assert.NotContains(t, text, leak, "no raw markup leaks into the editable text")
	}
}

func TestMarkersStableAndUnique(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(filepath.Base(f), func(t *testing.T) {
			src := readFixture(t, f)
			a, err := Parse(src)
			require.NoError(t, err)
			b, err := Parse(src)
			require.NoError(t, err)
			assert.Equal(t, a.Markers(), b.Markers(), "same input, same markers")
			assertMarkerInvariants(t, a)
		})
	}
}

func assertMarkerInvariants(t *testing.T, d *Doc) {
	t.Helper()
	text := d.Text()
	for i, m := range d.Markers() {
		assert.Equal(t, i+1, m.Ordinal, "ordinals are 1..n in document order")
		assert.NotEmpty(t, m.Label)
		assert.NotContains(t, m.Label, markerClose)
		assert.NotContains(t, m.Label, markerOpen)
		assert.NotContains(t, m.Label, "\n")
		assert.NotEmpty(t, m.Raw)
		assert.Equal(t, 1, strings.Count(text, m.token()), "marker %d appears exactly once", m.Ordinal)
	}
}

func TestMarkerLabelSanitized(t *testing.T) {
	src := `<p>x <ac:structured-macro ac:name="status"><ac:parameter ac:name="title">A ⟧ B ⟦ C
D</ac:parameter></ac:structured-macro></p>`
	d, err := Parse(src)
	require.NoError(t, err)
	require.Len(t, d.Markers(), 1)
	assert.Equal(t, "status A B C D", d.Markers()[0].Label)
	assert.Equal(t, src, d.Render())
}

func TestMarkerLabelCapped(t *testing.T) {
	src := `<p><ac:structured-macro ac:name="status"><ac:parameter ac:name="title">` +
		strings.Repeat("я", 200) + `</ac:parameter></ac:structured-macro></p>`
	d, err := Parse(src)
	require.NoError(t, err)
	require.Len(t, d.Markers(), 1)
	assert.LessOrEqual(t, len([]rune(d.Markers()[0].Label)), maxLabelRunes)
}

func TestMarkersReturnsCopy(t *testing.T) {
	d, err := Parse(`<p><ac:emoticon ac:name="smile"/></p>`)
	require.NoError(t, err)
	ms := d.Markers()
	ms[0].Label = "changed"
	assert.Equal(t, "emoticon smile", d.Markers()[0].Label)
}

// TestIrregularListFallsBackWithoutLeakingOrdinals: a list whose item holds
// a table is not a markdown list; it becomes one opaque marker, and the
// markers tried for its content before the fallback must not burn ordinals.
func TestIrregularListFallsBackWithoutLeakingOrdinals(t *testing.T) {
	src := `<ul><li><p><ac:emoticon ac:name="smile"/> a</p><table><tbody><tr><td>x</td></tr></tbody></table></li></ul><p><ac:emoticon ac:name="sad"/></p>`
	d, err := Parse(src)
	require.NoError(t, err)
	assert.Equal(t, "⟦1:list 1 item⟧\n\n⟦2:emoticon sad⟧", d.Text())
	assert.Equal(t, src, d.Render())
	assertMarkerInvariants(t, d)
}

// ordinalRe strips marker ordinals, which restart at 1 in a re-parse.
var ordinalRe = regexp.MustCompile(`⟦\d+:`)

// TestUnitSpansCoverExactlyTheirContent re-parses every unit's source span
// on its own, wrapped in the element kind its block implies, and requires
// the same editable text: a span off by even one byte (cutting into a tag,
// or swallowing one) renders differently. This is what makes unit spans
// safe for an edit to replace (Task 3).
func TestUnitSpansCoverExactlyTheirContent(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(filepath.Base(f), func(t *testing.T) {
			src := readFixture(t, f)
			d, err := Parse(src)
			require.NoError(t, err)
			checked := 0
			for _, bl := range d.blocks {
				for _, u := range blockUnits(bl) {
					open, closing := wrapperFor(bl)
					re, err := Parse(open + src[u.start:u.end] + closing)
					require.NoError(t, err)
					require.Len(t, re.blocks, 1, "span %q", src[u.start:u.end])
					assert.Equal(t, ordinalRe.ReplaceAllString(u.text, "⟦:"),
						ordinalRe.ReplaceAllString(re.blocks[0].unit.text, "⟦:"),
						"span %q", src[u.start:u.end])
					checked++
				}
			}
			assert.Equal(t, len(d.units), checked, "every unit belongs to a block")
		})
	}
}

// TestUnitSpansGolden pins every unit's exact source span per fixture, an
// oracle independent of the parser: the self-consistency check above
// cannot see a span that also swallows the enclosing end tag (the re-parse
// makes the same mistake), this golden can.
func TestUnitSpansGolden(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(filepath.Base(f), func(t *testing.T) {
			src := readFixture(t, f)
			d, err := Parse(src)
			require.NoError(t, err)
			var b strings.Builder
			for _, u := range d.units {
				fmt.Fprintf(&b, "%q\n", src[u.start:u.end])
			}
			golden := strings.TrimSuffix(f, ".xhtml") + ".units.golden"
			if *update {
				require.NoError(t, os.WriteFile(golden, []byte(b.String()), 0o644))
			}
			want, err := os.ReadFile(golden)
			require.NoError(t, err)
			assert.Equal(t, string(want), b.String())
		})
	}
}

// TestRenderReplacesOnlyTheRewrittenUnit drives the edit seam: rewriting
// one unit changes exactly its span and leaves every other byte of the
// document where it was.
func TestRenderReplacesOnlyTheRewrittenUnit(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(filepath.Base(f), func(t *testing.T) {
			src := readFixture(t, f)
			d, err := Parse(src)
			require.NoError(t, err)
			for _, u := range d.units {
				repl := "<!--edited-->"
				u.out = &repl
				assert.Equal(t, src[:u.start]+repl+src[u.end:], d.Render())
				u.out = nil
			}
		})
	}
}

func blockUnits(bl *block) []*unit {
	var out []*unit
	add := func(u *unit) {
		if u != nil {
			out = append(out, u)
		}
	}
	add(bl.unit)
	for _, it := range bl.items {
		for _, u := range it.paras {
			add(u)
		}
	}
	for _, row := range bl.rows {
		for _, u := range row {
			add(u)
		}
	}
	return out
}

func wrapperFor(bl *block) (string, string) {
	switch bl.kind {
	case blockHeading:
		return "<h1>", "</h1>"
	case blockCode:
		return `<ac:structured-macro ac:name="code"><ac:plain-text-body>`, `</ac:plain-text-body></ac:structured-macro>`
	default:
		return "<p>", "</p>"
	}
}

func TestMarkerRawIsTheWholeElement(t *testing.T) {
	d, err := Parse(readFixture(t, "testdata/rich.xhtml"))
	require.NoError(t, err)
	ms := d.Markers()
	require.Len(t, ms, 10)
	assert.Equal(t, `<ac:link><ri:user ri:account-id="557058:00000000-0000-0000-0000-000000000001" ri:local-id="u-0001"/></ac:link>`, ms[1].Raw)
	assert.Equal(t, `<ac:emoticon ac:name="tick" ac:emoji-shortname=":check_mark:" ac:emoji-id="2705" ac:emoji-fallback="✅"/>`, ms[4].Raw)
	assert.Equal(t, `<time datetime="2026-10-01" />`, ms[9].Raw)
	for _, m := range ms {
		assert.True(t, strings.HasPrefix(m.Raw, "<") && strings.HasSuffix(m.Raw, ">"), "marker %d: %q", m.Ordinal, m.Raw)
	}
}

func TestRichTableCellMakesWholeTableOneMarker(t *testing.T) {
	src := `<table><tbody><tr><td>a<br/>b</td></tr></tbody></table>`
	d, err := Parse(src)
	require.NoError(t, err)
	assert.Equal(t, "⟦1:table 1x1⟧", d.Text())
	assert.Empty(t, d.units, "an opaque table exposes no editable unit")
}

func TestPipeInCellMakesTableOpaque(t *testing.T) {
	d, err := Parse(`<table><tbody><tr><td>a | b</td></tr></tbody></table>`)
	require.NoError(t, err)
	assert.Equal(t, "⟦1:table 1x1⟧", d.Text())
}

func TestHeadingLevelsAndLineBreakInHeading(t *testing.T) {
	d, err := Parse(`<h4>Four</h4><h6>Six<br/>more</h6>`)
	require.NoError(t, err)
	assert.Equal(t, "#### Four\n\n###### Six⟦1:line break⟧more", d.Text())
}

func TestTopLevelBareTextIsAParagraph(t *testing.T) {
	src := "\n  Hello <strong>world</strong>\n<p>next</p>"
	d, err := Parse(src)
	require.NoError(t, err)
	assert.Equal(t, "Hello **world**\n\nnext", d.Text())
	assert.Equal(t, src, d.Render())
}

func TestEmphasisWhitespaceMovesOutside(t *testing.T) {
	d, err := Parse(`<p>a<strong> b </strong>c <em></em>d</p>`)
	require.NoError(t, err)
	assert.Equal(t, "a **b** c d", d.Text())
}

func TestCodeSpanWithBacktick(t *testing.T) {
	d, err := Parse("<p><code>a`b</code></p>")
	require.NoError(t, err)
	assert.Equal(t, "``a`b``", d.Text())
}

func TestCodeFenceLongerThanBody(t *testing.T) {
	d, err := Parse("<ac:structured-macro ac:name=\"noformat\"><ac:plain-text-body><![CDATA[x\n```\ny]]></ac:plain-text-body></ac:structured-macro>")
	require.NoError(t, err)
	assert.Equal(t, "````\nx\n```\ny\n````", d.Text())
}

func TestCodeMacroWithoutBodyIsMarker(t *testing.T) {
	d, err := Parse(`<ac:structured-macro ac:name="code"/>`)
	require.NoError(t, err)
	assert.Equal(t, "⟦1:macro code⟧", d.Text())
}

func TestUnclosedAndStrayTagsStillRoundTrip(t *testing.T) {
	for _, src := range []string{
		`<p>open <strong>bold`,
		`</div><p>a</p></span>`,
		`<p>a</b>c</p>`,
		`<p>tail <`,
		`<ul><li>x`,
	} {
		d, err := Parse(src)
		require.NoError(t, err, src)
		assert.Equal(t, src, d.Render(), src)
	}
}

func TestTooDeepIsAnError(t *testing.T) {
	src := strings.Repeat("<span>", maxDepth+1) + "x"
	_, err := Parse(src)
	require.ErrorIs(t, err, ErrTooDeep)
	_, err = Parse(strings.Repeat("<span>", maxDepth) + "x")
	require.NoError(t, err)
}

func TestEmptyAndWhitespaceDocs(t *testing.T) {
	for _, src := range []string{"", "  \n", "<p />", "<p></p>"} {
		d, err := Parse(src)
		require.NoError(t, err)
		assert.Equal(t, "", d.Text(), "%q", src)
		assert.Equal(t, src, d.Render())
	}
}

func FuzzRoundTrip(f *testing.F) {
	files, _ := filepath.Glob("testdata/*.xhtml")
	for _, p := range files {
		raw, err := os.ReadFile(p)
		if err == nil {
			f.Add(string(raw))
		}
	}
	f.Add("<p>a<![CDATA[b]]]]><![CDATA[>c]]></p>")
	f.Fuzz(func(t *testing.T, src string) {
		d, err := Parse(src)
		if err != nil {
			if !errors.Is(err, ErrTooDeep) {
				t.Fatalf("unexpected parse error: %v", err)
			}
			return
		}
		if got := d.Render(); got != src {
			t.Fatalf("round trip: got %q want %q", got, src)
		}
		checkFuzzMarkers(t, d)
		checkFuzzSpans(t, d)
	})
}

// checkFuzzMarkers: every marker's Raw is its exact recorded source span,
// marker spans are sorted and never overlap (a nested marker would be an
// orphan: its token inside another marker's Raw), labels are clean, and
// each token appears exactly once in Text() — unless the page's own text
// or attributes contain a marker bracket, which could legitimately repeat
// a token.
func checkFuzzMarkers(t *testing.T, d *Doc) {
	t.Helper()
	text := d.Text()
	literal := srcHasMarkerBracket(d.src)
	prev := 0
	for i, m := range d.markers {
		sp := d.markerSpans[i]
		if sp.start < prev || d.src[sp.start:sp.end] != m.Raw {
			t.Fatalf("marker %d span [%d,%d) bad or overlapping (prev end %d)", m.Ordinal, sp.start, sp.end, prev)
		}
		prev = sp.end
		if strings.Contains(m.Label, markerClose) || strings.Contains(m.Label, markerOpen) {
			t.Fatalf("bad label %q", m.Label)
		}
		if !literal && strings.Count(text, m.token()) != 1 {
			t.Fatalf("marker %d token appears %d times in %q", m.Ordinal, strings.Count(text, m.token()), text)
		}
	}
}

// checkFuzzSpans: unit spans are sorted and non-overlapping, block spans
// too, and every block lies inside its container's content.
func checkFuzzSpans(t *testing.T, d *Doc) {
	t.Helper()
	prev := 0
	for _, u := range d.units {
		if u.start < prev || u.end < u.start || u.end > len(d.src) {
			t.Fatalf("unit span [%d,%d) out of order after %d", u.start, u.end, prev)
		}
		prev = u.end
	}
	prev = 0
	for _, bl := range d.blocks {
		c := d.containers[bl.container].content
		if bl.start < prev || bl.end < bl.start || bl.start < c.start || bl.end > c.end {
			t.Fatalf("block span [%d,%d) bad (prev %d, container %+v)", bl.start, bl.end, prev, c)
		}
		prev = bl.end
	}
}

// srcHasMarkerBracket reports whether any decoded text or attribute value
// of src carries a marker bracket.
func srcHasMarkerBracket(src string) bool {
	root, err := parseTree(src)
	if err != nil {
		return true
	}
	var walk func(n *node) bool
	walk = func(n *node) bool {
		if strings.ContainsAny(n.text, markerOpen+markerClose) {
			return true
		}
		for _, a := range n.attrs {
			if strings.ContainsAny(a.Val, markerOpen+markerClose) {
				return true
			}
		}
		for _, ch := range n.children {
			if walk(ch) {
				return true
			}
		}
		return false
	}
	return walk(root)
}
