package db

import (
	"database/sql"
	"fmt"
)

// MeetingRecap is an AI-generated post-meeting summary. One row per event_id
// (UNIQUE); re-running the recap CLI overwrites the row. EventID is "" once the
// recap is orphaned (its calendar event was deleted, event_id → NULL, see
// 00056); TranscriptID is the durable link back to the meeting_transcripts row
// that keeps such a recap reachable.
type MeetingRecap struct {
	ID           int64
	EventID      string
	TranscriptID sql.NullInt64
	SourceText   string
	RecapJSON    string
	CreatedAt    string
	UpdatedAt    string
}

// recapExecer is the Exec subset of *DB / *sql.Tx, so the recap writes run
// either standalone or inside WriteTranscriptRecap's transaction.
type recapExecer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

// UpsertMeetingRecap inserts a new recap or updates the existing row for the
// given event_id. transcriptID (0 = none) links the recap to its transcript so
// it survives event deletion. updated_at is bumped to "now" on every call.
func (db *DB) UpsertMeetingRecap(eventID, sourceText, recapJSON string, transcriptID int64) error {
	return upsertMeetingRecap(db, eventID, sourceText, recapJSON, transcriptID)
}

func upsertMeetingRecap(q recapExecer, eventID, sourceText, recapJSON string, transcriptID int64) error {
	var tid any
	if transcriptID > 0 {
		tid = transcriptID
	}
	_, err := q.Exec(`
		INSERT INTO meeting_recaps (event_id, source_text, recap_json, transcript_id)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(event_id) DO UPDATE SET
			source_text   = excluded.source_text,
			recap_json    = excluded.recap_json,
			transcript_id = excluded.transcript_id,
			updated_at    = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
	`, eventID, sourceText, recapJSON, tid)
	if err != nil {
		return fmt.Errorf("upserting meeting recap for %s: %w", eventID, err)
	}
	return nil
}

// TranscriptRecapRow is one generated recap bound for a meeting_recaps row
// of transcript TranscriptID (see WriteTranscriptRecap).
type TranscriptRecapRow struct {
	// OwnRecapID > 0 rewrites that row in place (the recording's own row —
	// by id, so it also reaches an orphan whose event_id is NULL; event_id
	// and transcript_id are left as they are). 0 upserts EventID's row,
	// linked to TranscriptID.
	OwnRecapID   int64
	EventID      string
	TranscriptID int64
	SourceText   string
	RecapJSON    string
	// SyncSummary also rewrites the transcript's own summary_json copy (and
	// its summary_updated_at stamp) with the same recap.
	SyncSummary bool
}

// WriteTranscriptRecap writes r's meeting_recaps row and, when
// r.SyncSummary, the transcript's summary_json copy in ONE transaction: the
// Desktop's recap-refresh hint reads the copy's summary_updated_at for such a
// row, so the two must never diverge. Both writes bump their updated_at.
func (db *DB) WriteTranscriptRecap(r TranscriptRecapRow) (err error) {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("beginning transaction: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()

	if r.OwnRecapID > 0 {
		_, err = tx.Exec(`
			UPDATE meeting_recaps
			SET source_text = ?, recap_json = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
			WHERE id = ?
		`, r.SourceText, r.RecapJSON, r.OwnRecapID)
		if err != nil {
			return fmt.Errorf("updating meeting recap %d: %w", r.OwnRecapID, err)
		}
	} else if err = upsertMeetingRecap(tx, r.EventID, r.SourceText, r.RecapJSON, r.TranscriptID); err != nil {
		return err
	}
	if r.SyncSummary {
		if err = setMeetingTranscriptSummary(tx, r.TranscriptID, r.RecapJSON); err != nil {
			return err
		}
	}
	if err = tx.Commit(); err != nil {
		return fmt.Errorf("committing transcript %d recap: %w", r.TranscriptID, err)
	}
	return nil
}

const meetingRecapSelectCols = `SELECT id, event_id, transcript_id, source_text, recap_json, created_at, updated_at FROM meeting_recaps`

// GetMeetingRecap returns the recap for the given event, or (nil, nil) if none.
func (db *DB) GetMeetingRecap(eventID string) (*MeetingRecap, error) {
	return scanMeetingRecapRow(db.QueryRow(meetingRecapSelectCols+` WHERE event_id = ?`, eventID))
}

// GetMeetingRecapByTranscript returns the recap linked to the given transcript,
// or (nil, nil) if none. This is the path that still resolves an orphaned recap
// (event deleted, event_id NULL) — see 00056.
func (db *DB) GetMeetingRecapByTranscript(transcriptID int64) (*MeetingRecap, error) {
	return scanMeetingRecapRow(db.QueryRow(meetingRecapSelectCols+` WHERE transcript_id = ?`, transcriptID))
}

func scanMeetingRecapRow(row *sql.Row) (*MeetingRecap, error) {
	var r MeetingRecap
	var eventID sql.NullString
	err := row.Scan(&r.ID, &eventID, &r.TranscriptID, &r.SourceText, &r.RecapJSON, &r.CreatedAt, &r.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("loading meeting recap: %w", err)
	}
	r.EventID = eventID.String
	return &r, nil
}

// MeetingNote is a single row in meeting_notes (questions or freeform notes
// attached to a calendar event).
type MeetingNote struct {
	ID        int64
	EventID   string
	Type      string // 'question' | 'note'
	Text      string
	IsChecked bool
	SortOrder int
	TaskID    sql.NullInt64
	CreatedAt string
	UpdatedAt string
}

// GetMeetingNotesForEvent returns all meeting_notes for the event, ordered
// first by type (questions before notes) then by sort_order.
func (db *DB) GetMeetingNotesForEvent(eventID string) ([]MeetingNote, error) {
	rows, err := db.Query(`
		SELECT id, event_id, type, text, is_checked, sort_order, task_id, created_at, updated_at
		FROM meeting_notes WHERE event_id = ?
		ORDER BY type DESC, sort_order ASC
	`, eventID)
	if err != nil {
		return nil, fmt.Errorf("loading meeting notes for %s: %w", eventID, err)
	}
	defer rows.Close()

	var out []MeetingNote
	for rows.Next() {
		var n MeetingNote
		var checked int
		if err := rows.Scan(&n.ID, &n.EventID, &n.Type, &n.Text, &checked, &n.SortOrder, &n.TaskID, &n.CreatedAt, &n.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning meeting note: %w", err)
		}
		n.IsChecked = checked != 0
		out = append(out, n)
	}
	return out, rows.Err()
}
