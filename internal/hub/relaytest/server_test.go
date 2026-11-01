package relaytest_test

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/relaytest"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// hub is a hub's relay transport over the fake, with its keys for a phone.
type hub struct {
	tr      *relay.Transport
	c       *client.Client
	relayID string
	id      secure.ID
	sig     ed25519.PublicKey
	kx      *ecdh.PrivateKey
}

func newHub(t *testing.T, srv *relaytest.Server) *hub {
	t.Helper()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	c := relay.NewClient(srv.URL, key)
	if _, err := c.Register(t.Context()); err != nil { // a phone can vouch for it before it connects
		t.Fatal(err)
	}
	tr := relay.New(c, relay.Options{Origin: srv.URL, HubRelayID: c.DeviceID(), Store: st, AssetDir: t.TempDir()})
	t.Cleanup(func() { _ = tr.Close() })
	return &hub{tr: tr, c: c, relayID: c.DeviceID(), id: secure.DeviceID(pub), sig: pub, kx: kx}
}

func (h *hub) connect(t *testing.T) {
	t.Helper()
	if err := h.tr.Connect(t.Context(), nil); err != nil {
		t.Fatal(err)
	}
}

// phone is a hubtest phone on the fake relay, registered.
func newPhone(t *testing.T, srv *relaytest.Server, h *hub) (*hubtest.Phone, *hubtest.RelayStore) {
	t.Helper()
	store := &hubtest.RelayStore{}
	meta := make([]byte, 32)
	if _, err := rand.Read(meta); err != nil {
		t.Fatal(err)
	}
	p, err := hubtest.New(hubtest.Config{
		Hub: h.id, HubKX: h.kx.PublicKey(), HubSig: h.sig, MetaKey: meta, Epoch: 1,
		HubRelayID: h.relayID, Transport: store,
	})
	if err != nil {
		t.Fatal(err)
	}
	store.C = hubtest.NewPhoneClient(srv.URL, p)
	if account, err := store.Register(t.Context()); err != nil || account == "" {
		t.Fatalf("phone register: %q, %v", account, err)
	}
	return p, store
}

// waitEvent waits for the first hub event match accepts, skipping others.
func waitEvent(t *testing.T, tr *relay.Transport, what string, match func(transport.Event) bool) transport.Event {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case ev := <-tr.Events():
			if match(ev) {
				return ev
			}
		case <-deadline:
			t.Fatalf("no %s", what)
			return transport.Event{}
		}
	}
}

func control(kind transport.ControlKind, detail string) func(transport.Event) bool {
	return func(ev transport.Event) bool {
		return ev.Control != nil && ev.Control.Kind == kind && ev.Control.Detail == detail
	}
}

func controlOf(kind transport.ControlKind) func(transport.Event) bool {
	return func(ev transport.Event) bool { return ev.Control != nil && ev.Control.Kind == kind }
}

// addSlot vouches for h as the store's phone and puts it into the phone's
// slots.
func addSlot(t *testing.T, store *hubtest.RelayStore, h *hub) {
	t.Helper()
	vouch(t, store, h)
	if err := addSlotOnly(t, store, h.relayID); err != nil {
		t.Fatal(err)
	}
}

func addSlotOnly(t *testing.T, store *hubtest.RelayStore, mac string) error {
	t.Helper()
	_, err := store.C.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_AddSlot{AddSlot: &relayv1.AddMacSlot{
		MacDeviceId: mac,
	}}})
	return err
}

// vouch is the phone's vouch_hub for h (registered by newHub).
func vouch(t *testing.T, store *hubtest.RelayStore, h *hub) {
	t.Helper()
	if err := store.VouchHub(t.Context(), h.sig); err != nil {
		t.Fatal(err)
	}
}

