package kb

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBuildChunks_PacksSmallSections(t *testing.T) {
	chunks := BuildChunks([]Section{{Text: "a", Anchor: "1"}, {Text: "b", Anchor: "2"}})
	require.Len(t, chunks, 1)
	assert.Equal(t, "a\nb", chunks[0].Body)
	assert.Equal(t, "1", chunks[0].Anchor)
}

func TestBuildChunks_StartsNewChunkAtLimit(t *testing.T) {
	big := strings.Repeat("я", 1500)
	chunks := BuildChunks([]Section{{Text: big, Anchor: "1"}, {Text: big, Anchor: "2"}})
	require.Len(t, chunks, 2)
	assert.Equal(t, "2", chunks[1].Anchor)
	assert.Equal(t, 1, chunks[1].Idx)
}

func TestBuildChunks_SplitsOversizedSectionAtWhitespace(t *testing.T) {
	words := strings.Repeat("слово ", 900) // 5400 runes
	chunks := BuildChunks([]Section{{Text: words, Anchor: "a"}})
	require.GreaterOrEqual(t, len(chunks), 3)
	for _, c := range chunks {
		assert.LessOrEqual(t, utf8.RuneCountInString(c.Body), ChunkChars)
		assert.Equal(t, "a", c.Anchor)
		assert.False(t, strings.HasPrefix(c.Body, " "))
	}
}

func TestBuildChunks_HardSplitWithoutWhitespace(t *testing.T) {
	chunks := BuildChunks([]Section{{Text: strings.Repeat("x", 4100)}})
	require.Len(t, chunks, 3)
	assert.Equal(t, ChunkChars, utf8.RuneCountInString(chunks[0].Body))
}

func TestBuildChunks_SkipsBlankSections(t *testing.T) {
	assert.Empty(t, BuildChunks([]Section{{Text: "  "}, {Text: ""}}))
	assert.Empty(t, BuildChunks(nil))
}

func TestContentHash_ChangesWithContent(t *testing.T) {
	d := &Doc{ID: "idea:1", Title: "T", Time: time.Unix(10, 0), Anchor: map[string]string{"idea_id": "1"}}
	h1 := contentHash(d, BuildChunks([]Section{{Text: "a"}}))
	h2 := contentHash(d, BuildChunks([]Section{{Text: "b"}}))
	assert.NotEqual(t, h1, h2)
	assert.Equal(t, h1, contentHash(d, BuildChunks([]Section{{Text: "a"}})))
}
