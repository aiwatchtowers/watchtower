package db

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// insertChannel is a shared fixture helper for stream/detection tests.
func insertChannel(t *testing.T, db *DB, id, chType string) {
	t.Helper()
	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES (?, ?, ?)`, id, id, chType)
	require.NoError(t, err)
}

// insertMessage is a shared fixture helper for stream/detection tests.
func insertMessage(t *testing.T, db *DB, channelID, ts, userID, text string) {
	t.Helper()
	_, err := db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES (?, ?, ?, ?)`, channelID, ts, userID, text)
	require.NoError(t, err)
}

// insertMessageWithThread is like insertMessage but sets thread_ts.
func insertMessageWithThread(t *testing.T, db *DB, channelID, ts, threadTS, userID, text string) {
	t.Helper()
	_, err := db.Exec(`INSERT INTO messages (channel_id, ts, thread_ts, user_id, text) VALUES (?, ?, ?, ?, ?)`,
		channelID, ts, threadTS, userID, text)
	require.NoError(t, err)
}

// mustCreateInboxItem is a shared fixture helper wrapping CreateInboxItem.
func mustCreateInboxItem(t *testing.T, db *DB, it InboxItem) int64 {
	t.Helper()
	id, err := db.CreateInboxItem(it)
	require.NoError(t, err)
	return id
}

func TestCreateInboxItem(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateInboxItem(InboxItem{
		ChannelID:    "C123",
		MessageTS:    "1234567890.000100",
		SenderUserID: "U456",
		TriggerType:  "mention",
		Snippet:      "Hey, can you review this?",
	})
	require.NoError(t, err)
	assert.Greater(t, id, int64(0))

	item, err := db.GetInboxItemByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "C123", item.ChannelID)
	assert.Equal(t, "1234567890.000100", item.MessageTS)
	assert.Equal(t, "U456", item.SenderUserID)
	assert.Equal(t, "mention", item.TriggerType)
	assert.Equal(t, "Hey, can you review this?", item.Snippet)
	assert.Equal(t, "pending", item.Status)
	assert.Equal(t, "medium", item.Priority)
	// Regression: created_at/updated_at must always be populated.
	// Past incident: NOT NULL constraint failures spammed the daemon log
	// when CreateInboxItem skipped the timestamp; items were silently dropped.
	assert.NotEmpty(t, item.CreatedAt, "created_at must be populated")
	assert.NotEmpty(t, item.UpdatedAt, "updated_at must be populated")
}

func TestGetInboxItemByMessage(t *testing.T) {
	db := openTestDB(t)

	_, err := db.CreateInboxItem(InboxItem{
		ChannelID:    "C123",
		MessageTS:    "1234567890.000100",
		SenderUserID: "U456",
		TriggerType:  "mention",
	})
	require.NoError(t, err)

	item, err := db.GetInboxItemByMessage("C123", "1234567890.000100")
	require.NoError(t, err)
	assert.Equal(t, "C123", item.ChannelID)
	assert.Equal(t, "1234567890.000100", item.MessageTS)
}

func TestGetInboxItems_Filters(t *testing.T) {
	db := openTestDB(t)

	_, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention", Priority: "high"})
	require.NoError(t, err)
	_, err = db.CreateInboxItem(InboxItem{ChannelID: "C2", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "dm", Priority: "low"})
	require.NoError(t, err)

	// All pending
	items, err := db.GetInboxItems(InboxFilter{})
	require.NoError(t, err)
	assert.Len(t, items, 2)
	// High priority first
	assert.Equal(t, "high", items[0].Priority)

	// Filter by priority
	items, err = db.GetInboxItems(InboxFilter{Priority: "high"})
	require.NoError(t, err)
	assert.Len(t, items, 1)
	assert.Equal(t, "C1", items[0].ChannelID)

	// Filter by trigger type
	items, err = db.GetInboxItems(InboxFilter{TriggerType: "dm"})
	require.NoError(t, err)
	assert.Len(t, items, 1)
	assert.Equal(t, "C2", items[0].ChannelID)

	// Filter by channel
	items, err = db.GetInboxItems(InboxFilter{ChannelID: "C1"})
	require.NoError(t, err)
	assert.Len(t, items, 1)

	// Limit
	items, err = db.GetInboxItems(InboxFilter{Limit: 1})
	require.NoError(t, err)
	assert.Len(t, items, 1)
}

func TestUpdateInboxItemStatus(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)

	err = db.UpdateInboxItemStatus(int(id), "resolved")
	require.NoError(t, err)

	item, err := db.GetInboxItemByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "resolved", item.Status)
}

