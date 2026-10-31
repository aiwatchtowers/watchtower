package client

import (
	"context"
	"errors"
	"math/rand/v2"
	"net/http"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	relayv1 "watchtower/internal/hub/transport/relay/relayv1"
)

// Close codes of the relay protocol (see internal/ws).
const (
	closeUnsupportedVersion websocket.StatusCode = 4000
	closeUnauthenticated    websocket.StatusCode = 4001
)

// goingAwayDelay is the random 1-3 s a client waits before reconnecting after GoingAway.
func goingAwayDelay() time.Duration { return time.Second + rand.N(2*time.Second+1) } //nolint:gosec // jitter

const handshakeTimeout = 10 * time.Second

// ErrDisconnected is returned by Send while the connection is down or when it drops before the
// response arrived; the request may or may not have been executed.
var ErrDisconnected = errors.New("relay: websocket disconnected")

// errUnauthenticated: the server refused the session at hello.
var errUnauthenticated = errors.New("relay: websocket unauthenticated")

// ErrUnsupportedVersion: the server does not speak this protocol version; the app must be updated.
var ErrUnsupportedVersion = errors.New("relay: unsupported protocol version")

// Event is a server event, a record-less ZoneChanged (seq 0) the connection generates — changes of
// that zone may have been missed, pull them — or, with Err set, a zone the connection could not
// subscribe again after a reconnect (the zone is dropped).
type Event struct {
	*relayv1.Event
	Err *ZoneError
}

// ZoneError reports a zone dropped from the connection's subscriptions.
type ZoneError struct {
	Zone string
	Err  error
}

func (e *ZoneError) Error() string { return "relay: zone " + e.Zone + ": " + e.Err.Error() }

// Conn is a WebSocket connection that survives drops: it reconnects with the client's backoff,
// logs in again when the session expired (Control SESSION_EXPIRED or close 4001), reconnects at
// once on GoingAway, and subscribes its zones again, one by one. After every reconnect it emits a
// record-less ZoneChanged (seq 0) for each zone subscribed again.
//
// Reading frames never waits for the consumer of Events: a zone event that does not fit the
// buffer is dropped and replaced by a record-less ZoneChanged of its zone once there is room;
// control events and zone errors are queued without bound and never dropped.
type Conn struct {
	c      *Client
	ctx    context.Context
	cancel context.CancelFunc
	events chan Event
	wake   chan struct{} // nudges the deliverer
	done   chan struct{}
	nextID atomic.Uint64

	mu      sync.Mutex
	ws      *websocket.Conn // nil while reconnecting
	tok     string          // the session token ws was opened with
	zones   map[string]struct{}
	pending map[uint64]chan *relayv1.Response
	backlog []Event         // controls and zone errors waiting for room in events
	resync  map[string]bool // zones owed a record-less ZoneChanged
}

// Connect dials the WebSocket and returns once the hello handshake succeeded.
func (c *Client) Connect(ctx context.Context) (*Conn, error) {
	ws, tok, err := c.dial(ctx)
	if err != nil {
		return nil, err
	}
	cctx, cancel := context.WithCancel(context.Background())
	conn := &Conn{
		c: c, ctx: cctx, cancel: cancel, events: make(chan Event, c.eventBuffer),
		wake: make(chan struct{}, 1), done: make(chan struct{}),
		ws: ws, tok: tok, zones: map[string]struct{}{}, pending: map[uint64]chan *relayv1.Response{},
		resync: map[string]bool{},
	}
	go conn.run(ws)
	return conn, nil
}

func (c *Client) wsURL() string {
	switch {
	case strings.HasPrefix(c.base, "https://"):
		return "wss://" + strings.TrimPrefix(c.base, "https://") + "/v1/ws"
	case strings.HasPrefix(c.base, "http://"):
		return "ws://" + strings.TrimPrefix(c.base, "http://") + "/v1/ws"
	}
	return c.base + "/v1/ws"
}

// dial opens a connection and performs the hello handshake with the current (or a fresh) session.
// A session the server refuses (HTTP 401 at upgrade, close 4001 at hello) is replaced by a new
// login, once. It returns the token the connection was opened with.
func (c *Client) dial(ctx context.Context) (*websocket.Conn, string, error) {
	ws, tok, err := c.dialOnce(ctx)
	if errors.Is(err, errUnauthenticated) && ctx.Err() == nil {
		ws, tok, err = c.dialOnce(ctx) // the refused token was invalidated: this logs in again
	}
	return ws, tok, err
}

