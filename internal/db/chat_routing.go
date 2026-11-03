package db

import (
	"fmt"
	"strings"
)

// SetChatRouting is an explicit owner selection. Auto clears the previous
// sticky actual pair; provider/model remain the legacy pin representation.
func (db *DB) SetChatRouting(id int64, mode, provider, model string) error {
	if mode != "pinned" && mode != "preferred_reserve" {
		return fmt.Errorf("invalid chat routing mode %q", mode)
	}
	if mode == "pinned" && provider != "claude" && provider != "codex" && provider != "ollama" {
		return fmt.Errorf("invalid chat provider %q", provider)
	}
	if mode == "preferred_reserve" {
		provider, model = "", ""
	}
	_, err := db.Exec(`UPDATE chat_conversations SET routing_mode=?, provider=?, model=?, actual_provider='', actual_model='', routing_reason='' WHERE id=?`, mode, provider, model, id)
	return err
}

// SetChatActual records the last chosen attempt without changing the pin or
// configured preference. A reserve actual remains sticky until manual selection.
func (db *DB) SetChatActual(id int64, provider, model, reason string) error {
	_, err := db.Exec(`UPDATE chat_conversations SET actual_provider=?, actual_model=?, routing_reason=? WHERE id=?`, provider, model, reason, id)
	return err
}

// ChatActionReceipts reads bounded, content-free durable facts, newest first.
// The caller supplies only turn ids from the prior active conversation path.
func (db *DB) ChatActionReceipts(conversationID int64, turnIDs []string) ([]ChatActionReceipt, error) {
	if len(turnIDs) == 0 {
		return nil, nil
	}
	placeholders := make([]string, len(turnIDs))
	args := []any{conversationID}
	for i, id := range turnIDs {
		placeholders[i] = "?"
		args = append(args, id)
	}
	rows, err := db.Query(`SELECT id,turn_id,tool,status,result_json!='',error!='' FROM agent_actions WHERE conversation_id=? AND turn_id IN (`+strings.Join(placeholders, ",")+`) ORDER BY id DESC LIMIT 200`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ChatActionReceipt
	for rows.Next() {
		var r ChatActionReceipt
		if err := rows.Scan(&r.ID, &r.TurnID, &r.Tool, &r.Status, &r.HasResult, &r.HasError); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

type ChatActionReceipt struct {
	ID                   int64
	TurnID, Tool, Status string
	HasResult, HasError  bool
}
