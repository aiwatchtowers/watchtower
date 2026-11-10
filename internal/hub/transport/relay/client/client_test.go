package client_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/transport/relay/client"
	relayv1 "watchtower/internal/hub/transport/relay/relayv1"
)

const phoneKind = relayv1.DeviceKind_DEVICE_KIND_PHONE

// TestDefaultBackoffJitteredUpTo60s: delays double from 500 ms, carry jitter, never exceed 60 s.
func TestDefaultBackoffJitteredUpTo60s(t *testing.T) {
	for attempt := range 30 {
		ceil := min(500*time.Millisecond<<min(attempt, 8), 60*time.Second)
		for range 50 {
			if d := client.DefaultBackoff(attempt); d < ceil/2 || d > ceil {
				t.Fatalf("attempt %d: %v outside [%v, %v]", attempt, d, ceil/2, ceil)
			}
		}
	}
	seen := map[time.Duration]bool{}
	for range 50 {
		seen[client.DefaultBackoff(10)] = true
	}
	if len(seen) < 2 {
		t.Fatal("no jitter")
	}
}

// TestRegisterAsksForRegisterNonce: Register asks for a REGISTER challenge first, then registers with
// that nonce and a signature by auth_pub over RegisterClientDataHash.
func TestRegisterAsksForRegisterNonce(t *testing.T) {
	var seq []string
	var nonce []byte
	var reg *relayv1.RegisterDevice
	s := newFakeServer(t)
	s.op = func(w http.ResponseWriter, req *relayv1.Request) bool {
		if r := req.GetRegister(); r != nil {
			seq = append(seq, "register")
			reg = r
			writeResponse(w, &relayv1.Response{Result: &relayv1.Response_Registered{Registered: &relayv1.DeviceRegistered{
				DeviceId: client.DeviceID(r.GetAuthPub()), AccountId: "acct"}}})
			return true
		}
		return false
	}
	s.challenge = func(req *relayv1.GetChallenge) []byte {
		seq = append(seq, "challenge:"+req.GetPurpose().String())
		nonce = []byte("registration-nonce")
		return nonce
	}
	c := newClient(t, s)
	if _, err := c.Register(t.Context()); err != nil {
		t.Fatal(err)
	}
	if want := []string{"challenge:CHALLENGE_PURPOSE_REGISTER", "register"}; !slices.Equal(seq, want) {
		t.Fatalf("requests = %v, want %v", seq, want)
	}
	if !bytes.Equal(reg.GetNonce(), nonce) || reg.GetAttestation() != nil {
		t.Fatalf("register carries nonce %q / attestation %v", reg.GetNonce(), reg.GetAttestation())
	}
	if !ed25519.Verify(reg.GetAuthPub(), client.RegisterClientDataHash(nonce, reg.GetAuthPub(), s.URL), reg.GetSignature()) {
		t.Fatal("register signature does not verify against auth_pub")
	}
}

// TestRegisterClientDataHashVector pins the hash to the layout the Worker's clientDataHash uses.
func TestRegisterClientDataHashVector(t *testing.T) {
	got := client.RegisterClientDataHash([]byte{1, 2}, ed25519.PublicKey{3}, "https://r")
	h := sha256.Sum256([]byte("relay/v1/register\x01\x02\x03https://r"))
	if !bytes.Equal(got, h[:]) {
		t.Fatalf("hash = %x, want %x", got, h)
	}
	// The same digest is pinned in worker/test/attest.test.ts (registerClientDataHashSharedVector).
	if want := "d5a04d6b328a22dcf7e2489523dec888f63e34ed4bda0c087caf3ed34ab7943c"; fmt.Sprintf("%x", got) != want {
		t.Fatalf("hash = %x, want the shared vector %s", got, want)
	}
}

