package state

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// ErrUnsealed refuses a control-queue or held row without an envelope: the
// sidecar's new tables hold sealed envelopes only.
var ErrUnsealed = errors.New("hub: refusing to store an unsealed record")

// Control queue expect modes (control_queue.expect).
const (
	ExpectNone   = "none"
	ExpectAbsent = "absent"
	ExpectSeq    = "seq"
)

// Control is one queued write to a phone's mailbox: RecordName is the opaque
// wire name, Envelope a sealed envelope, Expect the save condition
// (ExpectSeq with ExpectSeq's value, any 64-bit record version).
type Control struct {
	ID         int64
	Mailbox    string
	RecordName string
	Kind       string
	Envelope   []byte
	Expect     string
	ExpectSeq  uint64
	Attempts   int
}

// Enqueue adds c to its mailbox's queue in the caller's transaction (the
// one that commits the decision the control reports).
func Enqueue(tx *sql.Tx, c Control) error {
	if len(c.Envelope) == 0 {
		return ErrUnsealed
	}
	var seq any
	switch c.Expect {
	case ExpectNone, ExpectAbsent:
	case ExpectSeq:
		// A record version: the hosted relay's record_seq or a CloudKit
		// change tag, which is opaque and uses all 64 bits, so it is stored
		// bit for bit (two's complement) and read back the same way.
		seq = int64(c.ExpectSeq)
	default:
		return fmt.Errorf("unknown control expect %q", c.Expect)
	}
	if _, err := tx.Exec(`INSERT INTO control_queue (mailbox, record_name, kind, envelope, expect, expect_seq, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, c.Mailbox, c.RecordName, c.Kind, c.Envelope, c.Expect, seq, toReal(time.Now())); err != nil {
		return fmt.Errorf("queueing a control: %w", err)
	}
	return nil
}

// PendingControls lists mailbox's queued controls in the order they were
// queued.
func (s *Store) PendingControls(mailbox string) ([]Control, error) {
	rows, err := s.db.Query(`SELECT id, mailbox, record_name, kind, envelope, expect, expect_seq, attempts
		FROM control_queue WHERE mailbox = ? ORDER BY id`, mailbox)
	if err != nil {
		return nil, fmt.Errorf("listing controls: %w", err)
	}
	defer rows.Close()
	var out []Control
	for rows.Next() {
		var (
			c   Control
			seq sql.NullInt64
		)
		if err := rows.Scan(&c.ID, &c.Mailbox, &c.RecordName, &c.Kind, &c.Envelope, &c.Expect, &seq, &c.Attempts); err != nil {
			return nil, fmt.Errorf("reading a control: %w", err)
		}
		c.ExpectSeq = uint64(seq.Int64)
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing controls: %w", err)
	}
	return out, nil
}

// ControlDone removes a written control.
func (s *Store) ControlDone(id int64) error {
	return s.write(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`DELETE FROM control_queue WHERE id = ?`, id); err != nil {
			return fmt.Errorf("removing a control: %w", err)
		}
		return nil
	})
}

// DropResendFrom removes a resend_from that can never be written and forgets
// that its gap was asked (resend_requested_from = 0), in one transaction, so
// the next held action asks for the gap again.
func (s *Store) DropResendFrom(id int64, device string) error {
	return s.write(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`DELETE FROM control_queue WHERE id = ?`, id); err != nil {
			return fmt.Errorf("removing a control: %w", err)
		}
		if err := SetResendRequested(tx, device, 0); err != nil && !errors.Is(err, ErrNoDevice) {
			return err
		}
		return nil
	})
}

// RekeyControls moves the rows queued under any of from to mailbox (a
// phone whose queue key changed: its mailbox moved between its own zone and a
// shared one), keeping their ids and so their order. It returns how many
// moved; a store whose rows are all under mailbox already writes nothing.
func (s *Store) RekeyControls(from []string, mailbox string) (int64, error) {
	var n int64
	for _, old := range from {
		if old == mailbox {
			continue
		}
		var pending bool
		if err := s.db.QueryRow(`SELECT EXISTS (SELECT 1 FROM control_queue WHERE mailbox = ?)`, old).Scan(&pending); err != nil {
			return n, fmt.Errorf("listing controls: %w", err)
		}
		if !pending {
			continue
		}
		var moved int64
		err := s.write(func(tx *sql.Tx) error {
			res, err := tx.Exec(`UPDATE control_queue SET mailbox = ? WHERE mailbox = ?`, mailbox, old)
			if err != nil {
				return fmt.Errorf("moving controls: %w", err)
			}
			moved, err = res.RowsAffected()
			return err
		})
		if err != nil {
			return n, err
		}
		n += moved
	}
	return n, nil
}

// ControlFailed counts a failed write and keeps its error class (a class
// only, never error text) for the next pass's retry.
func (s *Store) ControlFailed(id int64, class string) error {
	return s.write(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`UPDATE control_queue SET attempts = attempts + 1, last_error_class = ? WHERE id = ?`, class, id); err != nil {
			return fmt.Errorf("marking a control failed: %w", err)
		}
		return nil
	})
}

// Held is an action that arrived ahead of a gap.
type Held struct {
	DeviceID   string
	ActionSeq  uint64
	RecordName string
	Envelope   []byte
	HeldAt     time.Time
}

// HoldAction keeps an action until the gap before it closes; holding the
// same action again keeps the first copy.
func (s *Store) HoldAction(device string, seq uint64, record string, envelope []byte) error {
	return s.write(func(tx *sql.Tx) error { return Hold(tx, device, seq, record, envelope) })
}

// Hold is HoldAction in the caller's transaction (the hold decision commits
// with its rollback mark and resend_from).
func Hold(tx *sql.Tx, device string, seq uint64, record string, envelope []byte) error {
	if len(envelope) == 0 {
		return ErrUnsealed
	}
	v, err := u64(seq)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO held_actions (device_id, action_seq, record_name, envelope, held_at)
		VALUES (?, ?, ?, ?, ?) ON CONFLICT(device_id, action_seq) DO NOTHING`,
		deviceKey(device), v, record, envelope, toReal(time.Now())); err != nil {
		return fmt.Errorf("holding an action: %w", err)
	}
	return nil
}

// HeldActions lists device's held actions in action_seq order.
func (s *Store) HeldActions(device string) ([]Held, error) {
	rows, err := s.db.Query(`SELECT device_id, action_seq, record_name, envelope, held_at FROM held_actions
		WHERE device_id = ? COLLATE NOCASE ORDER BY action_seq`, device)
	if err != nil {
		return nil, fmt.Errorf("listing held actions: %w", err)
	}
	defer rows.Close()
	var out []Held
	for rows.Next() {
		var (
			h   Held
			seq int64
			at  float64
		)
		if err := rows.Scan(&h.DeviceID, &seq, &h.RecordName, &h.Envelope, &at); err != nil {
			return nil, fmt.Errorf("reading a held action: %w", err)
		}
		h.ActionSeq = uint64(max(seq, 0))
		h.HeldAt = fromReal(at)
		out = append(out, h)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing held actions: %w", err)
	}
	return out, nil
}

// DropHeld removes a held action once applied, in the caller's transaction.
func DropHeld(tx *sql.Tx, device string, seq uint64) error {
	v, err := u64(seq)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM held_actions WHERE device_id = ? COLLATE NOCASE AND action_seq = ?`, device, v); err != nil {
		return fmt.Errorf("dropping a held action: %w", err)
	}
	return nil
}
