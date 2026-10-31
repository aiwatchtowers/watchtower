package state

import (
	"database/sql"
	"errors"
	"fmt"
	"math"
	"time"
)

// ErrNoDevice is the answer for a device id no linked phone has.
var ErrNoDevice = errors.New("hub: no such linked device")

// Device is one linked phone (a devices row). Ids compare case-insensitively,
// as the Swift hub's queries do.
type Device struct {
	ID                   string
	Name, Scope          string
	LinkedAt             time.Time
	SigningKey           []byte
	AgreementKey         []byte
	LinkNonce            string
	TypingAllowed        bool
	TypingRequested      bool
	PermissionsAllowed   bool
	PermissionsRequested bool
	// StartSessionsAllowed is the phone's own toggle; StartSessionsGranted
	// the owner's grant.
	StartSessionsAllowed bool
	StartSessionsGranted bool
	LastAppliedActionSeq uint64
	Ordered              bool
	RelayDeviceID        string
	ResendRequestedFrom  uint64
	// AckedEpoch is the newest hub epoch the phone confirmed (epoch_ack).
	AckedEpoch uint32
}

const deviceColumns = `device_id, name, scope, linked_at, signing_key, agreement_key, link_nonce,
	typing_allowed, typing_requested, permissions_allowed, permissions_requested,
	start_sessions_allowed, start_sessions_granted,
	last_applied_action_seq, ordered, relay_device_id, resend_requested_from, acked_epoch`

type rowScanner interface{ Scan(dest ...any) error }

func scanDevice(r rowScanner) (Device, error) {
	var (
		d                  Device
		linked             float64
		nonce, relayID     sql.NullString
		lastApplied, resnd int64
		acked              int64
	)
	err := r.Scan(&d.ID, &d.Name, &d.Scope, &linked, &d.SigningKey, &d.AgreementKey, &nonce,
		&d.TypingAllowed, &d.TypingRequested, &d.PermissionsAllowed, &d.PermissionsRequested,
		&d.StartSessionsAllowed, &d.StartSessionsGranted,
		&lastApplied, &d.Ordered, &relayID, &resnd, &acked)
	if err != nil {
		return Device{}, err
	}
	d.LinkedAt = fromReal(linked)
	d.LinkNonce = nonce.String
	d.RelayDeviceID = relayID.String
	d.LastAppliedActionSeq = uint64(max(lastApplied, 0))
	d.ResendRequestedFrom = uint64(max(resnd, 0))
	d.AckedEpoch = uint32(min(max(acked, 0), math.MaxUint32))
	return d, nil
}

// Devices lists the linked phones, oldest link first.
func (s *Store) Devices() ([]Device, error) {
	rows, err := s.db.Query(`SELECT ` + deviceColumns + ` FROM devices ORDER BY linked_at, device_id`)
	if err != nil {
		return nil, fmt.Errorf("listing devices: %w", err)
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, fmt.Errorf("reading a device: %w", err)
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing devices: %w", err)
	}
	return out, nil
}

// Device reads one linked phone; ok is false when it is not linked.
func (s *Store) Device(id string) (Device, bool, error) {
	d, err := scanDevice(s.db.QueryRow(`SELECT `+deviceColumns+` FROM devices WHERE device_id = ? COLLATE NOCASE`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, false, nil
	}
	if err != nil {
		return Device{}, false, fmt.Errorf("reading a device: %w", err)
	}
	return d, true, nil
}

// SetLastApplied moves device's last applied action_seq, in the caller's
// transaction (the one that marks the action done).
func SetLastApplied(tx *sql.Tx, device string, seq uint64) error {
	return updateDevice(tx, device, seq, `UPDATE devices SET last_applied_action_seq = ? WHERE device_id = ? COLLATE NOCASE`)
}

// SetResendRequested records the gap start a resend_from was written for,
// so each gap gets one.
func SetResendRequested(tx *sql.Tx, device string, from uint64) error {
	return updateDevice(tx, device, from, `UPDATE devices SET resend_requested_from = ? WHERE device_id = ? COLLATE NOCASE`)
}

// SetOrdered marks device as sending action_seq (its first ordered action
// was read), in the caller's transaction.
func SetOrdered(tx *sql.Tx, device string) error {
	return updateDevice(tx, device, 1, `UPDATE devices SET ordered = ? WHERE device_id = ? COLLATE NOCASE`)
}

// AckEpoch raises device's confirmed epoch to epoch (never lowers it), in
// the caller's transaction.
func AckEpoch(tx *sql.Tx, device string, epoch uint32) error {
	return updateDevice(tx, device, uint64(epoch),
		`UPDATE devices SET acked_epoch = max(acked_epoch, ?) WHERE device_id = ? COLLATE NOCASE`)
}

// updateDevice runs one counter update (query binds the value, then the id).
func updateDevice(tx *sql.Tx, device string, v uint64, query string) error {
	n, err := u64(v)
	if err != nil {
		return err
	}
	res, err := tx.Exec(query, n, device)
	if err != nil {
		return fmt.Errorf("updating a device: %w", err)
	}
	if c, err := res.RowsAffected(); err != nil {
		return fmt.Errorf("updating a device: %w", err)
	} else if c == 0 {
		return ErrNoDevice
	}
	return nil
}

// LinkNonceTx reads a linked phone's link nonce inside the caller's
// transaction (ok false when it is not linked): a decision about a phone's
// action commits only while the link it was read under still stands, since a
// re-link or unlink resets the phone's action order.
func LinkNonceTx(tx *sql.Tx, id string) (nonce string, ok bool, err error) {
	var n sql.NullString
	err = tx.QueryRow(`SELECT link_nonce FROM devices WHERE device_id = ? COLLATE NOCASE`, id).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("reading a device: %w", err)
	}
	return n.String, true, nil
}
