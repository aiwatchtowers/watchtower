package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// towerRequestTimeLayout is the UTC text form of tower_requests.at.
const towerRequestTimeLayout = "2006-01-02T15:04:05Z"

// ErrTowerRequestExists is returned by BeginTowerRequestTx when the id
// already has a row, and by FinishTowerRequestTx when the id is already
// done: another call with the same request_id got there first.
var ErrTowerRequestExists = errors.New("tower request already recorded")

// TowerRequest is one tower_requests row: the ledger internal/tower keeps
// so a write command resent with the same request_id applies once.
// RefusalJSON is set (and ResultJSON empty) on a done row whose command
// refused: a resend answers the same refusal.
type TowerRequest struct {
	RequestID, Command, State, ResultJSON, RefusalJSON, At string
}

// GetTowerRequest returns the ledger row of id, or nil when there is none.
func (db *DB) GetTowerRequest(ctx context.Context, id string) (*TowerRequest, error) {
	var r TowerRequest
	err := db.QueryRowContext(ctx,
		`SELECT request_id, command, state, result_json, refusal_json, at FROM tower_requests WHERE request_id = ?`, id).
		Scan(&r.RequestID, &r.Command, &r.State, &r.ResultJSON, &r.RefusalJSON, &r.At)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get tower request: %w", err)
	}
	return &r, nil
}

// BeginTowerRequestTx records a non-idempotent command's intent as a begun
// row inside the caller's transaction. An id that already has a row fails
// with ErrTowerRequestExists.
func BeginTowerRequestTx(tx *sql.Tx, id, command string, at time.Time) error {
	res, err := tx.Exec(`INSERT INTO tower_requests (request_id, command, state, result_json, at)
VALUES (?, ?, 'begun', '', ?) ON CONFLICT(request_id) DO NOTHING`,
		id, command, at.UTC().Format(towerRequestTimeLayout))
	if err != nil {
		return fmt.Errorf("begin tower request: %w", err)
	}
	return requireOneRow(res, "begin tower request")
}

// FinishTowerRequestTx marks id done with the command's marshalled result
// inside the caller's transaction: it inserts the row, or moves a begun row
// to done. An id that is already done fails with ErrTowerRequestExists, so a
// concurrent duplicate never overwrites the first result.
func FinishTowerRequestTx(tx *sql.Tx, id, command, resultJSON string, at time.Time) error {
	return finishTowerRequestTx(tx, id, command, resultJSON, "", at, "finish tower request")
}

// RefuseTowerRequestTx marks id done with the command's marshalled refusal,
// as FinishTowerRequestTx does with a result: the command did not act, and a
// resend of id answers the same refusal.
func RefuseTowerRequestTx(tx *sql.Tx, id, command, refusalJSON string, at time.Time) error {
	return finishTowerRequestTx(tx, id, command, "", refusalJSON, at, "refuse tower request")
}

func finishTowerRequestTx(tx *sql.Tx, id, command, resultJSON, refusalJSON string, at time.Time, what string) error {
	res, err := tx.Exec(`INSERT INTO tower_requests (request_id, command, state, result_json, refusal_json, at)
VALUES (?, ?, 'done', ?, ?, ?)
ON CONFLICT(request_id) DO UPDATE SET
  command = excluded.command, state = 'done', result_json = excluded.result_json,
  refusal_json = excluded.refusal_json, at = excluded.at
WHERE tower_requests.state = 'begun'`,
		id, command, resultJSON, refusalJSON, at.UTC().Format(towerRequestTimeLayout))
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	return requireOneRow(res, what)
}

// requireOneRow turns a conflict that changed no row into
// ErrTowerRequestExists.
func requireOneRow(res sql.Result, what string) error {
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("%s: %w", what, err)
	}
	if n == 0 {
		return ErrTowerRequestExists
	}
	return nil
}

// PruneTowerRequests deletes the ledger rows of both states last written
// earlier than cutoff and returns how many it deleted.
func (db *DB) PruneTowerRequests(ctx context.Context, cutoff time.Time) (int64, error) {
	res, err := db.ExecContext(ctx, `DELETE FROM tower_requests WHERE at < ?`,
		cutoff.UTC().Format(towerRequestTimeLayout))
	if err != nil {
		return 0, fmt.Errorf("prune tower requests: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("prune tower requests: %w", err)
	}
	return n, nil
}
