package hub

import (
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy/policytest"
)

// ckShares is a CloudKit-kind memfake with the bridge's linking surface:
// the shared RelayZone, an available account, the share calls recorded
// (op, or op:zone:user for a removal) and the first failing calls of an op.
type ckShares struct {
	*memfake.Fake

	mu    sync.Mutex
	calls []string
	fail  map[string]int
}

func newCKShares() *ckShares {
	return &ckShares{Fake: memfake.New(transport.KindCloudKit, nil), fail: map[string]int{}}
}

func (c *ckShares) call(op string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls = append(c.calls, op)
	if c.fail[op] > 0 {
		c.fail[op]--
		return transport.ErrUnavailable
	}
	return nil
}

func (c *ckShares) failNext(op string, n int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.fail[op] = n
}

func (c *ckShares) count(prefix string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := 0
	for _, op := range c.calls {
		if strings.HasPrefix(op, prefix) {
			n++
		}
	}
	return n
}

func (c *ckShares) MailboxFor(hub, _ string) string { return transport.SharedMailboxZone(hub) }

func (c *ckShares) AccountStatus(context.Context) (transport.Account, error) {
	return transport.AccountAvailable, c.call("account_status")
}

func (c *ckShares) OwnerUser(context.Context) (string, error) {
	return "_owner-acme", c.call("owner_user")
}

func (c *ckShares) EnsureShares(context.Context) (string, string, error) {
	return "https://share.example.com/d", "https://share.example.com/r", c.call("ensure_shares")
}

func (c *ckShares) SetPublicLink(_ context.Context, open bool) error {
	if open {
		return c.call("set_public_link:open")
	}
	return c.call("set_public_link:close")
}

func (c *ckShares) Participants(context.Context, string) ([]transport.Participant, error) {
	return nil, c.call("participants")
}

func (c *ckShares) RemoveParticipants(_ context.Context, zone string, users []string) error {
	return c.call("remove_participants:" + zone + ":" + strings.Join(users, ","))
}

// ckHub is a running hub over ckShares, enabled, with its control client.
type ckHub struct {
	*rig
	ck     *ckShares
	c      *ControlClient
	status Status
	passes *atomic.Int64
}

// startCloudKitHub runs a hub over a ckShares; before runs on the hub dir
// and the fake first (meta, a linked phone, failing calls), configure on
// the options.
func startCloudKitHub(t *testing.T, before func(dir string, ck *ckShares), configure func(*Options)) *ckHub {
	t.Helper()
	policytest.Set(t, nil)
	dir := shortDir(t)
	r := newRig(t, dir)
	ck := newCKShares()
	r.fake = ck.Fake
	if before != nil {
		before(dir, ck)
	}
	passes := &atomic.Int64{}
	o := r.options()
	o.newTransport = func(context.Context, identity.Identity, *state.Store, []string) (transport.Transport, error) {
		return ck, nil
	}
	o.onPass = func() { passes.Add(1) }
	if configure != nil {
		configure(&o)
	}
	r.start(o)
	r.waitState(StateOff, ReasonDisabled)
	eventually(t, 5*time.Second, "the control socket", func() bool {
		_, err := os.Stat(filepath.Join(dir, SocketName))
		return err == nil
	})
	c, err := Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	if a, err := c.Do(ControlRequest{Op: OpEnable}); err != nil || !a.OK {
		t.Fatalf("enable: %+v, %v", a, err)
	}
	r.waitState(StateRunning, "")
	status, err := ReadStatus(dir)
	if err != nil {
		t.Fatal(err)
	}
	if status.Transport != string(transport.KindCloudKit) {
		t.Fatalf("status: %+v", status)
	}
	return &ckHub{rig: r, ck: ck, c: c, status: status, passes: passes}
}

