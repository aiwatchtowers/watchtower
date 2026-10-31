//go:build interop

// The interop run (Go hub spec §6.1, §13 "Interop"): the Go hub and the Go
// phone emulator against the relay's local stand (`wrangler dev` with
// RELAY_ENV=dev: App Attest off, /dev/* endpoints). Started by
// `make relay-interop RELAY=<relay checkout>`, which runs the stand, passes
// -relay and -relay-control-pid and stops the stand afterwards. Every hub
// runs on a temp dir through FromEnv with a hubtest-* workspace; nothing
// here touches a live workspace.
package hub

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy/policytest"
)

var (
	relayOrigin = flag.String("relay", "", "origin of the relay's local stand (make relay-interop sets it)")
	relayCtlPID = flag.Int("relay-control-pid", 0, "pid of scripts/relay-interop.sh; SIGUSR1 makes it restart the stand")
)

// interopWorkspace is the test workspace every interop hub runs in.
const interopWorkspace = TestWorkspacePrefix + "interop"

// The waits of the interop run (a local stand, but workerd and real sockets).
const (
	stepWait    = 60 * time.Second
	restartWait = 3 * time.Minute
	markKind    = "interop_mark"
)

func needStand(t *testing.T) string {
	t.Helper()
	if *relayOrigin == "" {
		t.Skip("no -relay origin: run `make relay-interop RELAY=<relay checkout>`")
	}
	return strings.TrimRight(*relayOrigin, "/")
}

// ---- the wire tap ----

// wireTap records every byte both ways of every TCP connection the hub's
// and the phone's relay clients open (HTTP ops and the WebSocket), so the
// E2E check sees exactly what left the process. Compression is off, so the
// bytes are the frames as sent (WebSocket frames a client sends are masked:
// those carry only subscribe and ping, every op goes over HTTP).
type wireTap struct {
	mu    sync.Mutex
	conns []*tappedConn
}

type tappedConn struct {
	net.Conn
	mu      sync.Mutex
	in, out bytes.Buffer
}

func (c *tappedConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.mu.Lock()
	c.in.Write(b[:n])
	c.mu.Unlock()
	return n, err
}

func (c *tappedConn) Write(b []byte) (int, error) {
	n, err := c.Conn.Write(b)
	c.mu.Lock()
	c.out.Write(b[:n])
	c.mu.Unlock()
	return n, err
}

func (w *wireTap) dial(ctx context.Context, network, addr string) (net.Conn, error) {
	var d net.Dialer
	c, err := d.DialContext(ctx, network, addr)
	if err != nil {
		return nil, err
	}
	tc := &tappedConn{Conn: c}
	w.mu.Lock()
	w.conns = append(w.conns, tc)
	w.mu.Unlock()
	return tc, nil
}

// httpClient is an HTTP client over the tap (no compression, HTTP/1.1).
func (w *wireTap) httpClient() *http.Client {
	return &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{
		DialContext: w.dial, DisableCompression: true, ForceAttemptHTTP2: false,
	}}
}

// streams is every recorded byte stream, each direction of each connection.
func (w *wireTap) streams() [][]byte {
	w.mu.Lock()
	defer w.mu.Unlock()
	var out [][]byte
	for _, c := range w.conns {
		c.mu.Lock()
		out = append(out, bytes.Clone(c.in.Bytes()), bytes.Clone(c.out.Bytes()))
		c.mu.Unlock()
	}
	return out
}

// ---- the hub's transport, seen from the test ----

// tappedTransport is the production relay transport; it forwards the
// transport's events, keeping the resync markers it saw.
type tappedTransport struct {
	*relay.Transport
	events chan transport.Event
	done   chan struct{}
	once   sync.Once

	mu      sync.Mutex
	resyncs map[string]int
}

func newTappedTransport(tr *relay.Transport) *tappedTransport {
	t := &tappedTransport{Transport: tr, events: make(chan transport.Event, 256), done: make(chan struct{}),
		resyncs: map[string]int{}}
	go func() {
		for {
			select {
			case <-t.done:
				return
			case ev := <-tr.Events():
				if ev.Resync && ev.Zone != "" {
					t.mu.Lock()
					t.resyncs[ev.Zone]++
					t.mu.Unlock()
				}
				select {
				case t.events <- ev:
				case <-t.done:
					return
				}
			}
		}
	}()
	return t
}

func (t *tappedTransport) Events() <-chan transport.Event { return t.events }

func (t *tappedTransport) Close() error {
	err := t.Transport.Close()
	t.once.Do(func() { close(t.done) })
	return err
}

