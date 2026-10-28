package kb

import (
	"context"
	"database/sql"
	"fmt"

	"watchtower/internal/db"
)

// DropPrivateRecording deletes, now, the indexed documents of a recording just
// turned private: its transcript and every recap it owns (MEETPRIV-04). The
// kb_dirty marks of the flip stay, so the indexer's next pass re-renders the
// same keys — as nothing while the recording is private, back again once it
// is not; this only spares search_knowledge and get_knowledge_document the
// wait for that pass. It returns how many documents were removed.
func DropPrivateRecording(ctx context.Context, d *db.DB, transcriptID int64) (int, error) {
	n := 0
	err := withTx(ctx, d, func(tx *sql.Tx) error {
		ids, err := queryStrings(ctx, tx, `SELECT 'transcript:' || ?
			UNION ALL SELECT 'recap:' || id FROM meeting_recaps WHERE transcript_id = ?`, transcriptID, transcriptID)
		if err != nil {
			return fmt.Errorf("kb: listing documents of recording %d: %w", transcriptID, err)
		}
		for _, id := range ids {
			removed, err := deleteDoc(ctx, tx, id)
			if err != nil {
				return err
			}
			if removed {
				n++
			}
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return n, nil
}
