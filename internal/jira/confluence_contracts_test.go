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
// transport half, narrowed for PutJSON: *ConfluenceAPI is the only
// Confluence client Watchtower has; its exported method set is pinned to
// exactly {Download, GetJSON, PutJSON}, so a new method fails this guard
// until it is exercised here too. GetJSON and Download are exercised
// against an httptest server that fails the test on any non-GET they issue
// — those two stay GET-only, full stop. PutJSON is the one deliberate
// exception (EXT-05's write path): it is exercised separately and pinned to
// issue exactly one PUT, never routed through the GET-only server above.
// Read-only toward the source now means "the sync engine and fetcher never
// reach PutJSON" (see TestEXT01_FetcherCannotReachPut in
// internal/confluence), not "the client has no write method at all". The
// fetcher half of the GET-only pin is internal/confluence's
// TestEXT01_FetcherReachesOnlyTheGETAPI.
func TestEXT01_ConfluenceAPIIsGETOnly(t *testing.T) {
	var mu sync.Mutex
	var methods []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		methods = append(methods, r.Method)
		mu.Unlock()
		if r.Method != http.MethodGet {
			t.Errorf("EXT-01: %s %s — GetJSON/Download must only ever see GET", r.Method, r.URL.Path)
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
	require.Equal(t, []string{"Download", "GetJSON", "PutJSON"}, exported,
		"a new ConfluenceAPI method must be exercised by this guard before it ships")

	api := newTestClient(t, srv.URL, "", "tok").Confluence()
	ctx := context.Background()
	var out map[string]any
	require.NoError(t, api.GetJSON(ctx, "/wiki/api/v2/spaces", nil, &out))
	rc, err := api.Download(ctx, "/wiki/rest/api/content/1/child/attachment/2/download", 1<<20)
	require.NoError(t, err)
	require.NoError(t, rc.Close())

	mu.Lock()
	assert.Equal(t, []string{http.MethodGet, http.MethodGet}, methods, "GetJSON and Download each issue exactly one GET")
	mu.Unlock()

	var putMethods []string
	putSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		putMethods = append(putMethods, r.Method)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer putSrv.Close()
	putAPI := newTestClient(t, putSrv.URL, "", "tok").Confluence()
	require.NoError(t, putAPI.PutJSON(ctx, "/wiki/api/v2/pages/1", map[string]any{"id": "1"}, &out))
	assert.Equal(t, []string{http.MethodPut}, putMethods, "PutJSON issues exactly one PUT — the sole write exception, see EXT-05")
}
