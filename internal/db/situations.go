package db

import (
	"fmt"
	"strings"
)

// situationSelectCols is the standard SELECT column list for situations.
const situationSelectCols = `id, title, kind, status, snooze_until, priority, rank,
	ai_reason, summary, why_matters, chronology, card_status, COALESCE(card_generated_at,''),
	target_id, track_id, converted_target_id, converted_track_id,
	last_signal_at, resolved_reason, suggested_resolution, created_at, updated_at`

// scanSituation scans a Situation from a row with situationSelectCols.
func scanSituation(row interface{ Scan(...any) error }) (*DashboardSituation, error) {
	var s DashboardSituation
	if err := row.Scan(
		&s.ID, &s.Title, &s.Kind, &s.Status, &s.SnoozeUntil, &s.Priority, &s.Rank,
		&s.AIReason, &s.Summary, &s.WhyMatters, &s.Chronology, &s.CardStatus, &s.CardGeneratedAt,
		&s.TargetID, &s.TrackID, &s.ConvertedTargetID, &s.ConvertedTrackID,
		&s.LastSignalAt, &s.ResolvedReason, &s.SuggestedResolution, &s.CreatedAt, &s.UpdatedAt,
	); err != nil {
		return nil, err
	}
	return &s, nil
}

// GetSituation returns a single situation by ID.
func (db *DB) GetSituation(id int) (DashboardSituation, error) {
	row := db.QueryRow(`SELECT `+situationSelectCols+` FROM situations WHERE id = ?`, id)
	s, err := scanSituation(row)
	if err != nil {
		return DashboardSituation{}, fmt.Errorf("getting situation %d: %w", id, err)
	}
	return *s, nil
}

// SituationFilter narrows ListSituations. The zero value lists every
// situation, newest-ranked first, capped at the default limit.
type SituationFilter struct {
	Status string // "" = any status
	// SinceISO bounds last_signal_at ("" = no bound). A situation that has
	// never received a signal has last_signal_at = '', which sorts below any
	// real timestamp — so it is deliberately excluded whenever a bound is
	// given, since a recency filter should not surface signal-less stories.
	SinceISO string
	Limit    int // <= 0 = 50
}

