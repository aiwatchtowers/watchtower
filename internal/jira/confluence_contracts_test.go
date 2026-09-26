package jira

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestEXT01_ConfluenceAPIIsGETOnly — EXT-01 (read-only toward the source),
// transport half: *ConfluenceAPI is the only Confluence client Watchtower
// has, every one of its exported methods is exercised here against an
// httptest server, and every request it issues is a GET. The exported
// method set is pinned, so a new method (a write, say) fails this guard
// until it is exercised here too. The fetcher half is
// internal/confluence's TestEXT01_FetcherReachesOnlyTheGETAPI.
func TestEXT01_ConfluenceAPIIsGETOnly(t *testing.T) {
	var mu sync.Mutex
	var methods []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		methods = append(methods, r.Method)
		mu.Unlock()
		if r.Method != http.MethodGet {
			t.Errorf("EXT-01: %s %s — Confluence must only ever see GET", r.Method, r.URL.Path)
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	apiType := reflect.TypeOf(&ConfluenceAPI{})
	var exported []string
	for i := 0; i < apiType.NumMethod(); i++ {
		exported = append(exported, apiType.Method(i).Name)
	}
	sort.Strings(exported)
	require.Equal(t, []string{"Download", "GetJSON", "GrantedScopes"}, exported,
		"a new ConfluenceAPI method must be exercised by this guard before it ships")

	api := newTestClient(t, srv.URL, "", "tok").Confluence()
	ctx := context.Background()
	var out map[string]any
	require.NoError(t, api.GetJSON(ctx, "/wiki/api/v2/spaces", nil, &out))
	rc, err := api.Download(ctx, "/wiki/rest/api/content/1/child/attachment/2/download", 1<<20)
	require.NoError(t, err)
	require.NoError(t, rc.Close())
	_, err = api.GrantedScopes() // token store only, no request
	require.NoError(t, err)

	mu.Lock()
	defer mu.Unlock()
	assert.Equal(t, []string{http.MethodGet, http.MethodGet}, methods, "GetJSON and Download each issue exactly one GET")
}
