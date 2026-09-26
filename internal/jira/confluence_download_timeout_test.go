package jira

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// slowBodyServer answers every request with headers at once and a body
// that only completes after delay.
func slowBodyServer(t *testing.T, delay time.Duration) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"a":`))
		w.(http.Flusher).Flush()
		time.Sleep(delay)
		_, _ = w.Write([]byte(`1}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestDownloadIsNotBoundByTheRequestTimeout: Download reads a body slower
// than the client's whole-request timeout (which still bounds GetJSON),
// because it runs under downloadTimeout instead.
func TestDownloadIsNotBoundByTheRequestTimeout(t *testing.T) {
	srv := slowBodyServer(t, 300*time.Millisecond)
	c := newTestClient(t, srv.URL, "", "tok")
	c.httpClient.Timeout = 100 * time.Millisecond

	var out map[string]any
	err := c.Confluence().GetJSON(context.Background(), "/wiki/x", nil, &out)
	require.Error(t, err, "GetJSON keeps the client's whole-request timeout")

	rc, err := c.Confluence().Download(context.Background(), "/wiki/dl", 1<<20)
	require.NoError(t, err)
	b, err := io.ReadAll(rc)
	require.NoError(t, err, "the body read outlives the 100 ms request timeout")
	require.NoError(t, rc.Close())
	assert.Equal(t, `{"a":1}`, string(b))
}

func TestDownloadHasItsOwnBound(t *testing.T) {
	old := downloadTimeout
	downloadTimeout = 100 * time.Millisecond
	t.Cleanup(func() { downloadTimeout = old })
	srv := slowBodyServer(t, 500*time.Millisecond)
	c := newTestClient(t, srv.URL, "", "tok")

	rc, err := c.Confluence().Download(context.Background(), "/wiki/dl", 1<<20)
	if err == nil {
		_, err = io.ReadAll(rc)
		_ = rc.Close()
	}
	require.Error(t, err, "downloadTimeout bounds the download")

	c.httpClient.Transport = &http.Transport{}
	hc := c.downloadHTTPClient()
	assert.Equal(t, downloadTimeout, hc.Timeout)
	assert.Same(t, c.httpClient.Transport, hc.Transport, "downloads share the client's transport")
	assert.Equal(t, 30*time.Second, c.httpClient.Timeout, "the Jira/GetJSON timeout is unchanged")
}
