package db

import (
	"database/sql"
	"fmt"
	"strconv"
	"strings"

	"github.com/rivo/uniseg"
)

// chatIdeaTitleLength caps a chat-born idea's title (Swift
// IdeaQueries.chatTitleLength), in characters (grapheme clusters).
const chatIdeaTitleLength = 120

// CreateIdeaFromChat records a knowledge prefix (`решили:`, `факт:`) the
// owner typed in a chat: an active, owner-sourced, chat-born idea of kind
// with the whole body as its essence and the body's first line (at most 120
// characters) as its title, plus one `chat` mention of the message. The Go
// twin of Swift IdeaQueries.createFromChat (shared fixture
// testdata/chat_idea_rows.json); each runs only for the owner row its own
// chat store wrote.
func (db *DB) CreateIdeaFromChat(kind, body string, conversationID, messageID int64) (int64, error) {
	var id int64
	err := db.WithTx(func(tx *sql.Tx) error {
		var err error
		id, err = CreateIdeaFromChatTx(tx, kind, body, conversationID, messageID)
		return err
	})
	return id, err
}

// CreateIdeaFromChatTx is CreateIdeaFromChat in the caller's transaction
// (the tower's ideas.create_from_chat).
func CreateIdeaFromChatTx(tx *sql.Tx, kind, body string, conversationID, messageID int64) (int64, error) {
	var now string
	if err := tx.QueryRow(`SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`).Scan(&now); err != nil {
		return 0, fmt.Errorf("creating idea from chat: %w", err)
	}
	res, err := tx.Exec(`INSERT INTO ideas (kind, title, essence, status, source, last_mention_at, chat_born)
		VALUES (?, ?, ?, 'active', 'owner', ?, 1)`, kind, chatIdeaTitle(body), body, now)
	if err != nil {
		return 0, fmt.Errorf("creating idea from chat: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("creating idea from chat: %w", err)
	}
	ref := "chat:" + strconv.FormatInt(conversationID, 10) + ":" + strconv.FormatInt(messageID, 10)
	if _, err := tx.Exec(`INSERT INTO idea_mentions (idea_id, source, ref, quote, said_at) VALUES (?, 'chat', ?, ?, ?)`,
		id, ref, body, now); err != nil {
		return 0, fmt.Errorf("creating idea from chat: %w", err)
	}
	return id, nil
}

// chatIdeaTitle is body's first line — split at any of Swift's
// Character.isNewline characters, "\r\n" as one — capped at
// chatIdeaTitleLength grapheme clusters, as Swift's String.prefix counts.
func chatIdeaTitle(body string) string {
	var b strings.Builder
	n := 0
	g := uniseg.NewGraphemes(body)
	for g.Next() && n < chatIdeaTitleLength {
		c := g.Str()
		if isSwiftNewline(c) {
			break
		}
		b.WriteString(c)
		n++
	}
	return b.String()
}

// isSwiftNewline is Swift's Character.isNewline for one grapheme cluster.
func isSwiftNewline(c string) bool {
	switch c {
	case "\n", "\r", "\r\n", "\v", "\f", "\u0085", " ", " ":
		return true
	}
	return false
}
