package chatstore

import (
	"database/sql"
	"errors"
	"fmt"
)

// artifactCommentsTextTx reads ids — open comments of one artifact key of
// conv — and composes the owner message that sends them
// (ArtifactCommentMessage.compose over the key's latest version), the
// comments in the given order. ErrNotFound when a comment or the artifact
// is missing; ErrInvalid when one is no longer open or the keys differ.
func artifactCommentsTextTx(tx *sql.Tx, conv int64, ids []int64) (string, error) {
	items := make([]CommentItem, 0, len(ids))
	key := ""
	for _, id := range ids {
		var (
			k, status string
			it        CommentItem
		)
		err := tx.QueryRow(`SELECT artifact_key, status, anchor_quote, anchor_heading, body FROM chat_artifact_comments
			WHERE id = ? AND conversation_id = ?`, id, conv).Scan(&k, &status, &it.Quote, &it.Heading, &it.Body)
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotFound
		}
		if err != nil {
			return "", fmt.Errorf("reading artifact comment %d: %w", id, err)
		}
		if status != "open" || (key != "" && k != key) {
			return "", ErrInvalid
		}
		key = k
		items = append(items, it)
	}
	var (
		title   string
		version int
	)
	err := tx.QueryRow(`SELECT title, version FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ?
		ORDER BY version DESC LIMIT 1`, conv, key).Scan(&title, &version)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("reading artifact %q: %w", key, err)
	}
	return ComposeArtifactComments(title, key, version, items), nil
}

// markCommentsSentTx is ArtifactCommentQueries.markSent in the start
// transaction: exactly ids, each still open, become `sent` at the owner
// row's created_at. A comment that stopped being open meanwhile refuses the
// start.
func markCommentsSentTx(tx *sql.Tx, conv int64, ids []int64, at float64) error {
	for _, id := range ids {
		res, err := tx.Exec(`UPDATE chat_artifact_comments SET status = 'sent', sent_at = ?
			WHERE id = ? AND conversation_id = ? AND status = 'open'`, at, id, conv)
		if err != nil {
			return fmt.Errorf("marking artifact comment %d sent: %w", id, err)
		}
		if n, err := res.RowsAffected(); err != nil || n != 1 {
			return ErrInvalid
		}
	}
	return nil
}

func hasDuplicate(ids []int64) bool {
	seen := make(map[int64]bool, len(ids))
	for _, id := range ids {
		if seen[id] || id <= 0 {
			return true
		}
		seen[id] = true
	}
	return false
}
