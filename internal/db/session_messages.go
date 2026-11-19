package db

import (
	"cmp"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"time"
)

// SessionMessage is a session_messages row (00209): a message between two
// live sessions of one workbench, delivered by the daemon at most once.
type SessionMessage struct {
	ID, WorkbenchID int64
	FromSessionID   sql.NullInt64 // NULL once the sender's row is gone
	ToSessionID     sql.NullInt64 // NULL once the receiver's row is gone
	Kind            string        // message | finished | failure
	Text            string
	CreatedAt       string
	State           string // queued | delivering | delivered | failed
	Reason          string
	DeliveredAt     sql.NullString
	// PromptClearedAt is, on a typed_not_submitted row, when the text left
	// the receiver's prompt; NULL while it may still sit there.
	PromptClearedAt sql.NullString
}

// ErrSessionMessageNotPending is a settle or requeue of a message that is
// not in the state the move starts from (another tick settled it, or the
// row is gone).
var ErrSessionMessageNotPending = errors.New("session message is not pending")

// The states a message settles in, and the reason of a delivery that
// waits in the receiver's prompt.
const (
	SessionMessageDelivered = "delivered"
	SessionMessageFailed    = "failed"
	// SessionMessageTypedNotSubmitted: the text was typed into the
	// receiver's prompt but not submitted.
	SessionMessageTypedNotSubmitted = "typed_not_submitted"
)

const sessionMessageCols = `id, workbench_id, from_session_id, to_session_id, kind, text, created_at, state, reason,
	delivered_at, prompt_cleared_at`

