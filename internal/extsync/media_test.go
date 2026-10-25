package extsync

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// mediaCall is one MediaRecorder call.
type mediaCall struct {
	extID     string
	refs      []MediaRef
	contentAt time.Time
}

// dbRecorder records through db.RecordMedia (images and links replaced), as
// the production recorder does, and keeps every call.
func dbRecorder(calls *[]mediaCall) MediaRecorder {
	return func(ctx context.Context, q Queryer, sourceID int64, extID string, refs []MediaRef, contentAt time.Time) error {
		*calls = append(*calls, mediaCall{extID, refs, contentAt})
		found := make([]db.MediaFound, 0, len(refs))
		for _, r := range refs {
			found = append(found, db.MediaFound{Kind: r.Kind, Locator: r.Locator, FetchURL: r.URL, Name: r.Name, Anchor: r.Anchor})
		}
		_, err := db.RecordMedia(ctx, q, db.MediaParent{Kind: "confluence", ExtSourceID: sourceID, ExtID: extID, ContentAt: contentAt},
			found, "image", "link")
		return err
	}
}

func mediaLocators(t *testing.T, d *db.DB, extID string) []string {
	t.Helper()
	rows, err := d.Query(`SELECT kind || ' ' || locator FROM media_items WHERE ext_id = ? ORDER BY id`, extID)
	require.NoError(t, err)
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		require.NoError(t, rows.Scan(&s))
		out = append(out, s)
	}
	require.NoError(t, rows.Err())
	return out
}

func newMediaDB(t *testing.T) (*db.DB, db.ExtSource) {
	t.Helper()
	d, src := newSourceDB(t)
	require.NoError(t, d.SetMediaStartAt(time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)))
	return d, src
}

// The recorder runs in the page's write transaction: a failing recorder
// rolls the page back (no document, no cursor), a working one records the
// page's media with the version's modified time.
func TestEngine_RecordsPageMediaInWriteTx(t *testing.T) {
	d, src := newMediaDB(t)
	f := newFake()
	f.addPage("p1", 1, t0)
	f.find("p1").item.Media = []MediaRef{{Kind: "image", Locator: "att:a.png", Name: "a.png"}}

	boom := errors.New("recorder failed")
	e := New(d, Options{Media: func(context.Context, Queryer, int64, string, []MediaRef, time.Time) error { return boom }})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.ErrorIs(t, err, boom)
	assert.Zero(t, countDocs(t, d, src.ID), "the page is rolled back with its media")
	assert.Empty(t, loadSource(t, d).PageCursor, "the batch's cursor is rolled back too")

	var calls []mediaCall
	e = New(d, Options{Media: dbRecorder(&calls)})
	e.SetFetcher(src.JiraAccountID, f)
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, countDocs(t, d, src.ID))
	require.Len(t, calls, 1)
	assert.Equal(t, "p1", calls[0].extID)
	assert.True(t, t0.Equal(calls[0].contentAt), "content time = the version's modified time")
	assert.Equal(t, []string{"image att:a.png"}, mediaLocators(t, d, "p1"))
}

// An image attachment records one {image, attachment} item of its own
// document at its created time; another attachment records none.
func TestEngine_ImageAttachmentRecorded(t *testing.T) {
	d, src := newMediaDB(t)
	f := newFake()
	f.addPage("p1", 1, t0)
	f.addAttachment("a-img", "p1", 1, t0.Add(time.Hour), "shot.png", "image/png", []byte("png bytes"), -1)
	created := t0.Add(-time.Hour)
	f.find("a-img").item.Created = created
	f.addAttachment("a-txt", "p1", 1, t0, "notes.txt", "text/plain", []byte("hello"), -1)

	var calls []mediaCall
	e := New(d, Options{Extractor: newFakeExtractor(), Media: dbRecorder(&calls)})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)

	assert.Equal(t, []string{"image attachment"}, mediaLocators(t, d, "a-img"))
	assert.Empty(t, mediaLocators(t, d, "a-txt"))
	for _, c := range calls {
		if c.extID == "a-img" {
			assert.True(t, created.Equal(c.contentAt), "content time = the attachment's created time")
			assert.Equal(t, []MediaRef{{Kind: "image", Locator: "attachment", Name: "shot.png"}}, c.refs)
		}
	}
	var name string
	require.NoError(t, d.QueryRow(`SELECT name FROM media_items WHERE ext_id = 'a-img'`).Scan(&name))
	assert.Equal(t, "shot.png", name)
}

