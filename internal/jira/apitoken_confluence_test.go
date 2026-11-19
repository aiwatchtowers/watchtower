package jira

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestProbeConfluence (#1887 C5): Confluence counts only when the token reads
// a space list there — at the site for a classic token, at the gateway's
// /ex/confluence/<cloudId> for a scoped one — so a Jira-only scoped token
// never records Confluence scopes it cannot use.
func TestProbeConfluence(t *testing.T) {
	for _, tc := range []struct {
		name   string
		scoped bool
		status int
		want   bool
	}{
		{"classic reads", false, http.StatusOK, true},
		{"scoped reads", true, http.StatusOK, true},
		{"scoped without Confluence scopes", true, http.StatusUnauthorized, false},
		{"forbidden", false, http.StatusForbidden, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var paths []string
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				paths = append(paths, r.URL.Path)
				assert.True(t, strings.HasPrefix(r.Header.Get("Authorization"), "Basic "))
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(`{"results":[]}`))
			}))
			t.Cleanup(srv.Close)
			prev, prevCheck := apiGatewayRoot, probeSiteCheck
			apiGatewayRoot, probeSiteCheck = srv.URL, func(string) error { return nil }
			t.Cleanup(func() { apiGatewayRoot, probeSiteCheck = prev, prevCheck })

			got, err := ProbeConfluence(context.Background(), nil, "cloud-x", srv.URL, testCreds(tc.scoped))
			require.NoError(t, err)
			assert.Equal(t, tc.want, got)
			want := "/wiki/api/v2/spaces"
			if tc.scoped {
				want = "/ex/confluence/cloud-x/wiki/api/v2/spaces"
			}
			assert.Equal(t, []string{want}, paths)
		})
	}

	t.Run("not reached", func(t *testing.T) {
		prevCheck := probeSiteCheck
		probeSiteCheck = func(string) error { return nil }
		t.Cleanup(func() { probeSiteCheck = prevCheck })
		srv := httptest.NewServer(http.NotFoundHandler())
		srv.Close()
		_, err := ProbeConfluence(context.Background(), nil, "cloud-x", srv.URL, testCreds(false))
		require.Error(t, err)
		assert.NotContains(t, err.Error(), testAPIToken)
	})
}