func TestResolveInboxItem(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)

	err = db.ResolveInboxItem(int(id), "User replied in thread")
	require.NoError(t, err)

	item, err := db.GetInboxItemByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "resolved", item.Status)
	assert.Equal(t, "User replied in thread", item.ResolvedReason)
}

func TestSnoozeAndUnsnoozeInboxItems(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)

	err = db.SnoozeInboxItem(int(id), "2020-01-01")
	require.NoError(t, err)

	item, err := db.GetInboxItemByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "snoozed", item.Status)
	assert.Equal(t, "2020-01-01", item.SnoozeUntil)

	n, err := db.UnsnoozeExpiredInboxItems()
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	item, err = db.GetInboxItemByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "pending", item.Status)
}

func TestMarkInboxRead(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)

	err = db.MarkInboxRead(int(id))
	require.NoError(t, err)

	item, err := db.GetInboxItemByID(int(id))
	require.NoError(t, err)
	assert.NotEmpty(t, item.ReadAt)
}

func TestLinkInboxTarget(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)

	err = db.LinkInboxTarget(int(id), 42)
	require.NoError(t, err)

	item, err := db.GetInboxItemByID(int(id))
	require.NoError(t, err)
	require.NotNil(t, item.TargetID)
	assert.Equal(t, 42, *item.TargetID)
}

func TestGetInboxCounts(t *testing.T) {
	db := openTestDB(t)

	_, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)
	id2, err := db.CreateInboxItem(InboxItem{ChannelID: "C2", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "dm"})
	require.NoError(t, err)

	// Mark one as read
	err = db.MarkInboxRead(int(id2))
	require.NoError(t, err)

	pending, unread, err := db.GetInboxCounts()
	require.NoError(t, err)
	assert.Equal(t, 2, pending)
	assert.Equal(t, 1, unread) // one unread (the first one)
}

func TestGetInboxItemsForBriefing(t *testing.T) {
	db := openTestDB(t)

	_, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention", Priority: "high"})
	require.NoError(t, err)
	id2, err := db.CreateInboxItem(InboxItem{ChannelID: "C2", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "dm", Priority: "low"})
	require.NoError(t, err)

	// Resolve one — should not appear in briefing
	err = db.ResolveInboxItem(int(id2), "done")
	require.NoError(t, err)

	items, err := db.GetInboxItemsForBriefing()
	require.NoError(t, err)
	assert.Len(t, items, 1)
	assert.Equal(t, "high", items[0].Priority)
}

func TestBulkUpdateInboxPriorities(t *testing.T) {
	db := openTestDB(t)

	id1, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)
	id2, err := db.CreateInboxItem(InboxItem{ChannelID: "C2", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "dm"})
	require.NoError(t, err)

	updates := map[int]struct {
		Priority string
		AIReason string
	}{
		int(id1): {Priority: "high", AIReason: "Direct request from manager"},
		int(id2): {Priority: "low", AIReason: "FYI message"},
	}
	err = db.BulkUpdateInboxPriorities(updates)
	require.NoError(t, err)

	item1, err := db.GetInboxItemByID(int(id1))
	require.NoError(t, err)
	assert.Equal(t, "high", item1.Priority)
	assert.Equal(t, "Direct request from manager", item1.AIReason)

	item2, err := db.GetInboxItemByID(int(id2))
	require.NoError(t, err)
	assert.Equal(t, "low", item2.Priority)
}

func TestInboxLastProcessedTS(t *testing.T) {
	db := openTestDB(t)

	// Need a workspace row first
	_, err := db.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`)
	require.NoError(t, err)

	ts, err := db.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, 0.0, ts)

	err = db.SetInboxLastProcessedTS(1234567890.0)
	require.NoError(t, err)

	ts, err = db.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, 1234567890.0, ts)
}

func TestFindPendingMentions(t *testing.T) {
	db := openTestDB(t)

	// Insert a channel and a message that mentions our user
	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, permalink) VALUES ('1:C1', '1000.001', 'U_OTHER', 'Hey <@U_ME> can you check this?', 'https://slack.com/p1')`)
	require.NoError(t, err)
	// Pipe-form mention `<@U_ME|Display Name>` — Slack frequently rewrites mentions
	// to this form once it knows the display name. Detector must match both forms.
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, permalink) VALUES ('1:C1', '1003.001', 'U_OTHER', 'cc <@U_ME|Vadym Trunov> please review', 'https://slack.com/p2')`)
	require.NoError(t, err)
	// Message that doesn't mention the user
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1001.001', 'U_OTHER', 'Regular message')`)
	require.NoError(t, err)
	// Message from the user themselves (should not match)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1002.001', 'U_ME', '<@U_ME> testing self-mention')`)
	require.NoError(t, err)
	// Mention of a different user whose ID is a prefix-match of ours — must NOT match.
	// Ensures the closing `>` / `|` boundary is enforced and `LIKE '%<@U_ME%'` is not used.
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1004.001', 'U_OTHER', 'cc <@U_MEEK> hello')`)
	require.NoError(t, err)

	candidates, err := db.FindPendingMentions(1, "U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 2)

	// Both forms detected.
	gotTS := map[string]bool{}
	for _, c := range candidates {
		gotTS[c.MessageTS] = true
		assert.Equal(t, "1:C1", c.ChannelID)
		assert.Equal(t, "mention", c.TriggerType)
		assert.Equal(t, "U_OTHER", c.SenderUserID)
	}
	assert.True(t, gotTS["1000.001"], "strict <@U_ME> form should match")
	assert.True(t, gotTS["1003.001"], "pipe <@U_ME|Name> form should match")
}

