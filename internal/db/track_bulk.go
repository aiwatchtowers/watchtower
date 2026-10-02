package db

import (
	"fmt"
	"strings"
	"time"
)

// TrackSelection narrows the tracks a bulk read or dismiss looks at. Every
// field is optional; the zero value selects every track. UpdatedBefore and
// CreatedBefore are ISO8601 UTC bounds ("2006-01-02T15:04:05Z", the format
// every tracks timestamp is written in), compared as TEXT — exclusive.
type TrackSelection struct {
	Origin        string // "auto" | "custom" | "" = both
	UpdatedBefore string // only tracks with updated_at < this
	CreatedBefore string // only tracks with created_at < this
	ExceptIDs     []int  // never selected
}

// where returns the selection's WHERE conditions and args (no dismissal
// condition — the caller decides whether dismissed rows count).
func (s TrackSelection) where() ([]string, []any) {
	var conds []string
	var args []any
	if s.Origin != "" {
		conds = append(conds, "origin = ?")
		args = append(args, s.Origin)
	}
	if s.UpdatedBefore != "" {
		conds = append(conds, "updated_at < ?")
		args = append(args, s.UpdatedBefore)
	}
	if s.CreatedBefore != "" {
		conds = append(conds, "created_at < ?")
		args = append(args, s.CreatedBefore)
	}
	if len(s.ExceptIDs) > 0 {
		conds = append(conds, "id NOT IN ("+placeholders(len(s.ExceptIDs))+")")
		args = append(args, intArgs(s.ExceptIDs)...)
	}
	return conds, args
}

// TrackBrief is the slice of a track a bulk proposal shows and pins.
type TrackBrief struct {
	ID        int    `json:"id"`
	Text      string `json:"text"`
	Origin    string `json:"origin"`
	UpdatedAt string `json:"updated_at"`
	Dismissed bool   `json:"dismissed,omitempty"`
}

// ActiveTracksMatching returns the non-dismissed tracks s selects, newest
// update first.
func (db *DB) ActiveTracksMatching(s TrackSelection) ([]TrackBrief, error) {
	conds, args := s.where()
	conds = append(conds, "dismissed_at = ''")
	rows, err := db.Query(`SELECT id, text, origin, updated_at FROM tracks WHERE `+
		strings.Join(conds, " AND ")+` ORDER BY updated_at DESC, id DESC`, args...)
	if err != nil {
		return nil, fmt.Errorf("selecting active tracks: %w", err)
	}
	defer rows.Close()
	var out []TrackBrief
	for rows.Next() {
		var b TrackBrief
		if err := rows.Scan(&b.ID, &b.Text, &b.Origin, &b.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning track: %w", err)
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// TrackBriefsByID returns the tracks with the given ids (dismissed ones
// included, flagged), newest update first; a missing id is simply absent.
func (db *DB) TrackBriefsByID(ids []int) ([]TrackBrief, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	query := `SELECT id, text, origin, updated_at, dismissed_at != '' FROM tracks WHERE id IN (` +
		placeholders(len(ids)) + `) ORDER BY updated_at DESC, id DESC`
	rows, err := db.Query(query, intArgs(ids)...)
	if err != nil {
		return nil, fmt.Errorf("reading tracks by id: %w", err)
	}
	defer rows.Close()
	var out []TrackBrief
	for rows.Next() {
		var b TrackBrief
		if err := rows.Scan(&b.ID, &b.Text, &b.Origin, &b.UpdatedAt, &b.Dismissed); err != nil {
			return nil, fmt.Errorf("scanning track: %w", err)
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// DismissTracks soft-dismisses the given tracks in one statement and returns
// how many it dismissed. Only active rows are stamped: a track that is
// already dismissed keeps its original dismissed_at, and a missing id is
// skipped — so a retried bulk dismiss is a no-op for the rows it already
// handled. Same stamp as DismissTrack.
//
// Dual path: the Desktop's Tracks tab bulk dismiss is
// TrackQueries.dismissMany (WatchtowerCore) — same UPDATE, same
// active-only rule. Change both together.
func (db *DB) DismissTracks(ids []int) (int, error) {
	if len(ids) == 0 {
		return 0, nil
	}
	//nolint:gosec // G202: only "?" placeholders are concatenated; ids are bound args.
	query := `UPDATE tracks SET dismissed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE dismissed_at = '' AND id IN (` + placeholders(len(ids)) + `)`
	res, err := db.Exec(query, intArgs(ids)...)
	if err != nil {
		return 0, fmt.Errorf("dismissing tracks: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("dismissing tracks: %w", err)
	}
	return int(n), nil
}

// TrackCounts is a grouped count of the tracks a selection matches. The
// groups count active tracks only; Dismissed is how many matching tracks are
// already dismissed.
type TrackCounts struct {
	Active      int            `json:"active"`
	Dismissed   int            `json:"dismissed"`
	ByOrigin    map[string]int `json:"by_origin"`
	ByOwnership map[string]int `json:"by_ownership"`
	ByPriority  map[string]int `json:"by_priority"`
	// ByLastUpdate buckets active tracks by the age of their last update:
	// "7d" (within 7 days), "30d", "90d", "older".
	ByLastUpdate map[string]int `json:"by_last_update"`
	// Newest are the most recently updated active tracks (at most 3).
	Newest []TrackBrief `json:"newest"`
}

// newestInCounts is how many newest tracks CountTracks echoes back.
const newestInCounts = 3

// CountTracks groups the tracks s selects without returning their rows.
func (db *DB) CountTracks(s TrackSelection, now time.Time) (TrackCounts, error) {
	c := TrackCounts{
		ByOrigin: map[string]int{}, ByOwnership: map[string]int{}, ByPriority: map[string]int{},
		ByLastUpdate: map[string]int{}, Newest: []TrackBrief{},
	}
	conds, args := s.where()
	query := `SELECT id, text, origin, ownership, priority, updated_at, dismissed_at != '' FROM tracks`
	if len(conds) > 0 {
		query += " WHERE " + strings.Join(conds, " AND ")
	}
	rows, err := db.Query(query+` ORDER BY updated_at DESC, id DESC`, args...)
	if err != nil {
		return c, fmt.Errorf("counting tracks: %w", err)
	}
	defer rows.Close()
	bounds := []struct {
		key   string
		since string
	}{
		{"7d", isoUTC(now.AddDate(0, 0, -7))},
		{"30d", isoUTC(now.AddDate(0, 0, -30))},
		{"90d", isoUTC(now.AddDate(0, 0, -90))},
	}
	for rows.Next() {
		var b TrackBrief
		var ownership, priority string
		if err := rows.Scan(&b.ID, &b.Text, &b.Origin, &ownership, &priority, &b.UpdatedAt, &b.Dismissed); err != nil {
			return c, fmt.Errorf("scanning track: %w", err)
		}
		if b.Dismissed {
			c.Dismissed++
			continue
		}
		c.Active++
		c.ByOrigin[b.Origin]++
		c.ByOwnership[ownership]++
		c.ByPriority[priority]++
		bucket := "older"
		for _, bd := range bounds {
			if b.UpdatedAt >= bd.since {
				bucket = bd.key
				break
			}
		}
		c.ByLastUpdate[bucket]++
		if len(c.Newest) < newestInCounts {
			c.Newest = append(c.Newest, b)
		}
	}
	return c, rows.Err()
}

// isoUTC formats t the way every tracks timestamp is stored.
func isoUTC(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05Z")
}
