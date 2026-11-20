package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/policy/policytest"
	"watchtower/internal/slackconnect"
)

// serveGolden is the wire fixture the Desktop's decoder tests read.
var serveGolden = filepath.Join("..", "internal", "slackconnect", "testdata", "serve_events.jsonl")

// serveHarness runs serveSlackConnect in-process on an ephemeral port, with
// stdin and stdout as pipes.
type serveHarness struct {
	stdin  *io.PipeWriter
	lines  chan string
	done   chan error
	base   string
	port   int
	closed bool

	mu     sync.Mutex
	opened []string
	raw    []string
	// openedCh gets each opened URL too, for a test that waits for a
	// browser step started off the loop (the company chain's).
	openedCh chan string
}

func fixedGrant(g slackconnect.Grant) func(string) (slackconnect.Grant, error) {
	return func(string) (slackconnect.Grant, error) { return g, nil }
}

func startConnectServe(t *testing.T, env connectEnv, exchange func(code string) (slackconnect.Grant, error)) *serveHarness {
	t.Helper()
	return startConnectServeOn(t, env, exchange, slackconnect.Listen)
}

func startConnectServeOn(t *testing.T, env connectEnv, exchange func(code string) (slackconnect.Grant, error),
	listen func(int) (net.Listener, error)) *serveHarness {
	t.Helper()
	return startConnectServeLogged(t, env, exchange, listen, io.Discard)
}

// startConnectServeLogged is startConnectServeOn with serve's log going to
// logOut (it must take concurrent writes).
func startConnectServeLogged(t *testing.T, env connectEnv, exchange func(code string) (slackconnect.Grant, error),
	listen func(int) (net.Listener, error), logOut io.Writer, opts ...func(*slackConnectDeps)) *serveHarness {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	h := &serveHarness{stdin: inW, lines: make(chan string, 64), done: make(chan error, 1), openedCh: make(chan string, 64)}
	deps := slackConnectDeps{
		port:   0,
		listen: listen,
		exchange: func(_ context.Context, _, code, _, _ string) (slackconnect.Grant, error) {
			return exchange(code)
		},
		openBrowser: func(u string) {
			h.mu.Lock()
			h.opened = append(h.opened, u)
			h.mu.Unlock()
			select {
			case h.openedCh <- u:
			default:
			}
		},
		clock: slackconnect.SystemClock{},
	}
	for _, o := range opts {
		o(&deps)
	}
	go func() {
		err := serveSlackConnect(context.Background(), env.cfg, env.db, inR, outW, logOut, deps)
		_ = outW.Close()
		h.done <- err
	}()
	go func() {
		defer close(h.lines)
		sc := bufio.NewScanner(outR)
		for sc.Scan() {
			h.lines <- sc.Text()
		}
	}()
	t.Cleanup(func() { h.closeStdin(t) })
	ev := h.expect(t, "listening")
	h.port = int(ev["port"].(float64))
	require.NotZero(t, h.port)
	require.NotEqual(t, slackconnect.Port, h.port, "tests never bind 18551")
	h.base = "http://127.0.0.1:" + strconv.Itoa(h.port)
	return h
}

func (h *serveHarness) send(t *testing.T, line string) {
	t.Helper()
	_, err := io.WriteString(h.stdin, line+"\n")
	require.NoError(t, err)
}

// expect reads the next event and requires its kind.
func (h *serveHarness) expect(t *testing.T, kind string) map[string]any {
	t.Helper()
	line, ok := <-h.lines
	require.True(t, ok, "serve stopped before %q", kind)
	h.mu.Lock()
	h.raw = append(h.raw, line)
	h.mu.Unlock()
	var ev map[string]any
	require.NoError(t, json.Unmarshal([]byte(line), &ev), line)
	require.Equal(t, kind, ev["event"], line)
	return ev
}

func (h *serveHarness) browserURLs() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.opened...)
}

