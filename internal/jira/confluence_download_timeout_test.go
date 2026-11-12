package jira

import (
	"context"
	"io"
	"net/http"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// slowBodyTransport answers every request in memory with headers at once and
// a body that only completes after delay — on the synctest bubble's clock, so
// the timeouts below run on virtual time. A read gives up when the request's
// context ends, as a real connection does when the client's deadline passes.
type slowBodyTransport struct{ delay time.Duration }

func (s slowBodyTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": {"application/json"}},
		Body:       &slowBody{ctx: r.Context(), delay: s.delay},
		Request:    r,
	}, nil
}

type slowBody struct {
	ctx   context.Context
	delay time.Duration
	part  int
}

func (b *slowBody) Read(p []byte) (int, error) {
	b.part++
	switch b.part {
	case 1:
		return copy(p, `{"a":`), nil
	case 2:
		select {
		case <-time.After(b.delay):
			return copy(p, `1}`), nil
		case <-b.ctx.Done():
			return 0, b.ctx.Err()
		}
	default:
		return 0, io.EOF
	}
}

func (b *slowBody) Close() error { return nil }

// slowBodyClient is a test client whose every request gets a slowBodyTransport answer.
func slowBodyClient(t *testing.T, delay time.Duration) *Client {
	t.Helper()
	c := newTestClient(t, "http://jira.invalid", "", "tok")
	c.httpClient.Transport = slowBodyTransport{delay: delay}
	return c
}

// TestDownloadIsNotBoundByTheRequestTimeout: Download reads a body slower
// than the client's whole-request timeout (which still bounds GetJSON),
// because it runs under downloadTimeout instead.
func TestDownloadIsNotBoundByTheRequestTimeout(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		c := slowBodyClient(t, 300*time.Millisecond)
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
	})
}

func TestDownloadHasItsOwnBound(t *testing.T) {
	old := downloadTimeout
	downloadTimeout = 100 * time.Millisecond
	t.Cleanup(func() { downloadTimeout = old })
	synctest.Test(t, func(t *testing.T) {
		c := slowBodyClient(t, 500*time.Millisecond)

		rc, err := c.Confluence().Download(context.Background(), "/wiki/dl", 1<<20)
		if err == nil {
			_, err = io.ReadAll(rc)
			_ = rc.Close()
		}
		require.Error(t, err, "downloadTimeout bounds the download")
	})

	c := newTestClient(t, "http://jira.invalid", "", "tok")
	c.httpClient.Transport = &http.Transport{}
	hc := c.downloadHTTPClient()
	assert.Equal(t, downloadTimeout, hc.Timeout)
	assert.Same(t, c.httpClient.Transport, hc.Transport, "downloads share the client's transport")
	assert.Equal(t, 30*time.Second, c.httpClient.Timeout, "the Jira/GetJSON timeout is unchanged")
}