// TestFindPendingMentions_NamespacedUserID pins the multi-account fix:
// GetCurrentUserID returns a namespaced id ("1:U_ME") post migration 00048,
// but messages.text carries Slack's raw mention markup ("<@U_ME>") untouched
// since it is source data no migration rewrites. FindPendingMentions must
// reduce the namespaced id to its raw form for the LIKE patterns while still
// comparing m.user_id — itself namespaced — against the namespaced id as-is.
func TestFindPendingMentions_NamespacedUserID(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)

	// Raw markup mentioning our user, written by someone else — should match.
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1000.001', '1:U_OTHER', 'hey <@U_ME> look')`)
	require.NoError(t, err)

	// Mentions a different user whose id is a prefix-match of ours — must NOT
	// match. Pins the closing `>` boundary with a namespaced caller id.
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1001.001', '1:U_OTHER', 'cc <@U_MEOW> hello')`)
	require.NoError(t, err)

	// Mentions our user but written by ourselves (namespaced sender) — must
	// NOT match. Only catches a regression if m.user_id != ? is bound with
	// the namespaced id; binding the raw form here would let this leak through.
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1002.001', '1:U_ME', '<@U_ME> self-mention')`)
	require.NoError(t, err)

	// Pipe-form mention, written by someone else — should also match. Pins
	// that the fix reduces both LIKE patterns to the raw id, not just the
	// strict one: a half-fix leaving the pipe pattern namespaced would miss
	// this silently.
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1003.001', '1:U_OTHER', 'cc <@U_ME|Name> ping')`)
	require.NoError(t, err)

	candidates, err := db.FindPendingMentions(1, "1:U_ME", 0)
	require.NoError(t, err)
	require.Len(t, candidates, 2)

	gotTS := map[string]bool{}
	for _, c := range candidates {
		gotTS[c.MessageTS] = true
		assert.Equal(t, "1:U_OTHER", c.SenderUserID)
	}
	assert.True(t, gotTS["1000.001"], "strict <@U_ME> form should match")
	assert.True(t, gotTS["1003.001"], "pipe <@U_ME|Name> form should match")
}

// TestFindPendingMentions_ScopedToAccount guards the multi-account regression:
// the same raw mention markup can appear in two different accounts' channels
// (both happen to be named "C1" pre-namespace) — a call for account 1 must
// only see account 1's channel, never account 2's.
func TestFindPendingMentions_ScopedToAccount(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO channels (id, name, type) VALUES ('2:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1000.001', 'U_OTHER', 'Hey <@U_ME> can you check this?')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:C1', '1000.002', 'U_OTHER', 'Hey <@U_ME> can you check this?')`)
	require.NoError(t, err)

	candidates, err := db.FindPendingMentions(1, "U_ME", 0)
	require.NoError(t, err)
	require.Len(t, candidates, 1, "the identical mention in the other account's channel must not leak in")
	assert.Equal(t, "1:C1", candidates[0].ChannelID)
}

