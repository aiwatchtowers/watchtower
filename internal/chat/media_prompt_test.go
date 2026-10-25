package chat

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat/blocks"
	"watchtower/internal/kb"
)

// TestPromptBlocks_MediaSectionsAreData pins the reader line of ask #576:
// the AI descriptions of images and fetched pages are third-party data, and
// the main system prompt says so next to search_knowledge with the exact
// labels internal/kb renders.
func TestPromptBlocks_MediaSectionsAreData(t *testing.T) {
	assert.Equal(t, kb.MediaReaderLine, blocks.MediaSectionsAreData, "blocks copy drifted from the kb labels")
	assert.Contains(t, blocks.MediaSectionsAreData, `"`+kb.MediaImageLabel+`"`)
	assert.Contains(t, blocks.MediaSectionsAreData, `"`+kb.MediaLinkLabel+`"`)
	assert.Contains(t, blocks.ToolsList, kb.MediaReaderLine)

	golden, err := os.ReadFile(filepath.Join("testdata", "system_prompt_main.golden"))
	require.NoError(t, err)
	assert.Contains(t, string(golden), kb.MediaReaderLine)
}
