package state

import (
	"database/sql"
	"fmt"
	"time"
)

// The outcome classes of an alert push (00012, Go hub plan 4 "Outcome
// classes"): pending until the request is answered, then one of the rest.
// Accepted is the relay's Ok, not an APNs delivery.
const (
	AlertPending   = "pending"
	AlertAccepted  = "accepted"
	AlertNoToken   = "no_token"
	AlertNotPaying = "not_paying"
	AlertForbidden = "forbidden"
	AlertPushOff   = "push_off"
	AlertTooLarge  = "too_large"
	AlertExpired   = "expired"
	AlertFailed    = "failed"
)

// The reasons an alert push expired unsent.
const (
	ReasonFreshness = "freshness"  // the 5-minute window ended
	ReasonOwnerBack = "owner_back" // the owner came back to the Mac
	ReasonRestart   = "restart"    // pending at hub start: never resent
	ReasonSwitched  = "switched"   // the hub switched to CloudKit
	ReasonOverflow  = "overflow"   // the phone's queue was full
	ReasonStopped   = "stopped"    // the hub stopped
)

// BeginAlertPush writes the pending row of key's push to device; false when
// a row exists already (pending or settled): a push is never begun twice.
func (s *Store) BeginAlertPush(key, device string, at time.Time) (bool, error) {
	begun, err := s.BeginAlertPushes(key, []string{device}, at)
	return len(begun) == 1, err
}

// BeginAlertPushes is BeginAlertPush for several phones in one short write
// transaction; it returns the devices whose row it wrote, in order.
func (s *Store) BeginAlertPushes(key string, devices []string, at time.Time) ([]string, error) {
	var begun []string
	err := s.write(func(tx *sql.Tx) error {
		begun = begun[:0]
		for _, d := range devices {
			res, err := tx.Exec(`INSERT INTO alert_pushes (alert_key, device_id, outcome, first_at)
				VALUES (?, ?, 'pending', ?) ON CONFLICT DO NOTHING`, key, d, toReal(at))
			if err != nil {
				return err
			}
			if n, err := res.RowsAffected(); err != nil {
				return err
			} else if n == 1 {
				begun = append(begun, d)
			}
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("beginning an alert push: %w", err)
	}
	return begun, nil
}

// SettleAlertPush settles the pending row of key's push to device with its
// outcome (reason only for expired) and attempt count. A row already settled
// keeps its outcome; a missing row is no error.
func (s *Store) SettleAlertPush(key, device, outcome, reason string, attempts int, at time.Time) error {
	err := s.write(func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE alert_pushes SET outcome = ?, reason = ?, attempts = ?, settled_at = ?
			WHERE alert_key = ? AND device_id = ? AND outcome = 'pending'`,
			outcome, reason, attempts, toReal(at), key, device)
		return err
	})
	if err != nil {
		return fmt.Errorf("settling an alert push: %w", err)
	}
	return nil
}

// ExpirePendingAlertPushes settles every pending row expired (reason
// restart): at hub start, a push queued or in flight at a crash is never
// resent. It returns how many it settled.
func (s *Store) ExpirePendingAlertPushes(at time.Time) (int, error) {
	var n int64
	err := s.write(func(tx *sql.Tx) error {
		res, err := tx.Exec(`UPDATE alert_pushes SET outcome = 'expired', reason = 'restart', settled_at = ?
			WHERE outcome = 'pending'`, toReal(at))
		if err != nil {
			return err
		}
		n, err = res.RowsAffected()
		return err
	})
	if err != nil {
		return 0, fmt.Errorf("expiring pending alert pushes: %w", err)
	}
	return int(n), nil
}

// AlertPushOverflows counts the pushes settled expired with reason overflow
// at or after since.
func (s *Store) AlertPushOverflows(since time.Time) (int, error) {
	var n int
	if err := s.db.QueryRow(`SELECT count(*) FROM alert_pushes
		WHERE outcome = 'expired' AND reason = 'overflow' AND settled_at >= ?`, toReal(since)).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting overflowed alert pushes: %w", err)
	}
	return n, nil
}

// AcceptedAlertPushes is, for each of keys, the devices whose push the relay
// accepted (key → device → true); a key with none is absent.
func (s *Store) AcceptedAlertPushes(keys []string) (map[string]map[string]bool, error) {
	out := map[string]map[string]bool{}
	for _, k := range keys {
		devices, err := s.acceptedAlertPushes(k)
		if err != nil {
			return nil, fmt.Errorf("reading accepted alert pushes: %w", err)
		}
		if len(devices) > 0 {
			out[k] = devices
		}
	}
	return out, nil
}

// acceptedAlertPushes is the devices whose push of key the relay accepted.
func (s *Store) acceptedAlertPushes(key string) (map[string]bool, error) {
	rows, err := s.db.Query(`SELECT device_id FROM alert_pushes WHERE alert_key = ? AND outcome = 'accepted'`, key)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := map[string]bool{}
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			return nil, err
		}
		out[d] = true
	}
	return out, rows.Err()
}

// LastAlertOutcomes is each device's newest settled outcome among the pushes
// settled at or after since (device → outcome class).
func (s *Store) LastAlertOutcomes(since time.Time) (map[string]string, error) {
	rows, err := s.db.Query(`SELECT device_id, outcome FROM alert_pushes
		WHERE outcome != 'pending' AND settled_at >= ? ORDER BY settled_at, rowid`, toReal(since))
	if err != nil {
		return nil, fmt.Errorf("reading alert push outcomes: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := map[string]string{}
	for rows.Next() {
		var d, o string
		if err := rows.Scan(&d, &o); err != nil {
			return nil, fmt.Errorf("reading alert push outcomes: %w", err)
		}
		out[d] = o // ascending: the newest wins
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading alert push outcomes: %w", err)
	}
	return out, nil
}

// PruneAlertPushes deletes the rows of pushes first queued earlier than
// before (7 days, with the alert lifetime).
func (s *Store) PruneAlertPushes(before time.Time) error {
	err := s.write(func(tx *sql.Tx) error {
		_, err := tx.Exec(`DELETE FROM alert_pushes WHERE first_at < ?`, toReal(before))
		return err
	})
	if err != nil {
		return fmt.Errorf("pruning alert pushes: %w", err)
	}
	return nil
}