func TestFindPendingDMs(t *testing.T) {
	db := openTestDB(t)

	// Insert a DM channel and messages
	_, err := db.Exec(`INSERT INTO channels (id, name, type, dm_user_id) VALUES ('1:D1', 'dm-user', 'dm', 'U_OTHER')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:D1', '1000.001', 'U_OTHER', 'Hey, got a minute?')`)
	require.NoError(t, err)
	// Our own message — should not be a candidate
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:D1', '1001.001', 'U_ME', 'Sure')`)
	require.NoError(t, err)

	candidates, err := db.FindPendingDMs(1, "U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 1)
	assert.Equal(t, "1:D1", candidates[0].ChannelID)
	assert.Equal(t, "dm", candidates[0].TriggerType)
}

// TestFindPendingDMs_ScopedToAccount guards the multi-account regression: the
// owner's own outgoing DM in a second connected account must never surface as
// an incoming DM, neither by leaking into account 1's results (no channel
// scoping) nor by slipping past account 2's own-message exclusion.
func TestFindPendingDMs_ScopedToAccount(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type, dm_user_id) VALUES ('2:CDM', 'dm-user', 'dm', '2:U_OTHER')`)
	require.NoError(t, err)
	// The owner's own outgoing DM, sent from the second connected account.
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:CDM', '1000.001', '2:U_ME', 'Sure, will do')`)
	require.NoError(t, err)

	candidates, err := db.FindPendingDMs(1, "1:U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 0, "another account's channel must not leak into account 1's results")

	candidates, err = db.FindPendingDMs(2, "2:U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 0, "the owner's own DM in its own account must still be excluded")
}

func TestCheckUserReplied(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`)
	require.NoError(t, err)

	// Message in thread
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('C1', '1000.001', 'U_OTHER', 'mention', '1000.001')`)
	require.NoError(t, err)
	// User reply in same thread
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('C1', '1001.001', 'U_ME', 'reply', '1000.001')`)
	require.NoError(t, err)

	replied, err := db.CheckUserReplied("U_ME", "C1", "1000.001", "1000.001")
	require.NoError(t, err)
	assert.True(t, replied)

	// No reply in different thread
	replied, err = db.CheckUserReplied("U_ME", "C1", "2000.001", "2000.001")
	require.NoError(t, err)
	assert.False(t, replied)
}

func TestCheckUserReplied_DMThreadReply(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('D1', 'dm-olena', 'dm')`)
	require.NoError(t, err)

	// DM message from another user (top-level, no thread_ts)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('D1', '1000.001', 'U_OTHER', 'please do this')`)
	require.NoError(t, err)

	// User replies as a thread to that DM message
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('D1', '1001.001', 'U_ME', 'done', '1000.001')`)
	require.NoError(t, err)

	// threadTS is empty because the original DM was top-level
	replied, err := db.CheckUserReplied("U_ME", "D1", "1000.001", "")
	require.NoError(t, err)
	assert.True(t, replied, "should detect thread reply to a top-level DM")
}

func TestFindThreadRepliesToUser(t *testing.T) {
	db := openTestDB(t)

	// Insert a channel
	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)

	// Root message by our user (thread_ts == ts means it's the root)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '1000.001', 'U_ME', 'Starting a thread', '1000.001')`)
	require.NoError(t, err)

	// Reply from someone else in that thread
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts, permalink) VALUES ('1:C1', '1001.001', 'U_OTHER', 'Replying to your thread', '1000.001', 'https://slack.com/p2')`)
	require.NoError(t, err)

	// Reply from ourselves (should not match)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '1002.001', 'U_ME', 'My own reply', '1000.001')`)
	require.NoError(t, err)

	// Reply in a thread started by someone else (should not match)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '2000.001', 'U_OTHER2', 'Other root', '2000.001')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '2001.001', 'U_OTHER', 'Reply to other thread', '2000.001')`)
	require.NoError(t, err)

	candidates, err := db.FindThreadRepliesToUser(1, "U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 1)
	assert.Equal(t, "1:C1", candidates[0].ChannelID)
	assert.Equal(t, "1001.001", candidates[0].MessageTS)
	assert.Equal(t, "1000.001", candidates[0].ThreadTS)
	assert.Equal(t, "U_OTHER", candidates[0].SenderUserID)
	assert.Equal(t, "thread_reply", candidates[0].TriggerType)
	assert.Equal(t, "https://slack.com/p2", candidates[0].Permalink)
}

func TestFindThreadRepliesToUser_ExcludesExistingInbox(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '1000.001', 'U_ME', 'Root', '1000.001')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '1001.001', 'U_OTHER', 'Reply', '1000.001')`)
	require.NoError(t, err)

	// Create an existing inbox item for this message
	_, err = db.CreateInboxItem(InboxItem{ChannelID: "1:C1", MessageTS: "1001.001", SenderUserID: "U_OTHER", TriggerType: "thread_reply"})
	require.NoError(t, err)

	candidates, err := db.FindThreadRepliesToUser(1, "U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 0)
}

func TestFindThreadRepliesToUser_SinceTS(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '1000.001', 'U_ME', 'Root', '1000.001')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '1001.001', 'U_OTHER', 'Old reply', '1000.001')`)
	require.NoError(t, err)

	// sinceTS after the reply — should find nothing
	candidates, err := db.FindThreadRepliesToUser(1, "U_ME", 2000.0)
	require.NoError(t, err)
	assert.Len(t, candidates, 0)
}

