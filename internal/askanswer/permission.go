package askanswer

import (
	"context"
	"database/sql"

	"watchtower/internal/db"
)

// ByWatchman is permission_requests.decided_by of the twin's decisions.
const ByWatchman = "watchman"

// PermissionDecision is one Allow once or Deny of a pending permission
// request of SessionID. DecidedBy names the decider (the phone's name,
// ByWatchman; "" stores NULL); Also is the caller's own write in the same
// transaction, run only when the decision is stored.
type PermissionDecision struct {
	RequestID, SessionID int64
	Allow                bool
	DecidedBy            string
	Also                 func(tx *sql.Tx) error
}

// ClosePermission stores p with one guarded write (PROJ-21): false when the
// request is not this session's or no longer pending — the Mac, a phone or
// the hook's expiry got there first, and nothing is written.
func (a *Answerer) ClosePermission(ctx context.Context, p PermissionDecision) (bool, error) {
	status := db.PermissionDenied
	if p.Allow {
		status = db.PermissionAllowed
	}
	by := sql.NullString{String: p.DecidedBy, Valid: p.DecidedBy != ""}
	closed := false
	err := a.d.DB.WithTx(func(tx *sql.Tx) error {
		res, err := tx.ExecContext(ctx, `UPDATE permission_requests SET status = ?, decided_at = ?, decided_by = ?
			WHERE id = ? AND terminal_session_id = ? AND status = ?`,
			status, db.AgentStateStamp(a.d.Clock()), by, p.RequestID, p.SessionID, db.PermissionPending)
		if err != nil {
			return err
		}
		n, err := res.RowsAffected()
		if err != nil || n != 1 {
			return err
		}
		if p.Also != nil {
			if err := p.Also(tx); err != nil {
				return err
			}
		}
		closed = true
		return nil
	})
	if err != nil {
		return false, err
	}
	return closed, nil
}
