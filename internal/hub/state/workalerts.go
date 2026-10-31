package state

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// The hub_meta keys of the work alerts (the Swift hub's names, so an adopted
// Swift sidecar keeps its values).
const (
	// MetaSyncGeneration is the sync generation counter (HubSyncState's
	// generationKey): an alert is published only in the generation that
	// pushed it; a rotation moves the current generation's alerts on.
	MetaSyncGeneration = "sync_generation"
	// MetaWorkAlertsStartedAt is the work alerts' first pass (session stops
	// and permission requests count from it).
	MetaWorkAlertsStartedAt = "work_alerts_started_at"
	// MetaWorkAlertsAwaySince is when the owner left the Mac, as the first
	// away pass saw it; absent while at the Mac.
	MetaWorkAlertsAwaySince = "work_alerts_away_since"
)

// WorkAlertMark is what the hub remembers of one alert key (ask-<id>,
// perm-<id>, stop-<session>-<ms>, cover-<stop key>): when it was first seen,
// when its push was raised (zero while only seen) and in which sync
// generation. The ledger holds keys and times only, never alert text.
type WorkAlertMark struct {
	SeenAt     time.Time
	PushedAt   time.Time
	Generation int64
}

// Pushed reports whether the key's push was raised.
func (m WorkAlertMark) Pushed() bool { return !m.PushedAt.IsZero() }

// NoteWorkAlerts is HubSyncState.noteWorkAlerts: each of keys not known yet
// is remembered as seen at `at` in the current generation (a known one keeps
// its first stamp); each of pushing (a subset of keys) not pushed yet gets
// its push stamped at `at` and moves to the current generation. It returns
// that generation and every remembered key, in one write transaction, so two
// overlapping passes never push one key twice.
func (s *Store) NoteWorkAlerts(ctx context.Context, keys []string, pushing map[string]bool, at time.Time) (int64, map[string]WorkAlertMark, error) {
	var (
		gen   int64
		marks map[string]WorkAlertMark
	)
	err := s.WithTx(ctx, func(tx *sql.Tx) error {
		var err error
		if gen, err = syncGeneration(tx); err != nil {
			return err
		}
		stamp := toReal(at)
		for _, k := range keys {
			if _, err := tx.Exec(`INSERT INTO work_alerts (key, seen_at, generation) VALUES (?, ?, ?)
				ON CONFLICT(key) DO NOTHING`, k, stamp, gen); err != nil {
				return fmt.Errorf("noting a work alert: %w", err)
			}
			if pushing[k] {
				if _, err := tx.Exec(`UPDATE work_alerts SET pushed_at = ?, generation = ?
					WHERE key = ? AND pushed_at IS NULL`, stamp, gen, k); err != nil {
					return fmt.Errorf("noting a work alert push: %w", err)
				}
			}
		}
		marks, err = workAlertMarks(tx)
		return err
	})
	if err != nil {
		return 0, nil, err
	}
	return gen, marks, nil
}

func workAlertMarks(tx *sql.Tx) (map[string]WorkAlertMark, error) {
	rows, err := tx.Query(`SELECT key, seen_at, pushed_at, generation FROM work_alerts`)
	if err != nil {
		return nil, fmt.Errorf("reading work alerts: %w", err)
	}
	defer rows.Close()
	out := map[string]WorkAlertMark{}
	for rows.Next() {
		var (
			key    string
			seen   float64
			pushed sql.NullFloat64
			m      WorkAlertMark
		)
		if err := rows.Scan(&key, &seen, &pushed, &m.Generation); err != nil {
			return nil, fmt.Errorf("reading work alerts: %w", err)
		}
		m.SeenAt = fromReal(seen)
		if pushed.Valid {
			m.PushedAt = fromReal(pushed.Float64)
		}
		out[key] = m
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading work alerts: %w", err)
	}
	return out, nil
}

