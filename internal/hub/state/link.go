package state

import (
	"context"
	"database/sql"
	"errors"
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
// empty. A re-link (no row, or another link nonce) starts with no relay key
// offer and no per-epoch relay keys: those were derived under the old nonce.
// The same link written again keeps both.
func LinkDevice(tx *sql.Tx, d Device) error {
	last, err := u64(d.LastAppliedActionSeq)
	if err != nil {
		return err
	}
	resend, err := u64(d.ResendRequestedFrom)
	if err != nil {
		return err
	}
	var (
		oldNonce   sql.NullString
		offer      []byte
		offerEpoch int64
	)
	err = tx.QueryRow(`SELECT link_nonce, kx_offer, kx_offer_epoch FROM devices WHERE device_id = ? COLLATE NOCASE`, d.ID).
		Scan(&oldNonce, &offer, &offerEpoch)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("linking a device: %w", err)
	}
	relink := err != nil || oldNonce.String != d.LinkNonce
	if _, err := tx.Exec(`DELETE FROM devices WHERE device_id = ? COLLATE NOCASE`, d.ID); err != nil {
		return fmt.Errorf("linking a device: %w", err)
	}
	_, err = tx.Exec(`INSERT INTO devices (`+deviceColumns+`, user_record_name)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '')`,
		deviceKey(d.ID), d.Name, d.Scope, toReal(d.LinkedAt), d.SigningKey, d.AgreementKey, nullString(d.LinkNonce),
		d.TypingAllowed, d.TypingRequested, d.PermissionsAllowed, d.PermissionsRequested,
		d.StartSessionsAllowed, d.StartSessionsGranted,
		last, d.Ordered, nullString(d.RelayDeviceID), resend, int64(d.AckedEpoch))
	if err != nil {
		return fmt.Errorf("linking a device: %w", err)
	}
	if relink {
		return deleteRelayKeys(tx, d.ID)
	}
	if offer != nil {
		if _, err := tx.Exec(`UPDATE devices SET kx_offer = ?, kx_offer_epoch = ? WHERE device_id = ? COLLATE NOCASE`,
			offer, offerEpoch, d.ID); err != nil {
			return fmt.Errorf("linking a device: %w", err)
		}
	}
	return nil
}

func nullString(s string) any {
	if s == "" {
		return nil
	}
	return s
}
