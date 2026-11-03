//go:build interop

// The Kit phone against this Go hub on the relay's local stand (relay client
// Phase 3 Task 13): `make relay-interop-kit-hub RELAY=<relay checkout>`
// starts the stand, runs TestInterop_KitPhone with -kit-dir and, beside it,
// the Kit's KitGoHubInteropTests with the same folder. The two sides hand off
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
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit/bridgefake"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"

	"google.golang.org/protobuf/proto"
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
	if *kitDesktop {
		t.Skip("-kit-desktop: the handoff folder is the desktop host's run (RELAY_INTEROP_DESKTOP=1)")
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
	// The positive control of retry_no_hello: the first slot's hello was
	// read and logged before the confirmation, so the log line is the one
	// the check below looks for.
	if !strings.Contains(logs.since(0), "hellos read") {
		k.fail("first_slot_hello", "no \"hellos read\" line for the first slot's hello (the log check is blind)")
	}
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

// ---- the transport switch both ways (relay client Phase 3b Task 20) ----
//
// TestInterop_KitPhoneFollowsASwitch runs with -kit-desktop (the script's
// RELAY_INTEROP_DESKTOP=1): the hub is a Mac's desktop host on both
// transports, its CloudKit side served to the Kit phone by the loopback
// store. The handoff, beyond Task 13's pair.url / pair.sas / confirmed:
//
//	hub → phone  ck.url             the loopback store's URL and token (0600)
//	hub → phone  free.url           the free phone's link code
//	phone → hub  free.sas           its four-digit code
//	hub → phone  free.confirmed     the owner confirmed it
//	phone → hub  upgraded           switchReport: the upgrade's steps 1–5 ran,
//	                                the free phone's forged record is written
//	phone → hub  on.relay           both phones followed the move to the relay
//	phone → hub  back.icloud        the phone asked for iCloud and followed the
//	                                marker (its relay copy of the notice gone)
//	phone → hub  too.soon           the relay again within 5 min was refused
//	phone → hub  old.epoch          an action of a retired epoch was resealed
//	phone → hub  lapse.done         the lapse moved the hub and the phone back
//	hub → phone  <step>.ok          the hub's checks of <step> passed
//	hub → phone  go.ok / go.fail    every check passed / the failed check's name
//
// Each phone step is answered by its .ok, or by go.fail.

// switchReport is what the phone writes with each step (fields it does not
// know yet are empty).
type switchReport struct {
	RelayDeviceID string   `json:"relay_device_id"`
	Marks         []string `json:"marks"`
	FreeMarks     []string `json:"free_marks"`
	OldMark       string   `json:"old_mark"`
	OldSeq        uint64   `json:"old_seq"`
	LapseMarks    []string `json:"lapse_marks"`
	AlertMark     string   `json:"alert_mark"`
	Epoch         uint32   `json:"epoch"`
	RetryAfter    int      `json:"retry_after_s"`
}

// jumpClock is the hub's clock: the real time plus an offset the test moves
// (the anti-flap and the 7-day epoch retention, never waited out).
type jumpClock struct{ off atomic.Int64 }

func (c *jumpClock) now() time.Time { return time.Now().Add(time.Duration(c.off.Load())) }

func (c *jumpClock) jump(d time.Duration) { c.off.Add(int64(d)) }

// dropSavesInto deletes every save the hub makes into zone again at once,
// until it is called with "".
func (t *tappedTransport) dropSavesInto(zone string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.dropZone = zone
}

func (t *tappedTransport) droppedCount() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.dropped
}

