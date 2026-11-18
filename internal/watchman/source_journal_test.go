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

func TestJournalSource_CorrectionWithoutTextIsSkipped(t *testing.T) {
	d := openSourceDB(t)
	at := srcT0.Add(time.Hour)
	seedJournalItem(t, d, 1, "sqlite", "corrected", "  ", &at)
	src := &journalSource{}
	ps, _, _, err := src.Next(context.Background(), d, 1, "", 50)
	require.NoError(t, err)
	require.Empty(t, ps)
	require.Equal(t, 1, src.Skipped())
}

func TestJournalSource_LearnStoresASearchablePrecedent(t *testing.T) {
	d, wb := learnDB(t)
	at := learnT0.Add(-time.Hour)
	id, _, err := d.QueueWatchmanItem(db.WatchmanItem{WorkbenchID: wb, Kind: "ask", RefKind: "ask", RefID: 7, Question: "Which cache should the importer use?"})
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE watchman_items SET state='done', outcome='answered', choice='sqlite', category='design', feedback='ok', feedback_at=? WHERE id=?`, stamp(at), id)
	require.NoError(t, err)
	st, err := Learn(context.Background(), d, wb, LearnOptions{
		Budget: 5 * time.Minute, Now: fixedNow, Sources: []Source{&journalSource{}}, Labeler: &fakeLabeler{label: CategoryDesign}, BatchSize: 5,
	})
	require.NoError(t, err)
	require.Equal(t, 1, st.BySource[SourceJournal])
	got, err := d.SearchWatchmanPrecedents(wb, CategoryDesign, "importer cache", learnT0.Add(time.Hour), nil, 5)
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "sqlite", got[0].Choice)
	require.Equal(t, SourceJournal, got[0].Source)
}