// TestVouchClientDataHashVector pins the vouch hash to the layout the Worker's vouchClientDataHash uses.
func TestVouchClientDataHashVector(t *testing.T) {
	got := client.VouchClientDataHash([]byte{1, 2}, "h", ed25519.PublicKey{3}, "https://r")
	h := sha256.Sum256([]byte("relay/v1/vouch\x01\x02h\x03https://r"))
	if !bytes.Equal(got, h[:]) {
		t.Fatalf("hash = %x, want %x", got, h)
	}
	// The same digest is pinned in worker/test/attest.test.ts (vouchClientDataHashVector).
	if want := "ecdda44ae74bd86e122f2edd43708cf2b8012cc194f78ed5728052e5c109956d"; fmt.Sprintf("%x", got) != want {
		t.Fatalf("hash = %x, want the shared vector %s", got, want)
	}
}

// TestVouchHubTakesVouchNonce: VouchHub asks for a VOUCH challenge for the phone itself, then sends
// vouch_hub with that nonce, the hub's id and key, and no attestation; an error answer is returned.
func TestVouchHubTakesVouchNonce(t *testing.T) {
	hubPub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var seq []string
	var vouch *relayv1.VouchHub
	s := newFakeServer(t)
	s.challenge = func(req *relayv1.GetChallenge) []byte {
		if req.GetPurpose() == relayv1.ChallengePurpose_CHALLENGE_PURPOSE_VOUCH {
			seq = append(seq, "challenge:vouch:"+req.GetDeviceId())
			return []byte("vouch-nonce")
		}
		return []byte("nonce")
	}
	s.op = func(w http.ResponseWriter, req *relayv1.Request) bool {
		if v := req.GetVouchHub(); v != nil {
			seq = append(seq, "vouch_hub")
			vouch = v
		}
		return false
	}
	c := newClient(t, s)
	if err := c.VouchHub(t.Context(), hubPub); err != nil {
		t.Fatal(err)
	}
	if want := []string{"challenge:vouch:" + c.DeviceID(), "vouch_hub"}; !slices.Equal(seq, want) {
		t.Fatalf("requests = %v, want %v", seq, want)
	}
	if vouch.GetHubDeviceId() != client.DeviceID(hubPub) || !bytes.Equal(vouch.GetAuthPub(), hubPub) ||
		!bytes.Equal(vouch.GetNonce(), []byte("vouch-nonce")) || vouch.GetAttestation() != nil {
		t.Fatalf("vouch_hub = %v", vouch)
	}

	s.op = func(w http.ResponseWriter, req *relayv1.Request) bool {
		writeResponse(w, &relayv1.Response{Result: &relayv1.Response_Error{Error: &relayv1.Error{
			Code: relayv1.ErrorCode_ERROR_CODE_NOT_FOUND}}})
		return true
	}
	if err := c.VouchHub(t.Context(), hubPub); client.Code(err) != relayv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Fatalf("err = %v, want NOT_FOUND", err)
	}
}

// TestLoginUnsupportedVersion: a server that answers UNSUPPORTED_VERSION over HTTPS stops the client
// with ErrUnsupportedVersion.
func TestLoginUnsupportedVersion(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		b, _ := proto.Marshal(&relayv1.Response{Result: &relayv1.Response_Error{Error: &relayv1.Error{
			Code: relayv1.ErrorCode_ERROR_CODE_UNSUPPORTED_VERSION}}})
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write(b)
	}))
	defer srv.Close()
	_, key, _ := ed25519.GenerateKey(rand.Reader)
	c := client.New(srv.URL, key, phoneKind)
	err := c.Login(t.Context())
	if !errors.Is(err, client.ErrUnsupportedVersion) || client.Code(err) != relayv1.ErrorCode_ERROR_CODE_UNSUPPORTED_VERSION {
		t.Fatalf("login: %v", err)
	}
	if _, err := c.Connect(t.Context()); !errors.Is(err, client.ErrUnsupportedVersion) {
		t.Fatalf("connect: %v", err)
	}
}

