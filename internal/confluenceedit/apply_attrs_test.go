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