// Save is the relay's save; a save into the drop zone is deleted at once
// (the phone never reads it).
func (t *tappedTransport) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	out, err := t.Transport.Save(ctx, items)
	t.mu.Lock()
	zone := t.dropZone
	t.mu.Unlock()
	if err != nil || zone == "" {
		return out, err
	}
	var gone []transport.DeleteItem
	for i, it := range items {
		if it.Record.Zone() == zone && i < len(out) && out[i].Saved {
			gone = append(gone, transport.DeleteItem{Name: it.Record.WireName()})
		}
	}
	if len(gone) > 0 {
		if _, derr := t.Transport.Delete(ctx, zone, gone); derr == nil {
			t.mu.Lock()
			t.dropped += len(gone)
			t.mu.Unlock()
		} else {
			log.Printf("interop: dropping %d saves failed: %v", len(gone), derr)
		}
	}
	return out, err
}

// SetReadersFrom is the relay's set_hub_readers, the readers kept.
func (t *tappedTransport) SetReadersFrom(ctx context.Context, st *relayv1.AccountState, linked []string) error {
	err := t.Transport.SetReadersFrom(ctx, st, linked)
	if err == nil {
		slotted := map[string]bool{}
		for _, p := range st.GetPhones() {
			slotted[p.GetPhoneDeviceId()] = true
		}
		var readers []string
		for _, id := range linked {
			if slotted[id] {
				readers = append(readers, id)
			}
		}
		t.mu.Lock()
		t.readers = readers
		t.mu.Unlock()
	}
	return err
}

func (t *tappedTransport) lastReaders() []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return slices.Clone(t.readers)
}

// step reads the phone's report for step, once written.
func (k kitRun) step(name string) switchReport {
	k.t.Helper()
	var r switchReport
	if err := json.Unmarshal([]byte(k.wait(name, kitStepWait)), &r); err != nil {
		k.fail(name, "not a report: %v", err)
	}
	return r
}

// pushWait answers every send_alert RATE_LIMITED for 5 minutes without
// sending it: the stand has no APNs key and would settle the push push_off at
// once, while check 9 needs a push still waiting when the hub moves to iCloud
// (TestSwitchToCloudKitResignalsOpenQueuedAlerts's phone half). Every other
// op goes to the stand.
type pushWait struct {
	base http.RoundTripper
}

func (p *pushWait) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.Method != http.MethodPost || !strings.HasSuffix(r.URL.Path, "/v1/op") || r.Body == nil {
		return p.base.RoundTrip(r)
	}
	body, err := io.ReadAll(r.Body)
	_ = r.Body.Close()
	if err != nil {
		return nil, err
	}
	var req relayv1.Request
	if proto.Unmarshal(body, &req) != nil || req.GetSendAlert() == nil {
		r.Body = io.NopCloser(bytes.NewReader(body))
		return p.base.RoundTrip(r)
	}
	wait := uint32(300)
	out, err := proto.Marshal(&relayv1.Response{Id: req.GetId(), Result: &relayv1.Response_Error{Error: &relayv1.Error{
		Code: relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, RetryAfterS: &wait,
	}}})
	if err != nil {
		return nil, err
	}
	return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": {"application/x-protobuf"}},
		Body: io.NopCloser(bytes.NewReader(out)), ContentLength: int64(len(out)), Request: r}, nil
}

