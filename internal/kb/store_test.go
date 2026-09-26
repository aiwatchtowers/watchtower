package kb

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func testNow() time.Time { return time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC) }

func testDoc() *Doc {
	return &Doc{
		ID: "idea:1", Source: "idea", Title: "Релиз", Meta: "active",
		Time: time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC), Anchor: map[string]string{"idea_id": "1"},
		Sections: []Section{{Text: "договорённость о релизе", Anchor: "1"}},
	}
}

func TestWriteDoc_InsertsSkipsUnchangedReplacesChanged(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	w, err := writeDoc(ctx, d, testDoc())
	require.NoError(t, err)
	assert.True(t, w)

	w, err = writeDoc(ctx, d, testDoc())
	require.NoError(t, err)
	assert.False(t, w, "unchanged content must not be rewritten")

	doc := testDoc()
	doc.Sections = append(doc.Sections, Section{Text: "второй", Anchor: "2"})
	w, err = writeDoc(ctx, d, doc)
	require.NoError(t, err)
	assert.True(t, w)

	var body string
	require.NoError(t, d.QueryRow(`SELECT body FROM kb_chunks WHERE doc_id='idea:1'`).Scan(&body))
	assert.Equal(t, "договоренность о релизе\nвторой", body, "text is normalized (ё→е)")
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_fts WHERE kb_fts MATCH '"второй"'`).Scan(&n))
	assert.Equal(t, 1, n)
	require.NoError(t, d.QueryRow(`SELECT chunk_count FROM kb_documents WHERE id='idea:1'`).Scan(&n))
	assert.Equal(t, 1, n)
}

// A document with blank sections but a title is indexed as title-only.
func TestWriteDoc_TitleOnlyDocIndexesTitle(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	_, err := writeDoc(ctx, d, testDoc())
	require.NoError(t, err)
	titleOnly := testDoc()
	titleOnly.Sections = []Section{{Text: "  "}}
	w, err := writeDoc(ctx, d, titleOnly)
	require.NoError(t, err)
	assert.True(t, w)
	var body string
	var n int
	require.NoError(t, d.QueryRow(`SELECT body FROM kb_chunks WHERE doc_id = 'idea:1'`).Scan(&body))
	assert.Equal(t, "Релиз", body)
	require.NoError(t, d.QueryRow(`SELECT chunk_count FROM kb_documents WHERE id = 'idea:1'`).Scan(&n))
	assert.Equal(t, 1, n)
}

func TestWriteDoc_EmptyDocDeletes(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	_, err := writeDoc(ctx, d, testDoc())
	require.NoError(t, err)
	empty := testDoc()
	empty.Title = " "
	empty.Sections = nil
	w, err := writeDoc(ctx, d, empty)
	require.NoError(t, err)
	assert.False(t, w)
	var n int
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_documents`).Scan(&n))
	assert.Equal(t, 0, n)
	require.NoError(t, d.QueryRow(`SELECT count(*) FROM kb_chunks`).Scan(&n))
	assert.Equal(t, 0, n)
}

func TestSourceState_RoundTrip(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	st, err := loadState(ctx, d, "slack")
	require.NoError(t, err)
	assert.Equal(t, sourceState{}, st)
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	require.NoError(t, saveCursor(ctx, d, "slack", "42", now))
	require.NoError(t, saveReconciled(ctx, d, "slack", now))
	st, err = loadState(ctx, d, "slack")
	require.NoError(t, err)
	assert.Equal(t, "42", st.Cursor)
	assert.Equal(t, "2026-09-26T12:00:00Z", st.LastReconciledAt)
	assert.Equal(t, "2026-09-26T12:00:00Z", st.UpdatedAt)
}

func TestDocIDs(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	_, err := writeDoc(ctx, d, testDoc())
	require.NoError(t, err)
	ids, err := docIDs(ctx, d, "idea")
	require.NoError(t, err)
	assert.Equal(t, map[string]bool{"idea:1": true}, ids)
	pref, err := docIDsWithPrefix(ctx, d, "idea:")
	require.NoError(t, err)
	assert.Equal(t, []string{"idea:1"}, pref)
}

func TestDocIDsWithPrefix_MultibytePrefix(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	doc := testDoc()
	doc.ID = "идея:1"
	_, err := writeDoc(ctx, d, doc)
	require.NoError(t, err)
	pref, err := docIDsWithPrefix(ctx, d, "идея:")
	require.NoError(t, err)
	assert.Equal(t, []string{"идея:1"}, pref, "prefix length must be counted in runes, not bytes")
}

func TestWriteDoc_NilAnchorStoredAsEmptyObject(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	doc := testDoc()
	doc.Anchor = nil
	_, err := writeDoc(ctx, d, doc)
	require.NoError(t, err)
	var anchorJSON string
	require.NoError(t, d.QueryRow(`SELECT anchor_json FROM kb_documents WHERE id='idea:1'`).Scan(&anchorJSON))
	assert.Equal(t, "{}", anchorJSON)
}

func TestDocIDsWithPrefix_RangeBoundaries(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	for _, id := range []string{"digest:5:0", "digest:5:1", "digest:55:0", "digest:6:0", "идея:1", "иж:1"} {
		doc := testDoc()
		doc.ID = id
		_, err := writeDoc(ctx, d, doc)
		require.NoError(t, err)
	}
	got, err := docIDsWithPrefix(ctx, d, "digest:5:")
	require.NoError(t, err)
	assert.Equal(t, []string{"digest:5:0", "digest:5:1"}, got)
	got, err = docIDsWithPrefix(ctx, d, "иде")
	require.NoError(t, err)
	assert.Equal(t, []string{"идея:1"}, got, "prefix ending in a multibyte rune excludes its successor rune")
}

func TestPrefixUpperBound(t *testing.T) {
	up, ok := prefixUpperBound("digest:")
	assert.True(t, ok)
	assert.Equal(t, "digest;", up)
	up, ok = prefixUpperBound("a\xff")
	assert.True(t, ok)
	assert.Equal(t, "b", up)
	_, ok = prefixUpperBound("")
	assert.False(t, ok)
}
