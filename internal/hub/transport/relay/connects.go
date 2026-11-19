package relay

import (
	"net/http"
	"strings"
	"sync"
	"time"
)

// clientHTTPTimeout is the relay client's own default HTTP timeout (kept
// when ConnectWatch wraps no client of the caller's).
const clientHTTPTimeout = 30 * time.Second

// ConnectWatch sees the relay client's WebSocket connects: every handshake
// the relay accepted (101 on /v1/ws) is one connect or reconnect, never a
// folded overflow's marker. The relay client has no reconnect event of its
// own; its record-less ZoneChanged follows both.
type ConnectWatch struct {
	base http.RoundTripper
	hc   *http.Client

	mu sync.Mutex
	fn func()
}

// WatchConnects wraps hc (nil = the relay client's default) so the client
// built with WithHTTPClient(w.HTTPClient()) reports its connects to w.
func WatchConnects(hc *http.Client) *ConnectWatch {
	copied := http.Client{Timeout: clientHTTPTimeout}
	if hc != nil {
		copied = *hc
	}
	w := &ConnectWatch{base: copied.Transport}
	if w.base == nil {
		w.base = http.DefaultTransport
	}
	copied.Transport = w
	w.hc = &copied
	return w
}

// HTTPClient is the client to hand the relay client.
func (w *ConnectWatch) HTTPClient() *http.Client { return w.hc }

// RoundTrip implements http.RoundTripper.
func (w *ConnectWatch) RoundTrip(r *http.Request) (*http.Response, error) {
	res, err := w.base.RoundTrip(r)
	if err == nil && res.StatusCode == http.StatusSwitchingProtocols && strings.HasSuffix(r.URL.Path, "/v1/ws") {
		w.mu.Lock()
		fn := w.fn
		w.mu.Unlock()
		if fn != nil {
			fn()
		}
	}
	return res, err
}

// OnConnected makes fn run at each later connect (on the client's dialing
// goroutine: fn must not block). A Transport built without a ConnectWatch
// never calls it.
func (t *Transport) OnConnected(fn func()) {
	if w := t.o.Connects; w != nil {
		w.mu.Lock()
		w.fn = fn
		w.mu.Unlock()
	}
}
