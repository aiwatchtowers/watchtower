package db

import (
	"database/sql"
	"fmt"
	"testing"

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
