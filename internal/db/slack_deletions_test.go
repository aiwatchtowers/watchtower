package db

import (
	"database/sql"
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTombstoneSlackMessages_BlanksRowAndChildren(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "1:C001", TS: "1758528000.000100", UserID: "1:U001",
		Text: "secret plan zebra", ThreadTS: sql.NullString{String: "1758527000.000100", Valid: true}}))
	require.NoError(t, d.UpsertMessage(Message{ChannelID: "1:C001", TS: "1758528000.000200", UserID: "1:U002", Text: "keep me"}))
	for _, q := range []string{
		`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES ('1:C001','1758528000.000100','1:U002','eyes')`,
		`INSERT INTO reactions (channel_id, message_ts, user_id, emoji) VALUES ('1:C001','1758528000.000200','1:U001','eyes')`,
		`INSERT INTO files (id, message_channel_id, message_ts, name) VALUES ('F1','1:C001','1758528000.000100','zebra.pdf')`,
		`INSERT INTO files (id, message_channel_id, message_ts, name) VALUES ('F2','1:C001','1758528000.000200','other.pdf')`,
	} {
		_, err := d.Exec(q)
		require.NoError(t, err)
	}
	_, err := d.CreateInboxItem(InboxItem{ChannelID: "1:C001", MessageTS: "1758528000.000100", SenderUserID: "1:U001",
		TriggerType: "mention", Snippet: "secret plan zebra", Context: "ctx zebra", RawText: "secret plan zebra"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, mentions)
		VALUES ('1:C001', '1758528000.000300', '1:U002', 'mention', 'newer',
		'[{"ts":"1758528000.000100","sender":"1:U001","trigger":"mention","text":"secret plan zebra"},{"ts":"1758528000.000300","sender":"1:U002","trigger":"mention","text":"newer"}]')`)
	require.NoError(t, err)

	n, err := d.TombstoneSlackMessages([]SlackMessageKey{{ChannelID: "1:C001", TS: "1758528000.000100"}})
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	var text, raw, user, threadTS string
	var deleted int
	require.NoError(t, d.QueryRow(`SELECT text, raw_json, user_id, thread_ts, is_deleted FROM messages
		WHERE channel_id = '1:C001' AND ts = '1758528000.000100'`).Scan(&text, &raw, &user, &threadTS, &deleted))
	assert.Equal(t, "", text)
	assert.Equal(t, "{}", raw)
	assert.Equal(t, "1:U001", user)
	assert.Equal(t, "1758527000.000100", threadTS)
	assert.Equal(t, 1, deleted)

	count := func(q string) int {
		var c int
		require.NoError(t, d.QueryRow(q).Scan(&c))
		return c
	}
	assert.Equal(t, 0, count(`SELECT COUNT(*) FROM reactions WHERE message_ts = '1758528000.000100'`))
	assert.Equal(t, 1, count(`SELECT COUNT(*) FROM reactions WHERE message_ts = '1758528000.000200'`))
	assert.Equal(t, 0, count(`SELECT COUNT(*) FROM files WHERE id = 'F1'`))
	assert.Equal(t, 1, count(`SELECT COUNT(*) FROM files WHERE id = 'F2'`))

	// The inbox item stays; its copies of the text are blanked.
	var snippet, ctx, rawText string
	require.NoError(t, d.QueryRow(`SELECT snippet, context, raw_text FROM inbox_items WHERE message_ts = '1758528000.000100'`).
		Scan(&snippet, &ctx, &rawText))
	assert.Equal(t, []string{"", "", ""}, []string{snippet, ctx, rawText})
	var mentions, newerSnippet string
	require.NoError(t, d.QueryRow(`SELECT mentions, snippet FROM inbox_items WHERE message_ts = '1758528000.000300'`).Scan(&mentions, &newerSnippet))
	assert.NotContains(t, mentions, "zebra")
	assert.Contains(t, mentions, `"newer"`)
	assert.Equal(t, "newer", newerSnippet)

	hits, err := d.SearchMessages("zebra", SearchOpts{})
	require.NoError(t, err)
	assert.Empty(t, hits)
	hits, err = d.SearchMessages("keep", SearchOpts{})
	require.NoError(t, err)
	assert.Len(t, hits, 1)

	// A second call is a no-op on the tombstone.
	n, err = d.TombstoneSlackMessages([]SlackMessageKey{{ChannelID: "1:C001", TS: "1758528000.000100"}})
	require.NoError(t, err)
	assert.Equal(t, 0, n)
}

func TestLiveSlackMessageKeys_Scope(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO users (id, name, is_bot, is_bot_override) VALUES
		('1:U001', 'alice', 0, NULL), ('1:B001', 'bot', 1, NULL),
		('1:B002', 'forced human', 1, 0), ('1:U002', 'forced bot', 0, 1)`)
	require.NoError(t, err)
	// 1758528000 = 2026-09-22T08:00:00Z
	for _, m := range []Message{
		{ChannelID: "1:C001", TS: "1758528000.000100", UserID: "1:U001", Text: "in"},
		{ChannelID: "1:C002", TS: "1758531600.000100", UserID: "1:U001", Text: "in too"},
		{ChannelID: "1:C002", TS: "1758531700.000100", UserID: "1:U009", Text: "no users row: unknown author"},
		{ChannelID: "1:C002", TS: "1758531800.000100", UserID: "1:B002", Text: "override says human"},
		{ChannelID: "1:C001", TS: "1758528050.000100", UserID: "1:B001", Text: "bot"},
		{ChannelID: "1:C001", TS: "1758528060.000100", UserID: "1:U002", Text: "override says bot"},
		{ChannelID: "1:C001", TS: "1758528070.000100", Text: "app post, no user"},
		{ChannelID: "1:C001", TS: "1758528100.000100", UserID: "1:U001", Text: "joined", Subtype: "channel_join"},
		{ChannelID: "1:C001", TS: "1758528200.000100", UserID: "1:U001", Text: "gone", IsDeleted: true},
		{ChannelID: "2:C001", TS: "1758528000.000100", UserID: "2:U001", Text: "other account"},
		{ChannelID: "1:C001", TS: "1758400000.000100", UserID: "1:U001", Text: "before"},
		{ChannelID: "1:C001", TS: "1758600000.000100", UserID: "1:U001", Text: "at or after to"},
		{ChannelID: "12:C001", TS: "1758528000.000100", UserID: "12:U001", Text: "account 12"},
	} {
		require.NoError(t, d.UpsertMessage(m))
	}
	keys, err := d.LiveSlackMessageKeys(1, 1758500000, 1758600000)
	require.NoError(t, err)
	assert.ElementsMatch(t, []SlackMessageKey{
		{ChannelID: "1:C001", TS: "1758528000.000100"},
		{ChannelID: "1:C002", TS: "1758531600.000100"},
		{ChannelID: "1:C002", TS: "1758531800.000100"},
	}, keys)
}

