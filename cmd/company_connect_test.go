package cmd

import (
	"bytes"
	"context"
	"errors"
	"io"
	"maps"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/slackconnect"
)

// --- the chain itself, with a fake sign-in per vendor ---

// chainLog records a chain's events.
type chainLog struct {
	mu     sync.Mutex
	events []any
}

func (l *chainLog) emit(ev any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events = append(l.events, ev)
}

// steps is each company_vendor event as "vendor:state".
func (l *chainLog) steps() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []string
	for _, ev := range l.events {
		if v, ok := ev.(companyVendorEvent); ok {
			out = append(out, v.Vendor+":"+v.State)
		}
	}
	return out
}

func (l *chainLog) vendor(vendor, state string) companyVendorEvent {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, ev := range l.events {
		if v, ok := ev.(companyVendorEvent); ok && v.Vendor == vendor && v.State == state {
			return v
		}
	}
	return companyVendorEvent{}
}

// calls records which fake sign-ins ran, in order.
type calls struct {
	mu  sync.Mutex
	got []string
}

func (c *calls) add(v string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.got = append(c.got, v)
}

func (c *calls) list() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.got...)
}

// okLogins signs every vendor in as "<vendor>-account", recording the call.
func okLogins(c *calls) map[string]vendorLogin {
	logins := map[string]vendorLogin{}
	for _, v := range chainVendorOrder {
		logins[v] = func(_ context.Context, slug string) (string, error) {
			c.add(v + "@" + slug)
			return v + "-account", nil
		}
	}
	return logins
}

// blockingLogin waits for its ctx; it reports its start on started.
func blockingLogin(started chan<- string, vendor string) vendorLogin {
	return func(ctx context.Context, _ string) (string, error) {
		started <- vendor
		<-ctx.Done()
		return "", ctx.Err()
	}
}

func allowAll(string) bool { return true }

func TestCompanyChain_OrderAndEvents(t *testing.T) {
	c, log := &calls{}, &chainLog{}
	states := runCompanyChain(context.Background(), chainDeps{logins: okLogins(c), policyAllowed: allowAll},
		&companyChain{flow: "f1"}, "acme", []string{"linear", "slack", "dropbox", "microsoft", "google", "atlassian", "slack"}, log.emit)

	assert.Equal(t, []string{"slack@acme", "google@acme", "atlassian@acme", "microsoft@acme", "linear@acme"}, c.list(),
		"spec §3 step 2's order, each once; not a vendor is dropped")
	assert.Equal(t, []string{
		"slack:waiting", "slack:connected", "google:waiting", "google:connected", "atlassian:waiting", "atlassian:connected",
		"microsoft:waiting", "microsoft:connected", "linear:waiting", "linear:connected",
	}, log.steps())
	assert.Equal(t, companyVendorEvent{Event: "company_vendor", Flow: "f1", Vendor: "google", State: chainConnected, Label: "google-account"},
		log.vendor("google", chainConnected))
	want := map[string]string{"slack": "connected", "google": "connected", "atlassian": "connected", "microsoft": "connected", "linear": "connected"}
	assert.Equal(t, want, states)
	assert.Equal(t, companyDoneEvent{Event: "company_done", Flow: "f1", States: want}, log.events[len(log.events)-1], "company_done comes last")
}

func TestCompanyChain_CancelledVendorContinues(t *testing.T) {
	c, log := &calls{}, &chainLog{}
	logins := okLogins(c)
	logins["google"] = func(context.Context, string) (string, error) {
		return "", errors.Join(errors.New("google authorization denied: access_denied"), errConsentDenied)
	}
	states := runCompanyChain(context.Background(), chainDeps{logins: logins, policyAllowed: allowAll},
		&companyChain{flow: "f"}, "acme", []string{"google", "atlassian"}, log.emit)
	assert.Equal(t, map[string]string{"google": chainCancelled, "atlassian": chainConnected}, states)
	assert.Equal(t, []string{"atlassian@acme"}, c.list(), "the chain moves on")
}

