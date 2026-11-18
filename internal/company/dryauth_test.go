package company

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// roundTrip answers every request with err, or with status, location and
// body, and records it.
type roundTrip struct {
	reqs     []*http.Request
	status   int
	location string
	body     string
	err      error
}

func (r *roundTrip) RoundTrip(req *http.Request) (*http.Response, error) {
	r.reqs = append(r.reqs, req)
	if r.err != nil {
		return nil, r.err
	}
	h := http.Header{}
	if r.location != "" {
		h.Set("Location", r.location)
	}
	return &http.Response{StatusCode: r.status, Header: h, Body: io.NopCloser(strings.NewReader(r.body)), Request: req}, nil
}

const (
	dryLinearID = "acmelinear01"
	dryMSID     = "00000000-0000-0000-0000-000000000001"
	dryTenant   = "00000000-0000-0000-0000-0000000000aa"
)

// TestDryAuthorize_Classifies: the plan's default markers (S1.6 pending).
func TestDryAuthorize_Classifies(t *testing.T) {
	cases := []struct {
		name, vendor string
		status       int
		location     string
		body         string
		want         DryResult
	}{
		{"linear sign-in page", "linear", 200, "", "<html>Sign in</html>", DryResult{Result: DryOK}},
		{"linear redirect to login", "linear", 302, "https://linear.app/login?redirect=x", "", DryResult{Result: DryOK}},
		{"linear bad client id", "linear", 400, "", `{"error":"invalid_client"}`,
			DryResult{Result: DryRejected, Code: "invalid_client", Message: "linear refused the client"}},
		{"linear bad client, no key", "linear", 404, "", "not found",
			DryResult{Result: DryRejected, Code: "http_404", Message: "linear refused the client"}},
		{"linear error on the redirect", "linear", 302, "http://localhost:18531/callback?error=invalid_request&error_description=bad+redirect", "",
			DryResult{Result: DryRejected, Code: "invalid_request", Message: "bad redirect"}},
		{"microsoft sign-in page", "microsoft", 200, "", "<html>Sign in to your account</html>", DryResult{Result: DryOK}},
		{"microsoft bad client id", "microsoft", 400, "", "AADSTS700016: Application with identifier was not found",
			DryResult{Result: DryRejected, Code: "AADSTS700016", Message: "Microsoft does not accept this client"}},
		{"microsoft admin consent", "microsoft", 302,
			"http://127.0.0.1:18531/callback?error=consent_required&error_description=AADSTS65001%3A+consent", "",
			DryResult{Result: DryAdminConsent, Code: "AADSTS65001", Message: "a tenant admin must grant consent"}},
		{"microsoft consent without a code", "microsoft", 302, "http://127.0.0.1:18531/callback?error=consent_required", "",
			DryResult{Result: DryAdminConsent, Code: "consent_required", Message: "a tenant admin must grant consent"}},
		{"microsoft login required", "microsoft", 302, "http://127.0.0.1:18531/callback?error=login_required", "", DryResult{Result: DryOK}},
		{"vendor down", "microsoft", 503, "", "", DryResult{Result: DryNetwork, Message: "microsoft answered 503"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assert.Equal(t, c.want, classifyDryAuthorize(c.vendor, c.status, c.location, []byte(c.body)))
		})
	}
}

// TestDryAuthorize_NeverFollowsRedirects: one GET of the authorize URL a
// sign-in would open; the redirect is read, never followed.
func TestDryAuthorize_NeverFollowsRedirects(t *testing.T) {
	rt := &roundTrip{status: 302, location: "https://login.microsoftonline.com/x/login"}
	got := DryAuthorize(context.Background(), &http.Client{Transport: rt}, "microsoft", dryMSID, dryTenant)

	assert.Equal(t, DryResult{Result: DryOK}, got)
	require.Len(t, rt.reqs, 1, "the redirect is never followed")
	u := rt.reqs[0].URL
	assert.Equal(t, http.MethodGet, rt.reqs[0].Method)
	assert.Equal(t, "login.microsoftonline.com", u.Host)
	assert.Equal(t, "/"+dryTenant+"/oauth2/v2.0/authorize", u.Path)
	assert.Equal(t, dryMSID, u.Query().Get("client_id"))
	assert.Equal(t, "http://127.0.0.1:18531/callback", u.Query().Get("redirect_uri"))
	assert.NotEmpty(t, u.Query().Get("code_challenge"))

	rt = &roundTrip{status: 302, location: "https://linear.app/login"}
	assert.Equal(t, DryResult{Result: DryOK}, DryAuthorize(context.Background(), &http.Client{Transport: rt}, "linear", dryLinearID, ""))
	require.Len(t, rt.reqs, 1)
	assert.Equal(t, "linear.app", rt.reqs[0].URL.Host)
	assert.Equal(t, dryLinearID, rt.reqs[0].URL.Query().Get("client_id"))
	assert.Equal(t, "http://localhost:18531/callback", rt.reqs[0].URL.Query().Get("redirect_uri"))
}

// A request that never gets an answer is a network result, its message
// without the URL.
func TestDryAuthorize_NetworkErrors(t *testing.T) {
	rt := &roundTrip{err: context.DeadlineExceeded}
	got := DryAuthorize(context.Background(), &http.Client{Transport: rt}, "linear", dryLinearID, "")
	assert.Equal(t, DryResult{Result: DryNetwork, Message: "the request timed out"}, got)

	rt = &roundTrip{err: io.ErrUnexpectedEOF}
	got = DryAuthorize(context.Background(), &http.Client{Transport: rt}, "microsoft", dryMSID, dryTenant)
	assert.Equal(t, DryNetwork, got.Result)
	assert.NotContains(t, got.Message, dryMSID)
}

func TestDryAuthorize_BadInput(t *testing.T) {
	rt := &roundTrip{status: 200}
	hc := &http.Client{Transport: rt}
	assert.Equal(t, DryRejected, DryAuthorize(context.Background(), hc, "microsoft", dryMSID, "").Result, "no tenant")
	assert.Equal(t, DryRejected, DryAuthorize(context.Background(), hc, "google", "x", "").Result, "no dry check")
	assert.Empty(t, rt.reqs)
}

func TestAdminConsentURL(t *testing.T) {
	got := AdminConsentURL(dryTenant, dryMSID)
	assert.Equal(t, "https://login.microsoftonline.com/"+dryTenant+"/adminconsent?client_id="+dryMSID, got)
	u, err := url.Parse(AdminConsentURL("acme.example.com", dryMSID))
	require.NoError(t, err)
	assert.Equal(t, "/acme.example.com/adminconsent", u.Path)
}