// sweepMark reads hub_meta's share_sweep_pending from a second handle.
func (h *ckHub) sweepMark() string {
	h.t.Helper()
	st, err := state.Open(h.dir)
	if err != nil {
		h.t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	v, _, err := st.Meta(link.MetaShareSweepPending)
	if err != nil {
		h.t.Fatal(err)
	}
	return v
}

// next reads the control stream up to event.
func (h *ckHub) next(event string) ControlAnswer {
	h.t.Helper()
	for {
		a, err := h.c.Next()
		if err != nil {
			h.t.Fatalf("waiting for %s: %v", event, err)
		}
		if a.Error != "" {
			h.t.Fatalf("waiting for %s: %+v", event, a)
		}
		if a.Event == event {
			return a
		}
	}
}

func TestCloudKitPassIs3sWhileInTouchElse30s(t *testing.T) {
	if CloudKitActivePass != 3*time.Second || CloudKitIdlePass != 30*time.Second || cloudKitTouchWindow != 10*time.Minute {
		t.Fatalf("cadence = %v / %v, window %v", CloudKitActivePass, CloudKitIdlePass, cloudKitTouchWindow)
	}
	now := time.Unix(1_800_000_000, 0).UTC()
	for _, tc := range []struct {
		name      string
		lastTouch time.Time
		urgent    bool
		want      time.Duration
	}{
		{"no phone wrote since start", time.Time{}, false, CloudKitIdlePass},
		{"a phone wrote just now", now, false, CloudKitActivePass},
		{"a phone wrote 9m59s ago", now.Add(-cloudKitTouchWindow + time.Second), false, CloudKitActivePass},
		{"a phone wrote 10m ago", now.Add(-cloudKitTouchWindow), false, CloudKitIdlePass},
		{"a link is waiting", time.Time{}, true, CloudKitActivePass},
		{"a link is waiting, the phone long gone", now.Add(-time.Hour), true, CloudKitActivePass},
	} {
		if got := cloudKitPassEvery(now, tc.lastTouch, tc.urgent); got != tc.want {
			t.Errorf("%s: %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestPullNowRunsAPassAtOnce(t *testing.T) {
	h := startCloudKitHub(t, nil, func(o *Options) { o.passEvery, o.linkEvery = time.Hour, time.Hour })
	// The start's passes settle; with no phone in touch the CloudKit
	// cadence is idle (30 s), so no tick passes meanwhile.
	settled := h.passes.Load()
	for {
		time.Sleep(200 * time.Millisecond)
		if n := h.passes.Load(); n == settled {
			break
		} else {
			settled = n
		}
	}
	h.ck.SendEvent(transport.Event{PullNow: true})
	eventually(t, 2*time.Second, "a pass after the push", func() bool { return h.passes.Load() > settled })
}

// A link an earlier run left open (the sweep marked pending) is closed once
// at start, with no grace: the public link closes, the participants are
// swept, the mark clears.
func TestCloudKitHubClosesALinkLeftOpenAtStart(t *testing.T) {
	h := startCloudKitHub(t, func(dir string, _ *ckShares) { setMeta(t, dir, link.MetaShareSweepPending, "1") }, nil)
	eventually(t, 5*time.Second, "the restart close", func() bool { return h.sweepMark() == "0" })
	if h.ck.count("set_public_link:close") == 0 || h.ck.count("participants") == 0 {
		t.Fatalf("no restart close")
	}
	if n := h.ck.count("set_public_link:open"); n != 0 {
		t.Fatalf("the public link was opened %d times", n)
	}
}

// With nothing marked the start makes no share call.
func TestCloudKitHubStartsWithNoShareCallWhenNothingIsLeftOpen(t *testing.T) {
	h := startCloudKitHub(t, nil, nil)
	time.Sleep(300 * time.Millisecond)
	if n := h.ck.count("set_public_link") + h.ck.count("participants") + h.ck.count("remove_participants"); n != 0 {
		t.Fatalf("%d share calls at start", n)
	}
}

// leftOpenFailingOnce marks the sweep pending (a link an earlier run left
// open) and fails the restart close's public-link call once, so the mark is
// still pending after the start.
func leftOpenFailingOnce(t *testing.T) func(string, *ckShares) {
	return func(dir string, ck *ckShares) {
		setMeta(t, dir, link.MetaShareSweepPending, "1")
		ck.failNext("set_public_link:close", 1)
	}
}

// waitFailedRestartClose waits for the restart close that failed.
func (h *ckHub) waitFailedRestartClose() {
	h.t.Helper()
	eventually(h.t, 5*time.Second, "the failed restart close", func() bool { return h.ck.count("set_public_link:close") == 1 })
	if h.sweepMark() != "1" {
		h.t.Fatal("the failed restart close cleared the mark")
	}
}

// The bridge's account_changed closes the link the old iCloud user opened,
// with no grace: the sweep runs at once.
func TestCloudKitAccountChangedClosesTheLink(t *testing.T) {
	h := startCloudKitHub(t, leftOpenFailingOnce(t), nil)
	h.waitFailedRestartClose()
	h.ck.SendEvent(transport.Event{AccountChanged: true})
	eventually(t, 5*time.Second, "the close after the account change", func() bool { return h.sweepMark() == "0" })
	if n := h.ck.count("set_public_link:close"); n != 2 {
		t.Fatalf("%d public-link closes, want 2", n)
	}
}

// A hello in the shared RelayZone reaches the link center before any phone
// is linked; the owner's confirm links it and closes the link (CloseUsed:
// the public link closes now, the participants wait for the grace).
func TestCloudKitHelloInTheRelayZoneLinksAndTheConfirmClosesTheLink(t *testing.T) {
	h := startCloudKitHub(t, leftOpenFailingOnce(t), nil)
	h.waitFailedRestartClose()
	if err := h.c.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	qr := h.next(link.EventQR)
	lp, err := wire.ParseLinkURL(qr.URL)
	if err != nil {
		t.Fatal(err)
	}
	phone, err := hubtest.FromLink(lp, h.ck.Fake, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := phone.Hello(transport.SharedMailboxZone(h.status.RelayDeviceID)); err != nil {
		t.Fatal(err)
	}
	sas := h.next(link.EventSAS)
	if sas.DeviceID != phone.ID().String() {
		t.Fatalf("sas for %s, want %s", sas.DeviceID, phone.ID())
	}
	if err := h.c.Send(ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}); err != nil {
		t.Fatal(err)
	}
	h.next(link.EventLinked)
	eventually(t, 5*time.Second, "the close after the confirm", func() bool { return h.ck.count("set_public_link:close") == 2 })
	if n := h.ck.count("remove_participants"); n != 0 {
		t.Fatalf("participants swept before the answer grace (%d calls)", n)
	}
}

const sharedPhoneID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

// The owner's Remove of a shared phone on CloudKit takes its iCloud user
// off both shares at once (RemoveCloudKit).
func TestCloudKitRemoveTakesThePhonesParticipant(t *testing.T) {
	h := startCloudKitHub(t, func(dir string, _ *ckShares) { linkSharedPhone(t, dir, sharedPhoneID, "_colleague-a") }, nil)
	if a, err := h.c.Do(ControlRequest{Op: OpUnlink, Device: sharedPhoneID}); err != nil || !a.OK {
		t.Fatalf("unlink: %+v, %v", a, err)
	}
	for _, zone := range []string{transport.DataZone(h.status.RelayDeviceID), transport.SharedMailboxZone(h.status.RelayDeviceID)} {
		if n := h.ck.count("remove_participants:" + zone + ":_colleague-a"); n == 0 {
			t.Errorf("%s: no removal", zone)
		}
	}
}

// A failed participant removal after the unlink still answers OK: the phone
// is unlinked and the sweep removes the participant.
func TestCloudKitRemoveAnswersOKWhenOnlyTheParticipantRemovalFailed(t *testing.T) {
	h := startCloudKitHub(t, func(dir string, _ *ckShares) { linkSharedPhone(t, dir, sharedPhoneID, "_colleague-a") }, nil)
	h.ck.failNext("remove_participants:"+transport.DataZone(h.status.RelayDeviceID)+":_colleague-a", 1)
	if a, err := h.c.Do(ControlRequest{Op: OpUnlink, Device: sharedPhoneID}); err != nil || !a.OK {
		t.Fatalf("unlink: %+v, %v", a, err)
	}
	if a, err := h.c.Do(ControlRequest{Op: OpUnlink, Device: sharedPhoneID}); err != nil || a.Error != ErrClassNoDevice {
		t.Fatalf("a second unlink: %+v, %v", a, err)
	}
}

// linkSharedPhone writes a shared-scope linked phone of user into the hub
// dir before the hub runs.
func linkSharedPhone(t *testing.T, dir, id, user string) {
	t.Helper()
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	sig, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	d := state.Device{ID: id, Name: "acme phone", Scope: wire.ScopeShared, LinkedAt: time.Now().UTC(),
		SigningKey: sig, AgreementKey: kx.PublicKey().Bytes(), LinkNonce: "nonce-acme"}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if err := state.LinkDevice(tx, d); err != nil {
			return err
		}
		_, err := tx.Exec(`UPDATE devices SET user_record_name = ? WHERE device_id = ?`, user, id)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if devices, err := st.Devices(); err != nil || !slices.ContainsFunc(devices, func(d state.Device) bool { return d.ID == id }) {
		t.Fatalf("devices: %v, %v", devices, err)
	}
}
