package hub

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
)

// The local control socket (spec §4): <dir>/hub.sock, 0600 in the 0700 hub
// dir, served while Run holds the hub lock. A client of another user is
// closed before anything is read. One JSON ControlRequest per line in, one
// JSON ControlAnswer per line out; a pair request streams the pairing
// events on its connection, and a confirm on that connection decides with
// the code the stream showed. Nothing here logs a name, a code or a URL.

// SocketName is the control socket's file name in the hub dir.
const SocketName = "hub.sock"

// maxRequestBytes caps one request line.
const maxRequestBytes = 64 << 10

// The control ops.
const (
	OpUnlink  = "unlink"
	OpAllow   = "allow"
	OpName    = "name"
	OpEnable  = "enable"
	OpDisable = "disable"
	OpPair    = "pair"
	OpConfirm = "confirm"
)

// The error classes a ControlAnswer carries.
const (
	ErrClassBadRequest   = "bad_request"
	ErrClassHubOff       = "hub_off"
	ErrClassPolicyOff    = "policy_off"
	ErrClassNoDevice     = "no_device"
	ErrClassUnknownGrant = "unknown_grant"
	ErrClassNoCode       = "no_code"
	ErrClassNoRequest    = "no_request"
	ErrClassCodeChanged  = "code_changed"
	ErrClassFailed       = "failed"
)

// ControlRequest is one request on the control socket. Device names a phone
// (unlink, allow, confirm), Grant a link.Grant (allow) with On, Name the
// hub's display name (name), Confirm the owner's answer (confirm).
type ControlRequest struct {
	Op      string `json:"op"`
	Device  string `json:"device,omitempty"`
	Grant   string `json:"grant,omitempty"`
	Name    string `json:"name,omitempty"`
	On      bool   `json:"on,omitempty"`
	Confirm bool   `json:"confirm,omitempty"`
}

// ControlAnswer is one line from the hub: the answer to a request (Op set,
// OK or an Error class) or a pairing event (Event set: qr, waiting, sas,
// linked, refused).
type ControlAnswer struct {
	Op        string     `json:"op,omitempty"`
	Event     string     `json:"event,omitempty"`
	OK        bool       `json:"ok"`
	Error     string     `json:"error,omitempty"`
	DeviceID  string     `json:"device_id,omitempty"`
	Name      string     `json:"name,omitempty"`
	Grant     string     `json:"grant,omitempty"`
	Allowed   *bool      `json:"allowed,omitempty"`
	Enabled   *bool      `json:"enabled,omitempty"`
	URL       string     `json:"url,omitempty"`
	ExpiresAt *time.Time `json:"expires_at,omitempty"`
	Code      string     `json:"code,omitempty"`
	Reason    string     `json:"reason,omitempty"`
}

// serveControl listens on <dir>/hub.sock until the returned stop is called
// (or ctx ends). A socket that cannot be served is logged and the hub runs
// without it: CLI writes then fail.
func (s *supervisor) serveControl(ctx context.Context) (stop func()) {
	path := filepath.Join(s.o.Dir, SocketName)
	l, err := listenControl(path)
	if err != nil {
		log.Printf("hub: control socket not served (%s)", errClass(err))
		return func() {}
	}
	ctx, cancel := context.WithCancel(ctx)
	var wg sync.WaitGroup
	conns := map[net.Conn]bool{}
	var connsMu sync.Mutex
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			uc, ok := c.(*net.UnixConn)
			if !ok {
				_ = c.Close()
				continue
			}
			uid, err := s.o.peerUID(uc)
			if err != nil || uid != os.Getuid() {
				log.Printf("hub: control socket: a client of another user refused")
				_ = c.Close()
				continue
			}
			if s.o.sendBuffer > 0 {
				if err := uc.SetWriteBuffer(s.o.sendBuffer); err != nil {
					log.Printf("hub: control socket: send buffer not set (%s)", errClass(err))
				}
			}
			connsMu.Lock()
			conns[c] = true
			connsMu.Unlock()
			wg.Add(1)
			go func() {
				defer wg.Done()
				s.serveConn(ctx, c)
				connsMu.Lock()
				delete(conns, c)
				connsMu.Unlock()
			}()
		}
	}()
	return func() {
		cancel()
		_ = l.Close()
		connsMu.Lock()
		for c := range conns {
			_ = c.Close()
		}
		connsMu.Unlock()
		wg.Wait()
		_ = os.Remove(path)
	}
}

// listenControl binds path 0600, replacing a stale socket (Run holds the
// hub lock, so no other hub serves it); a non-socket file there is refused.
func listenControl(path string) (net.Listener, error) {
	if fi, err := os.Lstat(path); err == nil {
		if fi.Mode().Type() != fs.ModeSocket {
			return nil, errors.New("hub: the control socket path is not a socket")
		}
		if err := os.Remove(path); err != nil {
			return nil, fmt.Errorf("hub: removing a stale control socket: %w", err)
		}
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("hub: listening on the control socket: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = l.Close()
		return nil, fmt.Errorf("hub: tightening the control socket: %w", err)
	}
	return l, nil
}

// pairListener is one connection's pairing stream: its writer, its queue
// of events (written by its own goroutine, so a stalled client never holds
// up the other streams) and the code each phone was shown on it.
type pairListener struct {
	w     *answerWriter
	queue chan ControlAnswer // guarded by supervisor.pairMu for sends and close
	mu    sync.Mutex
	codes map[string]string
}

func (p *pairListener) code(device string) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	c, ok := p.codes[strings.ToUpper(device)]
	return c, ok
}

