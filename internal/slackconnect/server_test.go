package slackconnect

import (
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// startListener runs Handler on a loopback listener on an ephemeral port
// (never 18551) and returns its base URL and Host value.
func startListener(t *testing.T, reg *Registry, events chan<- Event) (base, host string) {
	t.Helper()
	ln, err := Listen(0)
	if err != nil {
		t.Fatal(err)
	}
	host = ln.Addr().String()
	srv := httptest.NewUnstartedServer(Handler(reg, events, host))
	srv.Listener.Close()
	srv.Listener = ln
	srv.Start()
	t.Cleanup(srv.Close)
	return "http://" + host, host
}

func get(t *testing.T, rawURL string) (int, string) {
	t.Helper()
	resp, err := http.Get(rawURL) //nolint:gosec // loopback test server
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(body)
}

func TestListen_LoopbackOnly(t *testing.T) {
	ln, err := Listen(0)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	addr := ln.Addr().(*net.TCPAddr)
	if !addr.IP.Equal(net.IPv4(127, 0, 0, 1)) {
		t.Fatalf("listener bound %v, want 127.0.0.1", addr.IP)
	}
	// A second bind of the same port reports ErrPortBusy.
	if _, err := Listen(addr.Port); !errors.Is(err, ErrPortBusy) {
		t.Fatalf("second Listen err = %v, want ErrPortBusy", err)
	}
}

func TestSlackConnectListener_RequiresConfirm(t *testing.T) {
	reg, _, ex := newTestRegistry(t)
	events := make(chan Event, 4)
	base, _ := startListener(t, reg, events)

	status, body := get(t, base+"/slack/connect?team="+testTarget.TeamID+"&client="+testTarget.ClientID)
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}
	if !strings.Contains(body, "Switch to Watchtower to confirm") {
		t.Fatalf("page does not ask to switch to Watchtower:\n%s", body)
	}
	if strings.Contains(body, "slack.com") {
		t.Fatalf("the first hop page links to Slack:\n%s", body)
	}
	var ev Event
	select {
	case ev = <-events:
	default:
		t.Fatal("no link event")
	}
	if ev.Kind != EventLink || ev.Flow == "" || ev.Target.TeamID != testTarget.TeamID || ev.Target.ClientID != testTarget.ClientID {
		t.Fatalf("event = %+v, want a link event for the target", ev)
	}
	select {
	case extra := <-events:
		t.Fatalf("unexpected second event %+v", extra)
	default:
	}
	// Nothing reached Slack and the authorize URL is not handed out yet.
	if ex.count() != 0 {
		t.Fatalf("exchange called %d times", ex.count())
	}
	if _, err := reg.BrowserURL(ev.Flow); !errors.Is(err, ErrNotConfirmed) {
		t.Fatalf("BrowserURL err = %v, want ErrNotConfirmed", err)
	}

	// A second link while the first waits answers busy and names the running flow.
	status, _ = get(t, base+"/slack/connect?team="+testTarget.TeamID+"&client="+testTarget.ClientID)
	if status != http.StatusConflict {
		t.Fatalf("second link status = %d, want 409", status)
	}
	if busy := <-events; busy.Kind != EventBusy || busy.Flow != ev.Flow {
		t.Fatalf("busy event = %+v", busy)
	}

	// A malformed link is refused without an event.
	status, _ = get(t, base+"/slack/connect?team=nope&client="+testTarget.ClientID)
	if status != http.StatusBadRequest {
		t.Fatalf("bad link status = %d, want 400", status)
	}
	select {
	case extra := <-events:
		t.Fatalf("bad link produced an event %+v", extra)
	default:
	}
}

