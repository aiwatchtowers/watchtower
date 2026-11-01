//go:build interop

// The Kit phone against this Go hub on the relay's local stand (relay client
// Phase 3 Task 13): `make relay-interop-kit-hub RELAY=<relay checkout>`
// starts the stand, runs TestInterop_KitPhone with -kit-dir and, beside it,
// the Kit's GoHubInteropTests with the same folder. The two sides hand off
// through files in that folder, each written whole (temp file + rename):
//
//	hub → phone  pair.url       the link code (link.EventQR's URL)
//	phone → hub  pair.sas       the four-digit code the phone computed
//	hub → phone  confirmed      the owner confirmed (only on equal codes)
//	phone → hub  actions.done   kitReport (JSON): links, Try Again, actions done
//	hub → phone  go.ok          every check passed, or go.fail with the check's name
//	phone → hub  farewell.sent  the unlinked device record is flushed to the mailbox
//	hub → phone  farewell.ok    it opens with the hub's keys and says unlinked
//	phone → hub  unlinked       the slot is removed
//	hub → phone  unlink.ok      the hub's account state no longer lists the phone
//	phone → hub  readded        add_slot of the same Mac succeeded
//	hub → phone  go.done        the hub sees the phone again
//
// Without -kit-dir (every other interop run) the test skips.
package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

var kitDir = flag.String("kit-dir", "", "handoff folder of the Kit phone run (make relay-interop-kit-hub sets it)")

// The Kit's ActionKind is a closed enum, so the interop mark rides on a kind
// the Kit can send and this hub has no handler for: digest_read (idempotent,
// not refused, not a session kind). The test registers its counting handler
// under it; params.mark carries the phone's canary.
const kitMarkKind = "digest_read"

// The waits of the Kit run: the phone's steps run in another process.
const (
	kitSASWait  = 120 * time.Second
	kitStepWait = 5 * time.Minute
)

// kitReport is actions.done: what the phone did, for the checks it cannot
// make itself.
type kitReport struct {
	// The phone's own relay device id, sent in its hello.
	RelayDeviceID string `json:"relay_device_id"`
	// The slot of the hello and the slot Try Again opened (no hello there).
	FirstSlot string `json:"first_slot"`
	RetrySlot string `json:"retry_slot"`
	// The canaries of actions 1..3, in order.
	Marks []string `json:"marks"`
}

// kitMarks is the counting handler: every call in arrival order.
type kitMarks struct {
	mu    sync.Mutex
	calls []kitCall
}

type kitCall struct {
	seq  uint64
	mark string
}

func (m *kitMarks) register(d *actions.Dispatcher) {
	d.Register(kitMarkKind, func(_ context.Context, r actions.Request) actions.Outcome {
		var mark string
		_ = json.Unmarshal(r.Action.Params["mark"], &mark)
		c := kitCall{mark: mark}
		if r.Action.ActionSeq != nil {
			c.seq = *r.Action.ActionSeq
		}
		m.mu.Lock()
		m.calls = append(m.calls, c)
		m.mu.Unlock()
		return actions.Outcome{Status: wire.StatusApplied}
	}, actions.KindOptions{})
}

func (m *kitMarks) all() []kitCall {
	m.mu.Lock()
	defer m.mu.Unlock()
	return slices.Clone(m.calls)
}

// logTap keeps the standard logger's lines (the hub logs through it) while
// still writing them to stderr.
type logTap struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (l *logTap) Write(p []byte) (int, error) {
	l.mu.Lock()
	l.buf.Write(p)
	l.mu.Unlock()
	return os.Stderr.Write(p)
}

func (l *logTap) since(mark int) string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.String()[mark:]
}

func (l *logTap) len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.Len()
}

// outStreams is every byte the hub sent, one stream per connection.
func (w *wireTap) outStreams() [][]byte {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := make([][]byte, 0, len(w.conns))
	for _, c := range w.conns {
		c.mu.Lock()
		out = append(out, bytes.Clone(c.out.Bytes()))
		c.mu.Unlock()
	}
	return out
}

// wroteKeyboxTo reports whether a save the hub sent names a keybox record in
// zone: the record's zone bytes followed, after the protobuf tag and length,
// by a "keybox-" name (a changes request names the zone, never a keybox).
func wroteKeyboxTo(streams [][]byte, zone string) bool {
	z := []byte(zone)
	for _, s := range streams {
		rest := s
		for {
			i := bytes.Index(rest, z)
			if i < 0 {
				break
			}
			after := rest[i+len(z):]
			if len(after) > 8 {
				after = after[:2+len("keybox-")]
			}
			if bytes.Contains(after, []byte("keybox-")) {
				return true
			}
			rest = rest[i+len(z):]
		}
	}
	return false
}

// kitRun is the hub's half of one Kit run.
type kitRun struct {
	t   *testing.T
	dir string
}

// fail writes go.fail with the check's name, then fails the test.
func (k kitRun) fail(check, format string, args ...any) {
	k.t.Helper()
	k.write("go.fail", check)
	k.t.Fatalf(check+": "+format, args...)
}

