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
	assert.Equal(t, 0, result.TotalAlreadyAnswered)
	assert.Equal(t, 0, result.TotalEmptySnippet)
	assert.Equal(t, 0, result.TotalCreateErrors)
	require.Len(t, result.Accounts, 2)
	assert.Equal(t, int64(1), result.Accounts[0].AccountID)
	assert.Equal(t, 1, result.Accounts[0].CandidatesFound)
	assert.Equal(t, 1, result.Accounts[0].Created)
	assert.Equal(t, acct2ID, result.Accounts[1].AccountID)
	assert.Equal(t, 1, result.Accounts[1].CandidatesFound)
	assert.Equal(t, 1, result.Accounts[1].Created)
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

// TestBackfillMentions_SeveralPlainMentionsOneChannel_OneItemPerMention is
// the blocker-1 pin: createItemsFromCandidates (the live per-cycle path)
// groups by (channel, thread_ts), and a plain (non-threaded) message's
// thread_ts is always "" — so reusing that path over a multi-week backfill
// window used to collapse every plain-channel mention into a single group,
// creating one item for the whole channel instead of one per mention. With
// the create-only path this must recover one item per distinct mention.
func TestBackfillMentions_SeveralPlainMentionsOneChannel_OneItemPerMention(t *testing.T) {
	d := testDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")

	since := time.Now().Add(-20 * 24 * time.Hour)
	ts1 := recentTS(15 * 24 * 60)
	ts2 := recentTS(14 * 24 * 60)
	ts3 := recentTS(13 * 24 * 60)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_A', 'Hey <@U_ME1> please check A')`, ts1)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_B', 'Hey <@U_ME1> please check B')`, ts2)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_C', 'Hey <@U_ME1> please check C')`, ts3)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	result, err := p.BackfillMentions(context.Background(), since, false)
	require.NoError(t, err)

	assert.Equal(t, 3, result.TotalCandidates)
	assert.Equal(t, 3, result.TotalCreated, "one item per plain-channel mention, not one per channel")

	items, err := d.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	assert.Len(t, items, 3, "expected one row per mention")

	gotTS := map[string]bool{}
	for _, it := range items {
		gotTS[it.MessageTS] = true
	}
	assert.True(t, gotTS[ts1] && gotTS[ts2] && gotTS[ts3], "all three distinct mentions must each have their own row")
}

