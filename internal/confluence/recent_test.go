package confluence

import (
	"context"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func recentRow(key, status string) map[string]any {
	return map[string]any{"id": "1", "type": "page", "status": status, "space": map[string]any{"key": key}}
}

// TestRecentSpaceKeys_DistinctVisibleInOrder: the spaces of the user's own
// and recently viewed content, newest first, each once, trashed rows
// skipped, following the cursor.
func TestRecentSpaceKeys_DistinctVisibleInOrder(t *testing.T) {
	api := newFakeAPI(t)
	api.prepend(
		route{path: searchPath, match: cursorIs("r2"), gen: func(url.Values) any {
			return map[string]any{"results": []any{recentRow("OPS", "current"), recentRow("ENG", "current")}}
		}},
		route{path: searchPath, match: cqlHas("contributor = currentUser()"), gen: func(url.Values) any {
			return map[string]any{
				"results": []any{recentRow("ENG", "current"), recentRow("OLD", "trashed"), recentRow("ENG", "archived")},
				"_links":  map[string]any{"next": "/wiki/rest/api/content/search?cursor=r2"},
			}
		}},
	)
	keys, err := NewFetcher(api, "https://acme.atlassian.net").RecentSpaceKeys(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"ENG", "OPS"}, keys)
	q := api.requests()[0].q
	assert.Equal(t, "space", q.Get("expand"))
	assert.Contains(t, q.Get("cql"), "recentlyViewedContent(100, 90)")
}

// TestRecentSpaceKeys_StopsAtPageCap: a listing that never ends is read for
// at most recentSpacesMaxPages pages.
func TestRecentSpaceKeys_StopsAtPageCap(t *testing.T) {
	api := newFakeAPI(t)
	api.prepend(route{path: searchPath, match: anyQuery, gen: func(url.Values) any {
		return map[string]any{
			"results": []any{recentRow("ENG", "current")},
			"_links":  map[string]any{"next": "/wiki/rest/api/content/search?cursor=more"},
		}
	}})
	keys, err := NewFetcher(api, "https://acme.atlassian.net").RecentSpaceKeys(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"ENG"}, keys)
	assert.Len(t, api.requests(), recentSpacesMaxPages)
}

// TestRecentSpaceKeys_Error: a failed search is an error, never an empty
// list.
func TestRecentSpaceKeys_Error(t *testing.T) {
	api := newFakeAPI(t)
	api.prepend(route{path: searchPath, match: anyQuery, err: assert.AnError})
	_, err := NewFetcher(api, "https://acme.atlassian.net").RecentSpaceKeys(context.Background())
	require.Error(t, err)
}