// fakeClock is a manually driven client.Clock: After waits until Advance moves time far enough.
type fakeClock struct {
	mu      sync.Mutex
	now     time.Time
	waiters []*waiter
	waiting chan struct{} // receives once per After call
}

type waiter struct {
	at time.Time
	ch chan time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC), waiting: make(chan struct{}, 1024)}
}

func (f *fakeClock) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

func (f *fakeClock) After(d time.Duration) <-chan time.Time {
	f.mu.Lock()
	w := &waiter{at: f.now.Add(d), ch: make(chan time.Time, 1)}
	f.waiters = append(f.waiters, w)
	f.mu.Unlock()
	f.waiting <- struct{}{}
	return w.ch
}

// nextWait assumes a single waiter: it returns the duration of the most recent After call, so
// use it only when nothing else (the ping timer) is waiting. Otherwise use waitBetween.
// nextWait blocks until some goroutine waits on the clock and returns how long it asked for.
func (f *fakeClock) nextWait(t *testing.T) time.Duration {
	t.Helper()
	select {
	case <-f.waiting:
	case <-time.After(5 * time.Second):
		t.Fatal("nobody waits on the clock")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.waiters[len(f.waiters)-1].at.Sub(f.now)
}

// waitBetween blocks until a pending waiter asks for a duration in [lo, hi] and returns it.
func (f *fakeClock) waitBetween(t *testing.T, lo, hi time.Duration) time.Duration {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		f.mu.Lock()
		for _, w := range f.waiters {
			if d := w.at.Sub(f.now); d >= lo && d <= hi {
				f.mu.Unlock()
				return d
			}
		}
		f.mu.Unlock()
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("no waiter between %v and %v", lo, hi)
	return 0
}

func (f *fakeClock) Advance(d time.Duration) {
	f.mu.Lock()
	f.now = f.now.Add(d)
	var keep []*waiter
	for _, w := range f.waiters {
		if !w.at.After(f.now) {
			w.ch <- f.now
		} else {
			keep = append(keep, w)
		}
	}
	f.waiters = keep
	f.mu.Unlock()
}

// fakeServer is a minimal relay: it logs devices in (any signature) and serves a hook for /v1/ws
// and for the other operations.
type fakeServer struct {
	*httptest.Server
	logins atomic.Int32
	// challenge, when set, picks the nonce of a Challenge (default "nonce") and sees the request.
	challenge func(*relayv1.GetChallenge) []byte
	op        func(w http.ResponseWriter, req *relayv1.Request) bool // true when it answered
	ws        http.HandlerFunc
}

func newFakeServer(t *testing.T) *fakeServer {
	t.Helper()
	s := &fakeServer{}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", func(w http.ResponseWriter, r *http.Request) { s.ws(w, r) })
	mux.HandleFunc("/v1/op", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req relayv1.Request
		if err := proto.Unmarshal(body, &req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		var resp *relayv1.Response
		switch req.GetOp().(type) {
		case *relayv1.Request_Challenge:
			nonce := []byte("nonce")
			if s.challenge != nil {
				nonce = s.challenge(req.GetChallenge())
			}
			resp = &relayv1.Response{Result: &relayv1.Response_Challenge{Challenge: &relayv1.Challenge{Nonce: nonce}}}
		case *relayv1.Request_Login:
			n := s.logins.Add(1)
			resp = &relayv1.Response{Result: &relayv1.Response_Session{Session: &relayv1.Session{Token: "tok" + string(rune('0'+n))}}}
		default:
			if s.op != nil && s.op(w, &req) {
				return
			}
			resp = &relayv1.Response{Result: &relayv1.Response_Ok{Ok: &relayv1.Ok{}}}
		}
		writeResponse(w, resp)
	})
	s.Server = httptest.NewServer(mux)
	t.Cleanup(s.Close)
	return s
}

func writeResponse(w http.ResponseWriter, resp *relayv1.Response) {
	b, _ := proto.Marshal(resp)
	w.Header().Set("Content-Type", "application/x-protobuf")
	_, _ = w.Write(b)
}

func unavailable() *relayv1.Response {
	return &relayv1.Response{Result: &relayv1.Response_Error{Error: &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_UNAVAILABLE}}}
}

