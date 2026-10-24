package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func seedChatArtifact(t *testing.T, d *db.DB, version int, kind, title, content string) {
	t.Helper()
	exec(t, d, `INSERT OR IGNORE INTO chat_conversations (id, title, created_at, updated_at) VALUES (5, 'Release planning', 1, 1)`)
	exec(t, d, `INSERT OR IGNORE INTO chat_messages (id, conversation_id, role, text, created_at) VALUES (1, 5, 'assistant', 'x', 1)`)
	exec(t, d, `INSERT INTO chat_artifacts (conversation_id, message_id, artifact_key, version, kind, title, content, created_at)
		VALUES (5, 1, 'plan', ?, ?, ?, ?, 1)`, version, kind, title, content)
}

func TestChatArtifactSource_IndexesKeptVersionOnly(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedChatArtifact(t, d, 1, "document", "Plan v1", "first draft of the rollout")
	seedChatArtifact(t, d, 2, "document", "Plan v2", "second draft of the rollout")
	exec(t, d, `INSERT INTO chat_knowledge_artifacts (conversation_id, artifact_key, version, kept_at) VALUES (5, 'plan', 1, '2026-10-24T10:00:00Z')`)

	src := chatArtifactSource{}
	doc, err := src.Build(ctx, d, "chat_artifact:5:plan")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "chat_artifact", doc.Source)
	assert.Equal(t, "Plan v1", doc.Title)
	assert.Equal(t, "Release planning document", doc.Meta)
	require.Len(t, doc.Sections, 1)
	assert.Equal(t, "first draft of the rollout", doc.Sections[0].Text)

	keys, next, done, err := src.Changed(ctx, d, "", testNow())
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, []string{"chat_artifact:5:plan"}, keys)
	assert.Equal(t, "2026-10-24T10:00:00Z", next)
	all, err := src.Keys(ctx, d)
	require.NoError(t, err)
	assert.Equal(t, keys, all)

	// The row's version moves: the new version is indexed, and the change shows.
	exec(t, d, `UPDATE chat_knowledge_artifacts SET version = 2, kept_at = '2026-10-24T11:00:00Z'`)
	keys, next, _, err = src.Changed(ctx, d, next, testNow())
	require.NoError(t, err)
	assert.Equal(t, []string{"chat_artifact:5:plan"}, keys)
	assert.Equal(t, "2026-10-24T11:00:00Z", next)
	doc, err = src.Build(ctx, d, "chat_artifact:5:plan")
	require.NoError(t, err)
	assert.Equal(t, "Plan v2", doc.Title)
}

func TestChatArtifactSource_HTMLRenderedAsText(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedChatArtifact(t, d, 1, "html", "Page",
		`<html><head><style>p{color:red}</style></head><body><h1>Launch</h1><script>var secret=1;</script><p>Ship on <b>Friday</b></p></body></html>`)
	exec(t, d, `INSERT INTO chat_knowledge_artifacts (conversation_id, artifact_key, version, kept_at) VALUES (5, 'plan', 1, '2026-10-24T10:00:00Z')`)
	doc, err := chatArtifactSource{}.Build(ctx, d, "chat_artifact:5:plan")
	require.NoError(t, err)
	require.NotNil(t, doc)
	var text string
	for _, s := range doc.Sections {
		text += s.Text + "\n"
	}
	assert.Contains(t, text, "Launch")
	assert.Contains(t, text, "Ship on Friday")
	assert.NotContains(t, text, "secret")
	assert.NotContains(t, text, "color:red")
	assert.NotContains(t, text, "<")
}

func TestChatArtifactSource_GoneWithConversation(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedChatArtifact(t, d, 1, "document", "Plan", "body")
	exec(t, d, `INSERT INTO chat_knowledge_artifacts (conversation_id, artifact_key, version, kept_at) VALUES (5, 'plan', 1, '2026-10-24T10:00:00Z')`)
	exec(t, d, `DELETE FROM chat_conversations WHERE id = 5`)

	doc, err := chatArtifactSource{}.Build(ctx, d, "chat_artifact:5:plan")
	require.NoError(t, err)
	assert.Nil(t, doc)
	keys, err := chatArtifactSource{}.Keys(ctx, d)
	require.NoError(t, err)
	assert.Empty(t, keys)
}

// TestChatArtifactSource_SkipsCodeQuestionChats: an artifact kept from a
// workbench code question is never indexed (spec 2026-10-02 §9.4, the
// code-question guard in internal/tools): Changed, Keys and Build all leave
// it out.
func TestChatArtifactSource_SkipsCodeQuestionChats(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedChatArtifact(t, d, 1, "document", "Plan", "body")
	exec(t, d, `UPDATE chat_conversations SET context_type = 'code_question', context_id = '4:main.go' WHERE id = 5`)
	exec(t, d, `INSERT INTO chat_knowledge_artifacts (conversation_id, artifact_key, version, kept_at) VALUES (5, 'plan', 1, '2026-10-24T10:00:00Z')`)

	src := chatArtifactSource{}
	doc, err := src.Build(ctx, d, "chat_artifact:5:plan")
	require.NoError(t, err)
	assert.Nil(t, doc)
	keys, _, _, err := src.Changed(ctx, d, "", testNow())
	require.NoError(t, err)
	assert.Empty(t, keys)
	all, err := src.Keys(ctx, d)
	require.NoError(t, err)
	assert.Empty(t, all)

	// Another context type (a target chat) is still indexed.
	exec(t, d, `UPDATE chat_conversations SET context_type = 'target', context_id = '7' WHERE id = 5`)
	all, err = src.Keys(ctx, d)
	require.NoError(t, err)
	assert.Equal(t, []string{"chat_artifact:5:plan"}, all)
}

func TestChatArtifactSource_Registered(t *testing.T) {
	assert.Contains(t, sourceNames(), "chat_artifact")
}

// seedKeptChatArtifact is the shared-fixture document (seedAll).
func seedKeptChatArtifact(t *testing.T, d *db.DB) {
	t.Helper()
	seedChatArtifact(t, d, 1, "document", "Rollout plan", "Чертёж выкладки на три этапа")
	exec(t, d, `INSERT INTO chat_knowledge_artifacts (conversation_id, artifact_key, version, kept_at) VALUES (5, 'plan', 1, '2026-09-11T10:00:00Z')`)
}
