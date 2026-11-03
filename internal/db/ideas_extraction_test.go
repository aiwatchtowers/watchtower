package db

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestIdeasExtractionAtomicOutputReceiptAndReset(t *testing.T) {
	d, err := Open(":memory:")
	require.NoError(t, err)
	defer d.Close()
	_, err = d.Exec(`INSERT INTO google_accounts(id,email,gmail_enabled,ideas_email_floor) VALUES(1,'one@example.com',1,100)`)
	require.NoError(t, err)
	w, err := d.ClaimIdeasExtractionWindow(IdeasExtractionWindow{Source: "gmail", AccountID: 1, Key: "backfill:100:300", From: "100", To: "300"})
	require.NoError(t, err)
	row := &StreamDigest{Source: "gmail", AccountID: 1, PeriodFrom: "100", PeriodTo: "200", TopicsJSON: `[{"title":"saved"}]`}
	w.Reached, w.Complete = "200", true
	_, err = d.Exec(`CREATE TRIGGER fail_extraction_receipt BEFORE UPDATE ON ideas_extraction_windows BEGIN SELECT RAISE(ABORT,'receipt unavailable'); END`)
	require.NoError(t, err)
	require.Error(t, d.CommitIdeasExtraction(w, row))
	outputs, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Empty(t, outputs)
	_, err = d.Exec(`DROP TRIGGER fail_extraction_receipt`)
	require.NoError(t, err)
	_, err = d.Exec(`CREATE TRIGGER fail_extraction_floor BEFORE UPDATE OF ideas_email_floor ON google_accounts BEGIN SELECT RAISE(ABORT,'floor unavailable'); END`)
	require.NoError(t, err)
	require.Error(t, d.CommitIdeasExtraction(w, row))
	outputs, err = d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Empty(t, outputs)
	_, err = d.Exec(`DROP TRIGGER fail_extraction_floor`)
	require.NoError(t, err)
	require.NoError(t, d.CommitIdeasExtraction(w, row))
	// No in-memory acknowledgement: a new claimant observes the committed prefix.
	restored, err := d.ClaimIdeasExtractionWindow(IdeasExtractionWindow{Source: "gmail", AccountID: 1, Key: w.Key, From: "0", To: "999"})
	require.NoError(t, err)
	require.True(t, restored.Complete)
	require.Equal(t, "200", restored.Reached)
	require.Equal(t, "100", restored.From)
	floor, err := d.IdeasEmailFloor(1)
	require.NoError(t, err)
	require.Equal(t, float64(200), floor, "historical output raises a lower forward floor atomically")
	// The supported purge/reset clock invalidates even empty completion receipts.
	_, err = d.Exec(`UPDATE google_accounts SET ideas_email_floor=0 WHERE id=1`)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM ideas_extraction_windows`).Scan(&n))
	require.Zero(t, n)
}

func TestIdeasExtractionForwardEmptyCommitsFloorAndAck(t *testing.T) {
	d, err := Open(":memory:")
	require.NoError(t, err)
	defer d.Close()
	_, err = d.Exec(`INSERT INTO jira_accounts(id,cloud_id,site_url,label,ideas_jira_floor) VALUES(1,'test','https://example.com','test','2026-01-01T00:00:00.000Z')`)
	require.NoError(t, err)
	w, err := d.ClaimIdeasExtractionWindow(IdeasExtractionWindow{Source: "jira", AccountID: 1, Key: "forward", From: "2026-01-01T00:00:00.000Z", To: "2026-01-02T00:00:00.000Z"})
	require.NoError(t, err)
	w.Reached = "2026-01-01T00:00:01.123Z"
	w.Complete = true
	require.NoError(t, d.CommitIdeasExtraction(w, nil))
	floor, err := d.IdeasJiraFloor(1)
	require.NoError(t, err)
	require.Equal(t, w.Reached, floor)
	history, err := d.ClaimIdeasExtractionWindow(IdeasExtractionWindow{Source: "jira", AccountID: 1, Key: "backfill:older", From: w.From, To: w.To})
	require.NoError(t, err)
	history.Reached = "2026-01-01T00:00:01.122Z"
	history.Complete = true
	require.NoError(t, d.CommitIdeasExtraction(history, nil))
	floor, err = d.IdeasJiraFloor(1)
	require.NoError(t, err)
	require.Equal(t, w.Reached, floor, "a higher forward floor is never lowered, including milliseconds")
	_, err = d.Exec(`DELETE FROM ideas_extraction_windows WHERE window_key='backfill:older'`)
	require.NoError(t, err)

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM ideas_extraction_windows`).Scan(&n))
	require.Zero(t, n)
	rows, err := d.ListStreamDigestsAfter(0, "")
	require.NoError(t, err)
	require.Empty(t, rows)
}