func TestFindThreadRepliesToUser_ParticipantNotRoot(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)

	// Root message by someone else
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '3000.001', 'U_OTHER', 'Other starts a thread', '3000.001')`)
	require.NoError(t, err)

	// U_ME replies in that thread (participant, not root author)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '3001.001', 'U_ME', 'I chime in', '3000.001')`)
	require.NoError(t, err)

	// Third person replies after U_ME — should be detected
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts, permalink) VALUES ('1:C1', '3002.001', 'U_THIRD', 'Follow-up for you', '3000.001', 'https://slack.com/p3')`)
	require.NoError(t, err)

	// U_ME's own reply should NOT appear
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('1:C1', '3003.001', 'U_ME', 'My second reply', '3000.001')`)
	require.NoError(t, err)

	candidates, err := db.FindThreadRepliesToUser(1, "U_ME", 0)
	require.NoError(t, err)
	// Only U_THIRD's reply — root (thread_ts==ts) is filtered, U_ME's own replies are excluded
	assert.Len(t, candidates, 1)
	assert.Equal(t, "3002.001", candidates[0].MessageTS)
	assert.Equal(t, "U_THIRD", candidates[0].SenderUserID)
	assert.Equal(t, "thread_reply", candidates[0].TriggerType)
	assert.Equal(t, "https://slack.com/p3", candidates[0].Permalink)
}

// TestFindThreadRepliesToUser_ScopedToAccount guards the multi-account
// regression: a qualifying thread reply under account 2 must be invisible to
// account 1's call and only surface when called for account 2.
func TestFindThreadRepliesToUser_ScopedToAccount(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('2:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('2:C1', '1000.001', 'U_ME', 'Starting a thread', '1000.001')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('2:C1', '1001.001', 'U_OTHER', 'Replying to your thread', '1000.001')`)
	require.NoError(t, err)

	candidates, err := db.FindThreadRepliesToUser(1, "U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 0, "account 1 must not see account 2's thread reply")

	candidates, err = db.FindThreadRepliesToUser(2, "U_ME", 0)
	require.NoError(t, err)
	require.Len(t, candidates, 1)
	assert.Equal(t, "2:C1", candidates[0].ChannelID)
}

func TestFindReactionRequests(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)

	// Message by our user
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, permalink) VALUES ('1:C1', '1000.001', 'U_ME', 'Here is my proposal', 'https://slack.com/p1')`)
	require.NoError(t, err)

	// Question reaction from someone else
	_, err = db.Exec(`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES ('1:C1', '1000.001', 'U_OTHER', 'question')`)
	require.NoError(t, err)

	candidates, err := db.FindReactionRequests(1, "U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 1)
	assert.Equal(t, "1:C1", candidates[0].ChannelID)
	assert.Equal(t, "1000.001", candidates[0].MessageTS)
	assert.Equal(t, "U_OTHER", candidates[0].SenderUserID)
	assert.Equal(t, "reaction", candidates[0].TriggerType)
	assert.Equal(t, "https://slack.com/p1", candidates[0].Permalink)
}

func TestFindReactionRequests_IgnoresNonAttentionEmoji(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1000.001', 'U_ME', 'Nice work')`)
	require.NoError(t, err)

	// Thumbs up reaction (not an attention emoji)
	_, err = db.Exec(`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES ('1:C1', '1000.001', 'U_OTHER', '+1')`)
	require.NoError(t, err)

	candidates, err := db.FindReactionRequests(1, "U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 0)
}

