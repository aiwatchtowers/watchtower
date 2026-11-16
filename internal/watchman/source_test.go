package watchman

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestDBSources_Order(t *testing.T) {
	var names []string
	for _, s := range DBSources() {
		names = append(names, s.Name())
	}
	require.Equal(t, []string{"ask", "review", "spec", "permission"}, names)
}

func TestSourceCursor_RoundTrip(t *testing.T) {
	c := cursor{
		hi: &db.WatchmanMark{At: "2026-11-01T09:00:00.000Z", ID: 7, Sub: "ag:a,b|c"},
		lo: &db.WatchmanMark{At: "2026-10-01T09:00:00.000Z", ID: 3},
	}
	got, err := parseCursor(c.String())
	require.NoError(t, err)
	require.Equal(t, c, got)

	empty, err := parseCursor("")
	require.NoError(t, err)
	require.Equal(t, cursor{}, empty)
	require.Equal(t, "", empty.String())

	_, err = parseCursor("garbage")
	require.Error(t, err)
}

func TestSource_BadCursorIsAnError(t *testing.T) {
	d := openSourceDB(t)
	for _, s := range DBSources() {
		_, next, _, err := s.Next(context.Background(), d, 1, "x|y", 5)
		require.Error(t, err, s.Name())
		require.Equal(t, "x|y", next, s.Name())
	}
}