func TestCompanyChain_FailedVendorContinues(t *testing.T) {
	c, log := &calls{}, &chainLog{}
	logins := okLogins(c)
	logins["atlassian"] = func(context.Context, string) (string, error) { return "", errors.New("the site is not reached") }
	states := runCompanyChain(context.Background(), chainDeps{logins: logins, policyAllowed: allowAll},
		&companyChain{flow: "f"}, "acme", []string{"atlassian", "linear"}, log.emit)
	assert.Equal(t, map[string]string{"atlassian": chainFailed, "linear": chainConnected}, states)
	assert.Equal(t, "the site is not reached", log.vendor("atlassian", chainFailed).Message)
	assert.Equal(t, []string{"linear@acme"}, c.list())
}

func TestCompanyChain_SkipEndsCurrentOnly(t *testing.T) {
	c, log := &calls{}, &chainLog{}
	started := make(chan string, 1)
	logins := okLogins(c)
	logins["google"] = blockingLogin(started, "google")
	ch := &companyChain{flow: "f"}
	result := make(chan map[string]string)
	go func() {
		result <- runCompanyChain(context.Background(), chainDeps{logins: logins, policyAllowed: allowAll}, ch, "acme",
			[]string{"google", "atlassian"}, log.emit)
	}()
	<-started
	assert.False(t, ch.skipVendor("atlassian"), "a Skip for another vendor than the waiting one skips nothing")
	assert.True(t, ch.skipVendor("google"))
	assert.Equal(t, map[string]string{"google": chainSkipped, "atlassian": chainConnected}, <-result)
	assert.Equal(t, []string{"atlassian@acme"}, c.list())
	assert.False(t, ch.skipVendor(""), "no vendor waits after the chain")
}

func TestCompanyChain_StopSkipsRest(t *testing.T) {
	c, log := &calls{}, &chainLog{}
	started := make(chan string, 1)
	logins := okLogins(c)
	logins["google"] = blockingLogin(started, "google")
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	result := make(chan map[string]string)
	go func() {
		result <- runCompanyChain(ctx, chainDeps{logins: logins, policyAllowed: allowAll}, &companyChain{flow: "f"}, "acme",
			[]string{"slack", "google", "atlassian", "linear"}, log.emit)
	}()
	<-started
	stop()
	assert.Equal(t, map[string]string{"slack": chainConnected, "google": chainSkipped, "atlassian": chainSkipped, "linear": chainSkipped}, <-result)
	assert.Equal(t, []string{"slack@acme"}, c.list(), "no vendor after the Stop signs in")
}

func TestCompanyChain_ForbiddenVendorNotRun(t *testing.T) {
	c, log := &calls{}, &chainLog{}
	allowed := func(v string) bool { return v != "google" }
	states := runCompanyChain(context.Background(), chainDeps{logins: okLogins(c), policyAllowed: allowed},
		&companyChain{flow: "f"}, "acme", []string{"slack", "google", "linear"}, log.emit)
	assert.Equal(t, map[string]string{"slack": chainConnected, "google": chainSkipped, "linear": chainConnected}, states)
	assert.Equal(t, []string{"slack@acme", "linear@acme"}, c.list())
	assert.Equal(t, "Blocked by your organization", log.vendor("google", chainSkipped).Message)
	assert.NotContains(t, log.steps(), "google:waiting")
}

// The production policy check maps vendors to their sources (Microsoft is
// Outlook, part of imap; Atlassian is jira).
func TestCompanyChain_PolicyUsesTheVendorsSource(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowedSources": []any{"jira", "imap"}})
	assert.True(t, companyChainPolicyAllowed("atlassian"))
	assert.True(t, companyChainPolicyAllowed("microsoft"))
	assert.False(t, companyChainPolicyAllowed("slack"))
	assert.False(t, companyChainPolicyAllowed("linear"))
}

// --company "" would sign in through the shared app: never.
func TestCompanyChain_NoCompanyNeverSignsIn(t *testing.T) {
	c, log := &calls{}, &chainLog{}
	states := runCompanyChain(context.Background(), chainDeps{logins: okLogins(c), policyAllowed: allowAll},
		&companyChain{flow: "f"}, "", []string{"google", "linear"}, log.emit)
	assert.Equal(t, map[string]string{"google": chainFailed, "linear": chainFailed}, states)
	assert.Empty(t, c.list())
}