func (t *tappedTransport) resyncsOf(zone string) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.resyncs[zone]
}

// ---- the hub ----

type interopOpts struct {
	passEvery, linkEvery time.Duration
	register             func(*actions.Dispatcher)
}

// interopHub is one Run on the stand.
type interopHub struct {
	t      *testing.T
	origin string
	dir    string
	tap    *wireTap
	rec    *recorder
	ctl    *ControlClient
	cancel context.CancelFunc
	done   chan error

	mu sync.Mutex
	tr *tappedTransport // the transport of the hub's current start
}

func (h *interopHub) transport() *tappedTransport {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.tr
}

// startHub runs a hub through FromEnv on a fresh hubtest-* dir against the
// stand, turns it on over the control socket and waits until it runs.
func startHub(t *testing.T, opts interopOpts) *interopHub {
	t.Helper()
	origin := needStand(t)
	policytest.Set(t, nil)
	dir := shortDir(t)
	t.Setenv(EnvHubDir, dir)
	t.Setenv(EnvRelayOrigin, origin)
	t.Setenv(EnvTestWorkspace, interopWorkspace)
	o, ok, err := FromEnv(&config.Config{ActiveWorkspace: interopWorkspace}, nil)
	if err != nil || !ok {
		t.Fatalf("FromEnv: ok=%v, %v", ok, err)
	}
	h := &interopHub{t: t, origin: origin, dir: dir, tap: &wireTap{}, rec: &recorder{}}
	// The production relay transport, over the wire tap and seen through
	// tappedTransport.
	o.httpClient = h.tap.httpClient()
	o.newTransport = func(ctx context.Context, id identity.Identity, st *state.Store, zones []string) (transport.Transport, error) {
		tr, err := o.relayTransport(ctx, id, st, zones)
		if err != nil {
			t.Logf("hub transport: %v", err)
			return nil, err
		}
		tapped := newTappedTransport(tr.(*relay.Transport))
		if len(zones) > 0 {
			h.mu.Lock()
			h.tr = tapped
			h.mu.Unlock()
		}
		return tapped, nil
	}
	o.report = h.rec.report
	o.checkEvery = 100 * time.Millisecond
	o.lockRetry = 50 * time.Millisecond
	o.passEvery, o.linkEvery, o.Register = opts.passEvery, opts.linkEvery, opts.register

	ctx, cancel := context.WithCancel(context.Background())
	h.cancel, h.done = cancel, make(chan error, 1)
	go func() { h.done <- Run(ctx, o) }()
	t.Cleanup(h.stop)
	eventually(t, stepWait, "the control socket", func() bool {
		_, err := os.Stat(filepath.Join(dir, SocketName))
		return err == nil
	})
	if h.ctl, err = Dial(dir); err != nil {
		t.Fatal(err)
	}
	if a, err := h.ctl.Do(ControlRequest{Op: OpEnable}); err != nil || !a.OK {
		t.Fatalf("enable: %+v, %v", a, err)
	}
	h.waitRunning()
	return h
}

func (h *interopHub) waitRunning() {
	h.t.Helper()
	eventually(h.t, stepWait, "the hub running on the stand", func() bool {
		return h.rec.last().State == StateRunning
	})
}

func (h *interopHub) stop() {
	if h.cancel == nil {
		return
	}
	if h.ctl != nil {
		_ = h.ctl.Close()
	}
	h.cancel()
	h.cancel = nil
	select {
	case <-h.done:
	case <-time.After(30 * time.Second):
		h.t.Error("Run did not return after cancel")
	}
}

// next reads the control stream up to the pairing event named.
func (h *interopHub) next(event string) ControlAnswer {
	h.t.Helper()
	_ = h.ctl.SetReadDeadline(time.Now().Add(stepWait))
	defer func() { _ = h.ctl.SetReadDeadline(time.Time{}) }()
	for {
		a, err := h.ctl.Next()
		if err != nil {
			h.t.Fatalf("waiting for %s: %v", event, err)
		}
		if a.Error != "" || a.Event == link.EventRefused {
			h.t.Fatalf("waiting for %s: %+v", event, a)
		}
		if a.Event == event {
			return a
		}
	}
}

// ---- the stand's dev endpoints ----