// A page edit replaces the page's images and links: a link no longer named
// goes, a kept one keeps its row, a new one is added.
func TestEngine_PageEditReplacesLinks(t *testing.T) {
	d, src := newMediaDB(t)
	f := newFake()
	f.addPage("p1", 1, t0)
	f.find("p1").item.Media = []MediaRef{
		{Kind: "link", Locator: "url:https://example.com/a", URL: "https://example.com/a"},
		{Kind: "link", Locator: "url:https://example.com/b", URL: "https://example.com/b"},
		{Kind: "image", Locator: "att:old.png", Name: "old.png"},
	}
	var calls []mediaCall
	e := New(d, Options{Media: dbRecorder(&calls)})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	var keptID int64
	require.NoError(t, d.QueryRow(`SELECT id FROM media_items WHERE locator = 'url:https://example.com/b'`).Scan(&keptID))

	f.mutate("p1", 2, t0.Add(time.Hour))
	f.find("p1").item.Media = []MediaRef{
		{Kind: "link", Locator: "url:https://example.com/b", URL: "https://example.com/b"},
		{Kind: "link", Locator: "url:https://example.com/c", URL: "https://example.com/c"},
	}
	_, err = e.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"link url:https://example.com/b", "link url:https://example.com/c"}, mediaLocators(t, d, "p1"))
	var id int64
	require.NoError(t, d.QueryRow(`SELECT id FROM media_items WHERE locator = 'url:https://example.com/b'`).Scan(&id))
	assert.Equal(t, keptID, id, "a kept link keeps its row (and its description)")
	assert.True(t, t0.Add(time.Hour).Equal(calls[len(calls)-1].contentAt), "the edit records at the new version's time")
}

// storedTexts reads the document's ok image media text (never a link
// summary, never a row still pending).
func TestStoredTexts_IncludesOKImageMediaOnly(t *testing.T) {
	d, src := newMediaDB(t)
	f := newFake()
	f.addPage("p1", 1, t0)
	f.find("p1").item.Media = []MediaRef{
		{Kind: "image", Locator: "att:a.png", Name: "a.png"},
		{Kind: "image", Locator: "att:b.png", Name: "b.png"},
		{Kind: "link", Locator: "url:https://example.com/a", URL: "https://example.com/a"},
	}
	var calls []mediaCall
	e := New(d, Options{Media: dbRecorder(&calls)})
	e.SetFetcher(src.JiraAccountID, f)
	_, err := e.Run(context.Background())
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE media_items SET status = 'ok', title = 'IMG-T', body = 'IMG-B', image_text = 'IMG-X' WHERE locator = 'att:a.png'`)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE media_items SET title = 'PEND' WHERE locator = 'att:b.png'`)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE media_items SET status = 'ok', title = 'LINK-T', body = 'LINK-B' WHERE kind = 'link'`)
	require.NoError(t, err)

	texts, err := storedTexts(context.Background(), d, src.ID, "p1")
	require.NoError(t, err)
	assert.Contains(t, texts, "IMG-T")
	assert.Contains(t, texts, "IMG-B")
	assert.Contains(t, texts, "IMG-X")
	assert.NotContains(t, texts, "PEND")
	assert.NotContains(t, texts, "LINK-T")
	assert.NotContains(t, texts, "LINK-B")

	var got []string
	require.NoError(t, RelinkDocument(context.Background(), d, func(_ context.Context, _ Queryer, ref string, texts ...string) error {
		got = append([]string{ref}, texts...)
		return nil
	}, "confluence", src.ID, "p1"))
	require.NotEmpty(t, got)
	assert.Equal(t, docRef("confluence", src.ID, "p1"), got[0])
	assert.Contains(t, got, "IMG-X")
	assert.NoError(t, RelinkDocument(context.Background(), d, nil, "confluence", src.ID, "p1"), "nil relink is a no-op")
}
