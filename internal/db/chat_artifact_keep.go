package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// The knowledge-artifact writers, ported from the Desktop's
// ChatArtifactQueries.keep/unkeep (chat_knowledge_artifacts) and pinned with
// them by internal/chatstore/testdata/chat_writes.json.

// ErrChatLiveSlack refuses a keep in a conversation that used the Live Slack
// connector (LIVE-01): its text never becomes knowledge.
var ErrChatLiveSlack = errors.New("db: the chat used Live Slack")

// KeepChatArtifactTx pins version of an artifact key as knowledge (Keep, and
// Update for a newer version: one kept version per key).
func KeepChatArtifactTx(tx *sql.Tx, conv int64, key string, version int64) error {
	var marked bool
	if err := tx.QueryRow(`SELECT COUNT(*) > 0 FROM chat_conversations WHERE id = ? AND live_slack_since IS NOT NULL`,
		conv).Scan(&marked); err != nil {
		return fmt.Errorf("keep chat artifact: %w", err)
	}
	if marked {
		return ErrChatLiveSlack
	}
	if _, err := tx.Exec(`INSERT INTO chat_knowledge_artifacts (conversation_id, artifact_key, version, kept_at)
VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
ON CONFLICT (conversation_id, artifact_key) DO UPDATE SET version = excluded.version, kept_at = excluded.kept_at`,
		conv, key, version); err != nil {
		return fmt.Errorf("keep chat artifact: %w", err)
	}
	return nil
}

// UnkeepChatArtifactTx removes a key from knowledge; a key that is not kept
// is a no-op.
func UnkeepChatArtifactTx(tx *sql.Tx, conv int64, key string) error {
	if _, err := tx.Exec(`DELETE FROM chat_knowledge_artifacts WHERE conversation_id = ? AND artifact_key = ?`, conv, key); err != nil {
		return fmt.Errorf("unkeep chat artifact: %w", err)
	}
	return nil
}