// TestBackfillMentions_ExistingThreadItemLeftUntouchedByRealRun is the
// blocker-2 pin: createItemsFromCandidates folds a candidate into ANY
// pending item already on the same thread regardless of that item's age,
// which over a multi-week backfill window can just as easily be a
// different, currently live conversation — folding would silently rewrite
// its message_ts backwards and wipe its ai_reason/read_at. The create-only
// path must never touch an existing item, real run or dry run alike: it is
// read back from the DB byte-identical, and the new candidate gets its own
// separate row instead.
func TestBackfillMentions_ExistingThreadItemLeftUntouchedByRealRun(t *testing.T) {
	d := testDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")

	since := time.Now().Add(-20 * 24 * time.Hour)
	threadTS := recentTS(16 * 24 * 60) // thread root, 16 days ago

	// A pending item already covers this thread — e.g. a currently live
	// conversation that happens to share the thread with the backfill
	// candidate below.
	const originalSnippet = "original snippet, must survive a real run"
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

	// A second, not-yet-recovered mention in the SAME thread.
	secondTS := recentTS(15 * 24 * 60) // 15 days ago, after threadTS
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, thread_ts, user_id, text) VALUES ('1:C1', ?, ?, '1:U_SECOND', 'Also <@U_ME1> please check')`, secondTS, threadTS)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	result, err := p.BackfillMentions(context.Background(), since, false) // a REAL run — this path never folds, dry or not
	require.NoError(t, err)
	assert.Equal(t, 1, result.TotalCreated, "the second candidate must be recovered as its own item")

	// The load-bearing half: read both rows back from the DB. The pre-existing
	// item must be byte-identical; the new candidate must have landed in a
	// SEPARATE row, never merged into the first.
	items, err := d.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	require.Len(t, items, 2, "the existing item and the newly recovered one must both exist as separate rows")

	var original, created *db.InboxItem
	for i := range items {
		if items[i].ID == int(itemID) {
			original = &items[i]
		} else {
			created = &items[i]
		}
	}
	require.NotNil(t, original, "the pre-existing item must still be present")
	require.NotNil(t, created, "the new candidate must have been created")

	assert.Equal(t, threadTS, original.MessageTS, "a real run must not rewrite the existing item's message_ts backwards")
	assert.Equal(t, originalSnippet, original.Snippet, "a real run must not overwrite the existing item's snippet")
	assert.Equal(t, originalWaiting, original.WaitingUserIDs, "a real run must not merge waiting user ids into the existing item")

	assert.Equal(t, secondTS, created.MessageTS)
}

// TestBackfillMentions_IdempotentSecondRunOverMultiMentionThread guards the
// idempotency claim end to end for the case the fold bug used to break: two
// distinct mentions in the SAME thread. A first run must recover both as
// separate items; a second run over the identical window must create
// neither again, and the DB must still hold exactly two rows — not one
// degraded-by-folding row, and not a duplicate.
func TestBackfillMentions_IdempotentSecondRunOverMultiMentionThread(t *testing.T) {
	d := testDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")

	since := time.Now().Add(-20 * 24 * time.Hour)
	threadTS := recentTS(15 * 24 * 60)
	replyTS := recentTS(14 * 24 * 60)
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, thread_ts, user_id, text) VALUES ('1:C1', ?, ?, '1:U_A', 'Hey <@U_ME1> please check A')`, threadTS, threadTS)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, thread_ts, user_id, text) VALUES ('1:C1', ?, ?, '1:U_B', 'Also <@U_ME1> please check B')`, replyTS, threadTS)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())

	first, err := p.BackfillMentions(context.Background(), since, false)
	require.NoError(t, err)
	assert.Equal(t, 2, first.TotalCreated, "both mentions in the thread must be recovered on the first run")

	second, err := p.BackfillMentions(context.Background(), since, false)
	require.NoError(t, err)
	assert.Equal(t, 0, second.TotalCandidates, "both messages already produced items, so neither is a candidate anymore")
	assert.Equal(t, 0, second.TotalCreated)

	items, err := d.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	assert.Len(t, items, 2, "exactly two rows: one per mention, no duplication and no folding-driven loss")
}

// TestBackfillMentions_AlreadyAnsweredSkip guards the AlreadyAnswered
// classification: a mention the owner already reacted to or replied to
// after the fact (CheckUserReplied — the same "handled in Slack already"
// check autoResolveSlack/INBOX-02 uses) is skipped and counted, not
// recovered as a new inbox item.
func TestBackfillMentions_AlreadyAnsweredSkip(t *testing.T) {
	d := testDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")

	since := time.Now().Add(-20 * 24 * time.Hour)
	mentionTS := recentTS(15 * 24 * 60)
	replyTS := recentTS(14 * 24 * 60) // the owner's own reply, after the mention
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_OTHER', 'Hey <@U_ME1> please check')`, mentionTS)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U_ME1', 'On it')`, replyTS)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	result, err := p.BackfillMentions(context.Background(), since, false)
	require.NoError(t, err)

	assert.Equal(t, 1, result.TotalCandidates)
	assert.Equal(t, 0, result.TotalCreated, "already-answered mentions must not be recovered")
	assert.Equal(t, 1, result.TotalAlreadyAnswered)
	require.Len(t, result.Accounts, 1)
	assert.Equal(t, 1, result.Accounts[0].AlreadyAnswered)

	items, err := d.GetInboxItems(db.InboxFilter{})
	require.NoError(t, err)
	assert.Empty(t, items, "an already-answered mention must not create an inbox item")
}
