package company

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"time"

	"watchtower/internal/auth"
	"watchtower/internal/imap"
	"watchtower/internal/linear"
)

// The dry authorize check (#1887 P7, S28): Linear and Microsoft are public
// clients with PKCE and no secret, so the client id, the tenant and the
// redirect are all their authorize step can get wrong. The wizard checks
// them with one GET of the authorize URL a sign-in would open, without
// following its redirect and without signing in, and classifies the answer.

// Dry check results.
const (
	DryOK           = "ok"
	DryRejected     = "rejected"
	DryAdminConsent = "admin_consent"
	DryNetwork      = "network"
)

// DryResult is one dry check's answer: Code is the vendor's own error key
// (an OAuth error, an AADSTS code) when it gave one.
type DryResult struct {
	Result  string `json:"result"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

// dryTimeout bounds a dry check made with no client of the caller's.
const dryTimeout = 20 * time.Second

// dryBodyMax is how much of an answer's body the classifier reads.
const dryBodyMax = 256 << 10

// dryState is the state a dry check sends: nothing ever comes back to it.
const dryState = "watchtower-dry-check"

// The markers the answers are classified by — the plan's defaults until
// spike S1.6 records the vendors' real answers; every marker lives here.
var (
	// aadstsRE finds a Microsoft identity platform error code.
	aadstsRE = regexp.MustCompile(`AADSTS(\d{5,6})`)
	// aadstsAdminConsent are the codes of a client that is fine but needs a
	// tenant admin's consent (65001 consent missing, 90094/90095 admin
	// approval required).
	aadstsAdminConsent = map[string]bool{"65001": true, "90094": true, "90095": true}
	// oauthErrorRE finds an OAuth error key in an error page's body.
	oauthErrorRE = regexp.MustCompile(`\b(invalid_client|unauthorized_client|deleted_client|invalid_request|redirect_uri_mismatch|unsupported_response_type)\b`)
	// dryErrorSignInNeeded are redirect errors that prove the client works
	// and only lack a signed-in person.
	dryErrorSignInNeeded = map[string]bool{"login_required": true, "interaction_required": true}
	// dryErrorConsent is the redirect error of a client that needs consent.
	dryErrorConsent = "consent_required"
)

// dryAuthorizeURL is the URL a sign-in through the client would open.
func dryAuthorizeURL(vendor, clientID, tenantID string) (string, error) {
	pkce, err := auth.NewPKCEPair()
	if err != nil {
		return "", err
	}
	switch vendor {
	case "linear":
		return linear.DryAuthorizeURL(clientID, dryState, pkce.Challenge), nil
	case "microsoft":
		if tenantID == "" {
			return "", errors.New("a Microsoft check needs the tenant id")
		}
		cfg := imap.MicrosoftOAuthConfig{ClientID: clientID, TenantID: tenantID}
		return imap.MicrosoftDryAuthorizeURL(cfg, dryState, pkce.Challenge), nil
	}
	return "", fmt.Errorf("no dry check for %q", vendor)
}

// DryAuthorize GETs the authorize URL of vendor's client (linear, microsoft)
// once, never following a redirect, and classifies the answer. hc nil uses
// a client with dryTimeout. Nothing is stored.
func DryAuthorize(ctx context.Context, hc *http.Client, vendor, clientID, tenantID string) DryResult {
	u, err := dryAuthorizeURL(vendor, clientID, tenantID)
	if err != nil {
		return DryResult{Result: DryRejected, Message: err.Error()}
	}
	c := http.Client{Timeout: dryTimeout}
	if hc != nil {
		c = *hc
	}
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return DryResult{Result: DryRejected, Message: err.Error()}
	}
	resp, err := c.Do(req)
	if err != nil {
		return DryResult{Result: DryNetwork, Message: dryNetworkMessage(err)}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, dryBodyMax))
	if err != nil {
		return DryResult{Result: DryNetwork, Message: dryNetworkMessage(err)}
	}
	return classifyDryAuthorize(vendor, resp.StatusCode, resp.Header.Get("Location"), body)
}

// dryNetworkMessage names a failed request without its URL (which carries
// the client id twice and reads badly).
func dryNetworkMessage(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		err = ue.Err
	}
	var ne net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &ne) && ne.Timeout()) {
		return "the request timed out"
	}
	return err.Error()
}

// classifyDryAuthorize reads one authorize answer: an AADSTS code
// (Microsoft) decides first, then an error on the redirect, then the status.
// A sign-in page (2xx) or a redirect to one is ok; a 5xx is the vendor's
// trouble (network: try again).
func classifyDryAuthorize(vendor string, status int, location string, body []byte) DryResult {
	var redirectErr, redirectDesc string
	if loc, err := url.Parse(location); err == nil && location != "" {
		q := loc.Query()
		redirectErr, redirectDesc = q.Get("error"), q.Get("error_description")
	}
	if vendor == "microsoft" {
		if m := aadstsRE.FindStringSubmatch(redirectDesc + " " + string(body)); m != nil {
			code := "AADSTS" + m[1]
			if aadstsAdminConsent[m[1]] {
				return DryResult{Result: DryAdminConsent, Code: code, Message: "a tenant admin must grant consent"}
			}
			return DryResult{Result: DryRejected, Code: code, Message: "Microsoft does not accept this client"}
		}
		if redirectErr == dryErrorConsent {
			return DryResult{Result: DryAdminConsent, Code: redirectErr, Message: "a tenant admin must grant consent"}
		}
	}
	switch {
	case redirectErr != "" && dryErrorSignInNeeded[redirectErr]:
		return DryResult{Result: DryOK}
	case redirectErr != "":
		return DryResult{Result: DryRejected, Code: redirectErr, Message: redirectDesc}
	case status >= 500:
		return DryResult{Result: DryNetwork, Message: fmt.Sprintf("%s answered %d", vendor, status)}
	case status >= 400:
		code := fmt.Sprintf("http_%d", status)
		if m := oauthErrorRE.FindStringSubmatch(string(body)); m != nil {
			code = m[1]
		}
		return DryResult{Result: DryRejected, Code: code, Message: fmt.Sprintf("%s refused the client", vendor)}
	}
	return DryResult{Result: DryOK}
}

// AdminConsentURL is the link a tenant admin opens to grant consent to the
// company's Microsoft app.
func AdminConsentURL(tenantID, clientID string) string {
	return "https://login.microsoftonline.com/" + url.PathEscape(tenantID) + "/adminconsent?" +
		url.Values{"client_id": {clientID}}.Encode()
}
