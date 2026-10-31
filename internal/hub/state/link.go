package state

import (
	"context"
	"database/sql"
	"fmt"
)

// ReadTx runs fn in one read-only transaction (deferred: it never takes the
// write lock, so a reader never blocks the hub's writes). The link center
// reads its tables through it; fn must not write.
func (s *Store) ReadTx(ctx context.Context, fn func(*sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return fmt.Errorf("beginning a hub state read: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	return fn(tx)
}

// LinkDevice writes d as a linked phone, replacing a row with the same id
// (a re-pair); the id is stored uppercase. user_record_name, a CloudKit-only Swift column, is written
// empty.
func LinkDevice(tx *sql.Tx, d Device) error {
	last, err := u64(d.LastAppliedActionSeq)
	if err != nil {
		return err
	}
	resend, err := u64(d.ResendRequestedFrom)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM devices WHERE device_id = ? COLLATE NOCASE`, d.ID); err != nil {
		return fmt.Errorf("linking a device: %w", err)
	}
	_, err = tx.Exec(`INSERT INTO devices (`+deviceColumns+`, user_record_name)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '')`,
		deviceKey(d.ID), d.Name, d.Scope, toReal(d.LinkedAt), d.SigningKey, d.AgreementKey, nullString(d.LinkNonce),
		d.TypingAllowed, d.TypingRequested, d.PermissionsAllowed, d.PermissionsRequested,
		d.StartSessionsAllowed, d.StartSessionsGranted,
		last, d.Ordered, nullString(d.RelayDeviceID), resend)
	if err != nil {
		return fmt.Errorf("linking a device: %w", err)
	}
	return nil
}

func nullString(s string) any {
	if s == "" {
		return nil
	}
	return s
}
