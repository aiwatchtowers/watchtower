package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Presence bounds (spec 2026-10-10-owner-asks-v2 Part 2.4): the Desktop
// rewrites the row every 30 s while the owner is in a session, so a write
// older than three missed heartbeats is a hung Desktop or a Mac that slept
// without notice; a write further in the future than the tolerance is a
// clock it cannot trust.
const (
	ownerPresenceMaxAge          = 90 * time.Second
	ownerPresenceFutureTolerance = 5 * time.Second
)

// OwnerPresentIn reports whether the owner is in terminal session sessionID
// at now: the owner_presence row (written by the Desktop only) names it and
// its seen_at parses and is at most 90 s old and at most 5 s ahead of now.
// No row, another or no session, an unreadable stamp: false. A read error is
// returned; callers treat it as absent.
func (db *DB) OwnerPresentIn(sessionID int64, now time.Time) (bool, error) {
	var session sql.NullInt64
	var seenAt string
	err := db.QueryRow(`SELECT session_id, seen_at FROM owner_presence WHERE id = 1`).Scan(&session, &seenAt)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading owner presence: %w", err)
	}
	if !session.Valid || session.Int64 != sessionID {
		return false, nil
	}
	seen, ok := ParseAgentStateStamp(seenAt)
	if !ok {
		return false, nil
	}
	age := now.Sub(seen)
	return age <= ownerPresenceMaxAge && age >= -ownerPresenceFutureTolerance, nil
}