func newClient(t *testing.T, s *fakeServer, opts ...client.Option) *client.Client {
	t.Helper()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return client.New(s.URL, key, phoneKind, opts...)
}

// acceptHello accepts the upgrade, reads the Hello and answers HelloOk; it returns the socket.
func acceptHello(t *testing.T, w http.ResponseWriter, r *http.Request, opts *websocket.AcceptOptions) *websocket.Conn {
	t.Helper()
	ws, err := websocket.Accept(w, r, opts)
	if err != nil {
		t.Errorf("accept: %v", err)
		return nil
	}
	if _, _, err := ws.Read(r.Context()); err != nil {
		t.Errorf("read hello: %v", err)
		return nil
	}
	b, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_HelloOk{HelloOk: &relayv1.HelloOk{}}})
	if err := ws.Write(r.Context(), websocket.MessageBinary, b); err != nil {
		t.Errorf("write hello_ok: %v", err)
		return nil
	}
	return ws
}

// TestDialSendsAuthorizationHeader: the upgrade of /v1/ws carries the session token.
func TestDialSendsAuthorizationHeader(t *testing.T) {
	s := newFakeServer(t)
	got := make(chan string, 1)
	s.ws = func(w http.ResponseWriter, r *http.Request) {
		got <- r.Header.Get("Authorization")
		if ws := acceptHello(t, w, r, nil); ws != nil {
			_, _, _ = ws.Read(r.Context()) // hold the socket until the client closes
		}
	}
	c := newClient(t, s)
	conn, err := c.Connect(t.Context())
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = conn.Close() }()
	if h := <-got; h != "Bearer tok1" {
		t.Fatalf("Authorization = %q", h)
	}
}

// TestClientPings30s: an open connection is pinged every 30 s of the client's clock, not sooner.
func TestClientPings30s(t *testing.T) {
	s := newFakeServer(t)
	pings := make(chan struct{}, 8)
	s.ws = func(w http.ResponseWriter, r *http.Request) {
		ws := acceptHello(t, w, r, &websocket.AcceptOptions{OnPingReceived: func(context.Context, []byte) bool {
			pings <- struct{}{}
			return true
		}})
		if ws != nil {
			_, _, _ = ws.Read(r.Context()) // reading is what processes pings
		}
	}
	clk := newFakeClock()
	c := newClient(t, s, client.WithClock(clk))
	conn, err := c.Connect(t.Context())
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = conn.Close() }()
	for i := range 2 {
		if d := clk.nextWait(t); d != 30*time.Second {
			t.Fatalf("round %d: ping scheduled in %v, want 30s", i, d)
		}
		select {
		case <-pings:
			t.Fatalf("round %d: ping before 30 s", i)
		case <-time.After(100 * time.Millisecond):
		}
		clk.Advance(30 * time.Second)
		select {
		case <-pings:
		case <-time.After(5 * time.Second):
			t.Fatalf("round %d: no ping after 30 s", i)
		}
	}
}

// TestRetryOnUnavailable: UNAVAILABLE twice, then Ok: the call returns Ok after waiting 0.5 s and 1 s.
func TestRetryOnUnavailable(t *testing.T) {
	s := newFakeServer(t)
	var calls atomic.Int32
	s.op = func(w http.ResponseWriter, _ *relayv1.Request) bool {
		if calls.Add(1) <= 2 {
			writeResponse(w, unavailable())
			return true
		}
		return false
	}
	clk := newFakeClock()
	c := newClient(t, s, client.WithClock(clk))
	done := make(chan error, 1)
	go func() {
		_, err := c.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_RemoveSlot{RemoveSlot: &relayv1.RemoveMacSlot{}}})
		done <- err
	}()
	for _, want := range []time.Duration{500 * time.Millisecond, time.Second} {
		if d := clk.nextWait(t); d != want {
			t.Fatalf("retry delay %v, want %v", d, want)
		}
		clk.Advance(want)
	}
	if err := <-done; err != nil {
		t.Fatalf("Do: %v", err)
	}
	if calls.Load() != 3 {
		t.Fatalf("calls = %d", calls.Load())
	}
}