func phonesOf(t *testing.T, h *hub) []*relayv1.SlotHolder {
	t.Helper()
	st, err := h.tr.AccountState(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	return st.GetPhones()
}

// A phone pairs with the hub through the fake: open_pairing tells the hub
// over its WebSocket, the hello in pair/<slot> reaches it as a zone event,
// and promote_pairing puts the hub in the phone's slot (paying), which the
// hub's account state and readers then see.
func TestPairingThroughTheFakeRelay(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	h.connect(t)
	p, store := newPhone(t, srv, h)

	slot, err := store.OpenPairing(t.Context(), h.relayID)
	if err != nil {
		t.Fatal(err)
	}
	waitEvent(t, h.tr, "PAIRING_OPENED", control(transport.PairingOpened, slot))
	if err := h.tr.WatchPairZone(t.Context(), slot); err != nil {
		t.Fatal(err)
	}
	pair := transport.PairZone(slot)
	if err := p.Hello(pair); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, h.tr, "a zone event for the pair zone", func(ev transport.Event) bool { return ev.Zone == pair })
	b, err := h.tr.Changes(t.Context(), pair, 0)
	if err != nil || len(b.Changed) != 1 || b.Changed[0].Name != p.HelloName() {
		t.Fatalf("pair zone: %+v, %v", b, err)
	}

	if got := phonesOf(t, h); len(got) != 0 || h.tr.Admitted() {
		t.Fatalf("phones before promote_pairing: %v", got)
	}
	vouch(t, store, h)
	if err := store.PromotePairing(t.Context(), slot); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, h.tr, "SLOT_ADDED", control(transport.SlotAdded, p.RelayDeviceID()))
	if !h.tr.Vouched() {
		t.Fatal("SLOT_ADDED came before the account state showed the slot")
	}
	got := phonesOf(t, h)
	if len(got) != 1 || got[0].GetPhoneDeviceId() != p.RelayDeviceID() || !got[0].GetPaying() || !h.tr.Admitted() {
		t.Fatalf("phones after promote_pairing: %v", got)
	}
	if err := store.PromotePairing(t.Context(), slot); err == nil {
		t.Fatal("a pairing slot promoted twice")
	}
	ps, err := store.C.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_GetAccountState{GetAccountState: &relayv1.GetAccountState{}}})
	if err != nil || !slices.Equal(ps.GetAccountState().GetMacDeviceIds(), []string{h.relayID}) ||
		ps.GetAccountState().GetEntitlement().GetState() != relayv1.EntitlementKind_ENTITLEMENT_KIND_ACTIVE {
		t.Fatalf("the phone's account state: %v, %v", ps, err)
	}
	if err := h.tr.SetLinkedReaders(t.Context(), []string{p.RelayDeviceID()}); err != nil {
		t.Fatal(err)
	}
	if r := srv.Readers(); len(r) != 1 || !slices.Equal(r[0], []string{p.RelayDeviceID()}) {
		t.Fatalf("readers: %v", r)
	}
}

// A pairing opened while the hub has no WebSocket reaches it when it
// connects.
func TestPairingOpenedIsHeldForAnOfflineHub(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	_, store := newPhone(t, srv, h)
	slot, err := store.OpenPairing(t.Context(), h.relayID)
	if err != nil {
		t.Fatal(err)
	}
	h.connect(t)
	waitEvent(t, h.tr, "the held PAIRING_OPENED", control(transport.PairingOpened, slot))
}

// SetPaying(false) sends ENTITLEMENT_EXPIRED naming the phone to the hub it
// holds, and the hub's account state shows the phone not paying; paying
// again sends nothing and shows it paying.
func TestSetPayingSendsEntitlementExpiredToTheHub(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	h.connect(t)
	p, store := newPhone(t, srv, h)
	addSlot(t, store, h)
	if got := phonesOf(t, h); len(got) != 1 || !got[0].GetPaying() {
		t.Fatalf("phones after add_slot: %v", got)
	}

	srv.SetPaying(p.RelayDeviceID(), false)
	waitEvent(t, h.tr, "ENTITLEMENT_EXPIRED", control(transport.EntitlementExpired, p.RelayDeviceID()))
	if got := phonesOf(t, h); len(got) != 1 || got[0].GetPaying() || h.tr.Admitted() {
		t.Fatalf("phones after SetPaying(false): %v", got)
	}
	srv.SetPaying(p.RelayDeviceID(), false) // already off: no second control

	srv.SetPaying(p.RelayDeviceID(), true)
	if got := phonesOf(t, h); len(got) != 1 || !got[0].GetPaying() || !h.tr.Admitted() {
		t.Fatalf("phones after SetPaying(true): %v", got)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 300*time.Millisecond)
	defer cancel()
	for {
		select {
		case ev := <-h.tr.Events():
			if controlOf(transport.EntitlementExpired)(ev) {
				t.Fatal("a second ENTITLEMENT_EXPIRED")
			}
		case <-ctx.Done():
			return
		}
	}
}