func TestFindReactionRequests_IgnoresOwnReaction(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1000.001', 'U_ME', 'My message')`)
	require.NoError(t, err)

	// Own reaction should not match
	_, err = db.Exec(`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES ('1:C1', '1000.001', 'U_ME', 'question')`)
	require.NoError(t, err)

	candidates, err := db.FindReactionRequests(1, "U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 0)
}

func TestFindReactionRequests_DeduplicatesMultipleReactions(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1000.001', 'U_ME', 'My message')`)
	require.NoError(t, err)

	// Multiple attention reactions from different users on the same message
	_, err = db.Exec(`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES ('1:C1', '1000.001', 'U_A', 'question')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES ('1:C1', '1000.001', 'U_B', 'eyes')`)
	require.NoError(t, err)

	candidates, err := db.FindReactionRequests(1, "U_ME", 0)
	require.NoError(t, err)
	// Should return only one candidate per message
	assert.Len(t, candidates, 1)
	assert.Equal(t, "reaction", candidates[0].TriggerType)
}

// TestFindReactionRequests_ScopedToAccount guards the multi-account
// regression: a qualifying reaction request under account 2 must be invisible
// to account 1's call and only surface when called for account 2.
func TestFindReactionRequests_ScopedToAccount(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('2:C1', 'general', 'public')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('2:C1', '1000.001', 'U_ME', 'Here is my proposal')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES ('2:C1', '1000.001', 'U_OTHER', 'question')`)
	require.NoError(t, err)

	candidates, err := db.FindReactionRequests(1, "U_ME", 0)
	require.NoError(t, err)
	assert.Len(t, candidates, 0, "account 1 must not see account 2's reaction request")

	candidates, err = db.FindReactionRequests(2, "U_ME", 0)
	require.NoError(t, err)
	require.Len(t, candidates, 1)
	assert.Equal(t, "2:C1", candidates[0].ChannelID)
}

func TestGetInboxItems_IncludeResolved(t *testing.T) {
	db := openTestDB(t)

	id, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)
	err = db.ResolveInboxItem(int(id), "done")
	require.NoError(t, err)

	// Default: exclude resolved
	items, err := db.GetInboxItems(InboxFilter{})
	require.NoError(t, err)
	assert.Len(t, items, 0)

	// Include resolved
	items, err = db.GetInboxItems(InboxFilter{IncludeResolved: true})
	require.NoError(t, err)
	assert.Len(t, items, 1)
}

func TestCheckUserRepliedBefore(t *testing.T) {
	db := openTestDB(t)

	_, err := db.Exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`)
	require.NoError(t, err)

	// Thread: user replied before the "thanks" message.
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('C1', '1000.001', 'U_OTHER', 'Can you help?', '1000.001')`)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('C1', '1001.001', 'U_ME', 'Sure, done', '1000.001')`)
	require.NoError(t, err)
	// "Thanks" message at ts=1002.001
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES ('C1', '1002.001', 'U_OTHER', 'Thanks!', '1000.001')`)
	require.NoError(t, err)

	// User replied before the "thanks" message.
	replied, err := db.CheckUserRepliedBefore("U_ME", "C1", "1002.001", "1000.001")
	require.NoError(t, err)
	assert.True(t, replied)

	// User did NOT reply before the first message.
	replied, err = db.CheckUserRepliedBefore("U_ME", "C1", "1000.001", "1000.001")
	require.NoError(t, err)
	assert.False(t, replied)

	// Non-threaded: user replied in channel before.
	_, err = db.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '2000.001', 'U_ME', 'Channel message')`)
	require.NoError(t, err)

	replied, err = db.CheckUserRepliedBefore("U_ME", "C1", "2001.001", "")
	require.NoError(t, err)
	assert.True(t, replied)

	// No reply in a completely different context.
	replied, err = db.CheckUserRepliedBefore("U_ME", "C_NONE", "1000.001", "")
	require.NoError(t, err)
	assert.False(t, replied)
}

func TestCreateInboxItem_UniqueConstraint(t *testing.T) {
	db := openTestDB(t)

	_, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)

	// Duplicate should fail
	_, err = db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U1", TriggerType: "mention"})
	assert.Error(t, err)
}

func TestInboxItemCardFieldsRoundTrip(t *testing.T) {
	db := openTestDB(t)
	id, err := db.CreateInboxItem(InboxItem{
		ChannelID: "C1", MessageTS: "100.1", SenderUserID: "U2",
		TriggerType: "stream", Snippet: "release blocked",
	})
	if err != nil {
		t.Fatalf("create with trigger_type=stream: %v", err)
	}
	it, err := db.GetInboxItem(id)
	if err != nil {
		t.Fatal(err)
	}
	if it.CardStatus != "none" {
		t.Fatalf("card_status default = %q, want none", it.CardStatus)
	}
	if it.WhyMatters != "" || it.ThreadDigest != "" || it.DraftReply != "" {
		t.Fatalf("card text fields should default empty")
	}
}

func TestListStreamCandidatesSince(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertChannel(t, d, "D1", "dm")
	insertMessage(t, d, "C1", "100.1", "U2", "release blocked on infra") // candidate
	insertMessage(t, d, "C1", "100.2", "U1", "my own message")           // self → excluded
	insertMessage(t, d, "D1", "100.3", "U2", "dm text")                  // dm → excluded
	insertMessage(t, d, "C1", "99.0", "U2", "too old")                   // before watermark

	got, err := d.ListStreamCandidatesSince([]string{"U1"}, 99.5, 100)
	require.NoError(t, err)
	if len(got) != 1 || got[0].MessageTS != "100.1" {
		t.Fatalf("want exactly the C1/100.1 candidate, got %+v", got)
	}
	if got[0].TriggerType != "stream" {
		t.Fatalf("trigger type = %q, want stream", got[0].TriggerType)
	}
}