func (c *Client) dialOnce(ctx context.Context) (*websocket.Conn, string, error) {
	tok, err := c.sessionToken(ctx, "")
	if err != nil {
		return nil, "", err
	}
	hctx, cancel := context.WithTimeout(ctx, handshakeTimeout)
	defer cancel()
	ws, res, err := websocket.Dial(hctx, c.wsURL(), &websocket.DialOptions{
		HTTPClient: c.http,
		HTTPHeader: http.Header{"Authorization": {"Bearer " + tok}},
	})
	if err != nil {
		if res != nil && res.StatusCode == http.StatusUnauthorized {
			c.invalidate(tok)
			return nil, "", errUnauthenticated
		}
		return nil, "", err
	}
	ws.SetReadLimit(-1)
	hello, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Hello{Hello: &relayv1.Hello{
		ProtocolVersion: relayv1.ProtocolVersion, SessionToken: tok,
	}}})
	if err := ws.Write(hctx, websocket.MessageBinary, hello); err != nil {
		_ = ws.CloseNow()
		return nil, "", err
	}
	for {
		_, b, err := ws.Read(hctx)
		if err != nil {
			_ = ws.CloseNow()
			switch websocket.CloseStatus(err) {
			case closeUnauthenticated:
				c.invalidate(tok)
				return nil, "", errUnauthenticated
			case closeUnsupportedVersion:
				return nil, "", ErrUnsupportedVersion
			}
			return nil, "", err
		}
		var f relayv1.Frame
		if proto.Unmarshal(b, &f) == nil && f.GetHelloOk() != nil {
			return ws, tok, nil
		}
		// An error response before the close (unsupported version) is followed by the close frame.
	}
}

// Events delivers zone events, control events (SESSION_EXPIRED is handled internally) and zone
// errors. It is closed after Close or when the server rejects the protocol version.
func (k *Conn) Events() <-chan Event { return k.events }

// Close closes the connection for good.
func (k *Conn) Close() error {
	k.cancel()
	k.mu.Lock()
	ws := k.ws
	k.mu.Unlock()
	if ws != nil {
		_ = ws.Close(websocket.StatusNormalClosure, "")
	}
	<-k.done
	return nil
}

// Subscribe subscribes zones; they are subscribed again after every reconnect. While disconnected
// it returns ErrDisconnected and the zones are subscribed on the next connect.
func (k *Conn) Subscribe(ctx context.Context, zones ...string) error {
	k.mu.Lock()
	for _, z := range zones {
		k.zones[z] = struct{}{}
	}
	k.mu.Unlock()
	_, err := k.Send(ctx, &relayv1.Request{Op: &relayv1.Request_Subscribe{Subscribe: &relayv1.Subscribe{Zones: zones}}})
	if err != nil && !errors.Is(err, ErrDisconnected) {
		k.mu.Lock()
		for _, z := range zones {
			delete(k.zones, z)
		}
		k.mu.Unlock()
	}
	return err
}

// Send performs one operation over the WebSocket. Errors are as for Client.Do, plus ErrDisconnected;
// an operation answered UNAVAILABLE is retried as in Client.Do.
func (k *Conn) Send(ctx context.Context, req *relayv1.Request) (*relayv1.Response, error) {
	return k.c.retryUnavailable(ctx, func() (*relayv1.Response, error) { return k.sendOnce(ctx, req) })
}