// Frames holds every message the relay received — the phone's sealed
// action among them — and no plaintext from the hello or the action.
func TestFramesCaptureEverythingAndNoPlaintext(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	h.connect(t)
	p, store := newPhone(t, srv, h)
	slot, err := store.OpenPairing(t.Context(), h.relayID)
	if err != nil {
		t.Fatal(err)
	}
	if err := p.Hello(transport.PairZone(slot)); err != nil {
		t.Fatal(err)
	}
	const marker = "wt-canary-relaytest-7f3a91"
	a := p.NewAction("interop_mark")
	a.Params["mark"] = json.RawMessage(`"` + marker + `"`)
	seq, err := p.Queue(a)
	if err != nil {
		t.Fatal(err)
	}
	if err := p.Send(seq); err != nil {
		t.Fatal(err)
	}
	_, env := p.Sealed(seq)

	frames := srv.Frames()
	if len(frames) == 0 {
		t.Fatal("no frames captured")
	}
	sawEnv := false
	for _, f := range frames {
		sawEnv = sawEnv || bytes.Contains(f, env)
		for _, plain := range []string{marker, "Test Phone", "interop_mark"} {
			if bytes.Contains(f, []byte(plain)) {
				t.Fatalf("plaintext %q in a frame the relay received", plain)
			}
		}
	}
	if !sawEnv {
		t.Fatal("the phone's sealed action is not among the frames")
	}
}

// Guard: relaytest is a test-only package; no non-test package imports it,
// on either platform the hub ships for (a linux-only file counts too).
func TestRelaytestIsImportedOnlyByTests(t *testing.T) {
	const pkg = "watchtower/internal/hub/relaytest"
	for _, goos := range []string{"linux", "darwin"} {
		cmd := exec.Command("go", "list", "-f", "{{.ImportPath}} {{join .Imports \" \"}}", "watchtower/...")
		cmd.Dir = filepath.Join("..", "..", "..")
		cmd.Env = append(os.Environ(), "GOOS="+goos, "CGO_ENABLED=1")
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("GOOS=%s go list: %v", goos, err)
		}
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 0 || fields[0] == pkg {
				continue
			}
			if slices.Contains(fields[1:], pkg) {
				t.Errorf("GOOS=%s: %s imports %s from a non-test file", goos, fields[0], pkg)
			}
		}
	}
}

// ---- raw WebSockets (a device's sockets under the test's control) ----

func dialWS(t *testing.T, srv *relaytest.Server, device string) *websocket.Conn {
	t.Helper()
	ws, _, err := websocket.Dial(t.Context(), "ws"+strings.TrimPrefix(srv.URL, "http")+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ws.CloseNow() })
	hello, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Hello{Hello: &relayv1.Hello{
		ProtocolVersion: relayv1.ProtocolVersion, SessionToken: "tok-" + device,
	}}})
	if err := ws.Write(t.Context(), websocket.MessageBinary, hello); err != nil {
		t.Fatal(err)
	}
	if fr := readFrame(t, ws, time.Second); fr == nil || fr.GetHelloOk() == nil {
		t.Fatalf("no hello_ok: %v", fr)
	}
	return ws
}

