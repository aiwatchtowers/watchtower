package db

import (
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func mustMentions(t *testing.T, raw string) []InboxMention {
	t.Helper()
	list, ok := ParseInboxMentions(raw)
	require.True(t, ok, "mentions %q", raw)
	return list
}

func TestPackInboxMentions_DedupOrderTruncateCap(t *testing.T) {
	var in []InboxMention
	for i := 25; i >= 1; i-- {
		in = append(in, InboxMention{TS: fmt.Sprintf("%d.0", i), Trigger: "mention", Text: "m"})
	}
	in = append(in, InboxMention{TS: "25.0", Text: "dup"}, InboxMention{TS: "26.0", Text: strings.Repeat("x", 400)})
	raw, dropped := PackInboxMentions(in)
	list := mustMentions(t, raw)
	require.Len(t, list, InboxMentionsKeep)
	assert.Equal(t, 6, dropped, "26 distinct, 20 kept")
	assert.Equal(t, "7.0", list[0].TS, "oldest first, the newest kept")
	assert.Equal(t, "26.0", list[19].TS)
	assert.Equal(t, "m", list[18].Text, "a duplicate ts keeps the first entry")
	assert.Equal(t, InboxMentionTextRunes+1, len([]rune(list[19].Text)), "one truncation length (+ ellipsis)")
}

func TestInboxMentionCountLabel(t *testing.T) {
	ms := []InboxMention{{Trigger: "mention"}, {Trigger: "mention"}}
	assert.Equal(t, "5 mentions", InboxMentionCountLabel(ms, 3))
	assert.Equal(t, "3 messages", InboxMentionCountLabel(append(ms, InboxMention{Trigger: "reaction"}), 0))
}

// AppendInboxMentions seeds a pre-column row with its own message, skips a
// ts already listed, keeps the list oldest first, and leaves the top-level
// text alone when the appended message is older than the row's own.
func TestAppendInboxMentions_SeedDedupOrder(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateInboxItem(InboxItem{ChannelID: "1:C1", MessageTS: "200.0", SenderUserID: "1:U1",
		TriggerType: "mention", Snippet: "own"})
	require.NoError(t, err)

	grew, err := d.AppendInboxMentions(int(id), InboxItem{MessageTS: "100.0", SenderUserID: "1:U2", Snippet: "older"},
		[]InboxMention{{TS: "100.0", SenderID: "1:U2", Text: "older"}, {TS: "200.0", SenderID: "1:U1", Text: "dup"}})
	require.NoError(t, err)
	assert.True(t, grew)

	it, err := d.GetInboxItemByID(int(id))
	require.NoError(t, err)
	list := mustMentions(t, it.Mentions)
	require.Len(t, list, 2)
	assert.Equal(t, "100.0", list[0].TS)
	assert.Equal(t, "own", list[1].Text, "the seeded row message wins over a duplicate ts")
	assert.Equal(t, "mention", list[1].Trigger, "the seed carries the row's trigger")
	assert.Equal(t, "200.0", it.MessageTS, "an older message does not take over the top-level text")
	assert.Equal(t, "own", it.Snippet)
}

// Nothing new — the row is left exactly as it was: still read, no bump.
func TestAppendInboxMentions_NoGrowthWritesNothing(t *testing.T) {
	d := openTestDB(t)
	raw, _ := PackInboxMentions([]InboxMention{{TS: "100.0", Trigger: "mention", Text: "a"}, {TS: "200.0", Trigger: "mention", Text: "b"}})
	id, err := d.CreateInboxItem(InboxItem{ChannelID: "1:C1", MessageTS: "200.0", SenderUserID: "1:U1",
		TriggerType: "mention", Snippet: "b", Mentions: raw})
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE inbox_items SET read_at = 'R', updated_at = 'U' WHERE id = ?`, id)
	require.NoError(t, err)

	grew, err := d.AppendInboxMentions(int(id), InboxItem{MessageTS: "200.0"}, []InboxMention{{TS: "100.0"}, {TS: "200.0"}})
	require.NoError(t, err)
	assert.False(t, grew)
	var readAt, updatedAt, mentionedAt string
	require.NoError(t, d.QueryRow(`SELECT read_at, updated_at, mentioned_at FROM inbox_items WHERE id = ?`, id).Scan(&readAt, &updatedAt, &mentionedAt))
	assert.Equal(t, "R", readAt)
	assert.Equal(t, "U", updatedAt)
	assert.Empty(t, mentionedAt)
}

// A full list counts what falls off; a re-scanned message older than the
// oldest kept one is not counted twice.
func TestAppendInboxMentions_CapAndEarlier(t *testing.T) {
	d := openTestDB(t)
	var seed []InboxMention
	for i := 1; i <= InboxMentionsKeep; i++ {
		seed = append(seed, InboxMention{TS: fmt.Sprintf("%d.0", i), Trigger: "mention"})
	}
	raw, _ := PackInboxMentions(seed)
	id, err := d.CreateInboxItem(InboxItem{ChannelID: "1:C1", MessageTS: "20.0", SenderUserID: "1:U1",
		TriggerType: "mention", Mentions: raw})
	require.NoError(t, err)

	grew, err := d.AppendInboxMentions(int(id), InboxItem{MessageTS: "21.0"}, []InboxMention{{TS: "21.0", Trigger: "mention"}})
	require.NoError(t, err)
	assert.True(t, grew)
	it, err := d.GetInboxItemByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, 1, it.MentionsEarlier)
	assert.Equal(t, "2.0", mustMentions(t, it.Mentions)[0].TS)
	assert.Equal(t, "21.0", it.MessageTS)

	grew, err = d.AppendInboxMentions(int(id), InboxItem{MessageTS: "1.0"}, []InboxMention{{TS: "1.0"}})
	require.NoError(t, err)
	assert.False(t, grew, "the message that fell off is not counted again")
}

// A malformed list is reseeded from the row instead of failing the fold.
func TestAppendInboxMentions_MalformedListReseeds(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateInboxItem(InboxItem{ChannelID: "1:C1", MessageTS: "100.0", SenderUserID: "1:U1",
		TriggerType: "mention", Snippet: "own", Mentions: "not json"})
	require.NoError(t, err)
	grew, err := d.AppendInboxMentions(int(id), InboxItem{MessageTS: "200.0", Snippet: "new"}, []InboxMention{{TS: "200.0", Text: "new"}})
	require.NoError(t, err)
	assert.True(t, grew)
	it, err := d.GetInboxItemByID(int(id))
	require.NoError(t, err)
	list := mustMentions(t, it.Mentions)
	require.Len(t, list, 2)
	assert.Equal(t, "own", list[0].Text)
}

// A malformed list never fails a detector query: the dedupe clause reads it
// as empty.
func TestFindPendingMentions_MalformedMentionsDoesNotFail(t *testing.T) {
	d := openTestDB(t)
	_, err := d.CreateInboxItem(InboxItem{ChannelID: "1:C1", MessageTS: "1.0", SenderUserID: "1:U1",
		TriggerType: "mention", Mentions: "not json"})
	require.NoError(t, err)
	_, err = d.FindPendingMentions(1, "U_ME", 0)
	require.NoError(t, err)
}

// Catch-Up gathers a channel item by the time of its newest folded message,
// not only its creation, lists every message in the body, and the ack marks
// it read by the same instant.
func TestCatchupInbox_AccumulatedItemByMentionedAt(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO users (id, name, display_name) VALUES ('1:U1', 'ann', 'Ann'), ('1:U2', 'bob', 'Bob')`)
	require.NoError(t, err)
	raw, _ := PackInboxMentions([]InboxMention{
		{TS: "1.0", SenderID: "1:U1", Trigger: "mention", Text: "budget?"},
		{TS: "2.0", SenderID: "1:U2", Trigger: "mention", Text: "deck?"},
	})
	// Created before the window (unix 1000..2000), folded into inside it.
	_, err = d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, status, item_class, mentions, created_at, mentioned_at) VALUES
		('1:C1', '2.0', '1:U2', 'mention', 'deck?', 'pending', 'actionable', ?, '1970-01-01T00:01:00Z', '1970-01-01T00:20:00Z')`, raw)
	require.NoError(t, err)

	items, err := d.ListCatchupInbox(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Contains(t, items[0].Meta, "2 mentions")
	assert.Equal(t, "Ann: budget?\nBob: deck?", items[0].Body)

	recapID, err := d.InsertCatchupRecap(1000, 2000, 0)
	require.NoError(t, err)
	require.NoError(t, d.AcknowledgeCatchupWindow(recapID, 1000, 2000))
	var readAt string
	require.NoError(t, d.QueryRow(`SELECT COALESCE(read_at,'') FROM inbox_items`).Scan(&readAt))
	assert.NotEmpty(t, readAt)
}
