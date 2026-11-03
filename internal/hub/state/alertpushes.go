package state

import (
	"database/sql"
	"encoding/json"
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

// The reasons an alert push expired: unsent, except in_flight.
const (
	ReasonFreshness = "freshness"  // the 5-minute window ended
	ReasonOwnerBack = "owner_back" // the owner came back to the Mac
	ReasonRestart   = "restart"    // pending at hub start: never resent
	ReasonSwitched  = "switched"   // the hub switched to CloudKit
	ReasonOverflow  = "overflow"   // the phone's queue was full
	ReasonStopped   = "stopped"    // the hub stopped
	// ReasonInFlight: the request may have reached the relay (interrupted
	// while in progress, or a connection failure with no relay answer), so
	// it is never resent and counts as received (ReceivedAlertPushes).
	ReasonInFlight = "in_flight"
)

// AlertPushSettle is one push's settle: its row, its outcome (reason only
// for expired) and its attempt count.
type AlertPushSettle struct {
	Key, Device, Outcome, Reason string
	Attempts                     int
}

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
// keeps its outcome and a missing row is no error: false then (nothing
// changed).
func (s *Store) SettleAlertPush(key, device, outcome, reason string, attempts int, at time.Time) (bool, error) {
	changed, err := s.SettleAlertPushes([]AlertPushSettle{{Key: key, Device: device, Outcome: outcome, Reason: reason, Attempts: attempts}}, at)
	if err != nil {
		return false, err
	}
	return changed[0], nil
}

// SettleAlertPushes is SettleAlertPush for several rows in one short write
// transaction; changed[i] reports whether xs[i]'s row was pending.
func (s *Store) SettleAlertPushes(xs []AlertPushSettle, at time.Time) ([]bool, error) {
	changed := make([]bool, len(xs))
	if len(xs) == 0 {
		return changed, nil
	}
	err := s.write(func(tx *sql.Tx) error {
		stmt, err := tx.Prepare(`UPDATE alert_pushes SET outcome = ?, reason = ?, attempts = ?, settled_at = ?
			WHERE alert_key = ? AND device_id = ? AND outcome = 'pending'`)
		if err != nil {
			return err
		}
		defer func() { _ = stmt.Close() }()
		for i, x := range xs {
			res, err := stmt.Exec(x.Outcome, x.Reason, x.Attempts, toReal(at), x.Key, x.Device)
			if err != nil {
				return err
			}
			n, err := res.RowsAffected()
			if err != nil {
				return err
			}
			changed[i] = n == 1
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("settling alert pushes: %w", err)
	}
	return changed, nil
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

// ReceivedAlertPushes is, for each of keys, the devices that may hold its
// push (key → device → true): the relay accepted it, or it expired in flight
// and may have reached the relay. A key with none is absent. Resignal skips
// these pairs.
func (s *Store) ReceivedAlertPushes(keys []string) (map[string]map[string]bool, error) {
	out := map[string]map[string]bool{}
	if len(keys) == 0 {
		return out, nil
	}
	list, err := json.Marshal(keys)
	if err != nil {
		return nil, fmt.Errorf("reading received alert pushes: %w", err)
	}
	rows, err := s.db.Query(`SELECT alert_key, device_id FROM alert_pushes
		WHERE alert_key IN (SELECT value FROM json_each(?))
			AND (outcome = 'accepted' OR (outcome = 'expired' AND reason = 'in_flight'))`, string(list))
	if err != nil {
		return nil, fmt.Errorf("reading received alert pushes: %w", err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var k, d string
		if err := rows.Scan(&k, &d); err != nil {
			return nil, fmt.Errorf("reading received alert pushes: %w", err)
		}
		if out[k] == nil {
			out[k] = map[string]bool{}
		}
		out[k][d] = true
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading received alert pushes: %w", err)
	}
	return out, nil
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
