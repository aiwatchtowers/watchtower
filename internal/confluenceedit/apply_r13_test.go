package confluenceedit

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Ruling R13: a replace_section never loses formatting through pairing.
// When a gap deletes one block and changes another of the same kind, the
// text alone cannot say which original the changed block came from — so a
// rich original there refuses the edit rather than being silently deleted
// under a plain one re-rendered with its new text.
func TestEXT05_SectionRewriteRefusesAmbiguousPairing(t *testing.T) {
	for name, tc := range map[string]struct{ src, body, want string }{
		"delete plain, edit centred": {
			`<h2>S</h2><p>Alpha</p><p style="text-align:center">Beta</p>`,
			"Beta edited", `paragraph "Beta"`,
		},
		"keep first, delete plain, edit right-aligned": {
			`<h2>S</h2><p>Alpha</p><p>Beta</p><p style="text-align:right">Gamma</p>`,
			"Alpha\n\nGamma edited", `paragraph "Gamma"`,
		},
	} {
		t.Run(name, func(t *testing.T) {
			_, _, err := Apply(mustParse(t, tc.src), []Edit{sectionEdit("S", tc.body)})
			require.Error(t, err)
			assert.Contains(t, err.Error(), tc.want)
			assert.Contains(t, err.Error(), "attributes such as alignment or style")
		})
	}
}

// A rich block may still be deleted when nothing in the section could be
// its edit: no changed block of its kind is anywhere in it (R14).
func TestSectionRewriteDeletesARichBlockUnambiguously(t *testing.T) {
	out, _ := applyOK(t, `<h2>S</h2><p style="text-align:center">Beta</p><p>Alpha</p>`, sectionEdit("S", "- item\n\nAlpha"))
	assert.Equal(t, `<h2>S</h2><ul><li>item</li></ul><p>Alpha</p>`, out)
}

// Ruling R13: a block whose text is unchanged but was moved keeps its
// bytes at its new place — a code macro's title, a table's layout and a
// paragraph's alignment survive a reorder.
func TestEXT05_SectionRewriteMoveKeepsBytes(t *testing.T) {
	for name, tc := range map[string]struct{ rich, body string }{
		"centred paragraph": {`<p style="text-align:center">Centred</p>`, "Plain\n\nCentred"},
		"code with title": {
			`<ac:structured-macro ac:name="code"><ac:parameter ac:name="title">T</ac:parameter><ac:plain-text-body><![CDATA[x := 1]]></ac:plain-text-body></ac:structured-macro>`,
			"Plain\n\n```\nx := 1\n```",
		},
		"wide table": {
			`<table data-layout="wide"><tbody><tr><th>h</th></tr><tr><td>1</td></tr></tbody></table>`,
			"Plain\n\n| h |\n| --- |\n| 1 |",
		},
	} {
		t.Run(name, func(t *testing.T) {
			for _, sep := range []string{"", "\n"} {
				src := `<h2>S</h2>` + sep + tc.rich + sep + `<p>Plain</p>`
				d := mustParse(t, src)
				_, body := sectionBody(t, d)
				require.Equal(t, tc.body, "Plain\n\n"+body[:len(body)-len("\n\nPlain")], "fixture text")
				out, changes, err := Apply(d, []Edit{sectionEdit("S", tc.body)})
				require.NoError(t, err)
				assert.Contains(t, out, tc.rich)
				assert.Equal(t, `<h2>S</h2>`+sep+`<p>Plain</p>`+tc.rich, out)
				assert.Empty(t, changes[0].Removed)
			}
		})
	}
}

// A moved block stays editable: a later replace_text rewrites its unit
// inside the moved original bytes.
func TestSectionRewriteMovedBlockTakesLaterUnitEdit(t *testing.T) {
	src := `<h2>S</h2><p style="text-align:center">Centred <strong>b</strong></p><p>Plain</p>`
	out, _ := applyOK(t, src, sectionEdit("S", "Plain\n\nCentred **b**"), text("Centred", "Middle"))
	assert.Equal(t, `<h2>S</h2><p>Plain</p><p style="text-align:center">Middle <strong>b</strong></p>`, out)
}

// A new block inserted where a moved block used to start goes before the
// deletion of that old place (both start at the same byte).
func TestSectionRewriteInsertWhereAMovedBlockWas(t *testing.T) {
	out, _ := applyOK(t, `<h2>S</h2><p style="text-align:center">A</p><p>B</p>`, sectionEdit("S", "X\n\nB\n\nA"))
	assert.Equal(t, `<h2>S</h2><p>X</p><p>B</p><p style="text-align:center">A</p>`, out)
}
