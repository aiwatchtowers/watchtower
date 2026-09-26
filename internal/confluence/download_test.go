package confluence

import (
	"context"
	"io"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/extsync"
	"watchtower/internal/jira"
)

// failAfter yields data, then fails every Read with err.
type failAfter struct {
	data   *strings.Reader
	err    error
	closed bool
}

func (r *failAfter) Read(p []byte) (int, error) {
	if r.data.Len() > 0 {
		return r.data.Read(p)
	}
	return 0, r.err
}

func (r *failAfter) Close() error {
	r.closed = true
	return nil
}

var testAttachment = &extsync.Item{Ref: extsync.ItemRef{Kind: extsync.KindAttachment, ExtID: "att3"}, Download: "/wiki/x/download"}

// TestDownloadMapsGoneAndTooLarge: an attachment deleted between Fetch and
// Download (404) is extsync.ErrGone, so the engine deletes its row instead
// of failing the batch every cycle; the API's size cap is
// extsync.ErrTooLarge.
func TestDownloadMapsGoneAndTooLarge(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want error
	}{
		{"404 is gone", &jira.HTTPStatusError{Status: 404, Body: "not found"}, extsync.ErrGone},
		{"upfront cap", jira.ErrTooLarge, extsync.ErrTooLarge},
		{"revoked", jira.ErrAuthRevoked, extsync.ErrAuthRevoked},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			api := newFakeAPI(t)
			api.download = func(string) (io.ReadCloser, error) { return nil, c.err }
			_, err := NewFetcher(api, testSite).Download(context.Background(), testAttachment, 10)
			require.ErrorIs(t, err, c.want)
			require.ErrorIs(t, err, c.err, "the original error stays in the chain")
		})
	}

	api := newFakeAPI(t)
	api.download = func(string) (io.ReadCloser, error) { return nil, &jira.HTTPStatusError{Status: 500, Body: "boom"} }
	_, err := NewFetcher(api, testSite).Download(context.Background(), testAttachment, 10)
	require.Error(t, err)
	assert.NotErrorIs(t, err, extsync.ErrGone, "only a 404 is gone")
	assert.NotErrorIs(t, err, extsync.ErrTooLarge)
}

// TestDownloadMapsReadTimeTooLarge: the API enforces the cap while reading
// (a body without Content-Length); that read error must match
// extsync.ErrTooLarge too, while io.EOF passes through untouched.
func TestDownloadMapsReadTimeTooLarge(t *testing.T) {
	body := &failAfter{data: strings.NewReader("abc"), err: jira.ErrTooLarge}
	api := newFakeAPI(t)
	api.download = func(string) (io.ReadCloser, error) { return body, nil }
	rc, err := NewFetcher(api, testSite).Download(context.Background(), testAttachment, 10)
	require.NoError(t, err)
	b, err := io.ReadAll(rc)
	assert.Equal(t, "abc", string(b))
	require.ErrorIs(t, err, extsync.ErrTooLarge)
	require.ErrorIs(t, err, jira.ErrTooLarge, "the original error stays in the chain")
	require.NoError(t, rc.Close())
	assert.True(t, body.closed, "Close reaches the API body")

	api.download = func(string) (io.ReadCloser, error) { return io.NopCloser(strings.NewReader("ok")), nil }
	rc, err = NewFetcher(api, testSite).Download(context.Background(), testAttachment, 10)
	require.NoError(t, err)
	b, err = io.ReadAll(rc)
	require.NoError(t, err, "io.EOF is not wrapped")
	assert.Equal(t, "ok", string(b))
}
