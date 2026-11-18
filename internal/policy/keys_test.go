package policy

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestKeyDocs_EveryKeyDocumented pins that the IT key list names every key
// the package knows, in display order, each with a type, default and effect.
func TestKeyDocs_EveryKeyDocumented(t *testing.T) {
	docs := KeyDocs()
	var keys []string
	for _, d := range docs {
		keys = append(keys, d.Key)
		assert.NotEmpty(t, d.Type, d.Key)
		assert.NotEmpty(t, d.Default, d.Key)
		assert.NotEmpty(t, d.Effect, d.Key)
	}
	assert.Equal(t, append(append([]string{}, Keys...), ReservedKeys...), keys)
	assert.Len(t, keyDocs, len(keys), "a documented key that is not in Keys or ReservedKeys")
}

// TestITGuideURL_NotPlaceholder keeps the placeholder IT page address out of
// main: the umbrella merge checklist requires it to run unskipped.
func TestITGuideURL_NotPlaceholder(t *testing.T) {
	assert.NotEqual(t, itGuidePlaceholder, ITGuideURL)
}