// PruneWorkAlerts forgets the keys seen before `before` that are not in
// keeping (the work still open): a closed ask never reopens, while an open
// one must stay remembered, or it would alert a second time.
func (s *Store) PruneWorkAlerts(ctx context.Context, before time.Time, keeping map[string]bool) error {
	// Read first: a pass with nothing to prune takes no write lock.
	stale, err := staleWorkAlertKeys(ctx, s.db, before, keeping)
	if err != nil || len(stale) == 0 {
		return err
	}
	return s.WithTx(ctx, func(tx *sql.Tx) error {
		for _, k := range stale {
			// Still stale: a key seen again since the read keeps its row.
			if _, err := tx.Exec(`DELETE FROM work_alerts WHERE key = ? AND seen_at < ?`, k, toReal(before)); err != nil {
				return fmt.Errorf("pruning work alerts: %w", err)
			}
		}
		return nil
	})
}

func staleWorkAlertKeys(ctx context.Context, q *sql.DB, before time.Time, keeping map[string]bool) ([]string, error) {
	rows, err := q.QueryContext(ctx, `SELECT key FROM work_alerts WHERE seen_at < ?`, toReal(before))
	if err != nil {
		return nil, fmt.Errorf("pruning work alerts: %w", err)
	}
	defer rows.Close()
	var stale []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, fmt.Errorf("pruning work alerts: %w", err)
		}
		if !keeping[k] {
			stale = append(stale, k)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("pruning work alerts: %w", err)
	}
	return stale, nil
}

// SyncGeneration is the sync generation counter: 0 until the first bump.
func (s *Store) SyncGeneration() (int64, error) {
	tx, err := s.db.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return 0, fmt.Errorf("reading the sync generation: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	return syncGeneration(tx)
}

func syncGeneration(tx *sql.Tx) (int64, error) {
	raw, ok, err := MetaTx(tx, MetaSyncGeneration)
	if err != nil || !ok {
		return 0, err
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		// The Swift hub reads an unreadable counter as 0 (Int(raw) ?? 0).
		return 0, nil //nolint:nilerr // Swift parity: an unreadable counter is 0
	}
	return n, nil
}

// MoveWorkAlertsForRotation is the work alerts' share of an epoch rotation
// (HubSyncState.wipeForRotation), run in the rotation's transaction: the sync
// generation is bumped and the alerts of the old generation move to the new
// one, so they stay published (resealed under the new K_alert, with no second
// signal: their slice_state rows stay).
func MoveWorkAlertsForRotation(tx *sql.Tx) error {
	gen, err := syncGeneration(tx)
	if err != nil {
		return err
	}
	if err := SetMetaTx(tx, MetaSyncGeneration, strconv.FormatInt(gen+1, 10)); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE work_alerts SET generation = ? WHERE generation = ?`, gen+1, gen); err != nil {
		return fmt.Errorf("moving work alerts to the new generation: %w", err)
	}
	return nil
}

// ErrCorruptMeta is a hub_meta value that does not parse as its key's type.
var ErrCorruptMeta = errors.New("state: unreadable hub_meta value")

// EnsureMetaTime returns the time stored under key (Swift's String(Double)
// seconds since 1970), storing `at` there first when the key is unset — in
// one transaction, so two passes agree on the first stamp.
func (s *Store) EnsureMetaTime(ctx context.Context, key string, at time.Time) (time.Time, error) {
	var out time.Time
	err := s.WithTx(ctx, func(tx *sql.Tx) error {
		raw, ok, err := MetaTx(tx, key)
		if err != nil {
			return err
		}
		if !ok {
			raw = SwiftSeconds(at)
			if err := SetMetaTx(tx, key, raw); err != nil {
				return err
			}
		}
		f, err := strconv.ParseFloat(raw, 64)
		if err != nil {
			return fmt.Errorf("%w: %s", ErrCorruptMeta, key)
		}
		out = fromReal(f)
		return nil
	})
	return out, err
}

// DeleteMeta removes one hub_meta value (no error when it is unset).
func (s *Store) DeleteMeta(key string) error {
	return s.write(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`DELETE FROM hub_meta WHERE key = ?`, key); err != nil {
			return fmt.Errorf("deleting hub_meta %s: %w", key, err)
		}
		return nil
	})
}

// SwiftSeconds is `String(date.timeIntervalSince1970)` as Swift prints it for
// a date of this era: the shortest round-trip decimal, with ".0" on a whole
// second.
func SwiftSeconds(t time.Time) string {
	s := strconv.FormatFloat(toReal(t), 'f', -1, 64)
	for _, c := range s {
		if c == '.' {
			return s
		}
	}
	return s + ".0"
}
