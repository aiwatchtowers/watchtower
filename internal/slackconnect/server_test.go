package slackconnect

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

// startListener runs Handler on a loopback listener on an ephemeral port
// (never 18551) and returns its base URL and Host value.
func startListener(t *testing.T, reg *Registry, events chan<- Event) (base, host string) {
	t.Helper()
	stop := make(chan struct{})
	t.Cleanup(func() { close(stop) })
	return startListenerStop(t, reg, events, stop)
}

func startListenerStop(t *testing.T, reg *Registry, events chan<- Event, stop <-chan struct{}) (base, host string) {
	t.Helper()
	ln, err := Listen(0)
	if err != nil {
		t.Fatal(err)
	}
	host = ln.Addr().String()
	srv := httptest.NewUnstartedServer(Handler(reg, events, host, stop))
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
		ev.Reply <- errors.New("other_user: detail for the log only")
	}()
	status, body := get(t, base+"/callback?state="+url.QueryEscape(stateOf(t, authURL))+"&code=abc")
	if status != http.StatusOK || !strings.Contains(body, "could not save the connection") {
		t.Fatalf("callback = %d:\n%s", status, body)
	}
	if strings.Contains(body, "detail for the log only") {
		t.Fatalf("the owner's error reached the page:\n%s", body)
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

// callbackRequest builds a request for the handler's callback path.
func callbackRequest(ctx context.Context, host, query string) *http.Request {
	req := httptest.NewRequestWithContext(ctx, http.MethodGet, "http://"+host+"/callback?"+query, nil)
	req.Host = host
	return req
}

func TestSlackConnectListener_NonConnectedOutcomeNeedsNoReply(t *testing.T) {
	reg, _, _ := newTestRegistry(t)
	events := make(chan Event, 1)
	const host = "127.0.0.1:1"
	h := Handler(reg, events, host, nil)
	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, callbackRequest(context.Background(), host,
		"state="+url.QueryEscape(stateOf(t, authURL))+"&error=access_denied"))
	ev := <-events
	if ev.Kind != EventCallback || ev.Result.Outcome != OutcomeDenied || ev.Reply != nil {
		t.Fatalf("event = %+v, want a denied callback with no Reply", ev)
	}
	if !strings.Contains(rec.Body.String(), "not granted") {
		t.Fatalf("page:\n%s", rec.Body.String())
	}
}

func TestSlackConnectListener_OwnerNeverReplies(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ex := &fakeExchange{team: testTarget.TeamID}
		reg := NewRegistry(SystemClock{}, ex.exchange)
		events := make(chan Event, 1)
		const host = "127.0.0.1:1"
		h := Handler(reg, events, host, nil)
		id, _ := reg.Begin(testTarget, false)
		authURL, _ := reg.BrowserURL(id)

		start := time.Now()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, callbackRequest(context.Background(), host,
			"state="+url.QueryEscape(stateOf(t, authURL))+"&code=abc"))
		if waited := time.Since(start); waited != storeWait {
			t.Fatalf("handler waited %v, want storeWait %v", waited, storeWait)
		}
		if ev := <-events; ev.Reply == nil {
			t.Fatal("connected callback has no Reply")
		}
		if !strings.Contains(rec.Body.String(), "Check Watchtower for the result") {
			t.Fatalf("page:\n%s", rec.Body.String())
		}
	})
}

func TestSlackConnectListener_BrowserGoneBeforeReply(t *testing.T) {
	reg, _, _ := newTestRegistry(t)
	events := make(chan Event, 1)
	const host = "127.0.0.1:1"
	h := Handler(reg, events, host, nil)
	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	rec := httptest.NewRecorder()
	go func() {
		defer close(done)
		h.ServeHTTP(rec, callbackRequest(ctx, host, "state="+url.QueryEscape(stateOf(t, authURL))+"&code=abc"))
	}()
	ev := <-events // the owner has the grant even though the tab goes away
	if ev.Result.Outcome != OutcomeConnected {
		t.Fatalf("event = %+v", ev)
	}
	cancel()
	<-done
	ev.Reply <- nil // a late reply never blocks the owner
}

func TestSlackConnectListener_StoppedOwnerReleasesHandler(t *testing.T) {
	reg, _, _ := newTestRegistry(t)
	events := make(chan Event) // nobody reads
	stop := make(chan struct{})
	close(stop)
	const host = "127.0.0.1:1"
	h := Handler(reg, events, host, stop)

	// A callback whose flow ended: the handler does not block on events.
	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, callbackRequest(context.Background(), host, "state="+url.QueryEscape(stateOf(t, authURL))+"&code=abc"))
	if !strings.Contains(rec.Body.String(), "Check Watchtower for the result") {
		t.Fatalf("callback page with a stopped owner:\n%s", rec.Body.String())
	}

	// A link: refused, and the flow it began is not left behind.
	req := httptest.NewRequest(http.MethodGet,
		"http://"+host+"/slack/connect?team="+testTarget.TeamID+"&client="+testTarget.ClientID, nil)
	req.Host = host
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("link with a stopped owner = %d", rec.Code)
	}
	if _, err := reg.Begin(testTarget, false); err != nil {
		t.Fatalf("the refused link left a flow: %v", err)
	}
}

func TestSlackConnectListener_BusyLinkWithStoppedOwner(t *testing.T) {
	reg, _, _ := newTestRegistry(t)
	events := make(chan Event) // nobody reads
	stop := make(chan struct{})
	close(stop)
	const host = "127.0.0.1:1"
	h := Handler(reg, events, host, stop)
	running, _ := reg.Begin(testTarget, false)

	req := httptest.NewRequest(http.MethodGet,
		"http://"+host+"/slack/connect?team="+testTarget.TeamID+"&client="+testTarget.ClientID, nil)
	req.Host = host
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "did not take this link") {
		t.Fatalf("busy link with a stopped owner = %d:\n%s", rec.Code, rec.Body.String())
	}
	if _, ok := reg.WaitingSince(running); !ok {
		t.Fatal("the busy link ended the running flow")
	}
}

func TestSlackConnectListener_StopWhileWaitingForReply(t *testing.T) {
	reg, _, _ := newTestRegistry(t)
	events := make(chan Event, 1)
	stop := make(chan struct{})
	const host = "127.0.0.1:1"
	h := Handler(reg, events, host, stop)
	id, _ := reg.Begin(testTarget, false)
	authURL, _ := reg.BrowserURL(id)

	done := make(chan struct{})
	rec := httptest.NewRecorder()
	go func() {
		defer close(done)
		h.ServeHTTP(rec, callbackRequest(context.Background(), host,
			"state="+url.QueryEscape(stateOf(t, authURL))+"&code=abc"))
	}()
	ev := <-events // the owner took the event and stops before replying
	if ev.Reply == nil {
		t.Fatal("connected callback has no Reply")
	}
	close(stop)
	<-done
	if !strings.Contains(rec.Body.String(), "Check Watchtower for the result") {
		t.Fatalf("page after stop:\n%s", rec.Body.String())
	}
}