// TestRetryGivesUpAfter30s: UNAVAILABLE all the time: delays 0.5, 1, 2, 4, 8, 8, then the rest of
// the 30 s; the last answer, UNAVAILABLE, is returned.
func TestRetryGivesUpAfter30s(t *testing.T) {
	s := newFakeServer(t)
	s.op = func(w http.ResponseWriter, _ *relayv1.Request) bool { writeResponse(w, unavailable()); return true }
	clk := newFakeClock()
	c := newClient(t, s, client.WithClock(clk))
	start := clk.Now()
	done := make(chan error, 1)
	go func() {
		_, err := c.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_RemoveSlot{RemoveSlot: &relayv1.RemoveMacSlot{}}})
		done <- err
	}()
	var delays []time.Duration
loop:
	for {
		select {
		case err := <-done:
			if client.Code(err) != relayv1.ErrorCode_ERROR_CODE_UNAVAILABLE {
				t.Fatalf("err = %v", err)
			}
			break loop
		case <-clk.waiting:
			clk.mu.Lock()
			d := clk.waiters[len(clk.waiters)-1].at.Sub(clk.now)
			clk.mu.Unlock()
			delays = append(delays, d)
			clk.Advance(d)
		case <-time.After(5 * time.Second):
			t.Fatal("timeout")
		}
	}
	want := []time.Duration{500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 8 * time.Second, 6500 * time.Millisecond}
	if len(delays) != len(want) {
		t.Fatalf("delays = %v, want %v", delays, want)
	}
	for i := range want {
		if delays[i] != want[i] {
			t.Fatalf("delays = %v, want %v", delays, want)
		}
	}
	if el := clk.Now().Sub(start); el != 30*time.Second {
		t.Fatalf("gave up after %v, want 30s", el)
	}
}

// TestDialRelogsInOn401: an upgrade refused with HTTP 401 makes the client log in again and connect
// with the new token.
func TestDialRelogsInOn401(t *testing.T) {
	s := newFakeServer(t)
	var seen []string
	var mu sync.Mutex
	s.ws = func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.Header.Get("Authorization"))
		mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer tok2" {
			http.Error(w, "expired", http.StatusUnauthorized)
			return
		}
		if ws := acceptHello(t, w, r, nil); ws != nil {
			_, _, _ = ws.Read(r.Context())
		}
	}
	c := newClient(t, s)
	if err := c.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	conn, err := c.Connect(t.Context())
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = conn.Close() }()
	mu.Lock()
	defer mu.Unlock()
	if s.logins.Load() != 2 || len(seen) != 2 || seen[0] != "Bearer tok1" || seen[1] != "Bearer tok2" {
		t.Fatalf("logins %d, upgrades %v", s.logins.Load(), seen)
	}
}

// TestHelloMismatchRelogsIn: the server closes 4001 after Hello; the client logs in again and connects.
func TestHelloMismatchRelogsIn(t *testing.T) {
	s := newFakeServer(t)
	var upgrades atomic.Int32
	s.ws = func(w http.ResponseWriter, r *http.Request) {
		if upgrades.Add(1) == 1 {
			ws, err := websocket.Accept(w, r, nil)
			if err != nil {
				return
			}
			_, _, _ = ws.Read(r.Context()) // the Hello
			_ = ws.Close(4001, "token mismatch")
			return
		}
		if r.Header.Get("Authorization") != "Bearer tok2" {
			t.Errorf("second upgrade used %q", r.Header.Get("Authorization"))
		}
		if ws := acceptHello(t, w, r, nil); ws != nil {
			_, _, _ = ws.Read(r.Context())
		}
	}
	c := newClient(t, s)
	conn, err := c.Connect(t.Context())
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = conn.Close() }()
	if s.logins.Load() != 2 || upgrades.Load() != 2 {
		t.Fatalf("logins %d, upgrades %d", s.logins.Load(), upgrades.Load())
	}
}

