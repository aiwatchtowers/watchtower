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
