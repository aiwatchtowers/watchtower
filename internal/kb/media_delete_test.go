package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// Deleted at the source, gone here too — descriptions included (SRCDEL-02,
// SRCDEL-03 extended by the media-knowledge spec): a deleted or tombstoned
// parent takes its media rows along, and after the next kb.Run no document
// shows their text.

// chunksWith counts the indexed chunks whose body contains marker.
func chunksWith(t *testing.T, d *db.DB, marker string) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_chunks WHERE instr(body, ?) > 0`, marker).Scan(&n))
	return n
}

func mediaRowsOf(t *testing.T, d *db.DB, where string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM media_items WHERE `+where, args...).Scan(&n))
	return n
}

func hasDirty(t *testing.T, d *db.DB, source, key string) bool {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_dirty WHERE source = ? AND key = ?`, source, key).Scan(&n))
	return n > 0
}

func runKB(t *testing.T, d *db.DB) {
	t.Helper()
	_, err := Run(context.Background(), d, Options{Now: testNow()})
	require.NoError(t, err)
}

func TestSrcdel02_TombstoneDeletesMediaAndMarksParent(t *testing.T) {
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	seedSlackMedia(t, d)
	runKB(t, d)
	thread := slackThreadRef("1:C1", "1758000000.000100")
	require.Contains(t, docText(t, d, thread), MediaImageLabel)
	require.NotZero(t, chunksWith(t, d, "Payment failed"))

	n, err := d.TombstoneSlackMessages([]db.SlackMessageKey{{ChannelID: "1:C1", TS: "1758000100.000200"}})
	require.NoError(t, err)
	require.Equal(t, 1, n)
	assert.Zero(t, mediaRowsOf(t, d, `slack_channel_id = '1:C1' AND slack_ts = '1758000100.000200'`),
		"the tombstone deletes the message's media rows")
	assert.True(t, hasDirty(t, d, "slack", thread), "the thread document is marked in the same write")

	runKB(t, d)
	got := docText(t, d, thread)
	assert.NotContains(t, got, MediaImageLabel)
	assert.NotContains(t, got, MediaLinkLabel)
	assert.Zero(t, chunksWith(t, d, "Payment failed"), "no document shows the description")
	assert.Zero(t, chunksWith(t, d, "example domain"), "no document shows the link summary")
	assert.Zero(t, dirtyCount(t, d))
}

// A description stored while its top-level message lived in the day
// document keeps that kb_ref after the message gains its first reply and
// moves to its thread document. The tombstone marks both: the stored ref
// (the media delete trigger) and the message's current document (the
// messages trigger, the SQL twin of MediaParentRef).
func TestSrcdel02_TombstoneAfterPromotionLeavesNoDocument(t *testing.T) {
	d := db.OpenTestDB(t)
	seedSlack(t, d)
	mediaStartPast(t, d)
	const root = "1758000600.000700"
	msg(t, d, "1:D1", root, "1:U1", "see the screenshot", "", "")
	id := recordMedia(t, d, slackParent("1:D1", root), db.MediaFound{Kind: "image", Locator: "F9", Anchor: root})
	describeMedia(t, d, id, "Login form", "marker-promoted-shot", "")
	day := slackDayRef("1:D1", "2025-09-16")
	thread := slackThreadRef("1:D1", root)
	runKB(t, d)
	require.Contains(t, docText(t, d, day), "marker-promoted-shot")

	// promotion: the root gains thread_ts and a reply arrives
	exec(t, d, `UPDATE messages SET thread_ts = ts WHERE channel_id = '1:D1' AND ts = ?`, root)
	msg(t, d, "1:D1", "1758000650.000750", "1:U2", "looks broken", root, "")
	runKB(t, d)
	var storedRef string
	require.NoError(t, d.QueryRow(`SELECT kb_ref FROM media_items WHERE id = ?`, id).Scan(&storedRef))
	require.Equal(t, day, storedRef, "the stored ref is stale: the parent now renders into its thread")

	_, err := d.TombstoneSlackMessages([]db.SlackMessageKey{{ChannelID: "1:D1", TS: root}})
	require.NoError(t, err)
	assert.True(t, hasDirty(t, d, "slack", day), "the stored ref is marked")
	assert.True(t, hasDirty(t, d, "slack", thread), "the current document is marked")

	runKB(t, d)
	assert.Zero(t, chunksWith(t, d, "marker-promoted-shot"), "no document shows the description")
	assert.Zero(t, mediaRowsOf(t, d, `id = ?`, id))
}

func TestSrcdel03_GmailDiffDeleteTakesMedia(t *testing.T) {
	d := db.OpenTestDB(t)
	seedGmail(t, d)
	mediaStartPast(t, d)
	id := recordMedia(t, d, db.MediaParent{Kind: "gmail", GmailAccountID: 1, GmailMessageID: "m1"},
		db.MediaFound{Kind: "image", Locator: "part-2", Anchor: "m1"})
	describeMedia(t, d, id, "Budget chart", "marker-gmail-chart", "")
	runKB(t, d)
	require.Contains(t, docText(t, d, "gmail:1:t1"), "marker-gmail-chart")

	n, err := d.DeleteGmailMessages(1, []string{"m1"})
	require.NoError(t, err)
	require.Equal(t, 1, n)
	assert.Zero(t, mediaRowsOf(t, d, `id = ?`, id), "the deleted mail takes its media rows")
	assert.True(t, hasDirty(t, d, "gmail", "gmail:1:t1"))

	runKB(t, d)
	assert.Zero(t, chunksWith(t, d, "marker-gmail-chart"))
	assert.Contains(t, docText(t, d, "gmail:1:t1"), "snippet two", "the thread's other mail stays")
}

func TestSrcdel03_IMAPDiffDeleteTakesMedia(t *testing.T) {
	d := db.OpenTestDB(t)
	seedIMAP(t, d)
	exec(t, d, `INSERT INTO imap_messages (account_id, uid, uidvalidity, subject, body_text, internal_date, updated_at)
		VALUES (1, 43, 6, 'Old epoch', 'old body', '2026-09-04T09:00:00Z', '2026-09-04T09:00:05Z')`)
	mediaStartPast(t, d)
	cur := recordMedia(t, d, db.MediaParent{Kind: "imap", IMAPAccountID: 1, IMAPUIDValidity: 7, IMAPUID: 42},
		db.MediaFound{Kind: "image", Locator: "1.2", Anchor: "42"})
	describeMedia(t, d, cur, "Invoice", "marker-imap-invoice", "")
	old := recordMedia(t, d, db.MediaParent{Kind: "imap", IMAPAccountID: 1, IMAPUIDValidity: 6, IMAPUID: 43},
		db.MediaFound{Kind: "image", Locator: "1.2", Anchor: "43"})
	describeMedia(t, d, old, "Receipt", "marker-imap-old-epoch", "")
	runKB(t, d)
	require.NotZero(t, chunksWith(t, d, "marker-imap-invoice"))
	require.NotZero(t, chunksWith(t, d, "marker-imap-old-epoch"))

	n, err := d.DeleteImapMessages(1, 7, []int64{42})
	require.NoError(t, err)
	require.Equal(t, 1, n)
	n, err = d.DeleteImapMessagesOutsideUIDValidity(1, 7)
	require.NoError(t, err)
	require.Equal(t, 1, n)
	assert.Zero(t, mediaRowsOf(t, d, `parent_kind = 'imap'`), "both deletes take their media rows")

	runKB(t, d)
	assert.Zero(t, chunksWith(t, d, "marker-imap-invoice"))
	assert.Zero(t, chunksWith(t, d, "marker-imap-old-epoch"))
}

func TestExtDeleteTakesMedia(t *testing.T) {
	d := db.OpenTestDB(t)
	seedConfluence(t, d)
	mediaStartPast(t, d)
	page := recordMedia(t, d, db.MediaParent{Kind: "confluence", ExtSourceID: 1, ExtID: "101"},
		db.MediaFound{Kind: "image", Locator: "att:diagram.png", Name: "diagram.png", Anchor: "Release-plan"})
	describeMedia(t, d, page, "Deploy flow", "marker-ext-inline", "")
	att := recordMedia(t, d, db.MediaParent{Kind: "confluence", ExtSourceID: 1, ExtID: "att9"},
		db.MediaFound{Kind: "image", Locator: "att9", Name: "diagram.png"})
	describeMedia(t, d, att, "Deploy flow", "marker-ext-attachment", "")
	runKB(t, d)
	require.Contains(t, docText(t, d, "confluence:1:101"), "marker-ext-inline")
	require.Contains(t, docText(t, d, "confluence:1:att9"), "marker-ext-attachment")

	// the statement extsync's deleteDocument runs
	exec(t, d, `DELETE FROM ext_documents WHERE source_id = 1 AND ext_id = 'att9'`)
	assert.Zero(t, mediaRowsOf(t, d, `id = ?`, att))
	runKB(t, d)
	assert.Zero(t, chunksWith(t, d, "marker-ext-attachment"), "the attachment's description left the index")
	assert.Contains(t, docText(t, d, "confluence:1:101"), "marker-ext-inline", "the page is untouched")

	exec(t, d, `DELETE FROM ext_documents WHERE source_id = 1 AND ext_id = '101'`)
	assert.Zero(t, mediaRowsOf(t, d, `id = ?`, page))
	runKB(t, d)
	assert.Zero(t, chunksWith(t, d, "marker-ext-inline"), "the page's description left the index")
}