// A sign-in that finished as a Skip arrived is connected, not skipped.
func TestCompanyChain_FinishedSignInWinsOverLateSkip(t *testing.T) {
	log := &chainLog{}
	ch := &companyChain{flow: "f"}
	logins := map[string]vendorLogin{"google": func(context.Context, string) (string, error) {
		ch.skipVendor("google")
		return "a@example.com", nil
	}}
	states := runCompanyChain(context.Background(), chainDeps{logins: logins, policyAllowed: allowAll}, ch, "acme", []string{"google"}, log.emit)
	assert.Equal(t, map[string]string{"google": chainConnected}, states)
}

// --- the sign-in children ---

// Every non-Slack vendor runs the CLI verb Connections runs, with the
// company; each of those verbs takes --company.
func TestCompanyChain_ChildCommandsTakeCompany(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "test"}
	for vendor, verb := range companyChainCommand {
		args := companyChainArgs(cfg, vendor, "acme")
		assert.Equal(t, append(append([]string(nil), verb...), "--company", "acme", "--workspace", "test"), args[:len(verb)+4], vendor)
		found, _, err := rootCmd.Find(verb)
		require.NoError(t, err, vendor)
		assert.NotNil(t, found.Flags().Lookup("company"), "%s: %s takes --company", vendor, strings.Join(verb, " "))
	}
	assert.ElementsMatch(t, []string{"google", "atlassian", "microsoft", "linear"}, slices.Collect(maps.Keys(companyChainCommand)))
}

// The Microsoft step is `outlook login --company <slug>`, which signs in
// through the bundle's own tenant, never "common".
func TestCompanyChain_MicrosoftUsesTenant(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "test"}
	assert.Equal(t, []string{"outlook", "login", "--company", "acme"}, companyChainArgs(cfg, "microsoft", "acme")[:4])
	ws := t.TempDir()
	b := companySample("Acme")
	require.NoError(t, company.NewStore(ws).Save("acme", b))
	ms, src, err := resolveMicrosoftOAuthConfigForCompany(ws, "acme")
	require.NoError(t, err)
	assert.Equal(t, clientSourceCompany, src)
	assert.Equal(t, b.Microsoft.TenantID, ms.TenantID)
	assert.Equal(t, b.Microsoft.ClientID, ms.ClientID)
}

func TestCompanyChainChild_Outcomes(t *testing.T) {
	for _, c := range []struct {
		name, script string
		want         string // "" = success
		denied       bool
	}{
		{name: "connected", script: "exit 0"},
		{name: "denied", script: "echo 'Error: google authorization denied: access_denied' >&2; exit 1", denied: true},
		{name: "error line", script: "echo 'Opening the browser' >&2; echo 'Error: company \"acme\" has no Linear app' >&2; echo 'Run --help' >&2; exit 1",
			want: `company "acme" has no Linear app`},
		{name: "last line", script: "echo 'panic: boom' >&2; exit 2", want: "panic: boom"},
		{name: "silent", script: "exit 1", want: "the sign-in did not finish"},
	} {
		t.Run(c.name, func(t *testing.T) {
			err := runCompanyChainChild(context.Background(), "/bin/sh", []string{"-c", c.script})
			switch {
			case c.denied:
				assert.ErrorIs(t, err, errConsentDenied)
			case c.want == "":
				assert.NoError(t, err)
			default:
				require.Error(t, err)
				assert.Equal(t, c.want, err.Error())
			}
		})
	}
}

// Skip, Stop or the app gone end a waiting sign-in child: it is killed and
// reaped, and the step reads as ended, not failed.
func TestCompanyChainChild_CancelKillsAndReaps(t *testing.T) {
	fifo := filepath.Join(t.TempDir(), "started")
	require.NoError(t, syscall.Mkfifo(fifo, 0o600))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- runCompanyChainChild(ctx, "/bin/sh", []string{"-c", `echo started > "$0"; exec sleep 600`, fifo})
	}()
	f, err := os.Open(fifo) // blocks until the child opened it
	require.NoError(t, err)
	_, err = io.ReadAll(f)
	require.NoError(t, err)
	require.NoError(t, f.Close())
	cancel()
	assert.ErrorIs(t, <-done, context.Canceled)
}

