package db

import (
	"testing"
	"time"
)

// CloseTestWorkbenchTarget sets target id to status (done or dismissed) and
// moves its close — every status history row and updated_at — to ago before
// now, so the archive view (PROJ-15) sees a close that old. A parent the
// PROJ-05 rollup closes keeps a close of now until it is passed here too.
func CloseTestWorkbenchTarget(t *testing.T, d *DB, id int64, status string, ago time.Duration) {
	t.Helper()
	if err := d.UpdateTargetStatus(int(id), status); err != nil {
		t.Fatalf("closing target %d: %v", id, err)
	}
	at := time.Now().Add(-ago).UTC().Format("2006-01-02T15:04:05Z")
	if _, err := d.Exec(`UPDATE target_status_history SET changed_at = ? WHERE target_id = ?`, at, id); err != nil {
		t.Fatalf("backdating target %d's history: %v", id, err)
	}
	if _, err := d.Exec(`UPDATE targets SET updated_at = ? WHERE id = ?`, at, id); err != nil {
		t.Fatalf("backdating target %d: %v", id, err)
	}
}
