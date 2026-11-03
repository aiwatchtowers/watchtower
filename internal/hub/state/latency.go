package state

import (
	"database/sql"
	"fmt"
	"math"
	"time"
)

// The latency steps (00012, RC §10): a phone action read → applied, applied
// → the slice that shows it saved, and read → saved (the per-action total,
// recorded together with applied_saved).
const (
	StepReadApplied  = "read_applied"
	StepAppliedSaved = "applied_saved"
	StepReadSaved    = "read_saved"
)

// LatencySample is one content-free timing: when it was taken, the active
// transport ("cloudkit" or "relay"), the step and its duration in ms.
type LatencySample struct {
	At        time.Time
	Transport string
	Step      string
	MS        int64
}

// LatencyRow is one step on one transport over a window: the nearest-rank
// p50 and p90 and the number of samples.
type LatencyRow struct {
	Step, Transport string
	P50, P90        time.Duration
	Samples         int
}

// AddLatencySamples writes xs in one short transaction; a sample outside the
// table's enums (or a negative duration) fails the whole batch.
func (s *Store) AddLatencySamples(xs []LatencySample) error {
	if len(xs) == 0 {
		return nil
	}
	err := s.write(func(tx *sql.Tx) error {
		stmt, err := tx.Prepare(`INSERT INTO latency_samples (at, transport, step, ms) VALUES (?, ?, ?, ?)`)
		if err != nil {
			return err
		}
		defer func() { _ = stmt.Close() }()
		for _, x := range xs {
			if _, err := stmt.Exec(toReal(x.At), x.Transport, x.Step, x.MS); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("writing latency samples: %w", err)
	}
	return nil
}

// LatencyStats is every (step, transport) with samples taken at or after
// since, sorted by step then transport, with nearest-rank percentiles.
func (s *Store) LatencyStats(since time.Time) ([]LatencyRow, error) {
	rows, err := s.db.Query(`SELECT step, transport, ms FROM latency_samples WHERE at >= ?
		ORDER BY step, transport, ms`, toReal(since))
	if err != nil {
		return nil, fmt.Errorf("reading latency samples: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var (
		out []LatencyRow
		ms  []int64
		cur LatencyRow
	)
	flush := func() {
		if len(ms) == 0 {
			return
		}
		cur.Samples = len(ms)
		cur.P50, cur.P90 = nearestRank(ms, 0.5), nearestRank(ms, 0.9)
		out = append(out, cur)
		ms = ms[:0]
	}
	for rows.Next() {
		var step, tr string
		var v int64
		if err := rows.Scan(&step, &tr, &v); err != nil {
			return nil, fmt.Errorf("reading latency samples: %w", err)
		}
		if step != cur.Step || tr != cur.Transport {
			flush()
			cur = LatencyRow{Step: step, Transport: tr}
		}
		ms = append(ms, v)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading latency samples: %w", err)
	}
	flush()
	return out, nil
}

// nearestRank is the p-th percentile of sorted (ascending, non-empty): the
// value at rank ceil(p·n).
func nearestRank(sorted []int64, p float64) time.Duration {
	rank := int(math.Ceil(p * float64(len(sorted))))
	rank = max(1, min(rank, len(sorted)))
	return time.Duration(sorted[rank-1]) * time.Millisecond
}

// PruneLatency deletes the samples taken before before, then the oldest ones
// past keep rows.
func (s *Store) PruneLatency(before time.Time, keep int) error {
	err := s.write(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`DELETE FROM latency_samples WHERE at < ?`, toReal(before)); err != nil {
			return err
		}
		_, err := tx.Exec(`DELETE FROM latency_samples WHERE rowid IN (
			SELECT rowid FROM latency_samples ORDER BY at, rowid
			LIMIT max(0, (SELECT count(*) FROM latency_samples) - ?))`, max(0, keep))
		return err
	})
	if err != nil {
		return fmt.Errorf("pruning latency samples: %w", err)
	}
	return nil
}