func (h *serveHarness) get(t *testing.T, pathAndQuery string) (int, string) {
	t.Helper()
	resp, err := http.Get(h.base + pathAndQuery)
	require.NoError(t, err)
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	return resp.StatusCode, string(body)
}

// link opens a connect link on the listener, as a browser would.
func (h *serveHarness) link(t *testing.T, team, client string) (int, string) {
	t.Helper()
	return h.get(t, "/slack/connect?team="+team+"&client="+client)
}

// callback is Slack's redirect for the last opened sign-in.
func (h *serveHarness) callback(t *testing.T, code string) (int, string) {
	t.Helper()
	return h.redirect(t, "code="+code)
}

// redirect is Slack's redirect for the last opened sign-in with query
// (code=… or error=…).
func (h *serveHarness) redirect(t *testing.T, query string) (int, string) {
	t.Helper()
	return h.get(t, h.redirectPath(t, query))
}

func (h *serveHarness) redirectPath(t *testing.T, query string) string {
	t.Helper()
	urls := h.browserURLs()
	require.NotEmpty(t, urls, "no sign-in was opened")
	u, err := url.Parse(urls[len(urls)-1])
	require.NoError(t, err)
	return "/callback?state=" + url.QueryEscape(u.Query().Get("state")) + "&" + query
}

// closeStdin is the app going away: serve closes the listener and exits 0.
func (h *serveHarness) closeStdin(t *testing.T) {
	t.Helper()
	if h.closed {
		return
	}
	h.closed = true
	require.NoError(t, h.stdin.Close())
	require.NoError(t, <-h.done)
	for range h.lines { //nolint:revive // drain what is left
	}
}

func TestSlackConnectServe_LinkConfirmConnected(t *testing.T) {
	env := newConnectEnv(t)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))

	status, _ := h.link(t, connTeam, connNewID)
	assert.Equal(t, http.StatusOK, status)
	link := h.expect(t, "link")
	flow := link["flow"].(string)
	assert.Equal(t, connTeam, link["team_id"])
	assert.Equal(t, connNewID, link["client_id"])
	assert.Empty(t, h.browserURLs(), "nothing reaches Slack before confirm")

	h.send(t, `{"cmd":"confirm","flow":"`+flow+`"}`)
	assert.Equal(t, flow, h.expect(t, "browser")["flow"])
	status, body := h.callback(t, "code-1")
	assert.Equal(t, http.StatusOK, status)
	assert.NotContains(t, body, "could not save")
	ev := h.expect(t, "connected")
	assert.Equal(t, flow, ev["flow"])
	assert.Equal(t, connTeam, ev["team_id"])
	assert.Equal(t, "Acme", ev["team_name"])
	assert.Equal(t, "", ev["rebound_from"])

	id := int64(ev["account_id"].(float64))
	a := env.account(t, id)
	assert.Equal(t, "ok", a.Status)
	assert.Equal(t, connNewID, a.ClientID)
	tok, err := env.store(id).Load()
	require.NoError(t, err)
	assert.Equal(t, "xoxe-refresh", tok.RefreshToken)
}

func TestSlackConnectServe_StartSkipsConfirm(t *testing.T) {
	env := newConnectEnv(t)
	id := env.seedAccount(t, connTeam, connRetiredID)
	stubSlackIdentityServer(t, connUser, connTeam, "Acme", "acme")
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))

	h.send(t, `{"cmd":"start","team_id":"`+connTeam+`","client_id":"`+connNewID+`","account_id":`+strconv.FormatInt(id, 10)+`}`)
	flow := h.expect(t, "browser")["flow"].(string)
	require.Len(t, h.browserURLs(), 1)
	u, err := url.Parse(h.browserURLs()[0])
	require.NoError(t, err)
	assert.Equal(t, connNewID, u.Query().Get("client_id"))
	h.callback(t, "code-1")
	ev := h.expect(t, "connected")
	assert.Equal(t, flow, ev["flow"])
	assert.Equal(t, float64(id), ev["account_id"])
	assert.Equal(t, connRetiredID, ev["rebound_from"])
}

