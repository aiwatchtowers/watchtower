package db

import (
	"fmt"
	"strings"
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
	Text               string // the typed text only
	// ImageLines describes the turn's attached images (machine text,
	// labelled), one per image in attachment order; never the owner's words.
	ImageLines []string
	CreatedAt  string
}

// maxChatImageHold bounds how long a still-pending image holds the chat
// floor (IDEA-01); past it the turn is mined without the image line, so a
// pass that never runs cannot freeze mining.
const maxChatImageHold = 2 * time.Hour

// ChatImageLabel is the label of an image description; it equals
// kb.MediaImageLabel (pinned by a test there; db cannot import kb).
const ChatImageLabel = "Image (AI description of an attached image)"

// ListChatTurnsForIdeas returns up to limit owner and assistant messages with
// id > afterID, on each conversation's active branch, outside Discuss-an-idea
// chats (context_type 'idea'), workbench code questions ('code_question',
// which never leave their Questions tab — spec 2026-10-02 §9.4) and the
// meeting chat of a private recording (MEETPRIV-02), in id order. Failed replies (status 'error')
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
		  AND m.id < COALESCE((SELECT MIN(m.id) FROM chat_messages m
		        JOIN chat_conversations c ON c.id = m.conversation_id
		        JOIN chat_attachments a ON a.message_id = m.id
		        JOIN media_items mi ON mi.chat_attachment_id = a.id
		        WHERE m.id > ? AND m.role IN ('user', 'assistant') AND m.status != 'error'
		          AND COALESCE(c.context_type, '') NOT IN ('idea', 'code_question') AND `+ChatNotPrivateMeeting+` AND `+onActiveBranch+`
		          AND mi.status = 'pending'
		          AND mi.content_at >= (SELECT start_at FROM media_state WHERE id = 1)
		          AND mi.content_at > ?), 9223372036854775807)
		  AND COALESCE(c.context_type, '') NOT IN ('idea', 'code_question') AND `+ChatNotPrivateMeeting+` AND `+onActiveBranch+`
		ORDER BY m.id
		LIMIT ?`, afterID, afterID, at, afterID, mediaTime(time.Now().Add(-maxChatImageHold)), limit)
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
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, fmt.Errorf("listing chat turns for ideas: %w", err)
	}
	return out, db.appendChatImageLines(out)
}

// appendChatImageLines adds, to each turn with described ('ok') image
// attachments, one line per image in attachment id order. A pending image
// never reaches here: ListChatTurnsForIdeas stops below its message.
func (db *DB) appendChatImageLines(turns []ChatTurnForIdeas) error {
	if len(turns) == 0 {
		return nil
	}
	idx := make(map[int64]int, len(turns))
	args := make([]any, 0, len(turns))
	marks := make([]string, 0, len(turns))
	for i, t := range turns {
		idx[t.ID] = i
		args = append(args, t.ID)
		marks = append(marks, "?")
	}
	rows, err := db.Query(`SELECT a.message_id, a.name, mi.title, mi.body
		FROM chat_attachments a JOIN media_items mi ON mi.chat_attachment_id = a.id
		WHERE a.message_id IN (`+strings.Join(marks, ",")+`) AND mi.status = 'ok'
		ORDER BY a.id`, args...)
	if err != nil {
		return fmt.Errorf("listing chat image descriptions: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var msg int64
		var name, title, body string
		if err := rows.Scan(&msg, &name, &title, &body); err != nil {
			return fmt.Errorf("scanning chat image description: %w", err)
		}
		if i, ok := idx[msg]; ok && turns[i].Role == "user" {
			turns[i].ImageLines = append(turns[i].ImageLines,
				fmt.Sprintf("[image %q — %s: %s]", name, ChatImageLabel, MediaDescription(title, body)))
		}
	}
	return rows.Err()
}