// dev POSTs body to the stand's /dev/<path>, retrying 503 (a step still
// being delivered; every /dev step is idempotent), and decodes a 200 into out.
func dev(t *testing.T, origin, path string, body, out any) {
	t.Helper()
	b, _ := json.Marshal(body)
	deadline := time.Now().Add(stepWait)
	for {
		res, err := http.Post(origin+"/dev/"+path, "application/json", bytes.NewReader(b))
		if err != nil {
			t.Fatalf("/dev/%s: %v", path, err)
		}
		data, _ := io.ReadAll(res.Body)
		_ = res.Body.Close()
		switch {
		case res.StatusCode == http.StatusOK:
			if out != nil {
				if err := json.Unmarshal(data, out); err != nil {
					t.Fatalf("/dev/%s: %v", path, err)
				}
			}
			return
		case res.StatusCode == http.StatusServiceUnavailable && time.Now().Before(deadline):
			time.Sleep(200 * time.Millisecond)
		default:
			t.Fatalf("/dev/%s: %d %s", path, res.StatusCode, data)
		}
	}
}

// ---- the phone ----

// recordingStore keeps every envelope the phone read back from the stand.
type recordingStore struct {
	*hubtest.RelayStore
	mu   sync.Mutex
	seen map[string][]byte // zone + "\x00" + name → the last envelope read
}

func (s *recordingStore) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	b, err := s.RelayStore.Changes(ctx, zone, since)
	if err == nil {
		s.mu.Lock()
		for _, r := range b.Changed {
			s.seen[zone+"\x00"+r.Name] = bytes.Clone(r.Envelope)
		}
		s.mu.Unlock()
	}
	return b, err
}

func (s *recordingStore) envelopes() map[string][]byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string][]byte, len(s.seen))
	for k, v := range s.seen {
		out[k] = bytes.Clone(v)
	}
	return out
}

// linked is a phone linked to the hub over a pairing slot.
type linked struct {
	phone  *hubtest.Phone
	store  *recordingStore
	slot   string
	code   string
	status Status
}

// linkPhone links a fresh paying phone to h over a pairing slot: link code
// from the control socket, open_pairing, hello in pair/<slot>, the awaiting
// keybox, equal codes, the owner's confirmation, the keys, promote_pairing,
// and the hub admitted with the phone reading its device_grant from the
// data zone.
func linkPhone(t *testing.T, h *interopHub) *linked {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), restartWait)
	defer cancel()
	if err := h.ctl.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	qr := h.next(link.EventQR)
	lp, err := wire.ParseLinkURL(qr.URL)
	if err != nil {
		t.Fatal(err)
	}
	status, err := ReadStatus(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	if lp.RelayDeviceID != status.RelayDeviceID {
		t.Fatal("the link code names another relay device than the hub's")
	}
	store := &recordingStore{RelayStore: &hubtest.RelayStore{}, seen: map[string][]byte{}}
	phone, err := hubtest.FromLink(lp, store, nil)
	if err != nil {
		t.Fatal(err)
	}
	store.C = hubtest.NewPhoneClient(h.origin, phone, client.WithHTTPClient(h.tap.httpClient()))
	account, err := store.Register(ctx)
	if err != nil || account == "" {
		t.Fatalf("phone register: account %q, %v", account, err)
	}
	dev(t, h.origin, "entitlement", map[string]any{"accountId": account, "state": "active", "forMs": int64(30 * 24 * time.Hour / time.Millisecond)}, nil)

	slot, err := store.OpenPairing(ctx, lp.RelayDeviceID)
	if err != nil {
		t.Fatal(err)
	}
	pair := transport.PairZone(slot)
	if err := phone.Hello(pair); err != nil {
		t.Fatal(err)
	}
	sas := h.next(link.EventSAS)
	if sas.DeviceID != phone.ID().String() {
		t.Fatalf("sas for %s, want %s", sas.DeviceID, phone.ID())
	}
	var awaiting wire.Keybox
	eventually(t, stepWait, "the awaiting keybox in the pair zone", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		if err != nil {
			t.Fatal(err)
		}
		awaiting = kb
		return ok && kb.Grant.ConfirmNonce != nil
	})
	code, err := phone.SAS(*awaiting.Grant.ConfirmNonce)
	if err != nil {
		t.Fatal(err)
	}
	if code != sas.Code {
		t.Fatal("the phone's code differs from the hub's")
	}
	if err := h.ctl.Send(ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}); err != nil {
		t.Fatal(err)
	}
	if l := h.next(link.EventLinked); l.DeviceID != phone.ID().String() {
		t.Fatalf("linked: %+v", l)
	}
	eventually(t, stepWait, "the keys in the pair zone", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		if err != nil {
			t.Fatal(err)
		}
		return ok && kb.Keys != nil
	})
	// Vouched hubs: linked but in no slot, the hub is not_vouched, and the
	// stand refuses a promote with no vouch (HUB_NOT_VOUCHED to the phone).
	if s, err := ReadStatus(h.dir); err != nil || s.Reason != ReasonNotVouched {
		t.Fatalf("status before the vouch: %+v, %v", s, err)
	}
	if err := store.PromotePairing(ctx, slot); !errors.Is(err, transport.ErrNotVouched) {
		t.Fatalf("promote_pairing without a vouch: %v", err)
	}
	if err := phone.VouchLink(ctx, lp); err != nil {
		t.Fatal(err)
	}
	if err := store.PromotePairing(ctx, slot); err != nil {
		t.Fatal(err)
	}
	eventually(t, stepWait, "the hub admitted with one phone", func() bool {
		s, err := ReadStatus(h.dir)
		return err == nil && s.State == StateRunning && s.Reason == "" && s.Phones == 1
	})
	data := transport.DataZone(status.RelayDeviceID)
	eventually(t, stepWait, "the device_grant in the data zone", func() bool {
		kb, ok, err := phone.ReadKeybox(data)
		if err != nil {
			return false // not a reader yet: the next readers sync adds the phone
		}
		return ok && kb.Grant.Linked
	})
	return &linked{phone: phone, store: store, slot: slot, code: sas.Code, status: status}
}

