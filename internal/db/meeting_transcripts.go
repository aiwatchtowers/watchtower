package db

import (
	"database/sql"
	"fmt"
)

// MeetingTranscript is one locally-transcribed meeting recording (WhisperKit in
// the Desktop app). EventID is NULL for ad-hoc recordings and is SET NULL when
// the calendar event is deleted — the transcript outlives its event. AudioPath
// is NULLed by the daemon retention phase once the audio file is deleted;
// TranscriptText is kept forever. SummaryJSON holds the recap for ad-hoc
// recordings only (event-linked recaps live in meeting_recaps). SegmentsJSON
// is the per-utterance segment array (NULL for legacy rows); when set, the
// invariant transcript_text = render(segments where !deleted) must hold — see
// internal/meeting.RenderTranscriptSegments, the canonical Go renderer.
type MeetingTranscript struct {
	ID             int64
	EventID        sql.NullString
	Title          string
	AudioPath      sql.NullString
	DurationSec    int
	LangStats      string
	TranscriptText string
	SummaryJSON    sql.NullString
	NotesMD        sql.NullString
	SegmentsJSON   sql.NullString
	CreatedAt      string
	UpdatedAt      string
}

// MeetingTranscriptFilter narrows ListMeetingTranscripts. Zero values mean
// "no filter"; Limit 0 means the default of 50.
type MeetingTranscriptFilter struct {
	EventID  string // exact match; "" = no filter
	FromTime string // ISO8601 lower bound on created_at; "" = none
	ToTime   string // ISO8601 upper bound on created_at; "" = none
	Limit    int    // 0 = 50
}

const meetingTranscriptColumns = `id, event_id, title, audio_path, duration_sec, lang_stats, transcript_text, summary_json, notes_md, segments_json, created_at, updated_at`

func scanMeetingTranscript(row interface{ Scan(...any) error }) (MeetingTranscript, error) {
	var t MeetingTranscript
	err := row.Scan(&t.ID, &t.EventID, &t.Title, &t.AudioPath, &t.DurationSec,
		&t.LangStats, &t.TranscriptText, &t.SummaryJSON, &t.NotesMD, &t.SegmentsJSON, &t.CreatedAt, &t.UpdatedAt)
	return t, err
}

// InsertMeetingTranscript inserts a new transcript row and returns its id.
// CreatedAt/UpdatedAt are set by the table defaults.
func (db *DB) InsertMeetingTranscript(t MeetingTranscript) (int64, error) {
	res, err := db.Exec(`
		INSERT INTO meeting_transcripts (event_id, title, audio_path, duration_sec, lang_stats, transcript_text, summary_json, segments_json)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`, t.EventID, t.Title, t.AudioPath, t.DurationSec, t.LangStats, t.TranscriptText, t.SummaryJSON, t.SegmentsJSON)
	if err != nil {
		return 0, fmt.Errorf("inserting meeting transcript %q: %w", t.Title, err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading meeting transcript insert id: %w", err)
	}
	return id, nil
}

// GetMeetingTranscript returns the transcript with the given id, or (nil, nil)
// if none exists.
func (db *DB) GetMeetingTranscript(id int64) (*MeetingTranscript, error) {
	t, err := scanMeetingTranscript(db.QueryRow(`
		SELECT `+meetingTranscriptColumns+`
		FROM meeting_transcripts WHERE id = ?
	`, id))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("loading meeting transcript %d: %w", id, err)
	}
	return &t, nil
}

// ListMeetingTranscripts returns transcripts matching the filter, newest first.
func (db *DB) ListMeetingTranscripts(f MeetingTranscriptFilter) ([]MeetingTranscript, error) {
	query := `SELECT ` + meetingTranscriptColumns + ` FROM meeting_transcripts WHERE 1=1`
	var args []any
	if f.EventID != "" {
		query += ` AND event_id = ?`
		args = append(args, f.EventID)
	}
	if f.FromTime != "" {
		query += ` AND created_at >= ?`
		args = append(args, f.FromTime)
	}
	if f.ToTime != "" {
		query += ` AND created_at <= ?`
		args = append(args, f.ToTime)
	}
	limit := f.Limit
	if limit <= 0 {
		limit = 50
	}
	query += ` ORDER BY created_at DESC, id DESC LIMIT ?`
	args = append(args, limit)

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing meeting transcripts: %w", err)
	}
	defer rows.Close()

	var out []MeetingTranscript
	for rows.Next() {
		t, err := scanMeetingTranscript(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning meeting transcript: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// SetMeetingTranscriptSummary stores the recap JSON for an ad-hoc transcript
// and bumps updated_at.
func (db *DB) SetMeetingTranscriptSummary(id int64, summaryJSON string) error {
	_, err := db.Exec(`
		UPDATE meeting_transcripts
		SET summary_json = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?
	`, summaryJSON, id)
	if err != nil {
		return fmt.Errorf("setting meeting transcript %d summary: %w", id, err)
	}
	return nil
}

// SetMeetingTranscriptNotes stores the publishable markdown notes for a
// transcript and bumps updated_at.
func (db *DB) SetMeetingTranscriptNotes(id int64, notesMD string) error {
	_, err := db.Exec(`
		UPDATE meeting_transcripts
		SET notes_md = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?
	`, notesMD, id)
	if err != nil {
		return fmt.Errorf("setting meeting transcript %d notes: %w", id, err)
	}
	return nil
}

// ExpiredTranscriptAudio returns transcripts whose audio file is still on disk
// (audio_path NOT NULL) and that were created before the cutoff — candidates
// for the daemon audio-retention phase.
func (db *DB) ExpiredTranscriptAudio(cutoff string) ([]MeetingTranscript, error) {
	rows, err := db.Query(`
		SELECT `+meetingTranscriptColumns+`
		FROM meeting_transcripts
		WHERE audio_path IS NOT NULL AND created_at < ?
		ORDER BY created_at ASC, id ASC
	`, cutoff)
	if err != nil {
		return nil, fmt.Errorf("listing expired transcript audio: %w", err)
	}
	defer rows.Close()

	var out []MeetingTranscript
	for rows.Next() {
		t, err := scanMeetingTranscript(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning expired transcript audio: %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// TranscriptAudioPaths returns every non-NULL meeting_transcripts.audio_path —
// the recordings still referenced by a transcript row. The daemon orphan scan
// uses this set to know which rec_* files it must not delete.
func (db *DB) TranscriptAudioPaths() ([]string, error) {
	rows, err := db.Query(`SELECT audio_path FROM meeting_transcripts WHERE audio_path IS NOT NULL`)
	if err != nil {
		return nil, fmt.Errorf("listing transcript audio paths: %w", err)
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, fmt.Errorf("scanning transcript audio path: %w", err)
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ClearMeetingTranscriptAudio NULLs audio_path after the audio file has been
// deleted, and bumps updated_at. The transcript text is untouched.
func (db *DB) ClearMeetingTranscriptAudio(id int64) error {
	_, err := db.Exec(`
		UPDATE meeting_transcripts
		SET audio_path = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
		WHERE id = ?
	`, id)
	if err != nil {
		return fmt.Errorf("clearing meeting transcript %d audio path: %w", id, err)
	}
	return nil
}
