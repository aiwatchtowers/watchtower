package jira

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
)

// A standard Cloud host passes with no request; anything that is not an
// https origin is refused before any request.
func TestValidateCloudSite_HostRules(t *testing.T) {
	var calls atomic.Int32
	hc := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls.Add(1)
		return nil, errors.New("no network in this test")
	})}
	for _, ok := range []string{"https://acme.atlassian.net", "https://Acme.Atlassian.NET/"} {
		assert.NoError(t, ValidateCloudSite(context.Background(), hc, ok), ok)
	}
	assert.Zero(t, calls.Load(), "a .atlassian.net host needs no probe")

	for _, bad := range []string{
		"http://acme.atlassian.net",
		"https://acme.atlassian.net/wiki",
		"https://user@acme.atlassian.net", // leak-check:allow (a URL user part, not an email)
		"https://acme.atlassian.net?x=1",
		"acme.atlassian.net",
		"https://",
	} {
		err := ValidateCloudSite(context.Background(), hc, bad)
		assert.ErrorIs(t, err, ErrNotAtlassianCloud, bad)
	}
	assert.Zero(t, calls.Load(), "a malformed site is refused before any request")
}

// Look-alike hosts are not Cloud hosts: they must prove a tenant, and here
// the probe cannot run, which refuses them too.
func TestValidateCloudSite_LookAlikesNeedTheProbe(t *testing.T) {
	var calls atomic.Int32
	hc := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls.Add(1)
		return nil, errors.New("unreachable")
	})}
	for _, site := range []string{
		"https://atlassian.net",
		"https://acme.atlassian.net.example.com",
		"https://evil.acme.atlassian.net",
		"https://acme.atlassian.net:8443",
		"https://acmeatlassian.net",
	} {
		assert.Error(t, ValidateCloudSite(context.Background(), hc, site), site)
	}
	assert.Equal(t, int32(5), calls.Load())
}

// A custom domain passes only when _edge/tenant_info names a cloud id; a
// redirect is not followed and refuses.
func TestValidateCloudSite_TenantInfo(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		ok     bool
	}{
		{"cloud tenant", http.StatusOK, `{"cloudId":"11111111-2222-3333-4444-555555555555"}`, true},
		{"no cloud id", http.StatusOK, `{"cloudId":""}`, false},
		{"not json", http.StatusOK, `<html>hello</html>`, false},
		{"not found", http.StatusNotFound, `{}`, false},
		{"redirect", http.StatusFound, ``, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var gotPath string
			srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				gotPath = r.URL.Path
				assert.Empty(t, r.Header.Get("Authorization"), "the probe carries no credential")
				if tc.status == http.StatusFound {
					w.Header().Set("Location", "https://acme.atlassian.net/_edge/tenant_info")
				}
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			t.Cleanup(srv.Close)

			err := ValidateCloudSite(context.Background(), srv.Client(), srv.URL)
			assert.Equal(t, "/_edge/tenant_info", gotPath)
			if tc.ok {
				assert.NoError(t, err)
			} else {
				assert.ErrorIs(t, err, ErrNotAtlassianCloud)
			}
		})
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