func TestTombstoneSlackMessages_BatchesOverTwoHundredKeys(t *testing.T) {
	d := openTestDB(t)
	const n = 450
	keys := make([]SlackMessageKey, 0, n)
	for i := range n {
		k := SlackMessageKey{ChannelID: "1:C001", TS: fmt.Sprintf("%d.000100", 1758528000+i)}
		require.NoError(t, d.UpsertMessage(Message{ChannelID: k.ChannelID, TS: k.TS, UserID: "1:U001", Text: "x"}))
		keys = append(keys, k)
	}
	got, err := d.TombstoneSlackMessages(keys)
	require.NoError(t, err)
	assert.Equal(t, n, got)
	var deleted int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM messages WHERE is_deleted = 1`).Scan(&deleted))
	assert.Equal(t, n, deleted)
}

func TestNextSlackSweepDay(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateSlackAccount(SlackAccount{})
	require.NoError(t, err)
	ch := fmt.Sprintf("%d:C001", acct)
	at := func(day, hour int) string { // 2026-09-<day> <hour>:00Z
		return fmt.Sprintf("%d.000100", time.Date(2026, 9, day, hour, 0, 0, 0, time.UTC).Unix())
	}
	for _, m := range []Message{
		{ChannelID: ch, TS: at(10, 9), UserID: "U001", Text: "plain"},
		{ChannelID: ch, TS: at(5, 9), UserID: "U001", Text: "plain"},
		{ChannelID: ch, TS: at(8, 9), UserID: "U001", Text: "joined", Subtype: "channel_join"},
		{ChannelID: ch, TS: at(7, 9), UserID: "U001", Text: "", IsDeleted: true},
		{ChannelID: fmt.Sprintf("%d:C001", acct+1), TS: at(9, 9), UserID: "U001", Text: "other account"},
	} {
		require.NoError(t, d.UpsertMessage(m))
	}
	midnight := func(day int) float64 { return float64(time.Date(2026, 9, day, 0, 0, 0, 0, time.UTC).Unix()) }

	day, ok, err := d.NextSlackSweepDay(acct, midnight(22))
	require.NoError(t, err)
	assert.True(t, ok)
	assert.Equal(t, "2026-09-10", day)

	day, ok, err = d.NextSlackSweepDay(acct, midnight(10)) // strictly before
	require.NoError(t, err)
	assert.True(t, ok)
	assert.Equal(t, "2026-09-05", day, "tombstone-only, subtype-only and other-account days are skipped")

	_, ok, err = d.NextSlackSweepDay(acct, midnight(5))
	require.NoError(t, err)
	assert.False(t, ok)
}

func TestSlackDeletionSweepDay_RoundTrip(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateSlackAccount(SlackAccount{})
	require.NoError(t, err)
	day, err := d.SlackDeletionSweepDay(acct)
	require.NoError(t, err)
	assert.Empty(t, day)
	require.NoError(t, d.SetSlackDeletionSweepDay(acct, "2026-09-10"))
	day, err = d.SlackDeletionSweepDay(acct)
	require.NoError(t, err)
	assert.Equal(t, "2026-09-10", day)
	assert.Error(t, d.SetSlackDeletionSweepDay(acct+99, "2026-09-10"))
}
