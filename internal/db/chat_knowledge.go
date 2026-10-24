package db

import (
	"fmt"
	"time"
)

// KnowledgeVisibleIdeaCond is the WHERE condition every knowledge reader of
// the ideas registry adds: a chat-born idea is seen only once the owner has
// approved it: only the never-approved statuses ('proposed', 'not_now',
// 'rejected', 'dropped') are hidden, so an approved item that later became
// superseded, reversed or converted stays visible. alias qualifies the columns ("i" →
// i.chat_born); "" leaves them unqualified. alias is a constant at every call
// site, never input.
func KnowledgeVisibleIdeaCond(alias string) string {
	p := ""
	if alias != "" {
		p = alias + "."
	}
	return "NOT (" + p + "chat_born = 1 AND " + p + "status IN ('proposed','not_now','rejected','dropped'))"
}

// ChatTurnForIdeas is one chat message the ideas consolidator may mine.
// CreatedAt is RFC 3339 UTC (chat_messages.created_at is REAL unix seconds).
type ChatTurnForIdeas struct {
	ID, ConversationID int64
	ConversationTitle  string
	Role               string
	Text               string
	CreatedAt          string
}

// ListChatTurnsForIdeas returns up to limit owner and assistant messages with
// id > afterID and created_at at or before cutoffISO (RFC 3339), on each
// conversation's active branch, outside Discuss-an-idea chats
// (context_type 'idea'), in id order. The chat tables come from migration
// 00076, so they are always present.
func (db *DB) ListChatTurnsForIdeas(afterID int64, cutoffISO string, limit int) ([]ChatTurnForIdeas, error) {
	cutoff, err := time.Parse(time.RFC3339, cutoffISO)
	if err != nil {
		return nil, fmt.Errorf("listing chat turns for ideas: parsing cutoff: %w", err)
	}
	rows, err := db.Query(activeBranchCTE+`SELECT m.id, m.conversation_id, c.title, m.role, m.text, m.created_at
		FROM chat_messages m
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE m.id > ? AND m.created_at <= ? AND m.role IN ('user', 'assistant')
		  AND COALESCE(c.context_type, '') != 'idea' AND `+onActiveBranch+`
		ORDER BY m.id
		LIMIT ?`, afterID, float64(cutoff.Unix()), limit)
	if err != nil {
		return nil, fmt.Errorf("listing chat turns for ideas: %w", err)
	}
	defer rows.Close()
	var out []ChatTurnForIdeas
	for rows.Next() {
		var t ChatTurnForIdeas
		var at float64
		if err := rows.Scan(&t.ID, &t.ConversationID, &t.ConversationTitle, &t.Role, &t.Text, &at); err != nil {
			return nil, fmt.Errorf("scanning chat turn for ideas: %w", err)
		}
		t.CreatedAt = time.Unix(int64(at), 0).UTC().Format(time.RFC3339)
		out = append(out, t)
	}
	return out, rows.Err()
}