func TestSlackConnectServe_SecondStartBusy(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))

	start := `{"cmd":"start","team_id":"` + connTeam + `","client_id":"` + connNewID + `"}`
	h.send(t, start)
	flow := h.expect(t, "browser")["flow"]
	h.send(t, start)
	assert.Equal(t, flow, h.expect(t, "busy")["flow"])
	h.link(t, connTeam, connNewID)
	assert.Equal(t, flow, h.expect(t, "link_busy")["flow"], "a link is refused too, as its own event")
	assert.Len(t, h.browserURLs(), 1)
}

func TestSlackConnectServe_CancelStoresNothing(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))

	h.send(t, `{"cmd":"start","team_id":"`+connTeam+`","client_id":"`+connNewID+`"}`)
	flow := h.expect(t, "browser")["flow"].(string)
	h.send(t, `{"cmd":"cancel","flow":"`+flow+`"}`)
	ev := h.expect(t, "failed")
	assert.Equal(t, flow, ev["flow"])
	assert.Equal(t, "cancelled", ev["reason"])

	// Slack's redirect after the cancel finds no flow: nothing stored.
	h.callback(t, "code-1")
	h.closeStdin(t)
	accounts, err := env.db.ListSlackAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
	_, err = os.Stat(env.cfg.WorkspaceDir())
	if err == nil {
		matches, _ := filepath.Glob(filepath.Join(env.cfg.WorkspaceDir(), "slack_token_*.json"))
		assert.Empty(t, matches)
	}
}

func TestSlackConnectServe_StdinEOFExits(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	h.closeStdin(t)

	_, ok := <-h.lines
	assert.False(t, ok, "stdout closed")
	_, err := http.Get(h.base + "/slack/connect") //nolint:bodyclose // the dial must fail: no body
	require.Error(t, err, "the listener is closed")
	ln, err := slackconnect.Listen(h.port)
	require.NoError(t, err, "the port is free afterwards")
	require.NoError(t, ln.Close())
}

func TestSlackConnectListener_PortBusy(t *testing.T) {
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
	assert.ErrorIs(t, err, errQuietExit, "port_busy says it all; nothing on stderr")
	assert.JSONEq(t, `{"event":"port_busy","port":`+strconv.Itoa(port)+`}`, out.String())
}

func TestSlackConnectServe_BadStartFails(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	h.send(t, `not json`)
	h.send(t, `{"cmd":"start","team_id":"acme","client_id":"x"}`)
	ev := h.expect(t, "failed")
	assert.Equal(t, "other", ev["reason"])
	assert.Equal(t, "", ev["flow"])
	h.send(t, `{"cmd":"confirm","flow":"nope"}`)
	assert.Equal(t, "other", h.expect(t, "failed")["reason"])
	assert.Empty(t, h.browserURLs())
}

func TestSlackConnectServe_StartPurgeRunning(t *testing.T) {
	env := newConnectEnv(t)
	id := env.seedAccount(t, connTeam, connNewID)
	startRunningPurge(t, env.db, "slack", id)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	h.send(t, `{"cmd":"start","team_id":"`+connTeam+`","client_id":"`+connNewID+`","account_id":`+strconv.FormatInt(id, 10)+`}`)
	assert.Equal(t, "purge_running", h.expect(t, "failed")["reason"])
	assert.Empty(t, h.browserURLs())
}

func TestSlackConnectServe_OtherUserFails(t *testing.T) {
	env := newConnectEnv(t)
	env.seedAccount(t, connTeam, connRetiredID)
	stubSlackIdentityServer(t, connOtherUser, connTeam, "Acme", "acme")
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	h.send(t, `{"cmd":"start","team_id":"`+connTeam+`","client_id":"`+connNewID+`"}`)
	h.expect(t, "browser")
	_, body := h.callback(t, "code-1")
	assert.Contains(t, body, "could not save the connection")
	ev := h.expect(t, "failed")
	assert.Equal(t, "other_user", ev["reason"])
	assert.Equal(t, "signed in as someone else; nothing was changed", ev["message"])
}

