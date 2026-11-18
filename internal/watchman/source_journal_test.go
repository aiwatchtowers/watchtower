package watchman

import (
	"context"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func seedJournalItem(t *testing.T, d *db.DB, ref int64, choice, feedback, text string, at *time.Time) int64 {
	t.Helper()
	id, _, err := d.QueueWatchmanItem(db.WatchmanItem{WorkbenchID: 1, Kind: "ask", RefKind: "ask", RefID: ref, Question: "Which cache should the importer use?"})
	require.NoError(t, err)
	var fbAt any
	if at != nil {
		fbAt = stamp(*at)
	}
	_, err = d.Exec(`UPDATE watchman_items SET state='done', outcome='answered', choice=?, category='design', feedback=?, feedback_text=?, feedback_at=? WHERE id=?`,
		choice, feedback, text, fbAt, id)
	require.NoError(t, err)
	return id
}

func TestJournalSource_OKBecomesPrecedent(t *testing.T) {
	d := openSourceDB(t)
	at := srcT0.Add(time.Hour)
	id := seedJournalItem(t, d, 1, "sqlite", "ok", "", &at)
	ps, _, _, err := (&journalSource{}).Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	require.Len(t, ps, 1)
	require.Equal(t, strconv.FormatInt(id, 10), ps[0].SourceKey)
	require.Equal(t, "journal", ps[0].Source)
	require.Equal(t, "sqlite", ps[0].Choice)
	require.Equal(t, "design", ps[0].Category)
	require.EqualValues(t, 1, ps[0].Weight)
	require.True(t, ps[0].DecidedAt.Equal(at))
}

func TestJournalSource_CorrectionWeighsMore(t *testing.T) {
	d := openSourceDB(t)
	at := srcT0.Add(time.Hour)
	seedJournalItem(t, d, 1, "sqlite", "corrected", "redis", &at)
	ps, _, _, err := (&journalSource{}).Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	require.Len(t, ps, 1)
	require.Equal(t, "redis", ps[0].Choice)
	require.EqualValues(t, 3, ps[0].Weight)
}

func TestJournalSource_UnreviewedItemIsNot(t *testing.T) {
	d := openSourceDB(t)
	seedJournalItem(t, d, 1, "sqlite", "", "", nil)
	ps, _, done, err := (&journalSource{}).Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	require.Empty(t, ps)
	require.True(t, done)
}