// InsertSessionMessage queues m (its State, Reason and stamps are ignored;
// an empty CreatedAt takes the default) and returns its id.
func (db *DB) InsertSessionMessage(ctx context.Context, m SessionMessage) (int64, error) {
	var createdAt any
	if m.CreatedAt != "" {
		createdAt = m.CreatedAt
	}
	res, err := db.ExecContext(ctx, `INSERT INTO session_messages (workbench_id, from_session_id, to_session_id, kind, text,
		created_at) VALUES (?, ?, ?, ?, ?, COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ','now')))`,
		m.WorkbenchID, m.FromSessionID, m.ToSessionID, m.Kind, m.Text, createdAt)
	if err != nil {
		return 0, fmt.Errorf("queueing a session message: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("queueing a session message: %w", err)
	}
	return id, nil
}

// ClaimSessionMessage moves message id from queued to delivering in one
// autocommit update; true when this call took it (two ticks never both do).
func (db *DB) ClaimSessionMessage(ctx context.Context, id int64) (bool, error) {
	res, err := db.ExecContext(ctx, `UPDATE session_messages SET state = 'delivering' WHERE id = ? AND state = 'queued'`, id)
	if err != nil {
		return false, fmt.Errorf("claiming session message %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("claiming session message %d: %w", id, err)
	}
	return n == 1, nil
}

// SettleSessionMessage ends message id as delivered (delivered_at = at) or
// failed, with reason, from queued (a held line that expired) or delivering.
// A row in neither state is ErrSessionMessageNotPending.
func (db *DB) SettleSessionMessage(ctx context.Context, id int64, state, reason string, at time.Time) error {
	if state != SessionMessageDelivered && state != SessionMessageFailed {
		return fmt.Errorf("settling session message %d: state %q is not delivered or failed", id, state)
	}
	var deliveredAt any
	if state == SessionMessageDelivered {
		// Millisecond precision (agent_state_at's layout): a hook stamped in
		// the same second but before the paste is not after it.
		deliveredAt = at.UTC().Format(agentStateAtLayout)
	}
	res, err := db.ExecContext(ctx, `UPDATE session_messages SET state = ?, reason = ?, delivered_at = ?
		WHERE id = ? AND state IN ('queued','delivering')`, state, reason, deliveredAt, id)
	return requireMessageMoved(res, err, id, "settling")
}

// FailQueuedSessionMessage fails message id with reason only while it is
// still queued (never a row another tick has claimed); a row in any other
// state is ErrSessionMessageNotPending.
func (db *DB) FailQueuedSessionMessage(ctx context.Context, id int64, reason string) error {
	res, err := db.ExecContext(ctx, `UPDATE session_messages SET state = 'failed', reason = ? WHERE id = ? AND state = 'queued'`,
		reason, id)
	return requireMessageMoved(res, err, id, "failing")
}

// RequeueSessionMessage puts claimed message id back in the queue: the
// session host held it (nothing was pasted). A row not delivering is
// ErrSessionMessageNotPending.
func (db *DB) RequeueSessionMessage(ctx context.Context, id int64) error {
	res, err := db.ExecContext(ctx, `UPDATE session_messages SET state = 'queued' WHERE id = ? AND state = 'delivering'`, id)
	return requireMessageMoved(res, err, id, "requeueing")
}

func requireMessageMoved(res sql.Result, err error, id int64, verb string) error {
	if err != nil {
		return fmt.Errorf("%s session message %d: %w", verb, id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("%s session message %d: %w", verb, id, err)
	}
	if n == 0 {
		return fmt.Errorf("%s session message %d: %w", verb, id, ErrSessionMessageNotPending)
	}
	return nil
}

// QueuedSessionMessages is every queued message, oldest first; never nil.
func (db *DB) QueuedSessionMessages(ctx context.Context) ([]SessionMessage, error) {
	return db.sessionMessages(ctx, "queued session messages", `state = 'queued'`)
}

// UnclearedPromptMessages is every message typed into a prompt and not
// submitted whose text may still sit there (prompt_cleared_at NULL).
func (db *DB) UnclearedPromptMessages(ctx context.Context) ([]SessionMessage, error) {
	return db.sessionMessages(ctx, "messages waiting in a prompt",
		`state = 'delivered' AND reason = '`+SessionMessageTypedNotSubmitted+`' AND prompt_cleared_at IS NULL`)
}

func (db *DB) sessionMessages(ctx context.Context, what, where string) ([]SessionMessage, error) {
	return db.scanSessionMessages(ctx, "reading "+what,
		`SELECT `+sessionMessageCols+` FROM session_messages WHERE `+where+` ORDER BY id`)
}

// scanSessionMessages runs query (selecting or returning sessionMessageCols)
// and scans its rows, sorted by id; never nil. what names the failure.
func (db *DB) scanSessionMessages(ctx context.Context, what, query string, args ...any) ([]SessionMessage, error) {
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", what, err)
	}
	defer rows.Close()
	out := []SessionMessage{}
	for rows.Next() {
		var m SessionMessage
		if err := rows.Scan(&m.ID, &m.WorkbenchID, &m.FromSessionID, &m.ToSessionID, &m.Kind, &m.Text, &m.CreatedAt,
			&m.State, &m.Reason, &m.DeliveredAt, &m.PromptClearedAt); err != nil {
			return nil, fmt.Errorf("%s: %w", what, err)
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%s: %w", what, err)
	}
	slices.SortFunc(out, func(a, b SessionMessage) int { return cmp.Compare(a.ID, b.ID) })
	return out, nil
}

// FailInFlightSessionMessages fails, with reason, every message left
// delivering (a daemon start: whether its Deliver landed is unknown, so it
// is never retried) and returns them as they are now, oldest first; never
// nil.
func (db *DB) FailInFlightSessionMessages(ctx context.Context, reason string) ([]SessionMessage, error) {
	return db.scanSessionMessages(ctx, "failing in-flight session messages",
		`UPDATE session_messages SET state = 'failed', reason = ? WHERE state = 'delivering' RETURNING `+sessionMessageCols, reason)
}

// ClearPromptFlag records that message id's text left the receiver's
// prompt at at; a row already cleared keeps its first time.
func (db *DB) ClearPromptFlag(ctx context.Context, id int64, at time.Time) error {
	if _, err := db.ExecContext(ctx, `UPDATE session_messages SET prompt_cleared_at = ?
		WHERE id = ? AND prompt_cleared_at IS NULL`, at.UTC().Format(time.RFC3339), id); err != nil {
		return fmt.Errorf("clearing the prompt flag of session message %d: %w", id, err)
	}
	return nil
}
