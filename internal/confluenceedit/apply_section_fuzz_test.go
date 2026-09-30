package confluenceedit

import (
	"os"
	"strings"
	"testing"
)

// fuzzEditWord is what FuzzSectionMerge appends to the block it edits.
const fuzzEditWord = "zzedited"

// FuzzSectionMerge is ruling R14's property: a replace_section whose new
// body permutes the section's blocks (rotate, swap two, reverse), maybe
// edits one of them and maybe drops one either is refused, or keeps the
// original bytes of every block markdown cannot carry faithfully — unless
// that block is the one dropped and no edited block of its kind is in the
// body (an unambiguous deletion the diff shows). However the merge pairs,
// moves or derives blocks, a rich block is never silently re-rendered or
// dropped under a changed one.
func FuzzSectionMerge(f *testing.F) {
	for _, name := range []string{"rich", "layout", "table-blocks", "lists", "macros"} {
		if src, err := os.ReadFile("testdata/" + name + ".xhtml"); err == nil {
			for mode := range uint8(3) {
				f.Add(string(src), uint8(0), mode, uint8(1), uint8(2), uint8(1), uint8(0))
			}
		}
	}
	f.Add(sectionsSrc, uint8(0), uint8(0), uint8(0), uint8(1), uint8(1), uint8(0))
	for _, src := range judgeCases {
		f.Add(src, uint8(0), uint8(1), uint8(0), uint8(1), uint8(1), uint8(0))
	}
	for _, rich := range []string{r14Centred, r14Code, r14Wide, r14BrRich, r14BrPlain} {
		f.Add(`<h2>S</h2>`+rich+`<p>Plain</p>`, uint8(0), uint8(0), uint8(0), uint8(1), uint8(1), uint8(0))
		f.Add(`<h2>S</h2><p>Plain</p>`+rich, uint8(0), uint8(0), uint8(1), uint8(0), uint8(1), uint8(0))
		f.Add(`<h2>S</h2><p>A</p>`+rich+`<p>B</p>`, uint8(0), uint8(1), uint8(0), uint8(2), uint8(2), uint8(1))
	}
	f.Add(`<h2>S</h2><p style="text-align:center">Note</p><p>mid</p><p>Note</p>`, uint8(0), uint8(0), uint8(2), uint8(0), uint8(1), uint8(0))
	f.Add(`<h2>S</h2><p style="text-align:center">N</p><p>mid</p><p style="text-align:right">N</p>`, uint8(0), uint8(0), uint8(2), uint8(0), uint8(1), uint8(0))
	f.Fuzz(func(t *testing.T, src string, head, mode, x, y, edit, drop uint8) {
		d, err := Parse(src)
		if err != nil || strings.Contains(src, fuzzEditWord) {
			return
		}
		checkSectionMerge(t, d, int(head), int(mode), int(x), int(y), int(edit), int(drop))
	})
}

// checkSectionMerge builds one permuted new body for the head-th heading's
// section and checks the R14 property on it.
func checkSectionMerge(t *testing.T, d *Doc, head, mode, x, y, edit, drop int) {
	t.Helper()
	a := newApplier(d)
	var heads []int
	for i, bl := range a.d.blocks {
		if bl.kind == blockHeading && unitText(bl.unit) != "" {
			heads = append(heads, i)
		}
	}
	if len(heads) == 0 {
		return
	}
	hi := heads[head%len(heads)]
	region, err := a.d.sectionRegion(hi)
	if err != nil {
		return
	}
	var blocks []*block
	var texts []string
	for _, bl := range a.regionBlocks(a.d.blocks[hi], region) {
		if s := a.d.blockText(bl); s != "" {
			blocks, texts = append(blocks, bl), append(texts, s)
		}
	}
	if len(blocks) == 0 || cleanModelText(strings.Join(texts, "\n\n")) != strings.Join(texts, "\n\n") {
		return
	}
	order := permute(len(blocks), mode, x, y)
	dropped := -1
	if drop%2 == 1 && len(order) > 1 {
		k := (drop / 2) % len(order)
		dropped = order[k]
		order = append(order[:k:k], order[k+1:]...)
	}
	edited := -1
	if edit%2 == 1 {
		edited = order[(edit/2)%len(order)]
	}
	parts := make([]string, len(order))
	for k, i := range order {
		parts[k] = texts[i]
		if i == edited {
			if parts[k] = editBlockText(blocks[i], texts[i]); parts[k] == texts[i] {
				edited = -1
			}
		}
	}
	out, _, err := Apply(d, []Edit{sectionEdit(unitText(a.d.blocks[hi].unit), strings.Join(parts, "\n\n"))})
	checkEditError(t, err)
	if err != nil {
		return
	}
	for i, o := range blocks {
		if a.lossy(o, texts[i]) == nil || strings.Contains(out, d.src[o.start:o.end]) {
			continue
		}
		if dropped >= 0 && dropsAs(a, blocks[dropped], texts[dropped], o, texts[i]) && (edited < 0 || blocks[edited].kind != o.kind) {
			continue // an unambiguous deletion
		}
		t.Fatalf("section rewrite lost the rich %s %s (dropped %d, edited %d)\nsrc: %q\nbody: %q\nout: %q",
			blockKindName(o.kind), snippet(texts[i]), dropped, edited, d.src, strings.Join(parts, "\n\n"), out)
	}
}

// dropsAs reports that dropping block d may delete block o instead: o is d,
// or both are rich blocks of one kind with the same text — the new body
// cannot say which of the two it dropped, so losing either is the drop.
// (A plain block of o's text is not enough: then the rich one must stay.)
func dropsAs(a *applier, d *block, dText string, o *block, oText string) bool {
	return d == o || d.kind == o.kind && dText == oText && a.lossy(d, dText) != nil
}

// permute is 0..n-1 rotated by one, with two positions swapped, or
// reversed.
func permute(n, mode, x, y int) []int {
	order := make([]int, n)
	for i := range order {
		order[i] = i
	}
	switch mode % 3 {
	case 0:
		order = append(order[1:], order[0])
	case 1:
		i, j := x%n, y%n
		order[i], order[j] = order[j], order[i]
	default:
		for i, j := 0, n-1; i < j; i, j = i+1, j-1 {
			order[i], order[j] = order[j], order[i]
		}
	}
	return order
}

// editBlockText appends a word to a block's content in a way its markdown
// kind keeps: inside a code fence, in a table's last cell, or at the end.
// A marker block is left as it is (it has no content to edit).
func editBlockText(bl *block, text string) string {
	lines := strings.Split(text, "\n")
	last := len(lines) - 1
	switch bl.kind {
	case blockMarker:
		return text
	case blockCode:
		if last < 1 {
			return text
		}
		lines = append(lines[:last:last], fuzzEditWord, lines[last])
	case blockTable:
		if !strings.HasSuffix(lines[last], " |") {
			return text
		}
		lines[last] = strings.TrimSuffix(lines[last], " |") + " " + fuzzEditWord + " |"
	default:
		lines[last] += " " + fuzzEditWord
	}
	return strings.Join(lines, "\n")
}
