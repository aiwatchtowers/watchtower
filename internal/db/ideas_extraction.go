package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// IdeasExtractionWindow is local completion metadata, separate from forward
// source floors and the public stream digest. Historical receipts survive a
// restart between saving the extraction and advancing the history chunk.
type IdeasExtractionWindow struct {
	Source                 string
	AccountID              int64
	Key, From, To, Reached string
	Complete               bool
}

// ClaimIdeasExtractionWindow preserves the first input bounds until completion.
func (db *DB) ClaimIdeasExtractionWindow(w IdeasExtractionWindow) (IdeasExtractionWindow, error) {
	_, err := db.Exec(`INSERT INTO ideas_extraction_windows(source,account_id,window_key,from_value,to_value,reached_value) VALUES(?,?,?,?,?,?) ON CONFLICT DO NOTHING`, w.Source, w.AccountID, w.Key, w.From, w.To, w.From)
	if err != nil {
		return w, err
	}
	err = db.QueryRow(`SELECT from_value,to_value,reached_value,complete FROM ideas_extraction_windows WHERE source=? AND account_id=? AND window_key=?`, w.Source, w.AccountID, w.Key).Scan(&w.From, &w.To, &w.Reached, &w.Complete)
	return w, err
}

// CommitIdeasExtraction atomically saves an optional nonempty digest and its
// consumed prefix. Forward floors commit in the same transaction. A valid empty
// result saves the receipt without creating an unread empty stream digest.
func (db *DB) CommitIdeasExtraction(w IdeasExtractionWindow, row *StreamDigest) (err error) {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if row != nil {
		_, err = tx.Exec(`INSERT INTO stream_digests(source,account_id,scope,period_from,period_to,topics_json) VALUES(?,?,?,?,?,?)`, row.Source, row.AccountID, row.Scope, row.PeriodFrom, row.PeriodTo, row.TopicsJSON)
		if err != nil {
			return fmt.Errorf("saving extraction output: %w", err)
		}
	}
	result, err := tx.Exec(`UPDATE ideas_extraction_windows SET reached_value=?,complete=? WHERE source=? AND account_id=? AND window_key=?`, w.Reached, w.Complete, w.Source, w.AccountID, w.Key)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if n != 1 {
		return errors.New("missing ideas extraction window")
	}
	if err = advanceExtractionFloor(tx, w); err != nil {
		return err
	}
	if w.Key == "forward" {
		_, err = tx.Exec(`DELETE FROM ideas_extraction_windows WHERE source=? AND account_id=? AND window_key='forward'`, w.Source, w.AccountID)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

func advanceExtractionFloor(tx *sql.Tx, w IdeasExtractionWindow) error {
	var err error
	switch w.Source {
	case "gmail":
		_, err = tx.Exec(`UPDATE google_accounts SET ideas_email_floor=CAST(? AS REAL) WHERE id=? AND ideas_email_floor<CAST(? AS REAL)`, w.Reached, w.AccountID, w.Reached)
	case "imap":
		_, err = tx.Exec(`UPDATE email_accounts SET ideas_email_floor=CAST(? AS REAL) WHERE id=? AND ideas_email_floor<CAST(? AS REAL)`, w.Reached, w.AccountID, w.Reached)
	case "jira":
		_, err = tx.Exec(`UPDATE jira_accounts SET ideas_jira_floor=? WHERE id=? AND COALESCE(julianday(ideas_jira_floor),0)<julianday(?)`, w.Reached, w.AccountID, w.Reached)
	default:
		return fmt.Errorf("invalid extraction source %q", w.Source)
	}
	return err
}
