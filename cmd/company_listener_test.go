package cmd

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/oauthpage"
	"watchtower/internal/slackconnect"
)

// companyPagesGolden is the page-text fixture the Desktop's copy tests read.
var companyPagesGolden = filepath.Join("testdata", "company_pages.json")

// Sample secrets: a test fails if any of them reaches a log.
const (
	linkGoogleSecret    = "sample-google-secret"
	linkAtlassianSecret = "sample-atlassian-secret"
)

func acmeLinkBundle(t *testing.T) (companybundle.Bundle, string) {
	t.Helper()
	b := companybundle.Bundle{
		V: 1, Company: "Acme",
		Slack:  &companybundle.Slack{TeamID: "T0000", ClientID: "000.000"},
		Google: &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: linkGoogleSecret, Domain: "example.com"},
		Atlassian: &companybundle.Atlassian{ClientID: "acmeClientId01", ClientSecret: linkAtlassianSecret,
			Site: "https://acme.atlassian.net", Confluence: true},
	}
	wire, err := companybundle.Encode(b)
	require.NoError(t, err)
	return b, wire
}

// rawWire is a link bundle built from raw JSON (refusal cases).
func rawWire(js string) string { return base64.RawURLEncoding.EncodeToString([]byte(js)) }

// syncLog is a log sink the listener's goroutines may write concurrently.
type syncLog struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *syncLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *syncLog) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// noRedirect is a client that shows the listener's 302 instead of following it.
var noRedirect = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

func (h *serveHarness) companyLink(t *testing.T, wire string) (*http.Response, string) {
	t.Helper()
	return h.do(t, http.MethodGet, companyConnectPath+"?b="+wire, "")
}

func (h *serveHarness) do(t *testing.T, method, pathAndQuery, host string) (*http.Response, string) {
	t.Helper()
	req, err := http.NewRequestWithContext(context.Background(), method, h.base+pathAndQuery, nil)
	require.NoError(t, err)
	if host != "" {
		req.Host = host
	}
	resp, err := noRedirect.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	return resp, string(body)
}

func TestCompanyListener_ValidLinkRedirectsClean(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	_, wire := acmeLinkBundle(t)

	resp, body := h.companyLink(t, wire)
	assert.Equal(t, http.StatusFound, resp.StatusCode)
	assert.Equal(t, h.base+companyConnectedPath, resp.Header.Get("Location"), "a clean URL: a reload never resubmits")
	assert.Empty(t, body)
	assert.Equal(t, "no-store", resp.Header.Get("Cache-Control"))
	ev := h.expect(t, "company_link")
	assert.NotEmpty(t, ev["flow"])
	assert.Equal(t, wire, ev["bundle"])

	resp, body = h.do(t, http.MethodGet, companyConnectedPath, "")
	assert.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Contains(t, body, oauthpage.CompanyOpenHeading)
	assert.Contains(t, body, oauthpage.CompanyOpenMessage("Acme"))
	assert.NotContains(t, body, linkGoogleSecret)

	// A normalizing difference is the same bundle: the event carries the
	// normalized wire.
	h.send(t, `{"cmd":"company_dismiss","flow":"`+ev["flow"].(string)+`"}`)
	loose := rawWire(`{"v":1,"company":" Acme ","slack":{"team_id":"T0000","client_id":" 000.000"}}`)
	resp, _ = h.companyLink(t, loose)
	assert.Equal(t, http.StatusFound, resp.StatusCode)
	want, err := companybundle.Encode(companybundle.Bundle{V: 1, Company: "Acme",
		Slack: &companybundle.Slack{TeamID: "T0000", ClientID: "000.000"}})
	require.NoError(t, err)
	assert.Equal(t, want, h.expect(t, "company_link")["bundle"])
}

func TestCompanyListener_ConnectedWithoutLinkIsNotFound(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	resp, body := h.do(t, http.MethodGet, companyConnectedPath, "")
	assert.Equal(t, http.StatusNotFound, resp.StatusCode)
	assert.Empty(t, body)
}

