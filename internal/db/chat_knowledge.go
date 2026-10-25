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

// AgentVisibleMentionCond is the WHERE condition every agent-facing reader of
// idea_mentions adds: a chat mention the assistant authored is never shown to
// an agent or indexed — its quote is a model's words, and a model conclusion
// must not read as knowledge (ask #516). The owner's own chat turns stay.
// alias qualifies the columns like KnowledgeVisibleIdeaCond's; it is a
// constant at every call site, never input.
func AgentVisibleMentionCond(alias string) string {
	p := ""
	if alias != "" {
		p = alias + "."
	}
	return "NOT (" + p + "source = 'chat' AND " + p + "author = 'assistant')"
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
// id > afterID, on each conversation's active branch, outside Discuss-an-idea
// chats (context_type 'idea') and workbench code questions ('code_question',
// which never leave their Questions tab — spec 2026-10-02 §9.4), in id order. Failed replies (status 'error')
// are left out; a stopped reply ('partial') is real text and stays. The
// listing stops below the first message (of any kind) created after cutoffISO
// (RFC 3339): a caller that advances a floor to the last returned id can then
// never pass a message still inside the quiet window, even when a later id
// carries an older timestamp (IDEA-01). A non-positive limit is an error —
// SQLite would read it as no limit. The chat tables come from migration
// 00076, so they are always present.
func (db *DB) ListChatTurnsForIdeas(afterID int64, cutoffISO string, limit int) ([]ChatTurnForIdeas, error) {
	if limit <= 0 {
		return nil, fmt.Errorf("listing chat turns for ideas: limit %d is not positive", limit)
	}
	cutoff, err := time.Parse(time.RFC3339, cutoffISO)
	if err != nil {
		return nil, fmt.Errorf("listing chat turns for ideas: parsing cutoff: %w", err)
	}
	at := float64(cutoff.Unix())
	rows, err := db.Query(activeBranchCTE+`SELECT m.id, m.conversation_id, c.title, m.role, m.text, m.created_at
		FROM chat_messages m
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE m.id > ? AND m.role IN ('user', 'assistant') AND m.status != 'error'
		  AND m.id < COALESCE((SELECT MIN(f.id) FROM chat_messages f WHERE f.id > ? AND f.created_at > ?), 9223372036854775807)
		  AND COALESCE(c.context_type, '') NOT IN ('idea', 'code_question') AND `+onActiveBranch+`
		ORDER BY m.id
		LIMIT ?`, afterID, afterID, at, limit)
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