// TestListStreamCandidatesSince_MultipleOwners proves own-message exclusion
// spans every connected Slack account's owner id, not just one — the
// multi-account own-message-suppression contract (Task 7).
func TestListStreamCandidatesSince_MultipleOwners(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U1", "owner msg from account 1") // owner id #1
	insertMessage(t, d, "C1", "100.2", "U2", "owner msg from account 2") // owner id #2
	insertMessage(t, d, "C1", "100.3", "U3", "a real other person")      // not an owner

	// Both owner ids excluded → only the non-owner message survives.
	got, err := d.ListStreamCandidatesSince([]string{"U1", "U2"}, 0, 100)
	require.NoError(t, err)
	if len(got) != 1 || got[0].MessageTS != "100.3" {
		t.Fatalf("want only the non-owner C1/100.3 candidate, got %+v", got)
	}

	// Excluding only U2 leaves U1's message in — proves the clause targets the
	// listed ids, not "exclude everything".
	got, err = d.ListStreamCandidatesSince([]string{"U2"}, 0, 100)
	require.NoError(t, err)
	if len(got) != 2 {
		t.Fatalf("want 2 candidates (U1 + U3) when only U2 excluded, got %+v", got)
	}
	for _, c := range got {
		if c.SenderUserID == "U2" {
			t.Fatalf("U2 must be excluded, got %+v", got)
		}
	}

	// Empty owner slice excludes nothing (degenerate NOT IN () case): all three
	// messages surface, and the query stays valid SQL.
	got, err = d.ListStreamCandidatesSince(nil, 0, 100)
	require.NoError(t, err)
	if len(got) != 3 {
		t.Fatalf("empty owner slice must exclude nothing, want 3, got %+v", got)
	}
}

func TestListStreamCandidatesSince_SkipsAlreadyInboxed(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	insertMessage(t, d, "C1", "100.1", "U2", "hello")
	mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "100.1", SenderUserID: "U2", TriggerType: "mention"})

	got, err := d.ListStreamCandidatesSince([]string{"U1"}, 0, 100)
	require.NoError(t, err)
	if len(got) != 0 {
		t.Fatalf("already-inboxed message must not be a candidate, got %+v", got)
	}
}

func TestListStreamCandidatesSince_SkipsThreadWithPendingItem(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	// Realistic ingestion shape (internal/sync/message_sync.go): the thread
	// ROOT never has its own thread_ts set — only replies do.
	insertMessage(t, d, "C1", "100.1", "U2", "root of thread")
	insertMessageWithThread(t, d, "C1", "100.5", "100.1", "U2", "reply in thread")
	// A pending inbox item already exists for a REPLY in this thread
	// (e.g. from mention detection on the reply).
	mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "100.5", ThreadTS: "100.1", SenderUserID: "U2", TriggerType: "mention"})

	got, err := d.ListStreamCandidatesSince([]string{"U1"}, 0, 100)
	require.NoError(t, err)
	// Neither the root (100.1, matched via its own ts as the thread key) nor
	// the reply (100.5, matched via thread_ts) may surface as candidates.
	if len(got) != 0 {
		t.Fatalf("messages in a thread with a pending item must not be stream candidates, got %+v", got)
	}
}