// TestSlackConnectServe_WireGolden runs one session through every event
// kind and every failure reason and pins its stdout as the Desktop's
// decoder fixture (flow ids and ports normalized). -update rewrites it.
func TestSlackConnectServe_WireGolden(t *testing.T) {
	env := newConnectEnv(t)
	env.seedAccount(t, connTeam, connRetiredID)
	purging := env.seedAccount(t, "T0BETA", connNewID)
	startRunningPurge(t, env.db, "slack", purging)
	stub := stubSlackIdentity(t, connUser, connTeam)
	h := startConnectServe(t, env, func(code string) (slackconnect.Grant, error) {
		switch code {
		case "bad":
			return slackconnect.Grant{}, errors.New("slack oauth.v2.access: invalid_code")
		case "other-team":
			g := connGrant(connNewID)
			g.TeamID = connOtherTeam
			return g, nil
		}
		return connGrant(connNewID), nil
	})
	start := `{"cmd":"start","team_id":"` + connTeam + `","client_id":"` + connNewID + `"}`

	h.link(t, connTeam, connNewID)
	flow := h.expect(t, "link")["flow"].(string)
	h.send(t, start)
	h.expect(t, "busy")
	h.link(t, connTeam, connNewID)
	h.expect(t, "link_busy")
	h.send(t, `{"cmd":"confirm","flow":"`+flow+`"}`)
	h.expect(t, "browser")
	h.callback(t, "code-1")
	h.expect(t, "connected")

	for _, c := range []struct{ query, reason string }{
		{"error=access_denied", "denied"},
		{"code=bad", "exchange"},
		{"code=other-team", "team_mismatch"},
	} {
		h.send(t, start)
		h.expect(t, "browser")
		h.redirect(t, c.query)
		assert.Equal(t, c.reason, h.expect(t, "failed")["reason"])
	}
	stub.set(connOtherUser, connTeam)
	h.send(t, start)
	h.expect(t, "browser")
	h.callback(t, "code-2")
	assert.Equal(t, "other_user", h.expect(t, "failed")["reason"])

	h.send(t, start)
	second := h.expect(t, "browser")["flow"].(string)
	h.send(t, `{"cmd":"cancel","flow":"`+second+`"}`)
	assert.Equal(t, "cancelled", h.expect(t, "failed")["reason"])

	// Starts refused before a flow begins: "flow":"".
	h.send(t, `{"cmd":"start","team_id":"acme","client_id":"x"}`)
	assert.Equal(t, "other", h.expect(t, "failed")["reason"])
	h.send(t, `{"cmd":"start","team_id":"T0BETA","client_id":"`+connNewID+`","account_id":`+strconv.FormatInt(purging, 10)+`}`)
	assert.Equal(t, "purge_running", h.expect(t, "failed")["reason"])
	policytest.Set(t, map[string]any{"AllowedSources": []any{"google"}})
	h.send(t, start)
	assert.Equal(t, "policy", h.expect(t, "failed")["reason"])
	h.closeStdin(t)

	var busy strings.Builder
	held, err := slackconnect.Listen(0)
	require.NoError(t, err)
	defer held.Close()
	_ = serveSlackConnect(context.Background(), env.cfg, env.db, strings.NewReader(""), &busy, io.Discard,
		slackConnectDeps{port: held.Addr().(*net.TCPAddr).Port, listen: slackconnect.Listen})

	lines := append(append([]string(nil), h.raw...), strings.TrimSpace(busy.String()))
	got := normalizeServeWire(t, lines)
	if *updateSessionReportGolden {
		require.NoError(t, os.WriteFile(serveGolden, []byte(got), 0o600))
	}
	want, err := os.ReadFile(serveGolden)
	require.NoError(t, err, "run with -update to write the fixture")
	assert.Equal(t, string(want), got)
}

