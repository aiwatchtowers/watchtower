package slackconnect

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"syscall"

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

// EventKind names what the listener tells its owner.
type EventKind string

const (
	// EventLink: a connect link started a flow that waits for Confirm.
	EventLink EventKind = "link"
	// EventBusy: a link arrived while Flow was running; nothing started.
	EventBusy EventKind = "busy"
	// EventCallback: Slack's redirect ended Flow; Result says how. The owner
	// must answer on Reply exactly once — nil after storing a connected grant,
	// or the error that kept it from being stored — before the browser gets
	// its page.
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
func Handler(reg *Registry, events chan<- Event, host string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != host {
			w.WriteHeader(http.StatusMisdirectedRequest)
			return
		}
		var serve func(http.ResponseWriter, *http.Request, *Registry, chan<- Event)
		switch r.URL.Path {
		case connectPath:
			serve = serveConnect
		case callbackPath:
			serve = serveCallback
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
		serve(w, r, reg, events)
	})
}

func serveConnect(w http.ResponseWriter, r *http.Request, reg *Registry, events chan<- Event) {
	t, err := ParseConnectInput("http://" + linkHost() + connectPath + "?" + r.URL.RawQuery)
	if err != nil {
		writePage(w, http.StatusBadRequest, oauthpage.Error("This is not a Watchtower Slack link.", false))
		return
	}
	id, err := reg.Begin(t, true)
	switch {
	case errors.Is(err, ErrFlowRunning):
		if !send(r, events, Event{Kind: EventBusy, Flow: id}) {
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
	if !send(r, events, Event{Kind: EventLink, Flow: id, Target: t}) {
		reg.Cancel(id)
		return
	}
	writePage(w, http.StatusOK, oauthpage.SwitchToApp())
}

func serveCallback(w http.ResponseWriter, r *http.Request, reg *Registry, events chan<- Event) {
	q := r.URL.Query()
	res, err := reg.Callback(q.Get("state"), q.Get("code"), q.Get("error"))
	if err != nil {
		auth.WriteStaleCallback(w)
		return
	}
	reply := make(chan error, 1)
	// The flow has ended and the code is spent: the owner must learn the
	// result even if the browser tab is gone, so this send does not give up.
	events <- Event{Kind: EventCallback, Flow: res.Flow, Target: res.Target, Result: res, Reply: reply}
	var stored error
	select {
	case stored = <-reply:
	case <-r.Context().Done():
		return
	}
	switch {
	case res.Outcome != OutcomeConnected:
		writePage(w, http.StatusOK, oauthpage.Error(res.Message, false))
	case stored != nil:
		writePage(w, http.StatusOK, oauthpage.Error(stored.Error(), false))
	default:
		writePage(w, http.StatusOK, oauthpage.Success("Slack", false))
	}
}

// send hands ev to the listener's owner, giving up when the browser goes away.
func send(r *http.Request, events chan<- Event, ev Event) bool {
	select {
	case events <- ev:
		return true
	case <-r.Context().Done():
		return false
	}
}

func writePage(w http.ResponseWriter, status int, page string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, page)
}
