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
	// RelayAdmittedAt is when the relay first listed this phone as holding
	// the hub in a slot (zero = not yet). Read only: MarkRelayAdmitted
	// writes it; LinkDevice, SetRelayDeviceIDTx and ClearRelayDeviceIDTx clear it.
	RelayAdmittedAt time.Time
	// RelayLapsedAt is set while the phone's relay entitlement is lapsed
	// and the hub stays on the relay (sim rule 16). RelaySkipSeq and
	// RelaySkipBefore, kept after the lapse ends, cut off the relay
	// actions sent before it (never applied): ordered ones by action_seq
	// (the highest the hub saw at or during the lapse), legacy ones by the
	// lapse's time. Read only: LapseRelay, RaiseRelaySkipSeq and
	// EndRelayLapse write them, LinkDevice clears them, and
	// ClearRelayDeviceIDTx ends a running lapse.
	RelayLapsedAt   *time.Time
	RelaySkipBefore *time.Time
	RelaySkipSeq    uint64
	// WorkAlertsOff is the phone's "When work stops" switch being off, from its
	// device record: the hub pushes it no alert. Read only: the device record's
	// rewrite writes it, LinkDevice clears it.
	WorkAlertsOff bool
}

// MarkRelayAdmitted stamps at on the linked phones among relayIDs (their
// relay device ids) that carry no stamp yet; it returns how many it stamped.
func (s *Store) MarkRelayAdmitted(relayIDs []string, at time.Time) (int, error) {
	n := 0
	err := s.write(func(tx *sql.Tx) error {
		n = 0
		for _, id := range relayIDs {
			if id == "" {
				continue
			}
			res, err := tx.Exec(`UPDATE devices SET relay_admitted_at = ?
				WHERE relay_device_id = ? AND relay_admitted_at IS NULL`, toReal(at), id)
			if err != nil {
				return fmt.Errorf("stamping a device's relay admission: %w", err)
			}
			c, err := res.RowsAffected()
			if err != nil {
				return fmt.Errorf("stamping a device's relay admission: %w", err)
			}
			n += int(c)
		}
		return nil
	})
	return n, err
}

const deviceColumns = `device_id, name, scope, linked_at, signing_key, agreement_key, link_nonce,
	typing_allowed, typing_requested, permissions_allowed, permissions_requested,
	start_sessions_allowed, start_sessions_granted,
	last_applied_action_seq, ordered, relay_device_id, resend_requested_from, acked_epoch`

// deviceRead is what a read selects: the link's columns, the relay's admission
// stamp, which only MarkRelayAdmitted writes (a re-link clears it), and the
// switch only a device record's rewrite writes (a re-link clears it too).
const deviceRead = deviceColumns + `, relay_admitted_at, relay_lapsed_at, relay_skip_before, relay_skip_seq, work_alerts_off`

type rowScanner interface{ Scan(dest ...any) error }

