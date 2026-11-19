package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// WatchmanWaitingClause is the WHERE clause of a watchman item that waits
// for the owner (alias-free columns): parked or handed back with no
// feedback, or an answered handover whose next session failed to start for
// good — and not marked done by the owner. The Desktop's
// `WatchmanItem.waitsForOwner` is the same rule on one item.
const WatchmanWaitingClause = `state = 'done' AND owner_done_at IS NULL AND ((outcome IN ('parked', 'handed') AND feedback = '')` +
	` OR (kind = 'handover' AND outcome = 'answered' AND error != '' AND error NOT IN ('` +
	WatchmanStartPending + `', '` + WatchmanStartClaimed + `')))`

// WatchmanJournalSummary is what the Inbox's Watchman entry shows (the
// morning journal, spec 2026-11-16 §10).
type WatchmanJournalSummary struct {
	// UpdatedAt is the newest item's time, else when Watchman was first
	// turned on.
	UpdatedAt time.Time
	// Waiting counts the items waiting for the owner, every night.
	Waiting int
	// NightStart is the newest night with an item (zero before the first);
	// Decided and Unsure are that night's twin decisions and the unsure ones
	// among them.
	NightStart      time.Time
	Decided, Unsure int
}

// WatchmanNightStart is the start of the journal night t falls in: a night
// runs from 12:00 to 12:00 the next day in loc.
func WatchmanNightStart(t time.Time, loc *time.Location) time.Time {
	t = t.In(loc)
	y, m, d := t.Date()
	noon := time.Date(y, m, d, 12, 0, 0, 0, loc)
	if t.Before(noon) {
		return time.Date(y, m, d-1, 12, 0, 0, 0, loc)
	}
	return noon
}

// WatchmanJournalSummaryTx reads the Inbox entry's summary inside tx, nights
// in loc; nil while Watchman was never turned on and has no item, or when
// it has no item and its enable time does not read (no card rather than an
// Inbox that fails). The
// newest night counts its finished twin decisions the way the journal does:
// not pending, waiting, owner-marked-done, owner-first, superseded or check
// items.
func WatchmanJournalSummaryTx(ctx context.Context, tx *sql.Tx, loc *time.Location) (*WatchmanJournalSummary, error) {
	var newest, enabled sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT MAX(created_at) FROM watchman_items`).Scan(&newest); err != nil {
		return nil, fmt.Errorf("reading the newest watchman item: %w", err)
	}
	if !newest.Valid {
		if err := tx.QueryRowContext(ctx, `SELECT MAX(enabled_at) FROM watchman_workbenches`).Scan(&enabled); err != nil {
			return nil, fmt.Errorf("reading when watchman was turned on: %w", err)
		}
		if !enabled.Valid {
			return nil, nil
		}
		// An unreadable enable time shows no card, as the Mac did.
		if at, err := watchmanJournalTime("enabled_at", enabled.String); err == nil {
			return &WatchmanJournalSummary{UpdatedAt: at}, nil
		}
		return nil, nil
	}
	at, err := watchmanJournalTime("created_at", newest.String)
	if err != nil {
		return nil, err
	}
	s := &WatchmanJournalSummary{UpdatedAt: at, NightStart: WatchmanNightStart(at, loc)}
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM watchman_items WHERE `+WatchmanWaitingClause).
		Scan(&s.Waiting); err != nil {
		return nil, fmt.Errorf("counting the watchman items waiting: %w", err)
	}
	y, m, d := s.NightStart.Date()
	end := time.Date(y, m, d+1, 12, 0, 0, 0, loc)
	rows, err := tx.QueryContext(ctx, `SELECT state, outcome, kind, unsure, owner_done_at IS NOT NULL,
		(`+WatchmanWaitingClause+`) FROM watchman_items WHERE created_at >= ? AND created_at < ?`,
		wmTime(s.NightStart), wmTime(end))
	if err != nil {
		return nil, fmt.Errorf("reading the newest watchman night: %w", err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var state, outcome, kind string
		var unsure, ownerDone, waits bool
		if err := rows.Scan(&state, &outcome, &kind, &unsure, &ownerDone, &waits); err != nil {
			return nil, fmt.Errorf("reading the newest watchman night: %w", err)
		}
		switch {
		case state != "done", waits:
		case (outcome == "parked" || outcome == "handed") && ownerDone:
		case outcome == "owner_first" || outcome == "superseded":
		case kind == "check":
		default:
			s.Decided++
			if unsure {
				s.Unsure++
			}
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the newest watchman night: %w", err)
	}
	return s, nil
}

func watchmanJournalTime(column, v string) (time.Time, error) {
	t, err := time.Parse(time.RFC3339Nano, v)
	if err != nil {
		return time.Time{}, errors.Join(fmt.Errorf("watchman %s %q is not a time", column, v), err)
	}
	return t.UTC(), nil
}
