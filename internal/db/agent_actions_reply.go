package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// InboxItemContextType is the context of a Reply from an Inbox row (Inbox
// builder B, ask #445): context_id is the inbox_items id the reply answers.
const InboxItemContextType = "inbox_item"

// ErrReplyAlreadyWaiting is the refusal of a second Reply to an Inbox item
// while its reply #ID is still open (pending, approved or executing):
// approving both would post the reply twice.
type ErrReplyAlreadyWaiting struct{ ID int64 }

func (e *ErrReplyAlreadyWaiting) Error() string {
	return fmt.Sprintf("a reply to this item is already waiting for approval (#%d)", e.ID)
}

// InsertInboxReplyProposal records a Reply proposal (a.ContextType =
// InboxItemContextType) in one BEGIN IMMEDIATE transaction with its check:
// an open proposal of any of replyTools for the same item refuses it
// (*ErrReplyAlreadyWaiting), nothing written.
func (db *DB) InsertInboxReplyProposal(a AgentAction, replyTools []string) (int64, error) {
	if a.ContextType != InboxItemContextType {
		return 0, fmt.Errorf("inbox reply proposal: context type %q is not %q", a.ContextType, InboxItemContextType)
	}
	if len(replyTools) == 0 {
		return 0, errors.New("inbox reply proposal: no reply tools given")
	}
	if a.Status == "" {
		a.Status = "pending"
	}
	if a.TrustAtCreate == "" {
		a.TrustAtCreate = "ask"
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("inbox reply proposal: %w", err)
	}
	defer tx.Rollback()
	args := []any{a.ContextType, a.ContextID}
	for _, t := range replyTools {
		args = append(args, t)
	}
	var open int64
	err = tx.QueryRow(`SELECT id FROM agent_actions WHERE context_type = ? AND context_id = ?
		AND status IN ('pending','approved','executing')
		AND tool IN (?`+strings.Repeat(",?", len(replyTools)-1)+`) ORDER BY id DESC LIMIT 1`, args...).Scan(&open)
	switch {
	case err == nil:
		return 0, &ErrReplyAlreadyWaiting{ID: open}
	case !errors.Is(err, sql.ErrNoRows):
		return 0, fmt.Errorf("reading the open reply of inbox item %s: %w", a.ContextID, err)
	}
	res, err := tx.Exec(`INSERT INTO agent_actions
		(tool, external, args_json, reason, surface, conversation_id, context_type, context_id,
		 turn_id, status, trust_at_create, session_token)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.Tool, a.External, a.ArgsJSON, a.Reason, a.Surface, a.ConversationID, a.ContextType, a.ContextID,
		a.TurnID, a.Status, a.TrustAtCreate, a.SessionToken)
	if err != nil {
		return 0, fmt.Errorf("inserting inbox reply proposal: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("inserting inbox reply proposal: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("committing inbox reply proposal: %w", err)
	}
	return id, nil
}