func scanDevice(r rowScanner) (Device, error) {
	var (
		d                  Device
		linked             float64
		nonce, relayID     sql.NullString
		lastApplied, resnd int64
		acked              int64
		admitted           sql.NullFloat64
		lapsed, skip       sql.NullFloat64
		skipSeq            int64
	)
	err := r.Scan(&d.ID, &d.Name, &d.Scope, &linked, &d.SigningKey, &d.AgreementKey, &nonce,
		&d.TypingAllowed, &d.TypingRequested, &d.PermissionsAllowed, &d.PermissionsRequested,
		&d.StartSessionsAllowed, &d.StartSessionsGranted,
		&lastApplied, &d.Ordered, &relayID, &resnd, &acked, &admitted, &lapsed, &skip, &skipSeq, &d.WorkAlertsOff)
	if err != nil {
		return Device{}, err
	}
	if admitted.Valid {
		d.RelayAdmittedAt = fromReal(admitted.Float64)
	}
	if lapsed.Valid {
		t := fromReal(lapsed.Float64)
		d.RelayLapsedAt = &t
	}
	if skip.Valid {
		t := fromReal(skip.Float64)
		d.RelaySkipBefore = &t
	}
	d.RelaySkipSeq = uint64(max(skipSeq, 0))
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
	rows, err := s.db.Query(`SELECT ` + deviceRead + ` FROM devices ORDER BY linked_at, device_id`)
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
	d, err := scanDevice(s.db.QueryRow(`SELECT `+deviceRead+` FROM devices WHERE device_id = ? COLLATE NOCASE`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, false, nil
	}
	if err != nil {
		return Device{}, false, fmt.Errorf("reading a device: %w", err)
	}
	return d, true, nil
}

// SetRelayDeviceIDTx stores relayID as device's relay device id, in the
// caller's transaction, and clears its relay admission stamp in the same
// statement, so MarkRelayAdmitted stamps it again once the relay's account
// state lists the new id. ErrNoDevice when device is not linked.
func SetRelayDeviceIDTx(tx *sql.Tx, device, relayID string) error {
	res, err := tx.Exec(`UPDATE devices SET relay_device_id = ?, relay_admitted_at = NULL
		WHERE device_id = ? COLLATE NOCASE`, relayID, device)
	if err != nil {
		return fmt.Errorf("storing a device's relay id: %w", err)
	}
	if n, err := res.RowsAffected(); err != nil {
		return fmt.Errorf("storing a device's relay id: %w", err)
	} else if n == 0 {
		return ErrNoDevice
	}
	return nil
}

// ClearRelayDeviceIDTx takes relayID off every linked phone but keep, in the
// caller's transaction, with what stands on it: the admission stamp (the slot
// was the id's) and a running relay lapse, which only a paying read through
// that id could end. It returns how many phones lost the id. The skip marks
// stay: they only ever cut off records sent before a lapse.
func ClearRelayDeviceIDTx(tx *sql.Tx, relayID, keep string) (int, error) {
	res, err := tx.Exec(`UPDATE devices SET relay_device_id = NULL, relay_admitted_at = NULL, relay_lapsed_at = NULL
		WHERE relay_device_id = ? AND device_id <> ? COLLATE NOCASE`, relayID, keep)
	if err != nil {
		return 0, fmt.Errorf("clearing a device's relay id: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("clearing a device's relay id: %w", err)
	}
	return int(n), nil
}

// LapseRelay marks device lapsed on the relay as of at (sim rule 16), in the
// caller's transaction, and drops its held actions (echoed held, so the
// phone lists them as not delivered); relay_skip_seq becomes the highest
// action_seq the hub saw (applied or held). It is a compare-and-set: false,
// and nothing written, when the phone is already lapsed or not linked.
func LapseRelay(tx *sql.Tx, device string, at time.Time) (bool, error) {
	res, err := tx.Exec(`UPDATE devices SET relay_lapsed_at = ?, relay_skip_before = ?,
		relay_skip_seq = max(relay_skip_seq, last_applied_action_seq,
			ifnull((SELECT max(action_seq) FROM held_actions h WHERE h.device_id = devices.device_id COLLATE NOCASE), 0))
		WHERE device_id = ? COLLATE NOCASE AND relay_lapsed_at IS NULL`, toReal(at), toReal(at), device)
	if err != nil {
		return false, fmt.Errorf("marking a relay lapse: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil || n == 0 {
		return false, err
	}
	if _, err := tx.Exec(`DELETE FROM held_actions WHERE device_id = ? COLLATE NOCASE`, device); err != nil {
		return false, fmt.Errorf("dropping a lapsed phone's held actions: %w", err)
	}
	return true, nil
}

// RaiseRelaySkipSeq raises device's relay_skip_seq to seq (never lowers
// it): an ordered relay action the hub read while the phone is lapsed.
func (s *Store) RaiseRelaySkipSeq(device string, seq uint64) error {
	return s.write(func(tx *sql.Tx) error {
		return updateDevice(tx, device, seq,
			`UPDATE devices SET relay_skip_seq = max(relay_skip_seq, ?) WHERE device_id = ? COLLATE NOCASE`)
	})
}

// EndRelayLapse ends device's relay lapse (a fresh account read lists it
// paying); relay_skip_before stays. It reports whether a lapse ended.
func (s *Store) EndRelayLapse(device string) (bool, error) {
	ended := false
	err := s.write(func(tx *sql.Tx) error {
		res, err := tx.Exec(`UPDATE devices SET relay_lapsed_at = NULL
			WHERE device_id = ? COLLATE NOCASE AND relay_lapsed_at IS NOT NULL`, device)
		if err != nil {
			return fmt.Errorf("ending a relay lapse: %w", err)
		}
		n, err := res.RowsAffected()
		ended = n > 0
		return err
	})
	return ended, err
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

// CloudKitLinks counts the phones linked over CloudKit: they carry the
// iCloud user that created their hello; a relay link carries none.
func (s *Store) CloudKitLinks() (int, error) {
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM devices WHERE user_record_name <> ''`).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting CloudKit links: %w", err)
	}
	return n, nil
}