// ---- actions ----

// markCounter is the interop_mark handler: applied, its result repeats
// params.mark, and it counts its calls per action_seq.
type markCounter struct {
	mu    sync.Mutex
	calls map[uint64]int
}

func (m *markCounter) register(d *actions.Dispatcher) {
	d.Register(markKind, func(_ context.Context, r actions.Request) actions.Outcome {
		var mark string
		_ = json.Unmarshal(r.Action.Params["mark"], &mark)
		if r.Action.ActionSeq != nil {
			m.mu.Lock()
			m.calls[*r.Action.ActionSeq]++
			m.mu.Unlock()
		}
		return actions.Outcome{Status: wire.StatusApplied, Result: map[string]any{"mark": mark}}
	}, actions.KindOptions{})
}

func (m *markCounter) count(seq uint64) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.calls[seq]
}

// canary is a marker unique to this run.
func canary(t *testing.T, what string) string {
	t.Helper()
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return "wt-canary-" + what + "-" + hex.EncodeToString(b)
}

// queueMarked queues an interop_mark action carrying mark.
func queueMarked(t *testing.T, p *hubtest.Phone, mark string) uint64 {
	t.Helper()
	a := p.NewAction(markKind)
	raw, _ := json.Marshal(mark)
	a.Params["mark"] = raw
	seq, err := p.Queue(a)
	if err != nil {
		t.Fatal(err)
	}
	return seq
}

// waitApplied syncs the phone until every seq has an applied echo.
func waitApplied(t *testing.T, p *hubtest.Phone, wait time.Duration, seqs ...uint64) {
	t.Helper()
	eventually(t, wait, fmt.Sprintf("applied echoes for %v", seqs), func() bool {
		if _, err := p.Sync(); err != nil {
			t.Logf("phone sync: %v", err)
			return false
		}
		for _, s := range seqs {
			if p.Echoes[s].Status != wire.StatusApplied {
				return false
			}
		}
		return true
	})
}

// ---- the tests ----

// TestInterop_VouchedHubLinksAndPublishes (relay "Vouched hubs" on the
// stand; it absorbs Phase 1's TestInterop_LinkOverPairingSlot: the stand
// allows 10 registrations a minute per address and each test registers a
// hub and a phone, so the suite keeps four link tests). The Go phone opens
// a pairing slot for the hub — registered as DEVICE_KIND_HUB with no
// attestation —, the hub answers its hello with a keybox, both show the same
// four-digit code, the owner confirms and the phone gets the keys; the hub
// is then not_vouched and the stand refuses a promote with no vouch; the
// phone vouches and promotes, and the relay admits the hub (status running,
// no reason, one phone), the phone reads its device_grant from the data zone
// (linkPhone checks each step), the phone is stamped relay_admitted_at and
// the heartbeat is published.
func TestInterop_VouchedHubLinksAndPublishes(t *testing.T) {
	h := startHub(t, interopOpts{passEvery: time.Second, linkEvery: time.Second})
	l := linkPhone(t, h)
	if len(l.code) != 4 || strings.Trim(l.code, "0123456789") != "" {
		t.Fatalf("code %q is not four digits", l.code)
	}
	eventually(t, stepWait, "the phone stamped admitted", func() bool {
		st, err := state.OpenReadOnly(h.dir)
		if err != nil {
			return false
		}
		defer func() { _ = st.Close() }()
		devices, err := st.Devices()
		return err == nil && len(devices) == 1 && !devices[0].RelayAdmittedAt.IsZero()
	})
	data := transport.DataZone(l.status.RelayDeviceID)
	eventually(t, stepWait, "the heartbeat in the data zone", func() bool {
		recs, err := l.phone.OpenData(data)
		if err != nil {
			return false
		}
		for _, r := range recs {
			if r.Frame.Kind == "heartbeat" {
				return true
			}
		}
		return false
	})
}