// A child knows it is a chain's (its stdin is the chain's pipe): the env
// mark is set and its stdin stays open while the chain runs.
func TestCompanyChainChild_StdinIsTheChainsPipe(t *testing.T) {
	err := runCompanyChainChild(context.Background(), "/bin/sh",
		[]string{"-c", `[ "$` + companyChainChildEnv + `" = 1 ] || exit 3; [ -p /dev/stdin ] || exit 4`})
	assert.NoError(t, err)
}

// The chain's end, whatever way (its process killed included), is EOF on
// the child's stdin: the child says so and exits before it can write an
// account nobody asked for any more.
func TestWatchChainParent_EOFExits(t *testing.T) {
	r, w := io.Pipe()
	exited := make(chan struct{})
	var errOut bytes.Buffer
	go watchChainParent(r, &errOut, func() { close(exited) })
	_, err := w.Write([]byte("noise"))
	require.NoError(t, err)
	require.NoError(t, w.Close())
	<-exited
	assert.Contains(t, errOut.String(), "Error: the Watchtower company connect that started this sign-in is gone")
}

func TestTailWriter_KeepsTheTail(t *testing.T) {
	w := &tailWriter{max: 4}
	_, _ = w.Write([]byte("abc"))
	_, _ = w.Write([]byte("defg"))
	assert.Equal(t, "defg", w.String())
}

// --- the chain inside `slack connect serve` ---

// chainBundle is the sample company whose Slack app is the serve tests'.
func chainBundle() companybundle.Bundle {
	b := companySample("Acme")
	b.Slack = &companybundle.Slack{TeamID: connTeam, ClientID: connNewID}
	return b
}

// startChainServe stores chainBundle as acme and runs serve with logins as
// the non-Slack sign-ins.
func startChainServe(t *testing.T, env connectEnv, logins map[string]vendorLogin) *serveHarness {
	t.Helper()
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	require.NoError(t, company.NewStore(env.cfg.WorkspaceDir()).Save("acme", chainBundle()))
	return startConnectServeLogged(t, env, fixedGrant(connGrant(connNewID)), slackconnect.Listen, io.Discard,
		func(d *slackConnectDeps) { d.chainLogins = logins })
}

func (h *serveHarness) expectVendor(t *testing.T, vendor, state string) map[string]any {
	t.Helper()
	ev := h.expect(t, "company_vendor")
	require.Equal(t, vendor, ev["vendor"], ev)
	require.Equal(t, state, ev["state"], ev)
	return ev
}

const chainConnectAcme = `{"cmd":"company_connect","flow":"f1","slug":"acme","vendors":["slack","google"]}`

// Spec §7 "Watchtower quits mid-chain" (the app quitting closes serve's
// stdin; a SIGKILLed serve's sign-in children end on their stdin's EOF,
// TestWatchChainParent_EOFExits): vendor 1 stays connected and tied, the
// rest have no row, inspect says so, and nothing resumes on its own — a new
// serve runs no chain, so a Slack start there opens its sign-in at once.
func TestCompanyChain_KillAfterFirstVendor(t *testing.T) {
	env := newConnectEnv(t)
	started := make(chan string, 1)
	h := startChainServe(t, env, map[string]vendorLogin{"google": blockingLogin(started, "google")})

	h.send(t, chainConnectAcme)
	h.expectVendor(t, "slack", chainWaiting)
	<-h.openedCh
	status, body := h.callback(t, "code-1")
	assert.Equal(t, http.StatusOK, status)
	assert.NotContains(t, body, "could not save")
	assert.Equal(t, "Acme", h.expectVendor(t, "slack", chainConnected)["label"])
	h.expectVendor(t, "google", chainWaiting)
	<-started
	h.closeStdin(t)

	accounts, err := env.db.ListSlackAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, "acme", accounts[0].CompanySlug)
	assert.Equal(t, "ok", accounts[0].Status)
	assert.Equal(t, connNewID, accounts[0].ClientID)
	google, err := env.db.ListGoogleAccounts()
	require.NoError(t, err)
	assert.Empty(t, google)

	res, err := inspectCompany(company.NewStore(env.cfg.WorkspaceDir()), env.db, companyWire(t, chainBundle()), "")
	require.NoError(t, err)
	assert.Equal(t, map[string]bool{"slack": true}, res.Connected)

	fresh := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	fresh.send(t, `{"cmd":"start","team_id":"`+connTeam+`","client_id":"`+connNewID+`"}`)
	fresh.expect(t, "browser") // not busy: no chain resumed
}

