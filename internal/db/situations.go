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
// filters over the frozen table (memory reads it; nothing writes it any more —
// the composer and the dashboard lifecycle went with the inbox demolition, see
// docs/superpowers/specs/2026-09-14-inbox-demolition-design.md §4).
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