func TestListStreamCandidatesSince_ExcludesDeletedAndSubtype(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, is_deleted) VALUES ('C1', '100.1', 'U2', 'deleted msg', 1)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text, subtype) VALUES ('C1', '100.2', 'U2', 'joined the channel', 'channel_join')`)
	require.NoError(t, err)

	got, err := d.ListStreamCandidatesSince([]string{"U1"}, 0, 100)
	require.NoError(t, err)
	if len(got) != 0 {
		t.Fatalf("deleted/subtyped messages must not be stream candidates, got %+v", got)
	}
}

func TestListStreamCandidatesSince_CapAndOrder(t *testing.T) {
	d := openTestDB(t)
	insertChannel(t, d, "C1", "public")
	for i := 1; i <= 5; i++ {
		insertMessage(t, d, "C1", fmt.Sprintf("10%d.0", i), "U2", "msg")
	}
	got, err := d.ListStreamCandidatesSince([]string{"U1"}, 0, 3)
	require.NoError(t, err)
	if len(got) != 3 || got[0].MessageTS != "101.0" || got[2].MessageTS != "103.0" {
		t.Fatalf("want oldest-first capped at 3, got %+v", got)
	}
}

func TestInboxCardLifecycle(t *testing.T) {
	d := openTestDB(t)
	actionID := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "1.1", SenderUserID: "U2", TriggerType: "mention"}) // actionable by default
	ambient1 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "2.1", SenderUserID: "U2", TriggerType: "stream"})
	ambient2 := mustCreateInboxItem(t, d, InboxItem{ChannelID: "C1", MessageTS: "3.1", SenderUserID: "U2", TriggerType: "stream"})
	for _, id := range []int64{ambient1, ambient2} {
		if err := d.SetInboxItemClass(id, "ambient"); err != nil {
			t.Fatal(err)
		}
	}

	need, err := d.ListItemsNeedingCards(1)
	if err != nil {
		t.Fatal(err)
	}
	if len(need) != 2 { // 1 actionable + 1 capped ambient
		t.Fatalf("want 2 items needing cards, got %d", len(need))
	}

	if err := d.SetInboxCard(int(actionID), "why", "digest", "draft"); err != nil {
		t.Fatal(err)
	}
	it, _ := d.GetInboxItem(actionID)
	if it.CardStatus != "ready" || it.WhyMatters != "why" || it.CardGeneratedAt == "" {
		t.Fatalf("card not persisted: %+v", it)
	}

	if err := d.MarkInboxCardFailed(int(ambient1)); err != nil {
		t.Fatal(err)
	}
	need, _ = d.ListItemsNeedingCards(5)
	// actionID is ready now; ambient1 failed (retryable) + ambient2 none
	if len(need) != 2 {
		t.Fatalf("failed card must stay retryable, got %d items", len(need))
	}
}

// Regression: dedup must not collapse unrelated items that happen to share a
// channel_id + thread_ts but represent different trigger types (e.g. an
// @mention and a DM both landing in the same thread). Each trigger type is a
// distinct signal to the user and must not silently disappear as a "dupe" of
// the other.
func TestDeduplicateThreadInboxItems_PreservesDifferentTriggerTypes(t *testing.T) {
	db := openTestDB(t)

	mentionID, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", ThreadTS: "1.0", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)
	dmID, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.2", ThreadTS: "1.0", SenderUserID: "U1", TriggerType: "dm"})
	require.NoError(t, err)

	deduped, err := db.DeduplicateThreadInboxItems()
	require.NoError(t, err)
	assert.Equal(t, 0, deduped, "different trigger types in the same thread must not be merged")

	mentionItem, err := db.GetInboxItemByID(int(mentionID))
	require.NoError(t, err)
	assert.Equal(t, "pending", mentionItem.Status)

	dmItem, err := db.GetInboxItemByID(int(dmID))
	require.NoError(t, err)
	assert.Equal(t, "pending", dmItem.Status)
}

// TestDeduplicateThreadInboxItems_NonThreadItemsNeverCollapse pins audit
// #112: every non-threaded item shares thread_ts = '', so without a
// thread_ts guard the dedup query's GROUP BY (channel_id, thread_ts,
// trigger_type) treats every plain-channel mention in the same channel as a
// duplicate of the others and collapses them all down to one. Non-thread
// items must never be touched by this dedup pass.
func TestDeduplicateThreadInboxItems_NonThreadItemsNeverCollapse(t *testing.T) {
	db := openTestDB(t)

	var ids []int64
	for i := 0; i < 5; i++ {
		id, err := db.CreateInboxItem(InboxItem{
			ChannelID:    "C1",
			MessageTS:    fmt.Sprintf("1.%d", i),
			ThreadTS:     "",
			SenderUserID: "U1",
			TriggerType:  "mention",
		})
		require.NoError(t, err)
		ids = append(ids, id)
	}

	deduped, err := db.DeduplicateThreadInboxItems()
	require.NoError(t, err)
	assert.Equal(t, 0, deduped, "non-thread items must never be deduplicated by this pass")

	for _, id := range ids {
		item, err := db.GetInboxItemByID(int(id))
		require.NoError(t, err)
		assert.Equal(t, "pending", item.Status, "item %d must survive", id)
	}
}

// Same trigger type in the same thread is still a genuine duplicate and must
// keep collapsing to the most recent item.
func TestDeduplicateThreadInboxItems_MergesSameTriggerType(t *testing.T) {
	db := openTestDB(t)

	firstID, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.1", ThreadTS: "1.0", SenderUserID: "U1", TriggerType: "mention"})
	require.NoError(t, err)
	secondID, err := db.CreateInboxItem(InboxItem{ChannelID: "C1", MessageTS: "1.2", ThreadTS: "1.0", SenderUserID: "U2", TriggerType: "mention"})
	require.NoError(t, err)

	deduped, err := db.DeduplicateThreadInboxItems()
	require.NoError(t, err)
	assert.Equal(t, 1, deduped)

	kept, err := db.GetInboxItemByID(int(secondID))
	require.NoError(t, err)
	assert.Equal(t, "pending", kept.Status)

	merged, err := db.GetInboxItemByID(int(firstID))
	require.NoError(t, err)
	assert.Equal(t, "resolved", merged.Status)
}