// The §7 row "a web page opens the link silently": the link stores nothing,
// opens no sign-in and writes no account before the app confirms.
func TestCompanyListener_RequiresConfirm(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	_, wire := acmeLinkBundle(t)

	h.companyLink(t, wire)
	h.expect(t, "company_link")
	h.closeStdin(t)

	assert.Empty(t, h.browserURLs(), "no OAuth before a confirm")
	_, err := os.Stat(company.NewStore(env.cfg.WorkspaceDir()).Dir)
	assert.True(t, os.IsNotExist(err), "no company store file: %v", err)
	accounts, err := env.db.ListSlackAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

func TestCompanyListener_RefusedNothingReachesApp(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))

	cases := []struct {
		name, query string
		reason      companybundle.Refusal
	}{
		{"not base64", "?b=" + "%21%21%21", companybundle.RefusalDamaged},
		{"no bundle", "", companybundle.RefusalDamaged},
		{"two bundles", "?b=" + rawWire(`{"v":1,"company":"Acme"}`) + "&b=" + rawWire(`{"v":1,"company":"Beta"}`), companybundle.RefusalDamaged},
		{"unknown field", "?b=" + rawWire(`{"v":1,"company":"Acme","extra":1}`), companybundle.RefusalDamaged},
		{"too long", "?b=" + strings.Repeat("A", companybundle.MaxEncodedLen+1), companybundle.RefusalTooLong},
		{"site not https", "?b=" + rawWire(`{"v":1,"company":"Acme","atlassian":{"client_id":"acmeClientId01",` +
			`"client_secret":"s","site":"http://acme.atlassian.net","confluence":false}}`), companybundle.RefusalSiteNotHTTPS},
		{"personal", "?b=" + rawWire(`{"v":1,"company":"Acme","personal":true}`), companybundle.RefusalPersonal},
	}
	for _, c := range cases {
		resp, body := h.do(t, http.MethodGet, companyConnectPath+c.query, "")
		assert.Equal(t, http.StatusBadRequest, resp.StatusCode, c.name)
		assert.Contains(t, body, oauthpage.CompanyRefusedHeading, c.name)
		assert.Contains(t, body, oauthpage.CompanyRefusedReasons[c.reason], c.name)
		assert.Contains(t, body, oauthpage.CompanyRefusedHint, c.name)
	}
	resp, body := h.do(t, http.MethodGet, companyConnectPath+"?b="+rawWire(`{"v":2,"company":"Acme"}`), "")
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	assert.Contains(t, body, oauthpage.CompanyNewerHeading)
	assert.Contains(t, body, oauthpage.CompanyNewerMessage)

	// Nothing reached the app: the next event is the next valid link's.
	_, wire := acmeLinkBundle(t)
	h.companyLink(t, wire)
	assert.Equal(t, wire, h.expect(t, "company_link")["bundle"])
	assert.Empty(t, h.browserURLs())
}

// FILES-01: the request log keeps the path, never the query's bundle.
func TestCompanyListener_LogHasNoBundle(t *testing.T) {
	env := newConnectEnv(t)
	var logs syncLog
	h := startConnectServeLogged(t, env, fixedGrant(connGrant(connNewID)), slackconnect.Listen, &logs)
	_, wire := acmeLinkBundle(t)
	refused := rawWire(`{"v":1,"company":"Acme","google":{"client_id":"1234-abcd.apps.googleusercontent.com",` +
		`"client_secret":"` + linkGoogleSecret + `"},"extra":"` + linkAtlassianSecret + `"}`)

	h.companyLink(t, wire)
	h.expect(t, "company_link")
	h.companyLink(t, wire)
	h.companyLink(t, refused)
	h.do(t, http.MethodPost, companyConnectPath+"?b="+wire, "")
	h.closeStdin(t)

	got := logs.String()
	assert.Contains(t, got, companyConnectPath)
	assert.Contains(t, got, "refused: damaged")
	for _, secret := range []string{wire, refused, linkGoogleSecret, linkAtlassianSecret, "b=", "?"} {
		assert.NotContains(t, got, secret)
	}
	// Not one byte of the wire: no 16-character run of it either.
	for _, w := range []string{wire, refused} {
		for i := 0; i+16 <= len(w); i += 8 {
			assert.NotContains(t, got, w[i:i+16])
		}
	}
}

func TestCompanyListener_PostAndWrongHostRefused(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	_, wire := acmeLinkBundle(t)

	for _, path := range []string{companyConnectPath + "?b=" + wire, companyConnectedPath} {
		resp, body := h.do(t, http.MethodPost, path, "")
		assert.Equal(t, http.StatusMethodNotAllowed, resp.StatusCode, path)
		assert.Equal(t, http.MethodGet, resp.Header.Get("Allow"))
		assert.Empty(t, body)

		resp, body = h.do(t, http.MethodGet, path, "localhost:"+strconv.Itoa(h.port))
		assert.Equal(t, http.StatusMisdirectedRequest, resp.StatusCode, path)
		assert.Empty(t, body)
	}
	// Neighbouring paths are not the company's (the Slack listener's 404).
	for _, path := range []string{"/company/connect/x", "/company", "/company/../etc/passwd"} {
		resp, _ := h.do(t, http.MethodGet, path, "")
		assert.Equal(t, http.StatusNotFound, resp.StatusCode, path)
	}

	h.companyLink(t, wire)
	assert.Equal(t, wire, h.expect(t, "company_link")["bundle"], "none of the refused requests reached the app")
}