func TestSlackConnectServe_StartUnknownAccountFails(t *testing.T) {
	env := newConnectEnv(t)
	h := startConnectServe(t, env, fixedGrant(connGrant(connNewID)))
	h.send(t, `{"cmd":"start","team_id":"`+connTeam+`","client_id":"`+connNewID+`","account_id":42}`)
	ev := h.expect(t, "failed")
	assert.Equal(t, "other", ev["reason"])
	assert.Equal(t, "", ev["flow"])
	assert.Contains(t, ev["message"], "account 42 not found")
	assert.Empty(t, h.browserURLs())
}

// acceptSignal wraps a listener and reports each accepted connection.
type acceptSignal struct {
	net.Listener
	accepted chan struct{}
}

func (a acceptSignal) Accept() (net.Conn, error) {
	c, err := a.Listener.Accept()
	if err == nil {
		a.accepted <- struct{}{}
	}
	return c, err
}

// Stdin closes while the loop is storing a grant (the callback waits for
// the answer) and a link's handler is blocked handing its event over: both
// browsers get a page and serve exits 0.
func TestSlackConnectServe_EOFWhileRequestsWait(t *testing.T) {
	env := newConnectEnv(t)
	stub := stubSlackIdentity(t, connUser, connTeam)
	inAuth, release := make(chan struct{}), make(chan struct{})
	stub.onAuth = func() {
		close(inAuth)
		<-release
	}
	accepted := make(chan struct{}, 4)
	h := startConnectServeOn(t, env, fixedGrant(connGrant(connNewID)), func(port int) (net.Listener, error) {
		ln, err := slackconnect.Listen(port)
		if err != nil {
			return nil, err
		}
		return acceptSignal{Listener: ln, accepted: accepted}, nil
	})
	h.send(t, `{"cmd":"start","team_id":"`+connTeam+`","client_id":"`+connNewID+`"}`)
	h.expect(t, "browser")

	type page struct {
		status int
		err    error
	}
	fetch := func(path string) <-chan page {
		ch := make(chan page, 1)
		go func() {
			resp, err := http.Get(h.base + path)
			if err != nil {
				ch <- page{err: err}
				return
			}
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			ch <- page{status: resp.StatusCode}
		}()
		return ch
	}
	callbackPage := fetch(h.redirectPath(t, "code=code-1"))
	<-accepted
	<-inAuth // the loop is inside the account write
	linkPage := fetch("/slack/connect?team=" + connTeam + "&client=" + connNewID)
	<-accepted
	require.NoError(t, h.stdin.Close())
	close(release)

	cb := <-callbackPage
	require.NoError(t, cb.err)
	assert.Equal(t, http.StatusOK, cb.status)
	lp := <-linkPage
	require.NoError(t, lp.err, "the blocked link still gets a page")
	assert.Contains(t, []int{http.StatusOK, http.StatusServiceUnavailable}, lp.status)
	h.closed = true
	require.NoError(t, <-h.done, "serve exits 0")
}

// normalizeServeWire replaces flow ids with flow-1, flow-2… in order of
// appearance and every port with 18551.
func normalizeServeWire(t *testing.T, lines []string) string {
	t.Helper()
	flows := map[string]string{}
	var b strings.Builder
	for _, line := range lines {
		var ev map[string]any
		require.NoError(t, json.Unmarshal([]byte(line), &ev), line)
		if f, ok := ev["flow"].(string); ok && f != "" {
			if flows[f] == "" {
				flows[f] = "flow-" + strconv.Itoa(len(flows)+1)
			}
			line = strings.ReplaceAll(line, f, flows[f])
		}
		if p, ok := ev["port"].(float64); ok {
			line = strings.Replace(line, `"port":`+strconv.Itoa(int(p)), `"port":18551`, 1)
		}
		b.WriteString(line + "\n")
	}
	return b.String()
}