func (k kitRun) write(name, body string) {
	k.t.Helper()
	tmp := filepath.Join(k.dir, "."+name+".tmp")
	if err := os.WriteFile(tmp, []byte(body), 0o600); err != nil {
		k.t.Fatal(err)
	}
	if err := os.Rename(tmp, filepath.Join(k.dir, name)); err != nil {
		k.t.Fatal(err)
	}
}

// wait reads name once the phone wrote it; kit.fail (the phone gave up)
// ends the wait at once.
func (k kitRun) wait(name string, d time.Duration) string {
	k.t.Helper()
	deadline := time.Now().Add(d)
	for {
		if b, err := os.ReadFile(filepath.Join(k.dir, name)); err == nil {
			return string(b)
		}
		if b, err := os.ReadFile(filepath.Join(k.dir, "kit.fail")); err == nil {
			k.t.Fatalf("the Kit phone failed before %s: %s", name, b)
		}
		if time.Now().After(deadline) {
			k.fail("wait_"+name, "no %s from the Kit phone in %s", name, d)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// nextWithin is interopHub.next with its own deadline.
func (h *interopHub) nextWithin(event string, d time.Duration) ControlAnswer {
	h.t.Helper()
	_ = h.ctl.SetReadDeadline(time.Now().Add(d))
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

// within polls cond until it holds or d passes.
func within(d time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(d)
	for !cond() {
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(200 * time.Millisecond)
	}
	return true
}

// TestInterop_KitPhone: the Kit phone links (hello in its slot, the hub's
// code on both sides, the owner's confirmation, the keys), takes Try Again
// with a new slot and no hello, vouches and promotes, reads the data zone,
// sends three ordered actions and acknowledges the epoch, unlinks (farewell,
// remove_slot) and adds the Mac's slot back. This side checks what only the
// hub sees: no hello or keybox in the Try Again slot, the phone a reader
// under the relay id of its hello, the actions applied once each in order,
// the acknowledged epoch, no canary on the wire, the farewell intact, and
// the relay's phones before and after the slot came back.
func TestInterop_KitPhone(t *testing.T) {
	if *kitDir == "" {
		t.Skip("no -kit-dir: run `make relay-interop-kit-hub RELAY=<relay checkout>`")
	}
	k := kitRun{t: t, dir: *kitDir}
	logs := &logTap{}
	log.SetOutput(logs)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	marks := &kitMarks{}
	h := startHub(t, interopOpts{passEvery: time.Second, linkEvery: time.Second, register: marks.register})
	status, err := ReadStatus(h.dir)
	if err != nil {
		t.Fatal(err)
	}

	// 1–4: the link code, the phone's code, the confirmation.
	if err := h.ctl.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	k.write("pair.url", h.next(link.EventQR).URL)
	sas := h.nextWithin(link.EventSAS, kitSASWait)
	if code := strings.TrimSpace(k.wait("pair.sas", kitSASWait)); code != sas.Code {
		k.fail("sas", "the phone's code differs from the hub's")
	}
	if err := h.ctl.Send(ControlRequest{Op: OpConfirm, Device: sas.DeviceID, Confirm: true}); err != nil {
		t.Fatal(err)
	}
	if l := h.next(link.EventLinked); l.DeviceID != sas.DeviceID {
		t.Fatalf("linked: %+v", l)
	}
	confirmedAt := logs.len()
	k.write("confirmed", "")

	// 5: everything up to the epoch ack is done on the phone.
	var rep kitReport
	if err := json.Unmarshal([]byte(k.wait("actions.done", kitStepWait)), &rep); err != nil {
		k.fail("report", "actions.done is not a report: %v", err)
	}
	if rep.RetrySlot == "" || rep.RetrySlot == rep.FirstSlot || len(rep.Marks) != 3 {
		k.fail("report", "slots %q/%q, %d marks", rep.FirstSlot, rep.RetrySlot, len(rep.Marks))
	}
	if strings.Contains(logs.since(confirmedAt), "hellos read") {
		k.fail("retry_no_hello", "the hub read a hello after the confirmation")
	}
	out := h.tap.outStreams()
	if !wroteKeyboxTo(out, transport.PairZone(rep.FirstSlot)) {
		k.fail("first_slot_keybox", "no keybox write seen in the first slot (the wire check is blind)")
	}
	if wroteKeyboxTo(out, transport.PairZone(rep.RetrySlot)) {
		k.fail("retry_no_keybox", "the hub wrote a keybox into the Try Again slot")
	}

	st, err := state.Open(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	dev, ok, err := st.Device(sas.DeviceID)
	if err != nil || !ok {
		k.fail("reader", "the phone is not a linked device: %v", err)
	}
	if dev.RelayDeviceID != rep.RelayDeviceID {
		k.fail("reader", "the hub names the phone %q to the relay, its hello said %q", dev.RelayDeviceID, rep.RelayDeviceID)
	}

	// The three ordered actions: applied once each, in order, with the
	// phone's canaries.
	if !within(time.Minute, func() bool { return len(marks.all()) >= 3 }) {
		k.fail("order", "%d marks applied", len(marks.all()))
	}
	calls := marks.all()
	if len(calls) != 3 {
		k.fail("order", "%d handler calls, want 3", len(calls))
	}
	for i, c := range calls {
		if c.seq != uint64(i+1) || c.mark != rep.Marks[i] {
			k.fail("order", "call %d is action_seq %d with another mark", i+1, c.seq)
		}
	}

	// The epoch ack.
	epochs, err := st.Epochs()
	if err != nil || len(epochs) == 0 {
		t.Fatalf("hub epochs: %d, %v", len(epochs), err)
	}
	var hubEpoch uint32
	for _, e := range epochs {
		hubEpoch = max(hubEpoch, e.Epoch)
	}
	if !within(time.Minute, func() bool {
		d, ok, err := st.Device(sas.DeviceID)
		return err == nil && ok && d.AckedEpoch == hubEpoch
	}) {
		k.fail("acked_epoch", "the phone's acked epoch never reached the hub's %d", hubEpoch)
	}

	// No canary in any byte the hub sent or received.
	for i, s := range h.tap.streams() {
		for _, mark := range rep.Marks {
			if bytes.Contains(s, []byte(mark)) {
				k.fail("canary", "stream %d carries a canary in the clear", i)
			}
		}
	}
	k.write("go.ok", "")

	// 6: the unlink. The Go hub does not act on device records yet
	// (protocol §5.5): the check is that the farewell arrived intact. It is
	// read before remove_slot: a hub no slot holds is unvouched again, and
	// the relay answers its mailbox reads HUB_NOT_VOUCHED.
	k.wait("farewell.sent", kitStepWait)
	farewell(t, k, h, st, status.RelayDeviceID, dev)
	k.write("farewell.ok", "")
	k.wait("unlinked", kitStepWait)
	if !within(time.Minute, func() bool { return !hubHolds(t, h, rep.RelayDeviceID) }) {
		k.fail("unlink_phones", "the hub's account state still lists the phone")
	}
	k.write("unlink.ok", "")

	// 7: the slot is back.
	k.wait("readded", kitStepWait)
	if !within(time.Minute, func() bool { return hubHolds(t, h, rep.RelayDeviceID) }) {
		k.fail("readd_phones", "the hub's account state does not list the phone again")
	}
	k.write("go.done", "")
}

// hubHolds reports whether the hub's get_account_state lists phone.
func hubHolds(t *testing.T, h *interopHub, phone string) bool {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), stepWait)
	defer cancel()
	as, err := h.transport().AccountState(ctx)
	if err != nil {
		t.Logf("hub account state: %v", err)
		return false
	}
	for _, p := range as.GetPhones() {
		if p.GetPhoneDeviceId() == phone {
			return true
		}
	}
	return false
}

// farewell reads the phone's device-<DEVICE_ID> record from its mailbox on
// the stand and opens it with the hub's keys: it must say unlinked.
func farewell(t *testing.T, k kitRun, h *interopHub, st *state.Store, hubRelayID string, dev state.Device) {
	t.Helper()
	fs := identity.FileStore{Path: filepath.Join(h.dir, identity.FileName)}
	id, err := fs.Load()
	if err != nil {
		t.Fatal(err)
	}
	defer id.Zero()
	kr, err := identity.NewKeyring(id, st, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer kr.Wipe()
	wireName, err := secure.NewSealer(kr).WireName(secure.ZoneRelay, "device-"+strings.ToUpper(dev.ID))
	if err != nil {
		t.Fatal(err)
	}
	zone := transport.MailboxZone(hubRelayID, dev.RelayDeviceID)
	var env []byte
	ctx, cancel := context.WithTimeout(context.Background(), stepWait)
	defer cancel()
	_, err = readZoneAll(ctx, h.transport(), zone, func(r transport.Stored) {
		if r.Name == wireName {
			env = r.Envelope
		}
	})
	if err != nil {
		k.fail("farewell", "reading the phone's mailbox: %v", err)
	}
	if env == nil {
		k.fail("farewell", "no device record in the phone's mailbox")
	}
	opened, err := secure.NewOpener(kr, kr).FromPhone(zone, wireName, env)
	if err != nil {
		k.fail("farewell", "the device record does not open: %v", err)
	}
	var p wire.DevicePayload
	if opened.Frame.Kind != "device" || json.Unmarshal(opened.Frame.Payload, &p) != nil {
		k.fail("farewell", "the device record is a %q frame", opened.Frame.Kind)
	}
	if p.Unlinked == nil || !*p.Unlinked || !strings.EqualFold(p.DeviceID, dev.ID) {
		k.fail("farewell", "the device record does not say unlinked")
	}
}

// readZoneAll reads every page of zone from 0.
func readZoneAll(ctx context.Context, t transport.Transport, zone string, each func(transport.Stored)) (uint64, error) {
	var since uint64
	for {
		b, err := t.Changes(ctx, zone, since)
		if err != nil {
			return 0, err
		}
		for _, r := range b.Changed {
			each(r)
		}
		since = b.NewSeq
		if !b.More {
			return since, nil
		}
	}
}
