package db

import "fmt"

// The situations table is frozen history since the inbox demolition (see
// docs/superpowers/specs/2026-09-14-inbox-demolition-design.md): nothing
// writes it any more, and the only two production readers left are
// ListSituationSignals below (memory's chat ingest) and ConvertedSituationIDs
// in internal/db/memory.go (memory's operational mirrors). The former
// GetSituation/ListSituations readers had no production callers and were
// removed with the Dashboard/composer they served.

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