// The app gone (stdin EOF) is Stop: the waiting sign-in ends before serve
// returns.
func TestCompanyChain_StdinEOFStopsAndReaps(t *testing.T) {
	env := newConnectEnv(t)
	started, returned := make(chan string, 1), make(chan struct{})
	google := func(ctx context.Context, _ string) (string, error) {
		started <- "google"
		<-ctx.Done()
		close(returned)
		return "", ctx.Err()
	}
	h := startChainServe(t, env, map[string]vendorLogin{"google": google})
	h.send(t, `{"cmd":"company_connect","flow":"f1","slug":"acme","vendors":["google"]}`)
	h.expectVendor(t, "google", chainWaiting)
	<-started
	h.closeStdin(t)
	select {
	case <-returned:
	default:
		t.Fatal("serve returned before the chain's sign-in ended")
	}
}

func TestCompanyChain_SecondStartBusy(t *testing.T) {
	env := newConnectEnv(t)
	started := make(chan string, 2)
	h := startChainServe(t, env, map[string]vendorLogin{"google": blockingLogin(started, "google")})
	google := `{"cmd":"company_connect","flow":"FLOW","slug":"acme","vendors":["google"]}`

	h.send(t, strings.Replace(google, "FLOW", "f1", 1))
	h.expectVendor(t, "google", chainWaiting)
	<-started
	h.send(t, strings.Replace(google, "FLOW", "f2", 1))
	assert.Equal(t, "f1", h.expect(t, "busy")["flow"], "one chain at a time")
	h.send(t, `{"cmd":"start","team_id":"`+connTeam+`","client_id":"`+connNewID+`"}`)
	assert.Equal(t, "f1", h.expect(t, "busy")["flow"], "a Slack start waits for the chain")
	assert.Empty(t, h.browserURLs())

	h.send(t, `{"cmd":"company_stop","flow":"f2"}`) // not the running chain: nothing
	h.send(t, `{"cmd":"company_stop","flow":"f1"}`)
	h.expectVendor(t, "google", chainSkipped)
	assert.Equal(t, map[string]any{"google": "skipped"}, h.expect(t, "company_done")["states"])

	h.send(t, strings.Replace(google, "FLOW", "f3", 1))
	assert.Equal(t, "f3", h.expectVendor(t, "google", chainWaiting)["flow"], "the next chain may start once one ended")
	<-started
}

// A Slack flow holding the registry (a link waiting for its confirm) keeps a
// chain from starting: the guard is shared.
func TestCompanyChain_SlackFlowMakesChainBusy(t *testing.T) {
	env := newConnectEnv(t)
	h := startChainServe(t, env, nil)
	h.link(t, connTeam, connNewID)
	link := h.expect(t, "link")["flow"]
	h.send(t, chainConnectAcme)
	assert.Equal(t, link, h.expect(t, "busy")["flow"])
}

// A Slack link that arrives while a chain runs never holds the registry:
// its flow is cancelled and link_busy (not busy, which answers a start)
// names the chain, so a later Slack connect is free.
func TestCompanyChain_SlackLinkDuringChainIsBusy(t *testing.T) {
	env := newConnectEnv(t)
	started := make(chan string, 1)
	h := startChainServe(t, env, map[string]vendorLogin{"google": blockingLogin(started, "google")})
	h.send(t, `{"cmd":"company_connect","flow":"f1","slug":"acme","vendors":["google"]}`)
	h.expectVendor(t, "google", chainWaiting)
	<-started
	h.link(t, connTeam, connNewID)
	assert.Equal(t, "f1", h.expect(t, "link_busy")["flow"])
	h.send(t, `{"cmd":"company_stop","flow":"f1"}`)
	h.expectVendor(t, "google", chainSkipped)
	h.expect(t, "company_done")
	h.link(t, connTeam, connNewID)
	h.expect(t, "link")
}

