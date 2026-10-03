package memory

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestCodeQuestionGuard_ChatIngestNeverReadsCodeQuestions: memory's chat
// ingest is the one Go reader that lists owner turns across conversations.
// Even with every chat source on, a workbench code question (spec
// 2026-10-02 §9.4) is neither ingested nor accepted as owner evidence.
func TestCodeQuestionGuard_ChatIngestNeverReadsCodeQuestions(t *testing.T) {
	d := newTestDB(t)
	conv := seedChatConversation(t, d, "code_question", "1:Sources/App.swift:12")
	seedChatMessage(t, d, conv, "user", "what does this function do?", 1720000000)
	seedChatMessage(t, d, conv, "assistant", "It parses the config.", 1720000001)

	widest := chatContextTypes(true)
	assert.NotContains(t, widest, "code_question")
	turns, err := d.ListOwnerChatTurns(0, widest)
	require.NoError(t, err)
	assert.Empty(t, turns)
	ok, err := d.OwnerChatTurnExists(conv, 1720000000, widest)
	require.NoError(t, err)
	assert.False(t, ok)
}
