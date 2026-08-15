package inbox

import (
	"context"
	"log"
	"testing"
	"time"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestBackfillMentions_CreatesItemsAndLeavesWatermarkUntouched guards the
// INBOX-09 boundary this command must not cross: two enabled accounts, each
// with one mention that is older than the current watermark (i.e. exactly
// the kind of message a broken/behind detector already scanned past),
// recover into inbox items — and inbox_last_processed_ts is byte-identical
// before and after the call.
func TestBackfillMentions_CreatesItemsAndLeavesWatermarkUntouched(t *testing.T) {
	d := testDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	acct2ID, err := d.CreateSlackAccount(db.SlackAccount{CurrentUserID: "2:U_ME2"})
	require.NoError(t, err)

	insertChannel(t, d, "1:C1", "public")
	insertChannel(t, d, "2:C1", "public")

	since := time.Now().Add(-20 * 24 * time.Hour)
	msgTS := recentTS(15 * 24 * 60) // 15 days ago: inside the since window, older than the watermark below
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_OTHER', 'Hey <@U_ME1> review please')`, msgTS)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:C1', ?, '2:U_OTHER', 'Hey <@U_ME2> review please')`, msgTS)
	require.NoError(t, err)

	// The watermark sits 10 days ago — well after these 15-day-old messages —
	// simulating exactly the situation the backfill exists for: detection
	// already scanned past this window while mention detection was broken.
	frozen := float64(time.Now().Add(-10 * 24 * time.Hour).Unix())
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))
	before, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	require.Equal(t, frozen, before)

	p := New(d, testConfig(), nil, log.Default())
	result, err := p.BackfillMentions(context.Background(), since, false)
	require.NoError(t, err)

	assert.Equal(t, 2, result.TotalCandidates)
	assert.Equal(t, 2, result.TotalCreated)
	require.Len(t, result.Accounts, 2)
	assert.Equal(t, int64(1), result.Accounts[0].AccountID)
	assert.Equal(t, 1, result.Accounts[0].CandidatesFound)
	assert.Equal(t, 1, result.Accounts[0].ItemsCreated)
	assert.Equal(t, acct2ID, result.Accounts[1].AccountID)
	assert.Equal(t, 1, result.Accounts[1].CandidatesFound)
	assert.Equal(t, 1, result.Accounts[1].ItemsCreated)
	assert.Empty(t, result.SkippedAccountIDs)

	items, err := d.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 2, "both accounts' mentions must be recovered as inbox items")
	for _, it := range items {
		assert.Equal(t, "mention", it.TriggerType)
		assert.Equal(t, "actionable", it.ItemClass, "backfilled items must land untriaged in the conservative default class (INBOX-01)")
	}

	after, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, before, after, "BackfillMentions must never read or write inbox_last_processed_ts (INBOX-09)")
}

// TestBackfillMentions_SecondRunCreatesNothing guards the dedup guard: since
// FindPendingMentions excludes any message that already produced an
// inbox_items row, running the backfill twice over the identical window must
// create nothing the second time.
func TestBackfillMentions_SecondRunCreatesNothing(t *testing.T) {
	d := testDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")

	since := time.Now().Add(-20 * 24 * time.Hour)
	msgTS := recentTS(15 * 24 * 60)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_OTHER', 'Hey <@U_ME1> review please')`, msgTS)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())

	first, err := p.BackfillMentions(context.Background(), since, false)
	require.NoError(t, err)
	require.Equal(t, 1, first.TotalCreated)

	second, err := p.BackfillMentions(context.Background(), since, false)
	require.NoError(t, err)
	assert.Equal(t, 0, second.TotalCandidates, "the already-recovered message must not resurface as a candidate")
	assert.Equal(t, 0, second.TotalCreated)

	items, err := d.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	assert.Len(t, items, 1, "re-running the backfill must not duplicate the item")
}

// TestBackfillMentions_DryRunCreatesNoRows guards the --dry-run contract:
// the reported counts must match exactly what a real run would create, but
// nothing is written.
func TestBackfillMentions_DryRunCreatesNoRows(t *testing.T) {
	d := testDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")

	since := time.Now().Add(-20 * 24 * time.Hour)
	msgTS := recentTS(15 * 24 * 60)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_OTHER', 'Hey <@U_ME1> review please')`, msgTS)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	result, err := p.BackfillMentions(context.Background(), since, true)
	require.NoError(t, err)

	assert.Equal(t, 1, result.TotalCandidates)
	assert.Equal(t, 1, result.TotalCreated, "dry run must report the same count a real run would create")

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM inbox_items`).Scan(&n))
	assert.Equal(t, 0, n, "dry run must not insert any row")
}

// TestBackfillMentions_SkipsAccountWithNoIdentity mirrors
// detectSlackAccounts' own skip: an enabled account whose current_user_id
// was never resolved is skipped cleanly, not treated as an error, and does
// not stop a sibling account's recovery in the same call.
func TestBackfillMentions_SkipsAccountWithNoIdentity(t *testing.T) {
	d := testDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")

	since := time.Now().Add(-20 * 24 * time.Hour)
	msgTS := recentTS(15 * 24 * 60)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_OTHER', 'Hey <@U_ME1> review please')`, msgTS)
	require.NoError(t, err)

	acct2ID, err := d.CreateSlackAccount(db.SlackAccount{}) // current_user_id never resolved
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	result, err := p.BackfillMentions(context.Background(), since, false)
	require.NoError(t, err, "an unresolved-identity account must be a clean skip, not an error")

	assert.Equal(t, 1, result.TotalCreated, "account 1's mention must still be recovered despite account 2 having no identity")
	require.Len(t, result.Accounts, 1)
	assert.Equal(t, int64(1), result.Accounts[0].AccountID)
	require.Len(t, result.SkippedAccountIDs, 1)
	assert.Equal(t, acct2ID, result.SkippedAccountIDs[0])
}