// TestInterop_KitPhoneFollowsASwitch: the Kit phone links over iCloud (the
// loopback store), upgrades to the relay and moves the hub there; the hub
// moves back to iCloud at once, refuses the relay again within the
// anti-flap, retires an epoch, and falls back to iCloud on the phone's
// lapse. This side checks what only the hub sees (the stored relay id, the
// readers, the switches and epochs, every action applied once) and that the
// canary never crosses a tapped stream or a loopback request in the clear.
func TestInterop_KitPhoneFollowsASwitch(t *testing.T) {
	if *kitDir == "" || !*kitDesktop {
		t.Skip("needs -kit-dir and -kit-desktop: run `make relay-interop-kit-hub RELAY=<relay checkout> RELAY_INTEROP_DESKTOP=1`")
	}
	k := kitRun{t: t, dir: *kitDir}
	logs := &logTap{}
	log.SetOutput(logs)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	marks := &kitMarks{}
	alerts := &pushSource{}
	clock := &jumpClock{}
	cycle := make(chan struct{}, 1)
	h := startDesktopHub(t, interopOpts{
		passEvery: time.Second, linkEvery: time.Second, clock: clock.now, cycle: cycle, away: alwaysAway{},
		httpWrap: func(rt http.RoundTripper) http.RoundTripper { return &pushWait{base: rt} },
		sources:  func(*state.Store) []hubslices.Source { return []hubslices.Source{alerts} },
		register: func(d *actions.Dispatcher) {
			d.Register(kitMarkKind, func(_ context.Context, r actions.Request) actions.Outcome {
				var mark string
				_ = json.Unmarshal(r.Action.Params["mark"], &mark)
				c := kitCall{mark: mark}
				if r.Action.ActionSeq != nil {
					c.seq = *r.Action.ActionSeq
				}
				marks.mu.Lock()
				marks.calls = append(marks.calls, c)
				marks.mu.Unlock()
				if strings.HasPrefix(mark, "wt-canary-alert-") {
					alerts.set(t, workAlert("ask-t20"))
				}
				return actions.Outcome{Status: wire.StatusApplied}
			}, actions.KindOptions{Nudges: []string{string(hubslices.KindAskAlert)}})
		},
	})
	status, err := ReadStatus(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	url, token, loop := serveTappedCloudKitLoop(t, h.bridge)
	k.writeCloudKitURL(url, token)

	// 1. Both phones link over iCloud: the code, the phone's code, the owner.
	phone := kitLink(t, k, h, "pair.url", "pair.sas", "confirmed")
	free := kitLink(t, k, h, "free.url", "free.sas", "free.confirmed")

	st, err := state.Open(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	device := func(id string) state.Device {
		d, ok, err := st.Device(id)
		if err != nil || !ok {
			k.fail("device", "the phone is not a linked device: %v", err)
		}
		return d
	}
	meta := func(key string) string {
		v, _, err := st.Meta(key)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	kr := testKeyring(t, h, st, clock.now)
	current := func() uint32 {
		e, err := kr.CurrentEpoch()
		if err != nil {
			t.Fatal(err)
		}
		return e
	}
	linkedEpoch := current()

	// 2. The upgrade: the stored relay id, the readers, the switch accepted;
	// the free phone's forged record refused.
	rep := k.step("upgraded")
	if !within(time.Minute, func() bool { return device(phone).RelayDeviceID == rep.RelayDeviceID }) {
		k.fail("relay_id", "the hub did not store the phone's proven relay id")
	}
	if !within(time.Minute, func() bool { return slices.Contains(h.transport().lastReaders(), rep.RelayDeviceID) }) {
		k.fail("readers", "set_hub_readers never named the phone")
	}
	if !within(time.Minute, func() bool { return meta(switcher.MetaTransport) == string(transport.KindRelay) }) {
		k.fail("switch_accepted", "the hub did not move to the relay")
	}
	if strings.Contains(logs.since(0), "not_paying") {
		k.fail("switch_accepted", "the switch was refused not_paying")
	}
	if !within(time.Minute, func() bool { return strings.Contains(logs.since(0), "relay id ignored: key_mismatch") }) {
		k.fail("forged_id", "the free phone's record naming another id was not refused")
	}
	if d := device(free); d.RelayDeviceID != "" {
		k.fail("forged_id", "the free phone's record stored a relay id")
	}
	if device(phone).RelayDeviceID != rep.RelayDeviceID {
		k.fail("forged_id", "the paying phone's relay id changed")
	}
	k.write("upgraded.ok", "")

	// 3. On the relay: the new epoch acknowledged, the unechoed actions
	// applied once, the free phone's actions never.
	rep = k.step("on.relay")
	relayEpoch := current()
	if relayEpoch != linkedEpoch+1 || rep.Epoch != relayEpoch {
		k.fail("relay_epoch", "hub epoch %d (linked in %d), the phone's %d", relayEpoch, linkedEpoch, rep.Epoch)
	}
	if !within(time.Minute, func() bool { return device(phone).AckedEpoch == relayEpoch }) {
		k.fail("relay_ack", "the phone's epoch_ack{%d} was not recorded", relayEpoch)
	}
	appliedOnce(k, marks, "relay_resend", rep.Marks...)
	appliedNever(k, marks, "free_not_applied", rep.FreeMarks...)
	appliedOnce(k, marks, "alert_mark", rep.AlertMark)
	// Step 4 next: the phone asks for iCloud; its relay copy of the notice
	// is deleted the moment it is written.
	h.transport().dropSavesInto(transport.MailboxZone(status.RelayDeviceID, rep.RelayDeviceID))
	signalsBefore := signalFrames(h.bridge)
	k.write("on.relay.ok", "")

	// 4–5, 9. Back to iCloud at once, the notice's relay copy missed, the
	// open alert signalled again on CloudKit once.
	rep = k.step("back.icloud")
	h.transport().dropSavesInto("")
	if meta(switcher.MetaTransport) != string(transport.KindCloudKit) {
		k.fail("back_icloud", "the hub is not on iCloud")
	}
	if h.transport().droppedCount() == 0 {
		k.fail("missed_control", "no relay copy was deleted (the marker path is untested)")
	}
	if e := current(); e != relayEpoch+1 || rep.Epoch != e {
		k.fail("icloud_epoch", "hub epoch %d, the phone's %d", e, rep.Epoch)
	}
	if n := signalFrames(h.bridge) - signalsBefore; n != 1 {
		k.fail("alert_signal", "%d signal writes on CloudKit after the switch, want 1", n)
	}
	k.write("back.icloud.ok", "")

	// 6. Too soon: refused, the hub stays; then the anti-flap and the
	// 7-day retention pass on the hub's clock.
	rep = k.step("too.soon")
	if rep.RetryAfter <= 0 || rep.RetryAfter > 300 {
		k.fail("too_soon", "retry_after_s %d", rep.RetryAfter)
	}
	if meta(switcher.MetaTransport) != string(transport.KindCloudKit) {
		k.fail("too_soon", "the hub moved")
	}
	clock.jump(8 * 24 * time.Hour)
	if !within(time.Minute, func() bool {
		select {
		case cycle <- struct{}{}:
		default:
		}
		kept, err := kr.Retained()
		return err == nil && !slices.Contains(kept, relayEpoch)
	}) {
		k.fail("retire", "epoch %d is still retained 8 days on", relayEpoch)
	}
	k.write("too.soon.ok", "")

	// 7. The action sealed in the retired epoch: resealed, applied once
	// under its own action_seq.
	rep = k.step("old.epoch")
	appliedOnce(k, marks, "old_epoch", rep.OldMark)
	for _, c := range marks.all() {
		if c.mark == rep.OldMark && c.seq != rep.OldSeq {
			k.fail("old_epoch", "applied under action_seq %d, sealed under %d", c.seq, rep.OldSeq)
		}
	}
	if !within(time.Minute, func() bool { return device(phone).AckedEpoch == relayEpoch+1 }) {
		k.fail("icloud_ack", "the phone's epoch_ack{%d} was not recorded", relayEpoch+1)
	}
	k.write("old.epoch.ok", "")

	// 8. The lapse: the relay again, then the phone's entitlement expires;
	// the hub falls back to iCloud by entitlement_expired, nothing applied
	// twice.
	rep = k.step("lapse.done")
	if meta(switcher.MetaTransport) != string(transport.KindCloudKit) || meta(switcher.MetaSwitchedBy) != wire.SwitchedByEntitlement {
		k.fail("lapse", "transport %q by %q", meta(switcher.MetaTransport), meta(switcher.MetaSwitchedBy))
	}
	if e := current(); e != relayEpoch+3 || rep.Epoch != e {
		k.fail("lapse_epoch", "hub epoch %d, the phone's %d", e, rep.Epoch)
	}
	appliedOnce(k, marks, "lapse_once", rep.LapseMarks...)
	appliedOnce(k, marks, "all_once", append(append(rep.Marks, rep.OldMark, rep.AlertMark), rep.LapseMarks...)...)
	if !within(time.Minute, func() bool { return device(phone).AckedEpoch == relayEpoch+3 }) {
		k.fail("lapse_ack", "the phone's epoch_ack{%d} was not recorded", relayEpoch+3)
	}

	// 10. No canary in the clear: every tapped relay stream, every loopback
	// request body.
	all := append(append(append(append([]string{}, rep.Marks...), rep.FreeMarks...), rep.OldMark, rep.AlertMark), rep.LapseMarks...)
	streams := append(h.tap.streams(), loop.requestBodies()...)
	if len(loop.requestBodies()) == 0 {
		k.fail("canary", "no loopback request was tapped (the check is blind)")
	}
	for i, s := range streams {
		for _, mark := range all {
			if mark != "" && bytes.Contains(s, []byte(mark)) {
				k.fail("canary", "stream or body %d carries a canary in the clear", i)
			}
		}
	}
	k.write("go.ok", "")
}

// kitLink links one Kit phone over iCloud: the code written to urlFile,
// the phone's code read from sasFile and compared, the owner's confirmation,
// then okFile. It returns the phone's device id.
func kitLink(t *testing.T, k kitRun, h *interopHub, urlFile, sasFile, okFile string) string {
	t.Helper()
	if err := h.ctl.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	k.write(urlFile, h.next(link.EventQR).URL)
	sas := h.nextWithin(link.EventSAS, kitSASWait)
	if code := strings.TrimSpace(k.wait(sasFile, kitSASWait)); code != sas.Code {
		k.fail("sas", "the phone's code differs from the hub's")
	}
	if err := h.ctl.Send(ControlRequest{Op: OpConfirm, Device: sas.DeviceID, Confirm: true}); err != nil {
		t.Fatal(err)
	}
	if l := h.next(link.EventLinked); l.DeviceID != sas.DeviceID {
		t.Fatalf("linked: %+v", l)
	}
	k.write(okFile, "")
	return sas.DeviceID
}

// testKeyring is a keyring over the hub's sidecar on clock, for reads.
func testKeyring(t *testing.T, h *interopHub, st *state.Store, clock func() time.Time) *identity.Keyring {
	t.Helper()
	fs := identity.FileStore{Path: filepath.Join(h.dir, identity.FileName)}
	id, err := fs.Load()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(id.Zero)
	kr, err := identity.NewKeyring(id, st, clock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(kr.Wipe)
	return kr
}

// appliedOnce: the handler ran exactly once for each mark.
func appliedOnce(k kitRun, m *kitMarks, check string, want ...string) {
	k.t.Helper()
	count := func(mark string) int {
		n := 0
		for _, c := range m.all() {
			if c.mark == mark {
				n++
			}
		}
		return n
	}
	for _, mark := range want {
		if mark == "" {
			k.fail(check, "an empty mark in the report")
		}
		if !within(time.Minute, func() bool { return count(mark) >= 1 }) {
			k.fail(check, "a mark was never applied")
		}
		if n := count(mark); n != 1 {
			k.fail(check, "a mark was applied %d times", n)
		}
	}
}

// appliedNever: the handler never ran for any of the marks.
func appliedNever(k kitRun, m *kitMarks, check string, marks ...string) {
	k.t.Helper()
	for _, c := range m.all() {
		if slices.Contains(marks, c.mark) {
			k.fail(check, "an action of the free phone was applied")
		}
	}
}

// signalFrames counts the bridge requests naming a signal record.
func signalFrames(f *bridgefake.Fake) int {
	n := 0
	for _, fr := range f.Frames() {
		if bytes.Contains(fr, []byte(secure.SignalPrefix)) {
			n++
		}
	}
	return n
}