// TestInterop_ActionsInOrderWithEchoes: a1..a5 with a3 held back; the hub
// asks resend_from(3) once, the phone resends from its outbox, and every
// action is applied exactly once with its final echo read and deleted.
func TestInterop_ActionsInOrderWithEchoes(t *testing.T) {
	m := &markCounter{calls: map[uint64]int{}}
	h := startHub(t, interopOpts{passEvery: time.Second, linkEvery: time.Second, register: m.register})
	l := linkPhone(t, h)
	p := l.phone
	for i := 1; i <= 5; i++ {
		if seq := queueMarked(t, p, fmt.Sprintf("order-%d", i)); seq != uint64(i) {
			t.Fatalf("action_seq %d, want %d", seq, i)
		}
	}
	for _, s := range []uint64{1, 2, 4, 5} {
		if err := p.Send(s); err != nil {
			t.Fatal(err)
		}
	}
	waitApplied(t, p, 2*stepWait, 1, 2, 3, 4, 5)
	resends := 0
	for _, c := range p.Controls {
		if c.Kind != wire.ControlResendFrom {
			continue
		}
		resends++
		if c.Seq == nil || *c.Seq != 3 {
			t.Fatalf("resend_from %v, want 3", c.Seq)
		}
	}
	if resends != 1 {
		t.Fatalf("%d resend_from controls, want 1", resends)
	}
	for s := uint64(1); s <= 5; s++ {
		if n := m.count(s); n != 1 {
			t.Fatalf("a%d applied %d times", s, n)
		}
	}
	if len(p.Outbox()) != 0 || len(p.Undelivered) != 0 {
		t.Fatalf("outbox %v, undelivered %v", p.Outbox(), p.Undelivered)
	}
}

// TestInterop_ReconnectResubscribesAndPulls: the stand is restarted mid-run
// (same persisted state). The hub's client reconnects, resubscribes the
// mailbox (a resync marker for it on the same transport: the hub itself
// did not restart) and pulls: an action written after the restart is
// applied, once, and so was the one before it.
func TestInterop_ReconnectResubscribesAndPulls(t *testing.T) {
	if *relayCtlPID == 0 {
		t.Skip("no -relay-control-pid: the stand cannot be restarted (make relay-interop sets it)")
	}
	m := &markCounter{calls: map[uint64]int{}}
	h := startHub(t, interopOpts{passEvery: time.Second, linkEvery: time.Second, register: m.register})
	l := linkPhone(t, h)
	p := l.phone
	a1 := queueMarked(t, p, "before-restart")
	if err := p.Send(a1); err != nil {
		t.Fatal(err)
	}
	waitApplied(t, p, stepWait, a1)

	mailbox := p.Zone()
	tr := h.transport()
	before := tr.resyncsOf(mailbox)
	restartStand(t, h.origin)
	eventually(t, restartWait, "a resync of the mailbox after the restart", func() bool {
		return tr.resyncsOf(mailbox) > before
	})
	if h.transport() != tr {
		t.Fatal("the hub restarted instead of reconnecting")
	}
	a2 := queueMarked(t, p, "after-restart")
	eventually(t, stepWait, "a2 written after the restart", func() bool {
		return p.Send(a2) == nil
	})
	waitApplied(t, p, stepWait, a2)
	if m.count(a1) != 1 || m.count(a2) != 1 {
		t.Fatalf("applied a1 %d, a2 %d times", m.count(a1), m.count(a2))
	}
}

