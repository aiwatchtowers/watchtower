package state

import (
	"context"
	"database/sql"
	"fmt"
	"math"
	"time"
)

// The latency steps (00011, RC §10): a phone action read → applied, applied
// → the slice that shows it saved, and read → saved (the per-action total,
// recorded together with applied_saved). 00018 (live link R7) adds a mailbox
// event's arrival → the read it starts, and applied → the end of the first
// cycle that handled a kind it nudged, written or not.
const (
	StepReadApplied  = "read_applied"
	StepAppliedSaved = "applied_saved"
	StepReadSaved    = "read_saved"
	StepEventRead    = "event_read"
	StepNudgeSaved   = "nudge_saved"
)

// LatencySample is one content-free timing: when it was taken, the active
// transport ("cloudkit" or "relay"), the step, its duration in ms and the
// action kind it timed ("" for event_read, which precedes any action).
type LatencySample struct {
	At        time.Time
	Transport string
	Step      string
	Kind      string
	MS        int64
}

// LatencyRow is one step on one transport for one action kind over a
// window: the nearest-rank p50 and p90 and the number of samples.
type LatencyRow struct {
	Step, Transport, Kind string
	P50, P90              time.Duration
	Samples               int
}

// AddLatencySamples writes xs in one short transaction; a sample outside the
// table's enums (or a negative duration) fails the whole batch.
func (s *Store) AddLatencySamples(xs []LatencySample) error {
	if len(xs) == 0 {
		return nil
	}
	err := s.write(func(tx *sql.Tx) error {
		stmt, err := tx.Prepare(`INSERT INTO latency_samples (at, transport, step, kind, ms) VALUES (?, ?, ?, ?, ?)`)
		if err != nil {
			return err
		}
		defer func() { _ = stmt.Close() }()
		for _, x := range xs {
			if _, err := stmt.Exec(toReal(x.At), x.Transport, x.Step, x.Kind, x.MS); err != nil {
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
// since, over all action kinds (Kind ""), sorted by step then transport, with
// nearest-rank percentiles.
func (s *Store) LatencyStats(since time.Time) ([]LatencyRow, error) {
	return latencyStats(s.db, since, false)
}

// LatencyStatsByKind is LatencyStats per action kind: every (step,
// transport, kind), sorted by step, transport then kind. Kind "" is
// event_read and the samples taken before 00018.
func (s *Store) LatencyStatsByKind(since time.Time) ([]LatencyRow, error) {
	return latencyStats(s.db, since, true)
}

// LatencyStatsWithKinds is LatencyStats and LatencyStatsByKind read in one
// read-only transaction (one snapshot). A file not yet migrated to 00018
// (a newer CLI reading it read-only before the hub reopened it) has no kind
// column: byKind is then nil and all still comes back.
func (s *Store) LatencyStatsWithKinds(since time.Time) (all, byKind []LatencyRow, err error) {
	tx, err := s.db.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, nil, fmt.Errorf("reading latency samples: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // read-only: nothing to commit
	if all, err = latencyStats(tx, since, false); err != nil {
		return nil, nil, err
	}
	var kinds int
	if err := tx.QueryRow(`SELECT count(*) FROM pragma_table_info('latency_samples') WHERE name = 'kind'`).Scan(&kinds); err != nil {
		return nil, nil, fmt.Errorf("reading latency samples: %w", err)
	}
	if kinds == 0 {
		return all, nil, nil
	}
	if byKind, err = latencyStats(tx, since, true); err != nil {
		return nil, nil, err
	}
	return all, byKind, nil
}

// latencyQuerier is a *sql.DB or a *sql.Tx.
type latencyQuerier interface {
	Query(query string, args ...any) (*sql.Rows, error)
}

func latencyStats(db latencyQuerier, since time.Time, byKind bool) ([]LatencyRow, error) {
	q := `SELECT step, transport, '', ms FROM latency_samples WHERE at >= ? ORDER BY step, transport, ms`
	if byKind {
		q = `SELECT step, transport, kind, ms FROM latency_samples WHERE at >= ? ORDER BY step, transport, kind, ms`
	}
	rows, err := db.Query(q, toReal(since))
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
		var step, tr, kind string
		var v int64
		if err := rows.Scan(&step, &tr, &kind, &v); err != nil {
			return nil, fmt.Errorf("reading latency samples: %w", err)
		}
		if step != cur.Step || tr != cur.Transport || kind != cur.Kind {
			flush()
			cur = LatencyRow{Step: step, Transport: tr, Kind: kind}
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