// ListSituations lists dashboard situations with optional status/recency
// filters over the frozen table (memory reads it; see the "Residual writers"
// note below on why it is frozen).
func (db *DB) ListSituations(f SituationFilter) ([]DashboardSituation, error) {
	query := `SELECT ` + situationSelectCols + ` FROM situations`
	var conds []string
	var args []any

	if f.Status != "" {
		conds = append(conds, "status = ?")
		args = append(args, f.Status)
	}
	if f.SinceISO != "" {
		conds = append(conds, "last_signal_at >= ?")
		args = append(args, f.SinceISO)
	}
	if len(conds) > 0 {
		query += " WHERE " + strings.Join(conds, " AND ")
	}

	limit := f.Limit
	if limit <= 0 {
		limit = 50
	}
	query += " ORDER BY rank DESC, updated_at DESC LIMIT ?"
	args = append(args, limit)

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing situations: %w", err)
	}
	defer rows.Close()

	var out []DashboardSituation
	for rows.Next() {
		s, err := scanSituation(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning situation: %w", err)
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

// ---- Residual writers ----
//
// The situations table is frozen history: no production code path writes to it
// any more (the composer, the situation cards and the dashboard lifecycle were
// removed with the inbox demolition — see
// docs/superpowers/specs/2026-09-14-inbox-demolition-design.md §4). The five
// writers below survive only because tests in internal/memory (and this
// package's own tests) seed the frozen table through them; they have no
// non-test caller. internal/tools, internal/mcp and cmd no longer call them —
// their test-fixture calls were replaced with raw-SQL seeding when the
// situations readers were retired (inbox demolition, task 4).

// CreateSituation inserts a new situation and returns its ID.
func (db *DB) CreateSituation(s DashboardSituation) (int64, error) {
	if s.Status == "" {
		s.Status = "open"
	}
	if s.Priority == "" {
		s.Priority = "medium"
	}
	if s.Kind == "" {
		s.Kind = "external"
	}
	if s.CardStatus == "" {
		s.CardStatus = "none"
	}
	now := "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
	res, err := db.Exec(`INSERT INTO situations (title, kind, status, priority, rank, ai_reason,
		summary, why_matters, chronology, card_status, target_id, track_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, `+now+`, `+now+`)`,
		s.Title, s.Kind, s.Status, s.Priority, s.Rank, s.AIReason,
		s.Summary, s.WhyMatters, s.Chronology, s.CardStatus, s.TargetID, s.TrackID,
	)
	if err != nil {
		return 0, fmt.Errorf("inserting situation: %w", err)
	}
	return res.LastInsertId()
}

// AddSituationSignals attaches inbox items to a situation as signals
// (INSERT OR IGNORE, so re-adding an already-attached item is a no-op) and
// bumps the situation's last_signal_at/updated_at timestamps.
func (db *DB) AddSituationSignals(situationID int, inboxItemIDs []int) error {
	if len(inboxItemIDs) == 0 {
		return nil
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning tx for situation signals: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck

	for _, itemID := range inboxItemIDs {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO situation_signals (situation_id, inbox_item_id) VALUES (?, ?)`,
			situationID, itemID); err != nil {
			return fmt.Errorf("adding signal %d to situation %d: %w", itemID, situationID, err)
		}
	}
	if _, err := tx.Exec(`UPDATE situations SET
		last_signal_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?`, situationID); err != nil {
		return fmt.Errorf("touching situation %d: %w", situationID, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing situation signals: %w", err)
	}
	return nil
}

// SetSituationCard stores the card content and marks card_status ready.
func (db *DB) SetSituationCard(id int, summary, whyMatters, chronology string) error {
	_, err := db.Exec(`UPDATE situations SET summary = ?, why_matters = ?, chronology = ?,
		card_status = 'ready', card_generated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		summary, whyMatters, chronology, id)
	if err != nil {
		return fmt.Errorf("setting situation %d card: %w", id, err)
	}
	return nil
}

// SetSituationStatus changes a situation's status and records the reason.
func (db *DB) SetSituationStatus(id int, status, reason string) error {
	_, err := db.Exec(`UPDATE situations SET status = ?, resolved_reason = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`, status, reason, id)
	if err != nil {
		return fmt.Errorf("setting situation %d status: %w", id, err)
	}
	return nil
}

// MarkSituationConverted marks a situation as converted into a target and/or
// track. A zero targetID/trackID is stored as NULL (not converted to that kind).
func (db *DB) MarkSituationConverted(id int, targetID, trackID int) error {
	var convertedTarget, convertedTrack any
	if targetID != 0 {
		convertedTarget = targetID
	}
	if trackID != 0 {
		convertedTrack = trackID
	}
	_, err := db.Exec(`UPDATE situations SET status = 'converted',
		converted_target_id = ?, converted_track_id = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?`,
		convertedTarget, convertedTrack, id)
	if err != nil {
		return fmt.Errorf("marking situation %d converted: %w", id, err)
	}
	return nil
}

// ListSituationSignals returns the inbox items attached to a situation,
// ordered chronologically (oldest first) for chronology rendering.
func (db *DB) ListSituationSignals(situationID int) ([]InboxItem, error) {
	rows, err := db.Query(`SELECT `+inboxSelectCols+` FROM inbox_items
		JOIN situation_signals ss ON ss.inbox_item_id = inbox_items.id
		WHERE ss.situation_id = ?
		ORDER BY inbox_items.message_ts ASC`, situationID)
	if err != nil {
		return nil, fmt.Errorf("listing situation %d signals: %w", situationID, err)
	}
	defer rows.Close()
	return scanInboxItems(rows)
}