// A Skip sent in answer to the waiting event always ends that vendor.
func TestCompanyChain_SkipRightAfterWaiting(t *testing.T) {
	env := newConnectEnv(t)
	logins := map[string]vendorLogin{"google": func(ctx context.Context, _ string) (string, error) {
		<-ctx.Done()
		return "", ctx.Err()
	}}
	h := startChainServe(t, env, logins)
	h.send(t, `{"cmd":"company_connect","flow":"f1","slug":"acme","vendors":["google"]}`)
	h.expectVendor(t, "google", chainWaiting)
	h.send(t, `{"cmd":"company_skip","flow":"f1","vendor":"google"}`)
	h.expectVendor(t, "google", chainSkipped)
	h.expect(t, "company_done")
}

func TestCompanyChain_SkipViaStdin(t *testing.T) {
	env := newConnectEnv(t)
	started := make(chan string, 1)
	c := &calls{}
	logins := okLogins(c)
	logins["google"] = blockingLogin(started, "google")
	h := startChainServe(t, env, logins)
	h.send(t, `{"cmd":"company_connect","flow":"f1","slug":"acme","vendors":["google","linear"]}`)
	h.expectVendor(t, "google", chainWaiting)
	<-started
	h.send(t, `{"cmd":"company_skip","flow":"f1","vendor":"linear"}`) // not the waiting vendor: nothing
	h.send(t, `{"cmd":"company_skip","flow":"f1","vendor":"google"}`)
	h.expectVendor(t, "google", chainSkipped)
	h.expectVendor(t, "linear", chainWaiting)
	h.expectVendor(t, "linear", chainConnected)
	assert.Equal(t, map[string]any{"google": "skipped", "linear": "connected"}, h.expect(t, "company_done")["states"])
	assert.Equal(t, []string{"linear@acme"}, c.list())
}

