package confluenceedit

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// Emphasis and code carrying any attribute are markers, not markdown: a
// rewrite elsewhere in the unit writes them back byte for byte, attributes
// included (the skeleton guard compares tag names only, so a dropped
// attribute would otherwise go unnoticed).
func TestApplyKeepsAttributesOnEmphasisAndCode(t *testing.T) {
	for name, elem := range map[string]string{
		"strong with style": `<strong style="color:red">bold</strong>`,
		"code with class":   `<code class="lang-go">x := 1</code>`,
		"em with data-":     `<em data-mark="x">it</em>`,
		"b with style":      `<b style="font-size:2em">big</b>`,
		"s with class":      `<s class="gone">old</s>`,
	} {
		t.Run(name, func(t *testing.T) {
			src := `<p>Keep ` + elem + ` and change word here.</p>`
			out, _ := applyOK(t, src, text("word", "phrase"))
			assert.Equal(t, `<p>Keep `+elem+` and change phrase here.</p>`, out)
		})
	}
}

// Bare emphasis and code stay editable markdown.
func TestApplyBareEmphasisStaysMarkdown(t *testing.T) {
	d := mustParse(t, `<p>Keep <strong>bold</strong> and <code>x</code> here.</p>`)
	assert.Equal(t, "Keep **bold** and `x` here.", d.Text())
}

// Two links to one address with different start tags (a smart-link card
// and a plain link) cannot be told apart in the text: a rewrite would give
// both the first one's tag, silently turning the plain link into a card.
// Such a rewrite is refused; an edit that re-renders neither goes through.
func TestApplyRefusesToMergeTwoLinksToOneAddress(t *testing.T) {
	const card = `<a href="https://x.example/a" data-card-appearance="inline">A</a>`
	const plain = `<a href="https://x.example/a">B</a>`

	src := `<p>` + card + ` and ` + plain + ` end</p><p>other</p>`
	ee := applyErr(t, src, text("end", "fin"))
	assert.Contains(t, ee.Error(), "two links to https://x.example/a with different link settings")
	out, _ := applyOK(t, src, text("other", "else"))
	assert.Equal(t, `<p>`+card+` and `+plain+` end</p><p>else</p>`, out)

	twin := `<p>` + plain + ` and ` + plain + ` end</p>`
	out, _ = applyOK(t, twin, text("end", "fin"))
	assert.Equal(t, `<p>`+plain+` and `+plain+` fin</p>`, out, "same address, same tag: still editable")

	section := `<h2>S</h2><p>see ` + card + `</p><p>and ` + plain + ` here</p><p>plain text</p>`
	ee = applyErr(t, section, sectionEdit("S", "see [A](https://x.example/a)\n\nand [B](https://x.example/a) there\n\nplain text"))
	assert.Contains(t, ee.Error(), "two links to https://x.example/a with different link settings")
	out, _ = applyOK(t, section, sectionEdit("S", "see [A](https://x.example/a)\n\nand [B](https://x.example/a) here\n\nplain text changed"))
	assert.Equal(t, `<h2>S</h2><p>see `+card+`</p><p>and `+plain+` here</p><p>plain text changed</p>`, out,
		"blocks keeping their text keep their bytes; the changed one has no such link")
}
