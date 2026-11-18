package slackconnect

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"syscall"
	"time"

	"watchtower/internal/auth"
	"watchtower/internal/oauthpage"
)

// ErrPortBusy reports that another process holds the listener's port.
var ErrPortBusy = errors.New("port is busy")

// Listen binds the connect listener on 127.0.0.1:port (Port in production,
// 0 in tests); never on another interface. A port held by another process
// is ErrPortBusy.
func Listen(port int) (net.Listener, error) {
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if errors.Is(err, syscall.EADDRINUSE) {
		return nil, fmt.Errorf("port %d: %w", port, ErrPortBusy)
	}
	return ln, err
}

// storeWait bounds how long the browser's callback page waits for the
// owner to store a connected grant; past it the page says to check Watchtower.
const storeWait = 30 * time.Second

// EventKind names what the listener tells its owner.
type EventKind string

const (
	// EventLink: a connect link started a flow that waits for Confirm.
	EventLink EventKind = "link"
	// EventBusy: a link arrived while Flow was running; nothing started.
	EventBusy EventKind = "busy"
	// EventCallback: Slack's redirect ended Flow; Result says how. For
	// OutcomeConnected, Reply is set and the owner answers on it exactly once
	// (it is buffered, so the send never blocks) — nil after storing the
	// grant, or the error that kept it from being stored; the browser's page
	// waits for that answer (at most storeWait). For every other outcome
	// Reply is nil.
	EventCallback EventKind = "callback"
)

// Event is one thing the listener reports to the process that owns it.
type Event struct {
	Kind   EventKind
	Flow   FlowID
	Target Target
	Result Result
	Reply  chan<- error
}

// Handler serves the connect listener: GET /slack/connect (a link: starts a
// flow that waits for Confirm, answers "Switch to Watchtower to confirm" and
// never redirects) and GET /callback (Slack's redirect: finishes the flow; no
// flow → the "start again" page, nothing else). A request whose Host is not
// exactly host is 421, another path 404, another method 405 — all with no
// body. It never serves files.
//
// stop is closed by the owner when it stops reading events (shutdown): from
// then on no request blocks on events, so http.Server.Shutdown can finish.
func Handler(reg *Registry, events chan<- Event, host string, stop <-chan struct{}) http.Handler {
	l := &listener{reg: reg, events: events, stop: stop}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != host {
			w.WriteHeader(http.StatusMisdirectedRequest)
			return
		}
		var serve func(http.ResponseWriter, *http.Request)
		switch r.URL.Path {
		case connectPath:
			serve = l.serveConnect
		case callbackPath:
			serve = l.serveCallback
		default:
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		serve(w, r)
	})
}

type listener struct {
	reg    *Registry
	events chan<- Event
	stop   <-chan struct{}
}

func (l *listener) serveConnect(w http.ResponseWriter, r *http.Request) {
	t, err := ParseConnectInput("http://" + linkHost() + connectPath + "?" + r.URL.RawQuery)
	if err != nil {
		writePage(w, http.StatusBadRequest, oauthpage.Error("This is not a Watchtower Slack link.", false))
		return
	}
	id, err := l.reg.Begin(t, true)
	switch {
	case errors.Is(err, ErrFlowRunning):
		if !l.send(r, Event{Kind: EventBusy, Flow: id}) {
			writeNotTaken(w)
			return
		}
		writePage(w, http.StatusConflict, oauthpage.Error(
			"Another Slack connection is in progress in Watchtower. Finish or cancel it there, then open this link again.",
			false))
		return
	case err != nil:
		writePage(w, http.StatusInternalServerError, oauthpage.Error("Watchtower could not start the connection.", false))
		return
	}
	if !l.send(r, Event{Kind: EventLink, Flow: id, Target: t}) {
		l.reg.Cancel(id)
		writeNotTaken(w)
		return
	}
	writePage(w, http.StatusOK, oauthpage.SwitchToApp())
}

func (l *listener) serveCallback(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	res, err := l.reg.Callback(q.Get("state"), q.Get("code"), q.Get("error"))
	if err != nil {
		auth.WriteStaleCallback(w)
		return
	}
	ev := Event{Kind: EventCallback, Flow: res.Flow, Target: res.Target, Result: res}
	if res.Outcome != OutcomeConnected {
		// The flow has ended and the code is spent: the owner learns the
		// result even if the tab is gone — only its stop ends this send.
		if !l.sendUntilStop(ev) {
			writePage(w, http.StatusOK, oauthpage.CheckApp())
			return
		}
		writePage(w, http.StatusOK, oauthpage.Error(res.Message, false))
		return
	}
	reply := make(chan error, 1)
	ev.Reply = reply
	if !l.sendUntilStop(ev) {
		writePage(w, http.StatusOK, oauthpage.CheckApp())
		return
	}
	select {
	case stored := <-reply:
		if stored != nil {
			// The owner logs the error; the page carries a fixed sentence.
			writePage(w, http.StatusOK, oauthpage.Error(
				"Slack signed you in, but Watchtower could not save the connection. Check Watchtower for details.",
				false))
			return
		}
		writePage(w, http.StatusOK, oauthpage.Success("Slack", false))
	case <-r.Context().Done():
	case <-l.stop:
		writePage(w, http.StatusOK, oauthpage.CheckApp())
	case <-l.reg.clock.After(storeWait):
		writePage(w, http.StatusOK, oauthpage.CheckApp())
	}
}

// send hands ev to the owner, giving up when the browser goes away or the
// owner stops.
func (l *listener) send(r *http.Request, ev Event) bool {
	select {
	case l.events <- ev:
		return true
	case <-r.Context().Done():
		return false
	case <-l.stop:
		return false
	}
}

// sendUntilStop hands ev to the owner, giving up only when the owner stops.
func (l *listener) sendUntilStop(ev Event) bool {
	select {
	case l.events <- ev:
		return true
	case <-l.stop:
		return false
	}
}

// writeNotTaken answers a link the owner did not take (it stopped, or the
// tab went away while the owner was busy).
func writeNotTaken(w http.ResponseWriter) {
	writePage(w, http.StatusServiceUnavailable, oauthpage.Error(
		"Watchtower did not take this link. Open Watchtower, then open the link again.", false))
}

func writePage(w http.ResponseWriter, status int, page string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, page)
}
