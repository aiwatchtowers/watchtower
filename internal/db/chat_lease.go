package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// ChatLeaseOwner is the process kind that runs a chat turn.
type ChatLeaseOwner string

const (
	ChatLeaseDesktop ChatLeaseOwner = "desktop"
	ChatLeaseHub     ChatLeaseOwner = "hub"
)

// ChatLeaseStaleMS is the heartbeat age after which anyone may take a lease.
const ChatLeaseStaleMS = 60000

// ChatLease is one chat_turn_leases row. Every time is Unix epoch
// milliseconds (UTC); callers pass the clock in, the API never reads it.
type ChatLease struct {
	ConversationID      int64
	Owner               ChatLeaseOwner
	OwnerID, TurnID     string
	StartedAtMS         int64
	HeartbeatAtMS       int64
	CancelRequestedAtMS *int64
}

// ClaimChatLeaseTx takes the conversation's lease inside the caller's
// transaction (BEGIN IMMEDIATE, so the first commit wins). It succeeds only
// when the row is absent or its heartbeat is older than ChatLeaseStaleMS at
// nowMS; a taken-over row starts fresh (its cancel request is dropped). A
// false result means the claim was refused: the caller rolls back.
func ClaimChatLeaseTx(tx *sql.Tx, l ChatLease, nowMS int64) (bool, error) {
	res, err := tx.Exec(`INSERT INTO chat_turn_leases
  (conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms, cancel_requested_at_ms)
VALUES (?, ?, ?, ?, ?, ?, NULL)
ON CONFLICT(conversation_id) DO UPDATE SET
  owner = excluded.owner, owner_id = excluded.owner_id, turn_id = excluded.turn_id,
  started_at_ms = excluded.started_at_ms, heartbeat_at_ms = excluded.heartbeat_at_ms,
  cancel_requested_at_ms = NULL
WHERE chat_turn_leases.heartbeat_at_ms < ? - ?`,
		l.ConversationID, string(l.Owner), l.OwnerID, l.TurnID, l.StartedAtMS, l.HeartbeatAtMS,
		nowMS, ChatLeaseStaleMS)
	if err != nil {
		return false, fmt.Errorf("claim chat lease: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("claim chat lease: %w", err)
	}
	return n == 1, nil
}

// HeartbeatChatLease refreshes the lease of turnID; false means the row is
// gone or belongs to another turn (the conversation was deleted or the lease
// was taken over).
func (db *DB) HeartbeatChatLease(conv int64, turnID string, nowMS int64) (bool, error) {
	res, err := db.Exec(`UPDATE chat_turn_leases SET heartbeat_at_ms = ? WHERE conversation_id = ? AND turn_id = ?`,
		nowMS, conv, turnID)
	if err != nil {
		return false, fmt.Errorf("heartbeat chat lease: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("heartbeat chat lease: %w", err)
	}
	return n == 1, nil
}

// RequestChatCancel marks turnID's lease as cancel-requested (the other
// side's Stop); false means no such lease.
func (db *DB) RequestChatCancel(conv int64, turnID string, nowMS int64) (bool, error) {
	res, err := db.Exec(`UPDATE chat_turn_leases SET cancel_requested_at_ms = ? WHERE conversation_id = ? AND turn_id = ?`,
		nowMS, conv, turnID)
	if err != nil {
		return false, fmt.Errorf("request chat cancel: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("request chat cancel: %w", err)
	}
	return n == 1, nil
}

// ReleaseChatLeaseTx deletes turnID's lease inside the finalize transaction;
// a different turn's lease is left alone.
func ReleaseChatLeaseTx(tx *sql.Tx, conv int64, turnID string) error {
	if _, err := tx.Exec(`DELETE FROM chat_turn_leases WHERE conversation_id = ? AND turn_id = ?`, conv, turnID); err != nil {
		return fmt.Errorf("release chat lease: %w", err)
	}
	return nil
}

// GetChatLease returns the conversation's lease, or nil when none exists.
func (db *DB) GetChatLease(conv int64) (*ChatLease, error) {
	var l ChatLease
	var owner string
	var cancel sql.NullInt64
	err := db.QueryRow(`SELECT conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms, cancel_requested_at_ms
FROM chat_turn_leases WHERE conversation_id = ?`, conv).
		Scan(&l.ConversationID, &owner, &l.OwnerID, &l.TurnID, &l.StartedAtMS, &l.HeartbeatAtMS, &cancel)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil //nolint:nilnil // no lease is a normal answer
	}
	if err != nil {
		return nil, fmt.Errorf("get chat lease: %w", err)
	}
	l.Owner = ChatLeaseOwner(owner)
	if cancel.Valid {
		l.CancelRequestedAtMS = &cancel.Int64
	}
	return &l, nil
}

// ReleaseOwnedChatLeases deletes every lease held by one owner process (its
// shutdown or startup cleanup) and returns how many it removed.
func (db *DB) ReleaseOwnedChatLeases(owner ChatLeaseOwner, ownerID string) (int64, error) {
	res, err := db.Exec(`DELETE FROM chat_turn_leases WHERE owner = ? AND owner_id = ?`, string(owner), ownerID)
	if err != nil {
		return 0, fmt.Errorf("release owned chat leases: %w", err)
	}
	return res.RowsAffected()
}

// OwnedChatLeases lists the leases one owner process holds (the hub's
// startup sweep reads them before it releases them).
func (db *DB) OwnedChatLeases(owner ChatLeaseOwner, ownerID string) ([]ChatLease, error) {
	rows, err := db.Query(`SELECT conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms, cancel_requested_at_ms
FROM chat_turn_leases WHERE owner = ? AND owner_id = ? ORDER BY conversation_id`, string(owner), ownerID)
	if err != nil {
		return nil, fmt.Errorf("owned chat leases: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []ChatLease
	for rows.Next() {
		var l ChatLease
		var o string
		var cancel sql.NullInt64
		if err := rows.Scan(&l.ConversationID, &o, &l.OwnerID, &l.TurnID, &l.StartedAtMS, &l.HeartbeatAtMS, &cancel); err != nil {
			return nil, fmt.Errorf("owned chat leases: %w", err)
		}
		l.Owner = ChatLeaseOwner(o)
		if cancel.Valid {
			l.CancelRequestedAtMS = &cancel.Int64
		}
		out = append(out, l)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("owned chat leases: %w", err)
	}
	return out, nil
}

// MarkChatTurnSessionLost gives turnID's still-partial replies in conv the
// session_lost error code (a turn whose runner died: the error card offers
// Retry); the text is kept. It returns how many rows it marked.
func (db *DB) MarkChatTurnSessionLost(conv int64, turnID string) (int64, error) {
	res, err := db.Exec(`UPDATE chat_messages SET error_code = 'session_lost'
WHERE conversation_id = ? AND turn_id = ? AND role = 'assistant' AND status = 'partial'`, conv, turnID)
	if err != nil {
		return 0, fmt.Errorf("mark chat turn session lost: %w", err)
	}
	return res.RowsAffected()
}

// FreshChatLeases lists the conversations whose lease heartbeat is younger
// than ChatLeaseStaleMS at nowMS (a turn answering on some device), in id
// order: the hub's chat slices republish when the set changes, since a lease
// going stale changes no row.
func (db *DB) FreshChatLeases(nowMS int64) ([]int64, error) {
	rows, err := db.Query(`SELECT conversation_id FROM chat_turn_leases WHERE heartbeat_at_ms > ? ORDER BY conversation_id`,
		nowMS-ChatLeaseStaleMS)
	if err != nil {
		return nil, fmt.Errorf("fresh chat leases: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("fresh chat leases: %w", err)
		}
		out = append(out, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("fresh chat leases: %w", err)
	}
	return out, nil
}
