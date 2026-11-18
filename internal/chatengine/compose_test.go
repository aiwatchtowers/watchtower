package chatengine

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chatstore"
)

// composeCase is one testdata/compose_cases.json case. The Swift twin
// (ComposeFixtureTests) composes the same input with ChatQuoteReply +
// ChatTurnComposer, or ArtifactCommentMessage when artifact is set.
type composeCase struct {
	Name     string    `json:"name"`
	Text     string    `json:"text"`
	Skill    string    `json:"skill"`
	Mentions []Mention `json:"mentions"`
	Quotes   []Quote   `json:"quotes"`
	Artifact *struct {
		Title    string `json:"title"`
		Key      string `json:"key"`
		Version  int    `json:"version"`
		Comments []struct {
			Quote   string `json:"quote"`
			Heading string `json:"heading"`
			Body    string `json:"body"`
		} `json:"comments"`
	} `json:"artifact"`
	Stored string `json:"stored"`
}

func loadComposeCases(t *testing.T) []composeCase {
	t.Helper()
	b, err := os.ReadFile("testdata/compose_cases.json")
	require.NoError(t, err)
	var cases []composeCase
	require.NoError(t, json.Unmarshal(b, &cases))
	require.GreaterOrEqual(t, len(cases), 10)
	return cases
}

// TestCompose_SharedCases: ComposeOwnerText (and the artifact comment
// message) equal the Swift composer on every shared case.
func TestCompose_SharedCases(t *testing.T) {
	for _, c := range loadComposeCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			if c.Artifact != nil {
				items := make([]chatstore.CommentItem, len(c.Artifact.Comments))
				for i, cm := range c.Artifact.Comments {
					items[i] = chatstore.CommentItem{Quote: cm.Quote, Heading: cm.Heading, Body: cm.Body}
				}
				msg := chatstore.ComposeArtifactComments(c.Artifact.Title, c.Artifact.Key, c.Artifact.Version, items)
				assert.Equal(t, c.Stored, ComposeOwnerText(msg, Compose{}))
				return
			}
			assert.Equal(t, c.Stored, ComposeOwnerText(c.Text, Compose{Skill: c.Skill, Mentions: c.Mentions, Quotes: c.Quotes}))
		})
	}
}
