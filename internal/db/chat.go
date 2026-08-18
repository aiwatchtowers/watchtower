package db

import "fmt"

// ChatTurn is one message of a Desktop assistant conversation, projected for
// the Go side (the next-step prompt builder). Role is verbatim from
// chat_messages.role — 'user', 'assistant' or 'system'; system turns carry the
// "Action applied: ..." lines the Desktop writes after an approved action and
// are the highest-signal record of what was actually done.
type ChatTurn struct {
	ID        int64  // chat_messages.id
	Role      string // user | assistant | system
	Text      string // verbatim message text
	CreatedAt int64  // created_at truncated to whole unix seconds
}

// ListRecentChatTurns returns up to limit most recent messages across every
// conversation of one (context_type, context_id) pair — e.g. ("target", "42") —
// ordered oldest-first (newest LAST), so the caller can render them as a
// chronological excerpt. A context may own several conversations (the assistant
// tabs), and they are read together.
//
// The chat tables are Swift-owned: the Desktop app creates chat_conversations
// and chat_messages lazily via GRDB ensureTable the first time the owner opens a
// Discuss chat, so a CLI-only install has never seen them. Their absence is a
// clean empty read (nil, nil), never an error — the ListOwnerChatTurns contract.
// A non-positive limit is likewise a clean empty read.
func (db *DB) ListRecentChatTurns(contextType, contextID string, limit int) ([]ChatTurn, error) {
	if contextType == "" || contextID == "" || limit <= 0 {
		return nil, nil
	}
	present, err := db.ChatTablesPresent()
	if err != nil {
		return nil, err
	}
	if !present {
		return nil, nil
	}

	// Newest first so LIMIT keeps the RECENT tail, then reversed below.
	rows, err := db.Query(`SELECT m.id, m.role, m.text, CAST(m.created_at AS INTEGER)
		FROM chat_messages m
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE c.context_type = ? AND c.context_id = ?
		ORDER BY m.created_at DESC, m.id DESC
		LIMIT ?`, contextType, contextID, limit)
	if err != nil {
		return nil, fmt.Errorf("listing recent chat turns for %s/%s: %w", contextType, contextID, err)
	}
	defer rows.Close()

	var newestFirst []ChatTurn
	for rows.Next() {
		var t ChatTurn
		if err := rows.Scan(&t.ID, &t.Role, &t.Text, &t.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning chat turn: %w", err)
		}
		newestFirst = append(newestFirst, t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out := make([]ChatTurn, 0, len(newestFirst))
	for i := len(newestFirst) - 1; i >= 0; i-- {
		out = append(out, newestFirst[i])
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}
