package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/docs/guide"
	"watchtower/internal/db"
)

func TestGuideSourceChangedOnlyWhenHashMoves(t *testing.T) {
	ctx := context.Background()
	keys, next, done, err := guideSource{}.Changed(ctx, nil, "", testNow())
	require.NoError(t, err)
	assert.Equal(t, guideCursor(), next)
	assert.True(t, done)
	assert.Len(t, keys, len(guide.Pages()))
	assert.Contains(t, keys, "guide:features/inbox.md")

	keys, next, done, err = guideSource{}.Changed(ctx, nil, next, testNow())
	require.NoError(t, err)
	assert.Empty(t, keys)
	assert.Equal(t, guideCursor(), next)
	assert.True(t, done)
}

// A release build relinks every page: the cursor carries the link base.
func TestGuideSourceCursorCarriesLinkBase(t *testing.T) {
	assert.Contains(t, guideCursor(), guide.Hash())
	assert.Contains(t, guideCursor(), guide.BaseURL(guide.Version))
}

func TestGuideSourceBuild(t *testing.T) {
	ctx := context.Background()
	doc, err := guideSource{}.Build(ctx, nil, "guide:features/inbox.md")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "guide:features/inbox.md", doc.ID)
	assert.Equal(t, GuideSource, doc.Source)
	assert.Equal(t, guide.BaseURL(guide.Version)+"features/inbox.md", doc.Link)
	assert.True(t, doc.Time.IsZero())
	assert.Equal(t, map[string]string{"path": "features/inbox.md"}, doc.Anchor)
	var anchors []string
	for _, s := range doc.Sections {
		anchors = append(anchors, s.Anchor)
	}
	assert.Contains(t, anchors, "why-use-it")

	missing, err := guideSource{}.Build(ctx, nil, "guide:features/nope.md")
	require.NoError(t, err)
	assert.Nil(t, missing)
}

func TestSearchGuideNotPenalisedForAge(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	// Identical undated text in the guide and in another source: only the
	// other source gets the recency floor.
	for _, src := range []string{GuideSource, "idea"} {
		_, err := writeDoc(ctx, d, &Doc{
			ID: src + ":x", Source: src, Title: "doc " + src,
			Anchor: map[string]string{"k": "v"}, Sections: []Section{{Text: "quarterly infrastructure report"}},
		})
		require.NoError(t, err)
	}
	res, err := Search(ctx, d, Request{Queries: []string{"quarterly"}, Now: testNow()})
	require.NoError(t, err)
	require.Len(t, res.Hits, 2)
	scores := map[string]float64{}
	for _, h := range res.Hits {
		scores[h.Source] = h.score
	}
	// Equal bm25 ties by chunk id, so the guide may rank a step lower; it is
	// still not scaled down by the floor.
	assert.Greater(t, scores[GuideSource], scores["idea"])
}
