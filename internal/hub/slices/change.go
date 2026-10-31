package slices

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"slices"
	"time"
)

// The data_version poll's cadence (spec §9, RC decision).
const (
	// ActivePoll is the poll while a phone was in touch within ActiveWindow.
	ActivePoll = 250 * time.Millisecond
	// IdlePoll is the poll otherwise.
	IdlePoll = time.Second
	// ActiveWindow is how long a phone's last touch keeps the poll active.
	ActiveWindow = 10 * time.Minute
)

// ChangeWatch sees writes to watchtower.db made by other connections — the
// Desktop, MCP servers, hooks, the CLI and the daemon's own pool — through
// one PRAGMA data_version poll on a dedicated read connection (spec §9): on
// a change every database-backed kind is marked dirty, and the publisher's
// debounce coalesces them. data_version cannot say which table changed, so
// the table map only names the kinds the database feeds.
type ChangeWatch struct {
	conn    *sql.Conn
	kinds   []Kind
	touched func() time.Time
	clock   func() time.Time
	// timer is the wait between two polls; a test replaces it.
	timer func(d time.Duration) (<-chan time.Time, func())

	last    int64
	started bool
}

// NewChangeWatch builds a watch over conn, a connection no other code uses
// (data_version only moves for commits by other connections). tables maps
// each table a slice reads to the kinds it feeds; touched is when a phone
// was last in touch (zero = never); clock nil is time.Now.
func NewChangeWatch(conn *sql.Conn, tables map[string][]Kind, touched func() time.Time, clock func() time.Time) *ChangeWatch {
	if clock == nil {
		clock = time.Now
	}
	if touched == nil {
		touched = func() time.Time { return time.Time{} }
	}
	var kinds []Kind
	for _, ks := range tables {
		for _, k := range ks {
			if !slices.Contains(kinds, k) {
				kinds = append(kinds, k)
			}
		}
	}
	// AllKinds order, so the dirty call is stable.
	slices.SortFunc(kinds, func(a, b Kind) int { return slices.Index(AllKinds, a) - slices.Index(AllKinds, b) })
	return &ChangeWatch{conn: conn, kinds: kinds, touched: touched, clock: clock, timer: realTimer}
}

// Kinds is every database-backed kind a change marks dirty.
func (w *ChangeWatch) Kinds() []Kind { return slices.Clone(w.kinds) }

// Interval is the wait before the next poll: ActivePoll while a phone was in
// touch within ActiveWindow, else IdlePoll.
func (w *ChangeWatch) Interval() time.Duration {
	t := w.touched()
	if !t.IsZero() && w.clock().Sub(t) < ActiveWindow {
		return ActivePoll
	}
	return IdlePoll
}

// Run polls until ctx ends (it returns ctx.Err()): every Interval it reads
// data_version and, when it moved since the last read, calls dirty with
// every database-backed kind. The first read only takes the baseline (the
// publisher's start cycle covers what was written before). A failed read is
// logged once per run of failures and retried at the next poll.
func (w *ChangeWatch) Run(ctx context.Context, dirty func(kinds ...Kind)) error {
	failing := false
	for {
		changed, err := w.poll(ctx)
		switch {
		case ctx.Err() != nil:
			return ctx.Err()
		case err != nil:
			if !failing {
				log.Printf("hub slices: data_version poll failed (%s): retried", errClass(err))
			}
			failing = true
		default:
			failing = false
			if changed && len(w.kinds) > 0 {
				dirty(w.kinds...)
			}
		}
		fired, stop := w.timer(w.Interval())
		select {
		case <-ctx.Done():
			stop()
			return ctx.Err()
		case <-fired:
		}
		stop()
	}
}

// poll reads data_version once; changed is true when it differs from the
// previous read (never on the first).
func (w *ChangeWatch) poll(ctx context.Context) (changed bool, err error) {
	var v int64
	if err := w.conn.QueryRowContext(ctx, `PRAGMA data_version`).Scan(&v); err != nil {
		return false, fmt.Errorf("slices: data_version: %w", err)
	}
	changed = w.started && v != w.last
	w.last, w.started = v, true
	return changed, nil
}
