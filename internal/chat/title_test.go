package chat

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

type titleGen struct {
	reply string
	calls int
	// before runs inside Generate: the owner renaming the chat mid-call.
	before func()
}

func (g *titleGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls++
	if g.before != nil {
		g.before()
	}
	return g.reply, &digest.Usage{}, "", nil
}

func titleDB(t *testing.T, source string) (*db.DB, int64) {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "w.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	res, err := d.Exec(`INSERT INTO chat_conversations (title, title_source, created_at, updated_at) VALUES ('Mine', ?, 1, 1)`, source)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, 'user', 'hi', 1), (?, 'assistant', 'hello', 2)`, conv, conv)
	require.NoError(t, err)
	return d, conv
}

// TestGenerateTitle_NeverOverUser: an owner title is never overwritten — no
// AI call when it is already set, and a rename landing during the call wins.
func TestGenerateTitle_NeverOverUser(t *testing.T) {
	cfg := &config.Config{}
	d, conv := titleDB(t, "user")
	gen := &titleGen{reply: "AI title"}
	res, err := GenerateTitle(context.Background(), d, cfg, gen, conv)
	require.NoError(t, err)
	assert.Equal(t, TitleResult{Title: "Mine"}, res)
	assert.Zero(t, gen.calls)

	d2, conv2 := titleDB(t, "prefix")
	gen2 := &titleGen{reply: "AI title", before: func() {
		_, err := d2.Exec(`UPDATE chat_conversations SET title = 'Renamed', title_source = 'user' WHERE id = ?`, conv2)
		require.NoError(t, err)
	}}
	res, err = GenerateTitle(context.Background(), d2, cfg, gen2, conv2)
	require.NoError(t, err)
	assert.False(t, res.Written)
	c, err := d2.GetChatConversation(conv2)
	require.NoError(t, err)
	assert.Equal(t, "Renamed", c.Title)
	assert.Equal(t, "user", c.TitleSource)

	d3, conv3 := titleDB(t, "prefix")
	res, err = GenerateTitle(context.Background(), d3, cfg, &titleGen{reply: "# Title: Q3 plan."}, conv3)
	require.NoError(t, err)
	assert.True(t, res.Written)
	c, err = d3.GetChatConversation(conv3)
	require.NoError(t, err)
	assert.Equal(t, "Q3 plan", c.Title)
	assert.Equal(t, "ai", c.TitleSource)
}

func TestCleanTitle(t *testing.T) {
	cases := map[string]string{
		"Payments rollout":           "Payments rollout",
		"# Title: Q3 plan.\n\nextra": "Q3 plan",
		"«Релиз платежей»":           "Релиз платежей",
		"**Vendor contract review**": "Vendor contract review",
		"":                           "",
		strings.Repeat("Долгое название ", 10): strings.TrimSpace(string([]rune(strings.Repeat("Долгое название ", 10))[:59])) + "…",
	}
	for in, want := range cases {
		assert.Equal(t, want, CleanTitle(in), in)
	}
}