// restartStand asks the interop script to restart the stand and waits until
// it went down and answers /healthz again.
func restartStand(t *testing.T, origin string) {
	t.Helper()
	if err := syscall.Kill(*relayCtlPID, syscall.SIGUSR1); err != nil {
		t.Fatalf("signalling the interop script: %v", err)
	}
	healthy := func() bool {
		c := http.Client{Timeout: time.Second}
		res, err := c.Get(origin + "/healthz")
		if err != nil {
			return false
		}
		_ = res.Body.Close()
		return res.StatusCode == http.StatusOK
	}
	eventually(t, stepWait, "the stand going down", func() bool { return !healthy() })
	eventually(t, restartWait, "the stand answering again", healthy)
}

// TestInterop_NoPlaintextOnTheWire is the E2E red line on the real wire:
// a canary in the hub's name, in every action's payload (and so in every
// hub-sealed echo, which repeats it) never appears in any byte the hub or
// the phone sent or received, and every record read back from the stand —
// mailbox, pair zone, data zone — is a well-formed envelope without them.
func TestInterop_NoPlaintextOnTheWire(t *testing.T) {
	m := &markCounter{calls: map[uint64]int{}}
	h := startHub(t, interopOpts{passEvery: time.Second, linkEvery: time.Second, register: m.register})
	name := canary(t, "name")
	before := h.transport()
	if a, err := h.ctl.Do(ControlRequest{Op: OpName, Name: name}); err != nil || !a.OK {
		t.Fatalf("name: %+v, %v", a, err)
	}
	// The hub restarts for its new name: a new transport, then running.
	eventually(t, stepWait, "the hub restarted for its new name", func() bool {
		return h.transport() != before && h.rec.last().State == StateRunning
	})
	l := linkPhone(t, h)
	p := l.phone

	marks := map[uint64]string{}
	for range 3 {
		mark := canary(t, "action")
		seq := queueMarked(t, p, mark)
		marks[seq] = mark
		if err := p.Send(seq); err != nil {
			t.Fatal(err)
		}
	}
	seqs := make([]uint64, 0, len(marks))
	for s := range marks {
		seqs = append(seqs, s)
	}
	waitApplied(t, p, stepWait, seqs...)
	// The canaries made the round trip: the hub opened each action and
	// sealed it back in its echo.
	for s, mark := range marks {
		var got string
		if err := json.Unmarshal(p.Echoes[s].Result["mark"], &got); err != nil || got != mark {
			t.Fatalf("a%d echo result mark: %v", s, err)
		}
	}
	data := transport.DataZone(l.status.RelayDeviceID)
	for _, zone := range []string{p.Zone(), transport.PairZone(l.slot), data} {
		if _, err := l.store.Changes(context.Background(), zone, 0); err != nil && zone != transport.PairZone(l.slot) {
			t.Fatalf("reading %s back: %v", zone, err)
		}
	}

	canaries := []string{name, "Test Phone", "iPhone18,1", markKind, `"device_grant"`, `"keys"`}
	for _, mark := range marks {
		canaries = append(canaries, mark)
	}
	// The same canaries encoded as the protocol encodes bytes elsewhere.
	for _, c := range slices.Clone(canaries) {
		canaries = append(canaries, base64.StdEncoding.EncodeToString([]byte(c)),
			base64.RawURLEncoding.EncodeToString([]byte(c)), hex.EncodeToString([]byte(c)))
	}

	streams := h.tap.streams()
	var all []byte
	for _, s := range streams {
		all = append(all, s...)
	}
	// The tap saw the wire as sent: the phone's own sealed a1 is in it, and
	// so is its mailbox zone name (relay metadata is plaintext by design).
	_, env1 := p.Sealed(seqs[0])
	if !bytes.Contains(all, env1) || !bytes.Contains(all, []byte(p.Zone())) {
		t.Fatal("the wire tap did not see the records as sent")
	}
	for i, s := range streams {
		for _, c := range canaries {
			if bytes.Contains(s, []byte(c)) {
				t.Fatalf("stream %d carries the canary %q in the clear", i, c)
			}
		}
	}

	read := l.store.envelopes()
	zones := map[string]int{}
	for key, env := range read {
		zone, _, _ := strings.Cut(key, "\x00")
		zones[zone]++
		if _, err := secure.ParseHeader(env); err != nil {
			t.Fatalf("a record read back from %s is not an envelope: %v", zone, err)
		}
		for _, c := range canaries {
			if bytes.Contains(env, []byte(c)) {
				t.Fatalf("a record read back from %s carries the canary %q", zone, c)
			}
		}
	}
	if zones[p.Zone()] == 0 || zones[data] == 0 || zones[transport.PairZone(l.slot)] == 0 {
		t.Fatalf("records read back per zone: %v", zones)
	}
}