func TestSlackConnectListener_CallbackWithoutFlow(t *testing.T) {
	reg, _, ex := newTestRegistry(t)
	events := make(chan Event, 1)
	base, _ := startListener(t, reg, events)

	status, body := get(t, base+"/callback?state=x&code=y")
	if status != http.StatusBadRequest || !strings.Contains(body, "out of date") {
		t.Fatalf("callback without flow = %d:\n%s", status, body)
	}
	if ex.count() != 0 {
		t.Fatal("exchanger called without a flow")
	}
	select {
	case ev := <-events:
		t.Fatalf("callback without flow produced an event %+v", ev)
	default:
	}
}

func TestSlackConnectListener_CallbackDelivers(t *testing.T) {
	reg, _, _ := newTestRegistry(t)
	events := make(chan Event, 1)
	base, _ := startListener(t, reg, events)

	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)
	go func() {
		ev := <-events
		if ev.Kind == EventCallback && ev.Result.Outcome == OutcomeConnected {
			ev.Reply <- nil
			return
		}
		ev.Reply <- errors.New("unexpected")
	}()
	status, body := get(t, base+"/callback?state="+url.QueryEscape(stateOf(t, authURL))+"&code=abc")
	if status != http.StatusOK || !strings.Contains(body, "Connected") {
		t.Fatalf("callback = %d:\n%s", status, body)
	}
}

func TestSlackConnectListener_CallbackWriteFailureShowsError(t *testing.T) {
	reg, _, _ := newTestRegistry(t)
	events := make(chan Event, 1)
	base, _ := startListener(t, reg, events)

	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)
	go func() {
		ev := <-events
		ev.Reply <- errors.New("Signed in as someone else; nothing was changed")
	}()
	status, body := get(t, base+"/callback?state="+url.QueryEscape(stateOf(t, authURL))+"&code=abc")
	if status != http.StatusOK || !strings.Contains(body, "Authorization failed") ||
		!strings.Contains(body, "someone else") {
		t.Fatalf("callback = %d:\n%s", status, body)
	}
}

func TestSlackConnectListener_RejectsOtherHostsMethodsPaths(t *testing.T) {
	reg, _, ex := newTestRegistry(t)
	events := make(chan Event, 4)
	base, host := startListener(t, reg, events)
	_, port, _ := net.SplitHostPort(host)
	link := "/slack/connect?team=" + testTarget.TeamID + "&client=" + testTarget.ClientID

	cases := []struct {
		name, method, path, host string
		want                     int
	}{
		{"localhost host", http.MethodGet, link, "localhost:" + port, http.StatusMisdirectedRequest},
		{"host without port", http.MethodGet, link, "127.0.0.1", http.StatusMisdirectedRequest},
		{"foreign host", http.MethodGet, "/callback?state=x&code=y", "example.com", http.StatusMisdirectedRequest},
		{"unknown path", http.MethodGet, "/", host, http.StatusNotFound},
		{"file path", http.MethodGet, "/etc/passwd", host, http.StatusNotFound},
		{"path prefix", http.MethodGet, "/slack/connect/x", host, http.StatusNotFound},
		{"post connect", http.MethodPost, link, host, http.StatusMethodNotAllowed},
		{"head connect", http.MethodHead, link, host, http.StatusMethodNotAllowed},
		{"put callback", http.MethodPut, "/callback?state=x&code=y", host, http.StatusMethodNotAllowed},
		{"options callback", http.MethodOptions, "/callback", host, http.StatusMethodNotAllowed},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req, err := http.NewRequest(tc.method, base+tc.path, nil)
			if err != nil {
				t.Fatal(err)
			}
			req.Host = tc.host
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			body, _ := io.ReadAll(resp.Body)
			if resp.StatusCode != tc.want {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tc.want)
			}
			if len(body) != 0 {
				t.Fatalf("refusal carries a body: %q", body)
			}
		})
	}
	select {
	case ev := <-events:
		t.Fatalf("a refused request produced an event %+v", ev)
	default:
	}
	if ex.count() != 0 {
		t.Fatal("a refused request reached the exchanger")
	}
	if _, err := reg.Begin(testTarget, false); err != nil {
		t.Fatalf("a refused request started a flow: %v", err)
	}
}