// subscribeWS subscribes zones and waits for the answer.
func subscribeWS(t *testing.T, ws *websocket.Conn, zones ...string) {
	t.Helper()
	b, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Request{Request: &relayv1.Request{
		Id: 1, Op: &relayv1.Request_Subscribe{Subscribe: &relayv1.Subscribe{Zones: zones}},
	}}})
	if err := ws.Write(t.Context(), websocket.MessageBinary, b); err != nil {
		t.Fatal(err)
	}
	if fr := readFrame(t, ws, time.Second); fr == nil || fr.GetResponse() == nil {
		t.Fatalf("no subscribe answer: %v", fr)
	}
}

// readFrame reads one frame, nil when none comes within wait.
func readFrame(t *testing.T, ws *websocket.Conn, wait time.Duration) *relayv1.Frame {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), wait)
	defer cancel()
	_, b, err := ws.Read(ctx)
	if err != nil {
		return nil
	}
	var fr relayv1.Frame
	if err := proto.Unmarshal(b, &fr); err != nil {
		t.Fatal(err)
	}
	return &fr
}

// A control sent to a socket that just died is not lost: the device's next
// socket gets it.
func TestControlOnADeadSocketReachesTheNextOne(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	_, store := newPhone(t, srv, h)
	dead := dialWS(t, srv, h.relayID)
	_ = dead.CloseNow() // the relay may still hold it as current
	slot, err := store.OpenPairing(t.Context(), h.relayID)
	if err != nil {
		t.Fatal(err)
	}
	next := dialWS(t, srv, h.relayID)
	fr := readFrame(t, next, 5*time.Second)
	if c := fr.GetEvent().GetControl(); c.GetKind() != relayv1.ControlKind_CONTROL_KIND_PAIRING_OPENED || c.GetDetail() != slot {
		t.Fatalf("the next socket got %v, want PAIRING_OPENED %s", fr, slot)
	}
}

// A device's newer socket replaces the older one: controls and Push go to
// the newer only.
func TestNewSocketReplacesTheOldForControlsAndPush(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	p, store := newPhone(t, srv, h)
	addSlot(t, store, h)
	old := dialWS(t, srv, h.relayID)
	subscribeWS(t, old, "z")
	cur := dialWS(t, srv, h.relayID)
	subscribeWS(t, cur, "z")

	srv.SetPaying(p.RelayDeviceID(), false)
	if c := readFrame(t, cur, 5*time.Second).GetEvent().GetControl(); c.GetKind() != relayv1.ControlKind_CONTROL_KIND_ENTITLEMENT_EXPIRED {
		t.Fatalf("the current socket got control %v", c)
	}
	srv.Push(t, &relayv1.Event{Kind: &relayv1.Event_ZoneChanged{ZoneChanged: &relayv1.ZoneChanged{Zone: "z", Seq: 7}}})
	if zc := readFrame(t, cur, 5*time.Second).GetEvent().GetZoneChanged(); zc.GetSeq() != 7 {
		t.Fatalf("the current socket got %v from Push", zc)
	}
	if fr := readFrame(t, old, 300*time.Millisecond); fr != nil {
		t.Fatalf("the replaced socket got %v", fr)
	}
}

// Zone events reach a socket in seq order while several devices write the
// zone at once.
func TestZoneEventsArriveInSeqOrderAcrossWriters(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	ws := dialWS(t, srv, h.relayID)
	subscribeWS(t, ws, "z")
	const writers, each = 3, 20
	stores := make([]*hubtest.RelayStore, writers)
	for i := range stores {
		_, stores[i] = newPhone(t, srv, h)
	}
	var wg sync.WaitGroup
	errs := make(chan error, writers*each)
	for i, st := range stores {
		wg.Go(func() {
			for n := range each {
				if _, err := st.Write("z", fmt.Sprintf("r%d-%d", i, n), []byte{1}, transport.Expect{}); err != nil {
					errs <- err
				}
			}
		})
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	var last uint64
	for range writers * each {
		zc := readFrame(t, ws, 5*time.Second).GetEvent().GetZoneChanged()
		if zc == nil || zc.GetSeq() <= last {
			t.Fatalf("zone event %v after seq %d", zc, last)
		}
		last = zc.GetSeq()
	}
}