// TestBackfillMentions_SinceControlsWindowNotWatermark guards the core
// premise of the command: the recovery window comes from the explicit
// --since argument, not from inbox_last_processed_ts. The watermark is left
// at its zero default here — if the implementation used it instead of
// `since`, every message below (both older and newer than `since`) would
// pass a `ts_unix > 0` check and this test would catch that regression.
func TestBackfillMentions_SinceControlsWindowNotWatermark(t *testing.T) {
	d := testDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")

	since := time.Now().Add(-10 * 24 * time.Hour)

	newTS := recentTS(5 * 24 * 60)  // 5 days ago: after `since`
	oldTS := recentTS(15 * 24 * 60) // 15 days ago: before `since`

	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_OTHER', 'Hey <@U_ME1> newer please')`, newTS)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_OTHER2', 'Hey <@U_ME1> older please')`, oldTS)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	result, err := p.BackfillMentions(context.Background(), since, false)
	require.NoError(t, err)

	assert.Equal(t, 1, result.TotalCandidates, "only the message newer than `since` should even be found")
	assert.Equal(t, 1, result.TotalCreated)

	items, err := d.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, newTS, items[0].MessageTS, "the message older than `since` must not be recovered")
}

// TestBackfillMentions_DryRunDoesNotFoldIntoExistingThreadItem guards the
// other write path a dry run must skip: createItemsFromCandidates folds a
// candidate into an existing pending thread item (UpdateInboxItemSnippet +
// MergeWaitingUserIDs) instead of creating a new one whenever
// FindPendingInboxByThread already finds one — the common case for a dead
// window with several mentions in the same thread, not a contrived one. The
// earlier dry-run test only ever seeds fresh threads, so it never exercises
// this branch; this test seeds a pending item first and asserts it is
// untouched, read back from the DB rather than from the returned struct.
func TestBackfillMentions_DryRunDoesNotFoldIntoExistingThreadItem(t *testing.T) {
	d := testDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")

	since := time.Now().Add(-20 * 24 * time.Hour)
	threadTS := recentTS(16 * 24 * 60) // thread root, 16 days ago

	// A pending item already covers this thread — e.g. left behind by an
	// earlier backfill call over an earlier part of the same dead window.
	const originalSnippet = "original snippet, must survive a dry run"
	const originalWaiting = `["1:U_ORIGINAL"]`
	itemID := mustCreateInboxItem(t, d, db.InboxItem{
		ChannelID:      "1:C1",
		MessageTS:      threadTS,
		ThreadTS:       threadTS,
		SenderUserID:   "1:U_OTHER",
		TriggerType:    "mention",
		Snippet:        originalSnippet,
		WaitingUserIDs: originalWaiting,
	})

	// A second, not-yet-recovered mention in the SAME thread: the candidate
	// that would fold into the item above.
	secondTS := recentTS(15 * 24 * 60) // 15 days ago, after threadTS
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, thread_ts, user_id, text) VALUES ('1:C1', ?, ?, '1:U_SECOND', 'Also <@U_ME1> please check')`, secondTS, threadTS)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	result, err := p.BackfillMentions(context.Background(), since, true)
	require.NoError(t, err)

	// The mention query does find the candidate, but folding into an
	// existing thread item was never counted as a "create" — real run or
	// dry run alike — so the dry run reports exactly what a real run would
	// have: found, not created. This is the "stays informative" half of the
	// contract.
	assert.Equal(t, 1, result.TotalCandidates)
	assert.Equal(t, 0, result.TotalCreated)

	// The load-bearing half: read the existing item back from the DB and
	// confirm the dry run touched neither of its two fold-writable fields.
	items, err := d.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 1, "dry run must not create a second item for the same thread")
	assert.Equal(t, int(itemID), items[0].ID)
	assert.Equal(t, originalSnippet, items[0].Snippet, "dry run must not overwrite the existing item's snippet")
	assert.Equal(t, originalWaiting, items[0].WaitingUserIDs, "dry run must not merge waiting user ids into the existing item")
}
