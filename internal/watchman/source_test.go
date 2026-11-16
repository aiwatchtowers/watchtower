package watchman

import (
	"context"
	"strconv"
	"testing"
	"time"

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

func TestDBSources_CountSkips(t *testing.T) {
	for _, s := range DBSources() {
		c, ok := s.(SkipCounter)
		require.True(t, ok, s.Name())
		require.Zero(t, c.Skipped(), s.Name())
	}
}

// Unstamped rows become cursor marks with an empty decided_at; the cursor
// must round-trip them so the walk never stalls.
func TestDBSources_CursorRoundTripsEmptyStamp(t *testing.T) {
	d := openSourceDB(t)
	s := seedSession(t, d, 1, nil)
	want := map[string]bool{}
	for i := 0; i < 3; i++ {
		at := srcT0.Add(time.Duration(i) * time.Hour)
		want[strconv.FormatInt(seedPermission(t, d, s, 1, "Bash", "ls", "allowed", &at), 10)] = true
	}
	for i := 0; i < 3; i++ {
		seedPermission(t, d, s, 1, "Bash", "ls", "denied", nil) // decided, no stamp
	}

	src := &permissionSource{}
	seen := map[string]bool{}
	cur, done := "", false
	for i := 0; i < 10 && !done; i++ {
		var ps []db.WatchmanPrecedent
		var err error
		ps, cur, done, err = src.Next(context.Background(), d, 1, cur, 2)
		require.NoError(t, err, "cursor %q", cur)
		for _, k := range keys(ps) {
			require.False(t, seen[k], "repeated %s", k)
			seen[k] = true
		}
	}
	require.True(t, done)
	require.Equal(t, want, seen)
	require.Equal(t, 3, src.Skipped(), "each unstamped row counted once")

	ps, cur, done, err := src.Next(context.Background(), d, 1, cur, 2)
	require.NoError(t, err)
	require.Empty(t, ps)
	require.True(t, done)
	require.Equal(t, 3, src.Skipped(), "nothing counted twice")

	at := srcT0.Add(10 * time.Hour)
	fresh := seedPermission(t, d, s, 1, "Bash", "ls", "allowed", &at)
	ps, _, _, err = src.Next(context.Background(), d, 1, cur, 2)
	require.NoError(t, err)
	require.Equal(t, []string{strconv.FormatInt(fresh, 10)}, keys(ps))
}