// A consent refused at Slack is the vendor cancelled, reported by the chain
// only (no Slack failed event), and the chain goes on.
func TestCompanyChain_SlackDeniedContinues(t *testing.T) {
	env := newConnectEnv(t)
	c := &calls{}
	h := startChainServe(t, env, okLogins(c))
	h.send(t, chainConnectAcme)
	h.expectVendor(t, "slack", chainWaiting)
	<-h.openedCh
	h.redirect(t, "error=access_denied")
	h.expectVendor(t, "slack", chainCancelled)
	h.expectVendor(t, "google", chainWaiting)
	h.expectVendor(t, "google", chainConnected)
	assert.Equal(t, map[string]any{"slack": "cancelled", "google": "connected"}, h.expect(t, "company_done")["states"])
	accounts, err := env.db.ListSlackAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// company_connect answers the company link of its flow: the next link may
// wait for its confirm (Task 10's held link is released).
func TestCompanyChain_ConnectReleasesTheLink(t *testing.T) {
	env := newConnectEnv(t)
	h := startChainServe(t, env, nil)
	_, wire := acmeLinkBundle(t)
	h.companyLink(t, wire)
	flow := h.expect(t, "company_link")["flow"].(string)
	h.send(t, `{"cmd":"company_connect","flow":"`+flow+`","slug":"acme","vendors":[]}`)
	assert.Equal(t, map[string]any{}, h.expect(t, "company_done")["states"])

	resp, _ := h.companyLink(t, companyWire(t, companySample("Beta")))
	assert.Equal(t, http.StatusFound, resp.StatusCode, "not 409: no link waits any more")
	assert.NotEqual(t, flow, h.expect(t, "company_link")["flow"])
}

// companyGolden is the chain's wire fixture for the Desktop's decoder
// (`CompanyConnectFlowModelTests.testDecodesCompanyEvents` reads every
// line; serve_events.jsonl stays the Slack flow's).
var companyGolden = filepath.Join("..", "internal", "slackconnect", "testdata", "company_events.jsonl")

// TestCompanyChainServe_WireGolden runs one chain through every vendor state
// and pins the company lines of stdout. -update rewrites it.
func TestCompanyChainServe_WireGolden(t *testing.T) {
	env := newConnectEnv(t)
	policytest.Set(t, map[string]any{"AllowedSources": []any{"slack", "google", "jira", "imap"}})
	started := make(chan string, 1)
	h := startChainServe(t, env, map[string]vendorLogin{
		"google": func(context.Context, string) (string, error) { return "", errConsentDenied },
		"atlassian": func(context.Context, string) (string, error) {
			return "", errors.New("company Atlassian site: https://acme.atlassian.net is not reached")
		},
		"microsoft": blockingLogin(started, "microsoft"),
		"linear":    okLogins(&calls{})["linear"],
	})
	_, wire := acmeLinkBundle(t)
	h.companyLink(t, wire)
	flow := h.expect(t, "company_link")["flow"].(string)
	h.send(t, `{"cmd":"company_connect","flow":"`+flow+`","slug":"acme","vendors":["slack","google","atlassian","microsoft","linear"]}`)
	h.expectVendor(t, "slack", chainWaiting)
	<-h.openedCh
	h.callback(t, "code-1")
	h.expectVendor(t, "slack", chainConnected)
	h.expectVendor(t, "google", chainWaiting)
	h.expectVendor(t, "google", chainCancelled)
	h.expectVendor(t, "atlassian", chainWaiting)
	h.expectVendor(t, "atlassian", chainFailed)
	h.expectVendor(t, "microsoft", chainWaiting)
	<-started
	h.send(t, `{"cmd":"company_skip","flow":"`+flow+`"}`)
	h.expectVendor(t, "microsoft", chainSkipped)
	h.expectVendor(t, "linear", chainSkipped)
	h.expect(t, "company_done")
	h.closeStdin(t)

	var lines []string
	for _, l := range h.raw {
		if strings.Contains(l, `"event":"company_`) {
			lines = append(lines, l)
		}
	}
	got := normalizeServeWire(t, lines)
	if *updateSessionReportGolden {
		require.NoError(t, os.WriteFile(companyGolden, []byte(got), 0o600))
	}
	want, err := os.ReadFile(companyGolden)
	require.NoError(t, err, "run with -update to write the fixture")
	assert.Equal(t, string(want), got)
}

// --- connected Slack rows and the company tie ---

func TestSlackConnect_CompanySlugTiesNewAndExistingRows(t *testing.T) {
	env := newConnectEnv(t)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	target := connTarget(connNewID)
	target.CompanySlug = "acme"
	id, _, err := env.write(target, connGrant(connNewID))
	require.NoError(t, err)
	assert.Equal(t, "acme", env.account(t, id).CompanySlug, "a new row is tied in its insert")

	// A connect without a company keeps the row's tie.
	again, _, err := env.write(connTarget(connNewID), connGrant(connNewID))
	require.NoError(t, err)
	assert.Equal(t, id, again)
	assert.Equal(t, "acme", env.account(t, id).CompanySlug)
}

func TestSlackConnect_CompanySlugRetiesTheTeamsRow(t *testing.T) {
	env := newConnectEnv(t)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	id := env.seedAccount(t, connTeam, connRetiredID)
	target := connTarget(connNewID)
	target.CompanySlug = "acme"
	got, rebound, err := env.write(target, connGrant(connNewID))
	require.NoError(t, err)
	assert.Equal(t, id, got, "the team's row is re-bound, never a second row")
	assert.Equal(t, connRetiredID, rebound)
	a := env.account(t, id)
	assert.Equal(t, "acme", a.CompanySlug)
	assert.Equal(t, connNewID, a.ClientID)
}

// --- the one-shot `company connect` ---

func TestCompanyConnect_DefaultVendorsAreTheUnconnected(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	require.NoError(t, store.Save("acme", companySample("Acme")))
	ids := companyAccounts(t, d, "acme")
	require.NoError(t, d.SetSlackAccountAuthState(ids["slack"], "ok", ""))
	require.NoError(t, d.SetJiraAccountAuthState(ids["jira"], "ok", ""))
	require.NoError(t, d.SetGoogleAccountAuthState(ids["google"], "error", "invalid_client"))

	got, err := companyConnectVendors(store, d, "acme", nil, false)
	require.NoError(t, err)
	assert.Contains(t, got, "google", "an account in error needs its sign-in")
	assert.NotContains(t, got, "slack")
	assert.NotContains(t, got, "atlassian")
	assert.Equal(t, companyChainVendors(got), got, "in the chain's order")
}

func TestCompanyConnect_VendorsMustBeTheCompanys(t *testing.T) {
	store, d := company.NewStore(t.TempDir()), db.OpenTestDB(t)
	b := companySample("Acme")
	b.Linear = nil
	require.NoError(t, store.Save("acme", b))
	_, err := companyConnectVendors(store, d, "acme", []string{"google", "linear"}, true)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "has no linear app")
	got, err := companyConnectVendors(store, d, "acme", []string{}, true)
	require.NoError(t, err)
	assert.Empty(t, got)

	_, err = companyConnectVendors(store, d, "beta", nil, false)
	assert.ErrorIs(t, err, errUnknownCompany)
}

