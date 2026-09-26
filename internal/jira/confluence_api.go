package jira

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
)

// ErrTooLarge is returned by ConfluenceAPI.Download when the response body
// exceeds the caller's size cap, either because Content-Length announced it
// upfront or because more than max bytes were actually read.
var ErrTooLarge = errors.New("atlassian: response exceeds size cap")

// maxErrorBodyBytes caps how much of a non-2xx response body GetJSON/Download
// read into HTTPStatusError.Body — enough to see an error message (including
// the "scope" wording a 401/403 needs-consent response carries) without an
// unbounded read of a pathological response.
const maxErrorBodyBytes = 4096

// HTTPStatusError is returned for a non-2xx response from GetJSON/Download.
// Kept a plain, unwrapped struct (not composed with ErrAuthRevoked or a
// sentinel of its own): a later generic sync engine maps Status/Body to its
// own sentinels — a 401 or 403 whose Body mentions "scope" becomes that engine's
// needs_consent — without importing internal/jira, so these two exported
// fields are load-bearing across that package boundary.
type HTTPStatusError struct {
	Status int
	Body   string
}

func (e *HTTPStatusError) Error() string {
	return fmt.Sprintf("atlassian: status %d: %s", e.Status, e.Body)
}

// newHTTPStatusError reads up to maxErrorBodyBytes of resp's body and returns
// it as an *HTTPStatusError. Caller remains responsible for closing resp.Body.
func newHTTPStatusError(resp *http.Response) *HTTPStatusError {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, maxErrorBodyBytes))
	return &HTTPStatusError{Status: resp.StatusCode, Body: string(body)}
}

// ConfluenceAPI is a thin view over Client for the Confluence Cloud REST API
// (v1 + v2). Confluence and Jira share one Atlassian OAuth 2.0 (3LO) grant,
// one token store, and one single-flight refresh guard — ConfluenceAPI reuses
// Client's doURL/getAccessToken/rate limiter rather than duplicating them.
type ConfluenceAPI struct {
	c *Client
}

// Confluence returns a Confluence API view over this Jira client's OAuth
// grant and HTTP plumbing.
func (c *Client) Confluence() *ConfluenceAPI {
	return &ConfluenceAPI{c: c}
}

// base is the Confluence Cloud REST API root for this client's site:
// https://api.atlassian.com/ex/confluence/{cloudID}.
func (a *ConfluenceAPI) base() string {
	return a.c.apiRoot + "/ex/confluence/" + a.c.cloudID
}

// GetJSON performs an authenticated GET against path (relative to base(),
// e.g. "/wiki/api/v2/pages/1"), encoding q as the query string, and decodes
// the JSON response body into out. A non-2xx response is returned as
// *HTTPStatusError rather than decoded.
func (a *ConfluenceAPI) GetJSON(ctx context.Context, path string, q url.Values, out any) error {
	fullURL := a.base() + path
	if len(q) > 0 {
		fullURL += "?" + q.Encode()
	}

	resp, err := a.c.doURL(ctx, http.MethodGet, fullURL, nil, jsonAccept)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return newHTTPStatusError(resp)
	}

	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("decoding GET %s: %w", path, err)
	}
	return nil
}

// Download performs an authenticated GET against path (relative to base())
// and returns the response body as a ReadCloser capped at limit bytes. A
// response whose Content-Length already declares more than limit fails fast
// with ErrTooLarge before any body is read; otherwise the body is wrapped in
// a reader budgeted at limit+1 bytes so a response with no (or an understated)
// Content-Length is still caught — the read that would return the (limit+1)-th
// byte returns ErrTooLarge instead. The caller must Close the returned
// ReadCloser (on both the success and the io.EOF-terminated read paths).
func (a *ConfluenceAPI) Download(ctx context.Context, path string, limit int64) (io.ReadCloser, error) {
	// No Accept header: an attachment binary is not JSON, and asking
	// Confluence's download endpoint to expect one is wrong for this request.
	resp, err := a.c.doURL(ctx, http.MethodGet, a.base()+path, nil, "")
	if err != nil {
		return nil, err
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		defer resp.Body.Close()
		return nil, newHTTPStatusError(resp)
	}

	if resp.ContentLength > limit {
		resp.Body.Close()
		return nil, ErrTooLarge
	}

	return newCappedBody(resp.Body, limit), nil
}

// GrantedScopes returns the scope field of the stored OAuth token — the
// scopes Atlassian actually granted at consent, which HasConfluenceScopes
// checks against ConfluenceScopes to decide whether re-consent is needed.
// Reads under c.mu, the same lock getAccessToken/refreshIfCurrent hold while
// writing: TokenStore.Save is not atomic (MarshalIndent + WriteFile, no
// tmp+rename), so a read racing an in-flight refresh could otherwise land
// mid-write and see truncated or partial JSON.
func (a *ConfluenceAPI) GrantedScopes() (string, error) {
	a.c.mu.Lock()
	defer a.c.mu.Unlock()

	tok, err := a.c.tokenStore.Load()
	if err != nil {
		return "", fmt.Errorf("loading token: %w", err)
	}
	return tok.Scope, nil
}

// cappedBody wraps a download body in a hard budget of max+1 bytes (via
// io.LimitReader): once more than max bytes have been read, the read that
// would return byte max+1 is turned into ErrTooLarge instead of silently
// handing back a truncated — and therefore corrupt — attachment.
type cappedBody struct {
	limited   io.Reader
	rc        io.Closer
	max, read int64
}

func newCappedBody(rc io.ReadCloser, limit int64) *cappedBody {
	return &cappedBody{limited: io.LimitReader(rc, limit+1), rc: rc, max: limit}
}

func (b *cappedBody) Read(p []byte) (int, error) {
	n, err := b.limited.Read(p)
	b.read += int64(n)
	if b.read > b.max {
		return 0, ErrTooLarge
	}
	return n, err
}

func (b *cappedBody) Close() error {
	return b.rc.Close()
}
