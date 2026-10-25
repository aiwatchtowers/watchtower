package db

import (
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// seedConversations inserts chat conversations with the given ids.
func seedConversations(t *testing.T, d *DB, ids ...int64) {
	t.Helper()
	for _, id := range ids {
		_, err := d.Exec(`INSERT INTO chat_conversations (id, title, created_at, updated_at) VALUES (?, '', 1, 1)`, id)
		require.NoError(t, err)
	}
}

func TestAppendDraftCache_KeepsNewestFive(t *testing.T) {
	d := openTestDB(t)
	seedConversations(t, d, 7, 8)
	at := time.Date(2026, 10, 25, 9, 0, 0, 0, time.UTC)
	for i := range 7 {
		require.NoError(t, d.AppendDraftCache(7, fmt.Sprintf(`{"n":%d}`, i), at.Add(time.Duration(i)*time.Minute), 5))
	}
	require.NoError(t, d.AppendDraftCache(8, `{"other":true}`, at, 5))

	got, err := d.DraftCache(7)
	require.NoError(t, err)
	require.Equal(t, []string{`{"n":2}`, `{"n":3}`, `{"n":4}`, `{"n":5}`, `{"n":6}`}, got,
		"the newest five, oldest first; the last two appends at the end")
	other, err := d.DraftCache(8)
	require.NoError(t, err)
	require.Equal(t, []string{`{"other":true}`}, other, "conversations are kept apart")
}

func TestDeleteDraftCache(t *testing.T) {
	d := openTestDB(t)
	seedConversations(t, d, 7, 8)
	at := time.Now()
	require.NoError(t, d.AppendDraftCache(7, `{"n":1}`, at, 5))
	require.NoError(t, d.AppendDraftCache(8, `{"n":2}`, at, 5))
	require.NoError(t, d.DeleteDraftCache(7))
	got, err := d.DraftCache(7)
	require.NoError(t, err)
	require.Empty(t, got)
	other, err := d.DraftCache(8)
	require.NoError(t, err)
	require.Len(t, other, 1)
}

// Deleting a conversation, from Go or the Desktop, drops its draft rows.
func TestDraftCache_GoesWithItsConversation(t *testing.T) {
	d := openTestDB(t)
	seedConversations(t, d, 7)
	require.NoError(t, d.AppendDraftCache(7, `{"n":1}`, time.Now(), 5))
	_, err := d.Exec(`DELETE FROM chat_conversations WHERE id = 7`)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM automation_draft_cache`).Scan(&n))
	require.Zero(t, n)
}

func TestImportDraftCache_OnceAndOnlyIntoAnEmptyCache(t *testing.T) {
	d := openTestDB(t)
	seedConversations(t, d, 7)
	at := time.Now()
	entries := []DraftCacheImport{{`{"n":1}`, at}, {`{"n":2}`, at}}
	ok, err := d.ImportDraftCache(7, entries, 5)
	require.NoError(t, err)
	require.True(t, ok)
	ok, err = d.ImportDraftCache(7, entries, 5)
	require.NoError(t, err)
	require.False(t, ok, "a conversation that has rows is skipped")
	got, err := d.DraftCache(7)
	require.NoError(t, err)
	require.Equal(t, []string{`{"n":1}`, `{"n":2}`}, got)

	_, err = d.ImportDraftCache(99, entries, 5)
	require.ErrorIs(t, err, ErrDraftCacheNoConversation)
}
