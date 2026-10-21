package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
)

// AppendTargetNoteTx appends one note to target id's notes inside tx. It
// writes what the Desktop's note write writes (TargetsViewModel.mutateNotes →
// TargetQueries.updateNotes): notes and updated_at, nothing else. The entry's
// keys are the Swift TargetNote CodingKeys, text and created_at — a Go↔Swift
// dual path. A missing target is sql.ErrNoRows wrapped.
func (db *DB) AppendTargetNoteTx(tx *sql.Tx, id int, text, at string) error {
	return appendTargetEntryTx(tx, id, targetNotesColumn, TargetNote{Text: text, CreatedAt: at})
}

// AppendTargetSubItemTx appends one not-done checklist item to target id's
// sub_items inside tx, as the Desktop's addSubItem does
// (TargetsViewModel.mutateSubItems → TargetQueries.updateSubItems: sub_items
// and updated_at; progress is not recomputed there either). The entry's keys
// are the Swift TargetSubItem CodingKeys, text and done (due_date only when
// set). A missing target is sql.ErrNoRows wrapped.
func (db *DB) AppendTargetSubItemTx(tx *sql.Tx, id int, text string) error {
	return appendTargetEntryTx(tx, id, targetSubItemsColumn, promoteSubItem{Text: text})
}

// targetJSONColumn is one JSON-array column of targets with its fixed
// statements (no SQL is built from a name).
type targetJSONColumn struct {
	name, selectSQL, updateSQL string
}

var (
	targetNotesColumn = targetJSONColumn{"notes", `SELECT notes FROM targets WHERE id = ?`,
		`UPDATE targets SET notes = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`}
	targetSubItemsColumn = targetJSONColumn{"sub_items", `SELECT sub_items FROM targets WHERE id = ?`,
		`UPDATE targets SET sub_items = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`}
)

// appendTargetEntryTx appends entry to the JSON array in col. The existing
// entries are kept as stored, every key included; a column that does not
// hold a JSON array is refused rather than overwritten.
func appendTargetEntryTx(tx *sql.Tx, id int, col targetJSONColumn, entry any) error {
	column := col.name
	var stored string
	if err := tx.QueryRow(col.selectSQL, id).Scan(&stored); err != nil {
		return fmt.Errorf("reading target %d %s: %w", id, column, err)
	}
	var entries []json.RawMessage
	if stored != "" {
		if err := json.Unmarshal([]byte(stored), &entries); err != nil {
			return fmt.Errorf("target %d %s is not a JSON array: %w", id, column, err)
		}
	}
	raw, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("encoding target %d %s entry: %w", id, column, err)
	}
	out, err := json.Marshal(append(entries, raw))
	if err != nil {
		return fmt.Errorf("encoding target %d %s: %w", id, column, err)
	}
	if _, err := tx.Exec(col.updateSQL, string(out), id); err != nil {
		return fmt.Errorf("writing target %d %s: %w", id, column, err)
	}
	return nil
}