// pairQueue is how many events one pairing stream may have waiting; a
// stream that falls further behind is dropped (its connection closed).
const pairQueue = 64

// broadcast hands a pairing event to every pairing stream without waiting
// on any of them: a stream whose queue is full is dropped, the others get
// every event.
func (s *supervisor) broadcast(ev link.PairEvent) {
	a := ControlAnswer{Event: ev.Kind, OK: true, URL: ev.URL, DeviceID: ev.DeviceID, Name: ev.Name, Code: ev.Code, Reason: ev.Reason}
	if !ev.ExpiresAt.IsZero() {
		at := ev.ExpiresAt
		a.ExpiresAt = &at
	}
	s.pairMu.Lock()
	defer s.pairMu.Unlock()
	for p := range s.pairs {
		if ev.Kind == link.EventSAS {
			p.mu.Lock()
			p.codes[strings.ToUpper(ev.DeviceID)] = ev.Code
			p.mu.Unlock()
		}
		select {
		case p.queue <- a:
		default:
			// serveConn closes the queue once its reader ends.
			log.Printf("hub: control socket: a pairing stream fell behind and was dropped")
			delete(s.pairs, p)
			p.w.drop()
		}
	}
}

// answerWriter serialises a connection's lines (answers and events). Each
// line has a write deadline; a write that fails or times out closes the
// connection, and every later write is skipped.
type answerWriter struct {
	mu      sync.Mutex // serialises lines
	c       net.Conn
	enc     *json.Encoder
	timeout time.Duration
	dropped atomic.Bool
	once    sync.Once
}

func (w *answerWriter) write(a ControlAnswer) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.dropped.Load() {
		return false
	}
	if err := w.c.SetWriteDeadline(time.Now().Add(w.timeout)); err == nil {
		if err = w.enc.Encode(a); err == nil {
			return true
		}
	}
	if !w.dropped.Load() {
		log.Printf("hub: control socket: a client stopped reading and was dropped")
	}
	w.drop()
	return false
}

// drop closes the connection (its reader then ends serveConn). It never
// waits for a write in progress: closing the conn ends that write.
func (w *answerWriter) drop() {
	w.dropped.Store(true)
	w.once.Do(func() { _ = w.c.Close() })
}

// serveConn answers one client's requests in order.
func (s *supervisor) serveConn(ctx context.Context, c net.Conn) {
	defer func() { _ = c.Close() }()
	w := &answerWriter{c: c, enc: json.NewEncoder(c), timeout: s.o.writeTimeout}
	var (
		pl      *pairListener
		pumping sync.WaitGroup
	)
	defer func() {
		if pl != nil {
			s.pairMu.Lock()
			delete(s.pairs, pl)
			close(pl.queue)
			s.pairMu.Unlock()
			pumping.Wait()
		}
	}()
	sc := bufio.NewScanner(c)
	sc.Buffer(make([]byte, 0, 4096), maxRequestBytes)
	for sc.Scan() {
		if ctx.Err() != nil {
			return
		}
		var r ControlRequest
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			w.write(ControlAnswer{Error: ErrClassBadRequest})
			continue
		}
		if r.Op == OpPair && pl == nil {
			pl = &pairListener{w: w, queue: make(chan ControlAnswer, s.o.pairQueue), codes: map[string]string{}}
			pumping.Add(1)
			go func(p *pairListener) {
				defer pumping.Done()
				for a := range p.queue {
					p.w.write(a)
				}
			}(pl)
			s.pairMu.Lock()
			s.pairs[pl] = true
			s.pairMu.Unlock()
		}
		a := s.handle(r, pl)
		a.Op = r.Op
		if a.Error != "" {
			log.Printf("hub: control %s refused (%s)", opClass(r.Op), a.Error)
		}
		if !w.write(a) {
			return
		}
	}
}

// opClass is a request's op for a log line (an unknown op is not echoed).
func opClass(op string) string {
	for _, known := range []string{OpUnlink, OpAllow, OpName, OpEnable, OpDisable, OpPair, OpConfirm} {
		if op == known {
			return known
		}
	}
	return "unknown"
}

// handle runs one request.
func (s *supervisor) handle(r ControlRequest, pl *pairListener) ControlAnswer {
	switch r.Op {
	case OpEnable:
		return s.setEnabled(true)
	case OpDisable:
		return s.setEnabled(false)
	case OpName:
		name := strings.TrimSpace(r.Name)
		if name == "" || len([]rune(name)) > wire.MaxMacNameLength {
			return ControlAnswer{Error: ErrClassBadRequest}
		}
		if err := s.st.SetMeta(state.MetaDisplayName, name); err != nil {
			return ControlAnswer{Error: ErrClassFailed}
		}
		s.poke()
		return ControlAnswer{OK: true, Name: name}
	case OpUnlink, OpAllow, OpPair, OpConfirm:
		return s.withHub(func(h *hubRuntime) ControlAnswer { return h.handle(r, pl) })
	}
	return ControlAnswer{Error: ErrClassBadRequest}
}