// Review Focus 2: the same link opened twice while it waits is one confirm.
func TestCompanyListener_DuplicateLinkWhilePendingIsOne(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	_, wire := acmeLinkBundle(t)

	var wg sync.WaitGroup
	statuses := make([]int, 4)
	for i := range statuses {
		wg.Go(func() {
			resp, _ := h.companyLink(t, wire)
			statuses[i] = resp.StatusCode
		})
	}
	wg.Wait()
	assert.Equal(t, []int{http.StatusFound, http.StatusFound, http.StatusFound, http.StatusFound}, statuses)
	first := h.expect(t, "company_link")["flow"].(string)

	// Another company's link waits until the app answers the first.
	other, err := companybundle.Encode(companybundle.Bundle{V: 1, Company: "Beta"})
	require.NoError(t, err)
	resp, body := h.companyLink(t, other)
	assert.Equal(t, http.StatusConflict, resp.StatusCode)
	assert.Contains(t, body, oauthpage.CompanyBusyHeading)
	resp, body = h.do(t, http.MethodGet, companyConnectedPath, "")
	assert.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Contains(t, body, oauthpage.CompanyOpenMessage("Acme"), "the waiting link's company")

	h.send(t, `{"cmd":"company_dismiss","flow":"not-it"}`)
	h.send(t, `{"cmd":"company_dismiss","flow":"`+first+`"}`)
	h.companyLink(t, other)
	ev := h.expect(t, "company_link")
	assert.Equal(t, other, ev["bundle"], "the only second event is the other company's, after the dismiss")
	assert.NotEqual(t, first, ev["flow"])
}

// The app goes away while a link's handler waits to hand its event over:
// the browser gets the "not taken" page and the link does not stay pending.
func TestCompanyListener_EmitNotTakenReleases(t *testing.T) {
	links := &pendingLinks{}
	h := companyConnectHandler("127.0.0.1:18551", func(context.Context, any) bool { return false }, links,
		log.New(io.Discard, "", 0))
	_, wire := acmeLinkBundle(t)
	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:18551"+companyConnectPath+"?b="+wire, nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	assert.Equal(t, http.StatusServiceUnavailable, rec.Code)
	assert.Contains(t, rec.Body.String(), "Watchtower did not take this link.")
	_, offered := links.offer(wire, "Acme")
	assert.Equal(t, linkFresh, offered, "the link was released")
}

func TestCompanyListener_PortBusy(t *testing.T) {
	env := newConnectEnv(t)
	held, err := slackconnect.Listen(0)
	require.NoError(t, err)
	defer held.Close()
	port := held.Addr().(*net.TCPAddr).Port
	var out strings.Builder
	deps := slackConnectDeps{port: port, listen: slackconnect.Listen,
		openBrowser: func(string) { t.Error("no browser") }, clock: slackconnect.SystemClock{}}

	err = serveSlackConnect(context.Background(), env.cfg, env.db, strings.NewReader(""), &out, io.Discard, deps)
	var ec *exitCodeError
	require.ErrorAs(t, err, &ec)
	assert.Equal(t, 3, ec.code)
	assert.JSONEq(t, `{"event":"port_busy","port":`+strconv.Itoa(port)+`}`, out.String(),
		"port_busy is the only event: no company path is served")
}

func TestSlackConnectPath_StillServed(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	status, body := h.link(t, connTeam, connNewID)
	assert.Equal(t, http.StatusOK, status)
	assert.Contains(t, body, "Switch to Watchtower to confirm")
	link := h.expect(t, "link")
	assert.Equal(t, connTeam, link["team_id"])
}

// TestCompanyPages_Fixture pins the listener pages' texts for the Desktop
// (CompanySetupMockCopy's page constants are asserted against it). -update
// rewrites it.
func TestCompanyPages_Fixture(t *testing.T) {
	reasons := map[string]string{}
	for r, line := range oauthpage.CompanyRefusedReasons {
		reasons[string(r)] = line
	}
	fixture := map[string]any{
		"open":    map[string]string{"heading": oauthpage.CompanyOpenHeading, "message_acme": oauthpage.CompanyOpenMessage("Acme")},
		"refused": map[string]any{"heading": oauthpage.CompanyRefusedHeading, "hint": oauthpage.CompanyRefusedHint, "reasons": reasons},
		"newer":   map[string]string{"heading": oauthpage.CompanyNewerHeading, "message": oauthpage.CompanyNewerMessage},
		"busy":    map[string]string{"heading": oauthpage.CompanyBusyHeading, "message": oauthpage.CompanyBusyMessage},
	}
	got, err := json.MarshalIndent(fixture, "", "  ")
	require.NoError(t, err)
	got = append(got, '\n')
	if *updateSessionReportGolden {
		require.NoError(t, os.WriteFile(companyPagesGolden, got, 0o600))
	}
	want, err := os.ReadFile(companyPagesGolden)
	require.NoError(t, err, "run with -update to write the fixture")
	assert.Equal(t, string(want), string(got))
}