func (k *Conn) sendOnce(ctx context.Context, req *relayv1.Request) (*relayv1.Response, error) {
	req = proto.Clone(req).(*relayv1.Request)
	req.Id = k.nextID.Add(1)
	b, err := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Request{Request: req}})
	if err != nil {
		return nil, err
	}
	ch := make(chan *relayv1.Response, 1)
	k.mu.Lock()
	ws := k.ws
	if ws != nil {
		k.pending[req.Id] = ch
	}
	k.mu.Unlock()
	if ws == nil {
		return nil, ErrDisconnected
	}
	defer func() {
		k.mu.Lock()
		delete(k.pending, req.Id)
		k.mu.Unlock()
	}()
	if err := ws.Write(ctx, websocket.MessageBinary, b); err != nil {
		return nil, ErrDisconnected
	}
	select {
	case resp, ok := <-ch:
		if !ok {
			return nil, ErrDisconnected
		}
		return resp, errorOf(resp)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// endReason is why a connection ended.
type endReason int

const (
	endDropped endReason = iota
	endGoingAway
	endSessionExpired
	endClosed
)

func (k *Conn) run(ws *websocket.Conn) {
	delivered := make(chan struct{})
	go func() {
		defer close(delivered)
		k.deliver()
	}()
	defer close(k.done)
	defer func() {
		k.cancel() // also when the server stopped speaking our version
		<-delivered
		close(k.events)
	}()
	reconnected := false
	for {
		ended := make(chan endReason, 1)
		go func() { ended <- k.read(ws) }()
		stopPing := make(chan struct{})
		go k.ping(ws, stopPing)
		if reconnected {
			k.resubscribe(ws)
		}
		reason := <-ended
		close(stopPing)
		k.drop()
		if reason == endClosed || k.ctx.Err() != nil {
			return
		}
		var err error
		if ws, err = k.reconnect(reason); err != nil {
			return // closed, or the server no longer speaks our protocol version
		}
		reconnected = true
	}
}

// ping sends a WebSocket ping every 30 s until stop closes; a ping that gets no pong within the
// handshake timeout cuts the connection, so the reader notices and reconnects.
func (k *Conn) ping(ws *websocket.Conn, stop <-chan struct{}) {
	for {
		select {
		case <-k.c.clk.After(pingInterval):
		case <-stop:
			return
		case <-k.ctx.Done():
			return
		}
		ctx, cancel := context.WithTimeout(k.ctx, handshakeTimeout)
		err := ws.Ping(ctx)
		cancel()
		if err != nil {
			if k.ctx.Err() == nil {
				_ = ws.CloseNow()
			}
			return
		}
	}
}

// drop forgets the connection and fails the requests waiting on it.
func (k *Conn) drop() {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.ws = nil
	for id, ch := range k.pending {
		close(ch)
		delete(k.pending, id)
	}
}

// reconnect dials until it succeeds, waiting the backoff between attempts. After GoingAway
// (shutdown, rollout, displacement by a newer connection of the same device) the first attempt
// waits a random 1-3 s, so two clients of one device do not displace each other in a tight loop;
// an expired session is replaced by a new login.
func (k *Conn) reconnect(reason endReason) (*websocket.Conn, error) {
	if reason == endSessionExpired {
		k.mu.Lock()
		tok := k.tok
		k.mu.Unlock()
		k.c.invalidate(tok) // only the connection's own token: Do may already hold a newer one
	}
	for attempt := 0; ; attempt++ {
		wait := k.c.backoff(attempt)
		if attempt == 0 && reason == endGoingAway {
			wait = goingAwayDelay()
		}
		select {
		case <-k.c.clk.After(wait):
		case <-k.ctx.Done():
			return nil, k.ctx.Err()
		}
		ws, tok, err := k.c.dial(k.ctx)
		switch {
		case err == nil:
			k.mu.Lock()
			k.ws, k.tok = ws, tok
			k.mu.Unlock()
			if k.ctx.Err() != nil { // closed while dialing
				_ = ws.CloseNow()
				return nil, k.ctx.Err()
			}
			return ws, nil
		case errors.Is(err, ErrUnsupportedVersion), k.ctx.Err() != nil:
			return nil, err
		}
	}
}

// resubscribe subscribes every zone again, one at a time. A zone the server refuses is dropped and
// reported as a zone error; the others get a record-less ZoneChanged. If a subscribe gets no
// answer, the connection is cut so the next reconnect tries again rather than staying deaf.
func (k *Conn) resubscribe(ws *websocket.Conn) {
	k.mu.Lock()
	zones := make([]string, 0, len(k.zones))
	for z := range k.zones {
		zones = append(zones, z)
	}
	k.mu.Unlock()
	slices.Sort(zones)
	for _, z := range zones {
		ctx, cancel := context.WithTimeout(k.ctx, handshakeTimeout)
		_, err := k.Send(ctx, &relayv1.Request{Op: &relayv1.Request_Subscribe{Subscribe: &relayv1.Subscribe{Zones: []string{z}}}})
		cancel()
		var pe *Error
		switch {
		case err == nil:
			k.markResync(z)
		case errors.As(err, &pe):
			k.mu.Lock()
			delete(k.zones, z)
			k.mu.Unlock()
			k.queue(Event{Err: &ZoneError{Zone: z, Err: err}})
		default:
			_ = ws.CloseNow()
			return
		}
	}
}

// markResync owes zone a record-less ZoneChanged.
func (k *Conn) markResync(zone string) {
	k.mu.Lock()
	k.resync[zone] = true
	k.mu.Unlock()
	k.nudge()
}

// queue appends an event that must not be dropped.
func (k *Conn) queue(ev Event) {
	k.mu.Lock()
	k.backlog = append(k.backlog, ev)
	k.mu.Unlock()
	k.nudge()
}

func (k *Conn) nudge() {
	select {
	case k.wake <- struct{}{}:
	default:
	}
}

// emitZone hands a zone event over without waiting; when the buffer is full the zone is owed a
// record-less ZoneChanged instead.
func (k *Conn) emitZone(ev *relayv1.Event) {
	k.mu.Lock()
	owed := k.resync[ev.GetZoneChanged().GetZone()]
	k.mu.Unlock()
	if !owed { // otherwise the marker that follows covers this change too
		select {
		case k.events <- Event{Event: ev}:
			return
		default:
		}
	}
	k.markResync(ev.GetZoneChanged().GetZone())
}

// deliver moves queued events and owed markers into the events channel, waiting for room.
func (k *Conn) deliver() {
	for {
		select {
		case <-k.wake:
		case <-k.ctx.Done():
			return
		}
		for {
			ev, ok := k.next()
			if !ok {
				break
			}
			select {
			case k.events <- ev:
			case <-k.ctx.Done():
				return
			}
		}
	}
}

// next takes the next queued event, controls and errors before markers.
func (k *Conn) next() (Event, bool) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if len(k.backlog) > 0 {
		ev := k.backlog[0]
		k.backlog = k.backlog[1:]
		return ev, true
	}
	for z := range k.resync {
		delete(k.resync, z)
		return Event{Event: &relayv1.Event{Kind: &relayv1.Event_ZoneChanged{ZoneChanged: &relayv1.ZoneChanged{Zone: z}}}}, true
	}
	return Event{}, false
}

