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
func TestSectionRewriteRefusesAmbiguousPairingWithARichBlock(t *testing.T) {
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

// A rich block may still be deleted when nothing in its gap could be its
// edit: no new block of its kind shares the gap.
func TestSectionRewriteDeletesARichBlockUnambiguously(t *testing.T) {
	out, _ := applyOK(t, `<h2>S</h2><p style="text-align:center">Beta</p><p>Alpha</p>`, sectionEdit("S", "- item\n\nAlpha"))
	assert.Equal(t, `<h2>S</h2><ul><li>item</li></ul><p>Alpha</p>`, out)
}