// setEnabled flips hub_meta.enabled; turning it on is refused while the
// policy is off (the setting is not written).
func (s *supervisor) setEnabled(on bool) ControlAnswer {
	if on && s.o.mobileSync() == policy.MobileOff {
		return ControlAnswer{Error: ErrClassPolicyOff}
	}
	if err := s.st.SetMeta(state.MetaEnabled, strconv.Itoa(boolInt(on))); err != nil {
		return ControlAnswer{Error: ErrClassFailed}
	}
	s.poke()
	return ControlAnswer{OK: true, Enabled: &on}
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// withHub runs fn on the running hub, holding it so it cannot stop
// meanwhile; hub_off when none runs.
func (s *supervisor) withHub(fn func(*hubRuntime) ControlAnswer) ControlAnswer {
	s.hubMu.RLock()
	defer s.hubMu.RUnlock()
	if s.hub == nil {
		return ControlAnswer{Error: ErrClassHubOff}
	}
	return fn(s.hub)
}

// handle runs a request that needs the running hub.
func (h *hubRuntime) handle(r ControlRequest, pl *pairListener) ControlAnswer {
	switch r.Op {
	case OpUnlink:
		if r.Device == "" {
			return ControlAnswer{Error: ErrClassBadRequest}
		}
		if err := h.center.Unlink(r.Device); err != nil {
			return ControlAnswer{Error: linkErrClass(err)}
		}
		return ControlAnswer{OK: true, DeviceID: strings.ToUpper(r.Device)}
	case OpAllow:
		if r.Device == "" {
			return ControlAnswer{Error: ErrClassBadRequest}
		}
		if err := h.center.Allow(r.Device, link.Grant(r.Grant), r.On); err != nil {
			return ControlAnswer{Error: linkErrClass(err)}
		}
		on := r.On
		return ControlAnswer{OK: true, DeviceID: strings.ToUpper(r.Device), Grant: r.Grant, Allowed: &on}
	case OpPair:
		// The qr and waiting events reach the stream through the center.
		if _, _, err := h.center.Issue(); err != nil {
			return ControlAnswer{Error: ErrClassFailed}
		}
		return ControlAnswer{OK: true}
	case OpConfirm:
		if pl == nil || r.Device == "" {
			return ControlAnswer{Error: ErrClassNoCode}
		}
		code, ok := pl.code(r.Device)
		if !ok {
			return ControlAnswer{Error: ErrClassNoCode}
		}
		if err := h.center.Confirm(r.Device, code, r.Confirm); err != nil {
			return ControlAnswer{Error: linkErrClass(err)}
		}
		return ControlAnswer{OK: true, DeviceID: strings.ToUpper(r.Device)}
	}
	return ControlAnswer{Error: ErrClassBadRequest}
}

// linkErrClass maps a link error to its answer class.
func linkErrClass(err error) string {
	switch {
	case errors.Is(err, state.ErrNoDevice):
		return ErrClassNoDevice
	case errors.Is(err, link.ErrUnknownGrant):
		return ErrClassUnknownGrant
	case errors.Is(err, link.ErrNoRequest):
		return ErrClassNoRequest
	case errors.Is(err, link.ErrCodeChanged):
		return ErrClassCodeChanged
	}
	return ErrClassFailed
}

// ControlClient is a connection to a running hub's control socket.
type ControlClient struct {
	c   net.Conn
	enc *json.Encoder
	dec *json.Decoder
}

// Dial connects to the control socket of the hub running in dir.
func Dial(dir string) (*ControlClient, error) {
	c, err := net.DialTimeout("unix", filepath.Join(dir, SocketName), 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("hub: the hub is not running: %w", err)
	}
	return &ControlClient{c: c, enc: json.NewEncoder(c), dec: json.NewDecoder(c)}, nil
}

// Send writes one request.
func (c *ControlClient) Send(r ControlRequest) error { return c.enc.Encode(r) }

// Next reads the next line: an answer or a pairing event.
func (c *ControlClient) Next() (ControlAnswer, error) {
	var a ControlAnswer
	err := c.dec.Decode(&a)
	return a, err
}

// Do sends r and returns its answer, skipping pairing events.
func (c *ControlClient) Do(r ControlRequest) (ControlAnswer, error) {
	if err := c.Send(r); err != nil {
		return ControlAnswer{}, err
	}
	for {
		a, err := c.Next()
		if err != nil {
			return ControlAnswer{}, err
		}
		if a.Event == "" {
			return a, nil
		}
	}
}

// SetReadDeadline bounds the wait of Next and Do (zero: no bound); a read
// past it fails with a net.Error whose Timeout() is true.
func (c *ControlClient) SetReadDeadline(t time.Time) error { return c.c.SetReadDeadline(t) }

// Close closes the connection.
func (c *ControlClient) Close() error { return c.c.Close() }
