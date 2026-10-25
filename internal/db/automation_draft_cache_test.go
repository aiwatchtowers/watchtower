package db

import (
	"fmt"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestAppendDraftCache_KeepsNewestFive(t *testing.T) {
	d := openTestDB(t)
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