// read handles frames until the connection ends and reports why. A close with 1001 is GoingAway
// whether or not a GoingAway frame preceded it (a Cloudflare rollout sends none); onGoingAway runs
// once per connection either way.
func (k *Conn) read(ws *websocket.Conn) endReason {
	reason := endDropped
	announced := false
	goingAway := func() {
		reason = endGoingAway
		if !announced && k.c.onGoingAway != nil {
			k.c.onGoingAway()
		}
		announced = true
	}
	for {
		_, b, err := ws.Read(k.ctx)
		if err != nil {
			switch {
			case k.ctx.Err() != nil:
				return endClosed
			case websocket.CloseStatus(err) == closeUnauthenticated:
				return endSessionExpired
			case websocket.CloseStatus(err) == websocket.StatusGoingAway:
				goingAway()
				return endGoingAway
			}
			return reason
		}
		var f relayv1.Frame
		if proto.Unmarshal(b, &f) != nil {
			continue
		}
		switch kind := f.GetKind().(type) {
		case *relayv1.Frame_Response:
			k.mu.Lock()
			ch := k.pending[kind.Response.GetId()]
			k.mu.Unlock()
			if ch != nil {
				ch <- kind.Response
			}
		case *relayv1.Frame_GoingAway:
			goingAway()
		case *relayv1.Frame_Event:
			switch {
			case kind.Event.GetControl().GetKind() == relayv1.ControlKind_CONTROL_KIND_SESSION_EXPIRED:
				reason = endSessionExpired
			case kind.Event.GetZoneChanged() != nil:
				k.emitZone(kind.Event)
			default:
				k.queue(Event{Event: kind.Event})
			}
		}
	}
}