// TestReconnectDelayAfterGoingAway: after GoingAway the client waits a random 1-3 s of its clock
// before dialing again; not sooner.
func TestReconnectDelayAfterGoingAway(t *testing.T) {
	s := newFakeServer(t)
	var upgrades atomic.Int32
	s.ws = func(w http.ResponseWriter, r *http.Request) {
		ws := acceptHello(t, w, r, nil)
		if ws == nil {
			return
		}
		if upgrades.Add(1) == 1 {
			b, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_GoingAway{GoingAway: &relayv1.GoingAway{}}})
			_ = ws.Write(r.Context(), websocket.MessageBinary, b)
			_ = ws.Close(websocket.StatusGoingAway, "displaced")
			return
		}
		_, _, _ = ws.Read(r.Context())
	}
	clk := newFakeClock()
	c := newClient(t, s, client.WithClock(clk))
	conn, err := c.Connect(t.Context())
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = conn.Close() }()
	d := clk.waitBetween(t, time.Second, 3*time.Second)
	time.Sleep(100 * time.Millisecond)
	if upgrades.Load() != 1 {
		t.Fatal("reconnected before the delay")
	}
	clk.Advance(d)
	deadline := time.Now().Add(5 * time.Second)
	for upgrades.Load() < 2 {
		if time.Now().After(deadline) {
			t.Fatal("no reconnect after the delay")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestCloseGoingAwayWithoutFrame: a close with 1001 and no GoingAway frame (a Cloudflare rollout)
// counts as GoingAway: the callback runs once and the client waits 1-3 s before dialing again. A
// GoingAway frame followed by 1001 runs the callback once too, not twice.
func TestCloseGoingAwayWithoutFrame(t *testing.T) {
	for _, frame := range []bool{false, true} {
		t.Run(fmt.Sprintf("frame=%v", frame), func(t *testing.T) {
			s := newFakeServer(t)
			var upgrades atomic.Int32
			s.ws = func(w http.ResponseWriter, r *http.Request) {
				ws := acceptHello(t, w, r, nil)
				if ws == nil {
					return
				}
				if upgrades.Add(1) == 1 {
					if frame {
						b, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_GoingAway{GoingAway: &relayv1.GoingAway{}}})
						_ = ws.Write(r.Context(), websocket.MessageBinary, b)
					}
					_ = ws.Close(websocket.StatusGoingAway, "rollout")
					return
				}
				_, _, _ = ws.Read(r.Context())
			}
			var calls atomic.Int32
			clk := newFakeClock()
			c := newClient(t, s, client.WithClock(clk), client.WithOnGoingAway(func() { calls.Add(1) }))
			conn, err := c.Connect(t.Context())
			if err != nil {
				t.Fatalf("connect: %v", err)
			}
			defer func() { _ = conn.Close() }()
			d := clk.waitBetween(t, time.Second, 3*time.Second)
			if n := calls.Load(); n != 1 {
				t.Fatalf("onGoingAway ran %d times, want 1", n)
			}
			clk.Advance(d)
			deadline := time.Now().Add(5 * time.Second)
			for upgrades.Load() < 2 {
				if time.Now().After(deadline) {
					t.Fatal("no reconnect after the delay")
				}
				time.Sleep(5 * time.Millisecond)
			}
			if n := calls.Load(); n != 1 {
				t.Fatalf("onGoingAway ran %d times, want 1", n)
			}
		})
	}
}
