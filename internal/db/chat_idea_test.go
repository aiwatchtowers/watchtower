package db

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type chatIdeaCase struct {
	Name           string `json:"name"`
	Kind           string `json:"kind"`
	Body           string `json:"body"`
	ConversationID int64  `json:"conversation_id"`
	MessageID      int64  `json:"message_id"`
	Expect         struct {
		Idea struct {
			Kind, Title, Essence, Status, Source string
			ChatBorn                             int `json:"chat_born"`
		} `json:"idea"`
		Mention struct{ Source, Ref, Quote string } `json:"mention"`
	} `json:"expect"`
}

// TestCreateIdeaFromChat_SharedRows runs chat_idea_rows.json, which the
// Swift IdeaQueries.createFromChat test (ChatIdeaRowsFixtureTests) reads too:
// both writers of a chat-born idea write the same columns.
func TestCreateIdeaFromChat_SharedRows(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "chat_idea_rows.json"))
	require.NoError(t, err)
	var cases []chatIdeaCase
	require.NoError(t, json.Unmarshal(raw, &cases))
	require.GreaterOrEqual(t, len(cases), 8)
	stamp := regexp.MustCompile(`^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$`)
	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			d := openTestDB(t)
			id, err := d.CreateIdeaFromChat(tc.Kind, tc.Body, tc.ConversationID, tc.MessageID)
			require.NoError(t, err)
			var kind, title, essence, status, source, lastMention string
			var chatBorn int
			require.NoError(t, d.QueryRow(`SELECT kind, title, essence, status, source, chat_born, last_mention_at FROM ideas WHERE id = ?`, id).
				Scan(&kind, &title, &essence, &status, &source, &chatBorn, &lastMention))
			e := tc.Expect.Idea
			assert.Equal(t, []any{e.Kind, e.Title, e.Essence, e.Status, e.Source, e.ChatBorn},
				[]any{kind, title, essence, status, source, chatBorn})
			var mSource, ref, quote, saidAt string
			var n int
			require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM idea_mentions WHERE idea_id = ?`, id).Scan(&n))
			assert.Equal(t, 1, n)
			require.NoError(t, d.QueryRow(`SELECT source, ref, quote, said_at FROM idea_mentions WHERE idea_id = ?`, id).
				Scan(&mSource, &ref, &quote, &saidAt))
			m := tc.Expect.Mention
			assert.Equal(t, []string{m.Source, m.Ref, m.Quote}, []string{mSource, ref, quote})
			assert.Regexp(t, stamp, lastMention)
			assert.Equal(t, lastMention, saidAt, "one clock reading for both rows")
		})
	}
}