func TestCompanyConnect_OncePrintsAndFailsOnNotConnected(t *testing.T) {
	logins := okLogins(&calls{})
	logins["google"] = func(context.Context, string) (string, error) { return "", errConsentDenied }
	var out bytes.Buffer
	err := connectCompanyOnce(context.Background(), chainDeps{logins: logins, policyAllowed: allowAll}, "acme",
		[]string{"slack", "google", "linear"}, false, &out)
	require.Error(t, err)
	assert.Equal(t, "not connected: google; connect them later from Connections", err.Error())
	assert.Equal(t, "slack: connected (slack-account)\ngoogle: cancelled: you did not allow Watchtower\nlinear: connected (linear-account)\n", out.String())

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err = connectCompanyOnce(ctx, chainDeps{logins: okLogins(&calls{}), policyAllowed: allowAll}, "acme", []string{"linear"}, false, io.Discard)
	assert.ErrorIs(t, err, context.Canceled, "an interrupted run is not a success")

	out.Reset()
	require.NoError(t, connectCompanyOnce(context.Background(), chainDeps{logins: okLogins(&calls{}), policyAllowed: allowAll}, "acme",
		[]string{"linear"}, true, &out))
	assert.Contains(t, out.String(), `"event":"company_vendor"`)
	assert.Contains(t, out.String(), `"event":"company_done"`)
}

// oneShotSlackDeps answers the one-shot Slack step's sign-in at once with
// query (code=… or error=…), as the browser and Slack would.
func oneShotSlackDeps(t *testing.T, query string) slackConnectDeps {
	t.Helper()
	var addr string
	return slackConnectDeps{
		listen: func(port int) (net.Listener, error) {
			ln, err := slackconnect.Listen(port)
			if err == nil {
				addr = ln.Addr().String()
			}
			return ln, err
		},
		exchange: func(context.Context, string, string, string, string) (slackconnect.Grant, error) {
			return connGrant(connNewID), nil
		},
		openBrowser: func(raw string) {
			u, err := url.Parse(raw)
			if err != nil {
				t.Error(err)
				return
			}
			go func() {
				resp, err := http.Get("http://" + addr + "/callback?state=" + url.QueryEscape(u.Query().Get("state")) + "&" + query)
				if err == nil {
					_ = resp.Body.Close()
				}
			}()
		},
		clock: slackconnect.SystemClock{},
	}
}

func TestCompanySlackOnce_TiesTheAccount(t *testing.T) {
	env := newConnectEnv(t)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	require.NoError(t, company.NewStore(env.cfg.WorkspaceDir()).Save("acme", chainBundle()))
	label, err := companySlackOnce(context.Background(), env.cfg, env.db, oneShotSlackDeps(t, "code=c1"), "acme", io.Discard)
	require.NoError(t, err)
	assert.Equal(t, "Acme", label)
	accounts, err := env.db.ListSlackAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, "acme", accounts[0].CompanySlug)
}

func TestCompanySlackOnce_DeniedIsConsentDenied(t *testing.T) {
	env := newConnectEnv(t)
	require.NoError(t, company.NewStore(env.cfg.WorkspaceDir()).Save("acme", chainBundle()))
	_, err := companySlackOnce(context.Background(), env.cfg, env.db, oneShotSlackDeps(t, "error=access_denied"), "acme", io.Discard)
	assert.ErrorIs(t, err, errConsentDenied)

	b := chainBundle()
	b.Slack = nil
	require.NoError(t, company.NewStore(env.cfg.WorkspaceDir()).Save("acme", b))
	_, err = companySlackOnce(context.Background(), env.cfg, env.db, oneShotSlackDeps(t, "code=c1"), "acme", io.Discard)
	assert.ErrorIs(t, err, errNoOAuthClient, "a company without a Slack app signs nothing in")
}
