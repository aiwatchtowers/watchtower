package db

import (
	"errors"
	"fmt"
	"time"
)

// DraftCacheImport is one legacy cache line for ImportDraftCache.
type DraftCacheImport struct {
	EntryJSON string
	At        time.Time
}

// ErrDraftCacheNoConversation is ImportDraftCache's answer for a conversation
// that no longer exists: there is nothing to attach the entries to.
var ErrDraftCacheNoConversation = errors.New("the conversation no longer exists")

// AppendDraftCache appends entryJSON (one automation editor DraftCacheEntry)
// to conversationID's draft cache and keeps only its newest keep entries, in
// one transaction (#604 G2: the cache lived in automation-drafts/<id>.jsonl).
func (db *DB) AppendDraftCache(conversationID int64, entryJSON string, at time.Time, keep int) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("caching a draft of conversation %d: %w", conversationID, err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`INSERT INTO automation_draft_cache (conversation_id, seq, entry_json, at)
		SELECT ?, COALESCE(MAX(seq), 0) + 1, ?, ? FROM automation_draft_cache WHERE conversation_id = ?`,
		conversationID, entryJSON, at.UTC().Format(time.RFC3339), conversationID); err != nil {
		return fmt.Errorf("caching a draft of conversation %d: %w", conversationID, err)
	}
	if _, err := tx.Exec(`DELETE FROM automation_draft_cache WHERE conversation_id = ? AND seq NOT IN
		(SELECT seq FROM automation_draft_cache WHERE conversation_id = ? ORDER BY seq DESC LIMIT ?)`,
		conversationID, conversationID, keep); err != nil {
		return fmt.Errorf("trimming the draft cache of conversation %d: %w", conversationID, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("caching a draft of conversation %d: %w", conversationID, err)
	}
	return nil
}

// DraftCache returns conversationID's cached draft entries, oldest first.
func (db *DB) DraftCache(conversationID int64) ([]string, error) {
	rows, err := db.Query(`SELECT entry_json FROM automation_draft_cache WHERE conversation_id = ? ORDER BY seq`, conversationID)
	if err != nil {
		return nil, fmt.Errorf("reading the draft cache of conversation %d: %w", conversationID, err)
	}
	defer rows.Close()
	entries := []string{}
	for rows.Next() {
		var e string
		if err := rows.Scan(&e); err != nil {
			return nil, fmt.Errorf("reading the draft cache of conversation %d: %w", conversationID, err)
		}
		entries = append(entries, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the draft cache of conversation %d: %w", conversationID, err)
	}
	return entries, nil
}

// DeleteDraftCache removes conversationID's cached drafts.
func (db *DB) DeleteDraftCache(conversationID int64) error {
	if _, err := db.Exec(`DELETE FROM automation_draft_cache WHERE conversation_id = ?`, conversationID); err != nil {
		return fmt.Errorf("deleting the draft cache of conversation %d: %w", conversationID, err)
	}
	return nil
}

// ImportDraftCache writes entries (oldest first; the newest keep are kept) as
// conversationID's draft cache in one transaction, unless the conversation
// already has rows: then nothing is written and imported is false. A re-run
// after a failed removal of the legacy file therefore never duplicates or
// reorders entries. A missing conversation is ErrDraftCacheNoConversation.
func (db *DB) ImportDraftCache(conversationID int64, entries []DraftCacheImport, keep int) (imported bool, err error) {
	tx, err := db.Begin()
	if err != nil {
		return false, fmt.Errorf("importing the draft cache of conversation %d: %w", conversationID, err)
	}
	defer func() { _ = tx.Rollback() }()
	var exists, rows int
	if err := tx.QueryRow(`SELECT (SELECT COUNT(*) FROM chat_conversations WHERE id = ?),
		(SELECT COUNT(*) FROM automation_draft_cache WHERE conversation_id = ?)`, conversationID, conversationID).
		Scan(&exists, &rows); err != nil {
		return false, fmt.Errorf("importing the draft cache of conversation %d: %w", conversationID, err)
	}
	if exists == 0 {
		return false, ErrDraftCacheNoConversation
	}
	if rows > 0 {
		return false, nil
	}
	if len(entries) > keep {
		entries = entries[len(entries)-keep:]
	}
	for i, e := range entries {
		if _, err := tx.Exec(`INSERT INTO automation_draft_cache (conversation_id, seq, entry_json, at) VALUES (?, ?, ?, ?)`,
			conversationID, i+1, e.EntryJSON, e.At.UTC().Format(time.RFC3339)); err != nil {
			return false, fmt.Errorf("importing the draft cache of conversation %d: %w", conversationID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("importing the draft cache of conversation %d: %w", conversationID, err)
	}
	return true, nil
}
