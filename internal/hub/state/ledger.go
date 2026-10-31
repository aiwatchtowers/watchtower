package state

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// relay_processed phases (the exactly-once ledger, Swift RelayPhase).
const (
	PhaseBegun = "begun"
	PhaseDone  = "done"
)

// ErrClaimed is Begin's answer for a record the ledger already holds: only
// the caller whose insert created the row may apply it.
var ErrClaimed = errors.New("hub: relay record already in the ledger")

// Begin claims record as begun, committed with the caller's transaction
// before a non-idempotent kind writes anything. A record already begun or
// done returns ErrClaimed, so two passes never both apply it; a begun row
// with no done at a later pass means the hub stopped mid-apply.
func Begin(tx *sql.Tx, record string, at time.Time) error {
	res, err := tx.Exec(`INSERT INTO relay_processed (record_name, phase, outcome, updated_at)
		VALUES (?, 'begun', NULL, ?) ON CONFLICT(record_name) DO NOTHING`, record, toReal(at))
	if err != nil {
		return fmt.Errorf("claiming a relay record: %w", err)
	}
	if n, err := res.RowsAffected(); err != nil {
		return fmt.Errorf("claiming a relay record: %w", err)
	} else if n == 0 {
		return ErrClaimed
	}
	return nil
}

// MarkDone records record as done with its outcome, the echo it was
// answered with (nil for none) and, when the echo went out, the mailbox seq
// it was written at. It applies with or without a begun row (idempotent
// kinds are marked done directly).
func MarkDone(tx *sql.Tx, record, outcome string, echo []byte, doneSeq *uint64, at time.Time) error {
	var seq any
	if doneSeq != nil {
		v, err := u64(*doneSeq)
		if err != nil {
			return err
		}
		seq = v
	}
	if _, err := tx.Exec(`INSERT INTO relay_processed (record_name, phase, outcome, updated_at, echo, done_seq)
		VALUES (?, 'done', ?, ?, ?, ?)
		ON CONFLICT(record_name) DO UPDATE SET phase = 'done', outcome = excluded.outcome,
			updated_at = excluded.updated_at, echo = excluded.echo, done_seq = excluded.done_seq`,
		record, outcome, toReal(at), echo, seq); err != nil {
		return fmt.Errorf("marking a relay record done: %w", err)
	}
	return nil
}

// Phase is where record stands: "" (unknown), PhaseBegun or PhaseDone, with
// a done record's outcome and stored echo.
func (s *Store) Phase(record string) (phase, outcome string, echo []byte, err error) {
	var o sql.NullString
	err = s.db.QueryRow(`SELECT phase, outcome, echo FROM relay_processed WHERE record_name = ?`, record).
		Scan(&phase, &o, &echo)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", nil, nil
	}
	if err != nil {
		return "", "", nil, fmt.Errorf("reading the relay ledger: %w", err)
	}
	return phase, o.String, echo, nil
}

// RecordSeen writes the rollback mark for a record (relay_seen: the newest
// epoch/seq seen under its wire name from sender) inside the caller's
// transaction, the one that commits the first decision about the record.
// sender is stored uppercase.
func RecordSeen(tx *sql.Tx, wire, sender string, epoch uint32, seq uint64) error {
	v, err := u64(seq)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO relay_seen (wire_name, sender_id, epoch, seq, at) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(wire_name, sender_id) DO UPDATE SET epoch = excluded.epoch, seq = excluded.seq, at = excluded.at`,
		wire, deviceKey(sender), int64(epoch), v, toReal(time.Now())); err != nil {
		return fmt.Errorf("writing the rollback mark: %w", err)
	}
	return nil
}
