package chat

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestChat05_ContractSaysArtifactsNeverSend teaches the fence syntax, every
// kind's attributes, and the "artifacts never send" rule (CHAT-05). Renamed
// from TestArtifactsContract_TeachesFenceKindsAndRules per preflight A55.
// BEHAVIOR CHAT-05 — see docs/inventory/chat.md
func TestChat05_ContractSaysArtifactsNeverSend(t *testing.T) {
	c := ArtifactsContract()
	for _, want := range []string{
		`:::artifact key="`, "\n:::\n",
		"document", "table", "email", "slack", "event", "code",
		`to="`, `subject="`, `channel="`, `thread_ts="`, `permalink="`, `start="`, `attendees="`, `language="`,
		`\"`, "SAME key", "Never say or imply", "outside any ``` code block", "never send",
	} {
		assert.Contains(t, c, want)
	}
}

func TestArtifactsContract_EmbedsTheSharedExamples(t *testing.T) {
	c := ArtifactsContract()
	assert.Contains(t, c, strings.TrimSpace(artifactExamples))
	openers, closers := 0, 0
	for _, line := range strings.Split(artifactExamples, "\n") {
		if strings.HasPrefix(line, ":::artifact ") {
			openers++
		}
		if strings.TrimSpace(line) == ":::" {
			closers++
		}
	}
	assert.Equal(t, 3, openers)
	assert.Equal(t, 3, closers, "every example must be closed")
}

func TestArtifactsContract_StaysSmall(t *testing.T) {
	assert.Less(t, len(ArtifactsContract()), 4500, "the contract is one block of a 40k-char prompt budget")
}

// TestArtifactsContract_CommentsAreAnsweredWithANewVersion: the owner's
// "Send N comments" message is ordinary chat text; the contract tells the
// model to answer it with a new version of the same key, which the Desktop
// re-anchors the comments onto.
func TestArtifactsContract_CommentsAreAnsweredWithANewVersion(t *testing.T) {
	c := ArtifactsContract()
	assert.Contains(t, c, "sends comments on an artifact")
	assert.Contains(t, c, "new version of that artifact under the SAME key")
}
