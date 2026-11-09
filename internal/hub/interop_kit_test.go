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
//	phone → hub  device.sent    a rewritten device record is flushed to the mailbox
//	hub → phone  device.ok      the hub applied it: the name, the permission request, the switch
//	phone → hub  farewell.sent  the unlinked device record is about to be flushed
//	hub → phone  farewell.ok    the hub read it with the slot still held and removed the row
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
	"encoding/base64"
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
// the acknowledged epoch, no canary on the wire, a device record applied over
// the relay, the farewell read within the phone's pause, and
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
	h := startHub(t, interopOpts{passEvery: time.Minute, linkEvery: time.Second, register: marks.register})
	_, err := ReadStatus(h.dir)
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

	// 6: the phone's device record over the relay (G1): a request is stored,
	// never granted.
	k.wait("device.sent", kitStepWait)
	if !within(time.Minute, func() bool {
		d, ok, err := st.Device(dev.ID)
		return err == nil && ok && d.Name == "Renamed on the relay" && d.PermissionsRequested && d.WorkAlertsOff
	}) {
		k.fail("device_record", "the device record over the relay did not apply")
	}
	if d, _, err := st.Device(dev.ID); err != nil || d.PermissionsAllowed {
		k.fail("device_record", "a request became a grant (%v)", err)
	}
	k.write("device.ok", "")

	// 7: the unlink. The hub must read the farewell before remove_slot: a hub
	// no slot holds is unvouched again, and the relay answers its mailbox reads
	// HUB_NOT_VOUCHED. The phone waits 3 s for that (LinkingViewModel
	// farewellReadPause); this measures it against the real Worker.
	k.wait("farewell.sent", kitStepWait)
	sent, err := os.Stat(filepath.Join(k.dir, "farewell.sent")) // its write is the clock's start: k.wait polls
	if err != nil {
		t.Fatal(err)
	}
	if !within(farewellReadPause-time.Since(sent.ModTime()), func() bool {
		_, ok, err := st.Device(dev.ID)
		return err == nil && !ok
	}) {
		k.fail("farewell", "the hub did not apply the farewell within the phone's pause")
	}
	t.Logf("the farewell applied at most %v after the phone began to send it", time.Since(sent.ModTime()))
	k.write("farewell.ok", "")
	k.wait("unlinked", kitStepWait)
	if !within(time.Minute, func() bool { return !hubHolds(t, h, rep.RelayDeviceID) }) {
		k.fail("unlink_phones", "the hub's account state still lists the phone")
	}
	k.write("unlink.ok", "")

	// 8: the slot is back.
	k.wait("readded", kitStepWait)
	if !within(time.Minute, func() bool { return hubHolds(t, h, rep.RelayDeviceID) }) {
		k.fail("readd_phones", "the hub's account state does not list the phone again")
	}
	k.write("go.done", "")
}

// farewellReadPause is the phone's pause between its farewell and remove_slot.
const farewellReadPause = 3 * time.Second

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
	if *kitRotation {
		t.Skip("-kit-rotation: the handoff folder is the rotation run's (RELAY_INTEROP_ROTATION=1)")
	}
	if *kitUpgrade {
		t.Skip("-kit-upgrade: the handoff folder is the first-upgrade run's (RELAY_INTEROP_UPGRADE=1)")
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

// ---- relay keys rotate on the stand (relay client Phase 5 Task 11) ----
//
// TestInterop_KitPhoneRotates runs with -kit-desktop -kit-rotation (the
// script's RELAY_INTEROP_ROTATION=1): the hub is a Mac's desktop host on both
// transports, on a clock the test moves; a cycle tick runs its housekeeping,
// which rotates. Two Kit phones link over iCloud and move the hub to the
// relay; the first offers ephemeral keys (the app's HubLinkKeys merge and
// offer), the second never does. The handoff, beyond kitLink's files
// (pair.* for the offering phone, free.* for the static one) and ck.url:
//
//	phone → hub  r<N>              rotReport after the phone's step N
//	phone → hub  r<N>.ready        rotReport: the phone is ready for the hub's step N
//	hub → phone  r<N>.go           the hub's step N ran; its body is rotAnswer
//	hub → phone  r<N>.ok           the hub's checks of step N passed (rotAnswer)
//	hub → phone  go.ok / go.fail   every check passed / the failed check's name
//
// Steps: 1 both phones on the relay, a static keybox, the offer acked; 2 one
// rotation, ephemeral for the offering phone; 3 one rotation with that phone
// away, its action sealed in the epoch it left, the alert push it opens while
// locked; 4 three rotations away, a held action resealed after resend_from,
// then an echo left in a gone epoch; 5 to iCloud with an offer out and back
// after the 5-minute rule (s5.icloud / s5.icloud.ok, s5.relay / s5.go,
// s5 / s5.ok); 8 the offering phone lapses while the static one pays, then
// pays again 15 moved days later (s8.left / s8.go, s8 / s8.ok, s8.back /
// s8.rot, s8.done / s8.done.ok). The static phone is step 6 throughout.

var kitRotation = flag.Bool("kit-rotation", false, "the Kit run is the rotation scenario's (RELAY_INTEROP_ROTATION=1)")

// rotationJump is one rotation's move of the hub's clock: past the relay's
// 7-day cadence.
const rotationJump = 8 * 24 * time.Hour

// rotReport is what the phone writes with each step (fields it does not know
// yet are empty).
type rotReport struct {
	RelayA string `json:"relay_a"`
	RelayB string `json:"relay_b"`
	// Offer is the offering phone's outstanding offer (base64url, raw 32
	// bytes), "" when it holds none.
	Offer     string   `json:"offer"`
	Epoch     uint32   `json:"epoch"`
	Marks     []string `json:"marks"`
	FreeMarks []string `json:"free_marks"`
	// HeldMark/HeldSeq: an action sealed before the hub's step, held until
	// after it (steps 3 and 4).
	HeldMark string `json:"held_mark"`
	HeldSeq  uint64 `json:"held_seq"`
	// GoneMark/GoneSeq: the action whose echo is left in a gone epoch.
	GoneMark string `json:"gone_mark"`
	GoneSeq  uint64 `json:"gone_seq"`
	// PrevKX: the offering phone's keybox of this step carried
	// previous_relay_kx.
	PrevKX bool `json:"prev_kx"`
}

// rotAnswer is the hub's answer: its clock's offset, and the alert push the
// hub sent the offering phone (base64url envelope), when the step made one.
type rotAnswer struct {
	OffsetS int64  `json:"offset_s"`
	Push    string `json:"push,omitempty"`
	// Epoch is the hub's current epoch, when the step names it.
	Epoch uint32 `json:"epoch,omitempty"`
}

func (c *jumpClock) offset() time.Duration { return time.Duration(c.off.Load()) }

// rotStep reads the phone's report name, once written.
func (k kitRun) rotStep(name string) rotReport {
	k.t.Helper()
	var r rotReport
	if err := json.Unmarshal([]byte(k.wait(name, kitStepWait)), &r); err != nil {
		k.fail(name, "not a report: %v", err)
	}
	return r
}

func (k kitRun) rotAnswer(name string, clock *jumpClock, push []byte) {
	k.t.Helper()
	k.rotAnswerAt(name, clock, push, 0)
}

// rotAnswerAt is rotAnswer naming the hub's current epoch.
func (k kitRun) rotAnswerAt(name string, clock *jumpClock, push []byte, epoch uint32) {
	k.t.Helper()
	a := rotAnswer{OffsetS: int64(clock.offset() / time.Second), Epoch: epoch}
	if push != nil {
		a.Push = base64.RawURLEncoding.EncodeToString(push)
	}
	b, err := json.Marshal(a)
	if err != nil {
		k.t.Fatal(err)
	}
	k.write(name, string(b))
}

// pushCapture keeps every send_alert envelope per phone relay id and answers
// it Ok without sending it (the stand has no APNs key: it would settle the
// push push_off). Every other op goes to the stand.
type pushCapture struct {
	base http.RoundTripper
	mu   sync.Mutex
	sent map[string][][]byte
}

func (p *pushCapture) wrap(rt http.RoundTripper) http.RoundTripper {
	p.base = rt
	return p
}

func (p *pushCapture) RoundTrip(r *http.Request) (*http.Response, error) {
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
	p.mu.Lock()
	if p.sent == nil {
		p.sent = map[string][][]byte{}
	}
	sa := req.GetSendAlert()
	p.sent[sa.GetPhoneDeviceId()] = append(p.sent[sa.GetPhoneDeviceId()], bytes.Clone(sa.GetEnvelope()))
	p.mu.Unlock()
	out, err := proto.Marshal(&relayv1.Response{Id: req.GetId(), Result: &relayv1.Response_Ok{Ok: &relayv1.Ok{}}})
	if err != nil {
		return nil, err
	}
	return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": {"application/x-protobuf"}},
		Body: io.NopCloser(bytes.NewReader(out)), ContentLength: int64(len(out)), Request: r}, nil
}

// last is the newest push sent to phone, nil when none.
func (p *pushCapture) last(phone string) []byte {
	p.mu.Lock()
	defer p.mu.Unlock()
	s := p.sent[phone]
	if len(s) == 0 {
		return nil
	}
	return bytes.Clone(s[len(s)-1])
}

// kitRotWorld is the hub's half of the rotation run.
type kitRotWorld struct {
	t      *testing.T
	k      kitRun
	h      *interopHub
	st     *state.Store
	kr     *identity.Keyring
	clock  *jumpClock
	cycle  chan struct{}
	marks  *kitMarks
	alerts *pushSource
	pushes *pushCapture
	logs   *logTap
}

func (w *kitRotWorld) device(id string) state.Device {
	w.t.Helper()
	d, ok, err := w.st.Device(id)
	if err != nil || !ok {
		w.k.fail("device", "the phone is not a linked device: %v", err)
	}
	return d
}

func (w *kitRotWorld) current() uint32 {
	w.t.Helper()
	e, err := w.kr.CurrentEpoch()
	if err != nil {
		w.t.Fatal(err)
	}
	return e
}

// rotate moves the hub's clock one rotation on and ticks its daemon cycle
// until the epoch after the current one begins.
func (w *kitRotWorld) rotate(check string) uint32 {
	w.t.Helper()
	want := w.current() + 1
	w.clock.jump(rotationJump)
	if !within(time.Minute, func() bool {
		select {
		case w.cycle <- struct{}{}:
		default:
		}
		return w.current() == want
	}) {
		w.k.fail(check, "no rotation to epoch %d", want)
	}
	return want
}

// relayKX is device's relay-key row of epoch: its device_pub, ok false when
// the epoch is static for the phone.
func (w *kitRotWorld) relayKX(epoch uint32, device string) ([]byte, bool) {
	w.t.Helper()
	row, ok, err := w.st.EpochRelayKeys(epoch, device)
	if err != nil {
		w.t.Fatal(err)
	}
	return row.DevicePub, ok
}

// prevKX: the offering phone's keybox for epoch carried previous_relay_kx
// exactly when the hub still holds the phone's row of the epoch before.
func (w *kitRotWorld) prevKX(check string, rep rotReport, epoch uint32, device string) {
	w.t.Helper()
	if _, held := w.relayKX(epoch-1, device); held != rep.PrevKX {
		w.k.fail(check, "the hub holds the row of epoch %d: %v; the keybox of %d carried previous_relay_kx: %v", epoch-1, held, epoch, rep.PrevKX)
	}
}

// offerOf decodes a report's offer.
func (w *kitRotWorld) offerOf(check, offer string) []byte {
	w.t.Helper()
	b, err := base64.RawURLEncoding.DecodeString(offer)
	if err != nil || len(b) != 32 {
		w.k.fail(check, "the report's offer is not 32 bytes of base64url (%v)", err)
	}
	return b
}

// ackedWithOffer waits until device acked epoch carrying offer (nil: no offer).
func (w *kitRotWorld) ackedWithOffer(check, device string, epoch uint32, offer []byte) {
	w.t.Helper()
	if !within(time.Minute, func() bool {
		d := w.device(device)
		if d.AckedEpoch != epoch {
			return false
		}
		if offer == nil {
			return d.KXOffer == nil
		}
		return bytes.Equal(d.KXOffer, offer) && d.KXOfferEpoch == epoch
	}) {
		d := w.device(device)
		w.k.fail(check, "acked %d with an offer of epoch %d (offer held: %v), want %d", d.AckedEpoch, d.KXOfferEpoch, d.KXOffer != nil, epoch)
	}
}

// TestInterop_KitPhoneRotates: relay keys rotate end to end between the Kit
// phones and the Go hub on the stand (relay client Phase 5 Task 11). This
// side checks what only the hub sees: the relay-key rows of each epoch (the
// offering phone's device_pub is its offer, the static phone has none), the
// offers it stored from the acks, every action applied once under its own
// action_seq, the erased epoch, and the alert push it sealed for the away
// phone. The phone side checks the keyboxes (never a static then a keyed one
// for one epoch, previous_relay_kx while the hub holds that row), the
// promotion and the erased private key, the pushes it opens with the alert
// copy alone, and the echoes.
func TestInterop_KitPhoneRotates(t *testing.T) {
	if *kitDir == "" || !*kitDesktop || !*kitRotation {
		t.Skip("needs -kit-dir, -kit-desktop and -kit-rotation: run `make relay-interop-kit-hub RELAY=<relay checkout> RELAY_INTEROP_ROTATION=1`")
	}
	k := kitRun{t: t, dir: *kitDir}
	logs := &logTap{}
	log.SetOutput(logs)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	w := &kitRotWorld{t: t, k: k, clock: &jumpClock{}, cycle: make(chan struct{}, 1), marks: &kitMarks{},
		alerts: &pushSource{}, pushes: &pushCapture{}, logs: logs}
	w.h = startDesktopHub(t, interopOpts{
		passEvery: time.Second, linkEvery: time.Second, clock: w.clock.now, cycle: w.cycle, away: alwaysAway{},
		httpWrap: w.pushes.wrap, register: w.marks.register,
		sources: func(*state.Store) []hubslices.Source { return []hubslices.Source{w.alerts} },
	})
	url, token := serveCloudKitLoop(t, w.h.bridge)
	k.writeCloudKitURL(url, token)

	// Both phones link over iCloud.
	phone := kitLink(t, k, w.h, "pair.url", "pair.sas", "confirmed")
	static := kitLink(t, k, w.h, "free.url", "free.sas", "free.confirmed")
	st, err := state.Open(w.h.dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	w.st = st
	w.kr = testKeyring(t, w.h, st, w.clock.now)
	linkedEpoch := w.current()

	e1 := w.rotStepOnRelay(phone, static, linkedEpoch)
	e2 := w.rotStepEphemeral(phone, static, e1)
	e3 := w.rotStepAway(phone, static, e2)
	w.rotStepLongAway(phone, e3)
	w.rotStepICloudAndBack(phone, static)
	w.rotStepLapse(phone, static)
	k.write("go.ok", "")
}

// Step 1: both phones on the relay. The switch's epoch is static for both
// (no offer yet), the offering phone acks it with next_kx, the static one
// with none.
func (w *kitRotWorld) rotStepOnRelay(phone, static string, linkedEpoch uint32) uint32 {
	rep := w.k.rotStep("r1")
	if !within(time.Minute, func() bool {
		v, _, err := w.st.Meta(switcher.MetaTransport)
		return err == nil && v == string(transport.KindRelay)
	}) {
		w.k.fail("r1_relay", "the hub did not move to the relay")
	}
	e1 := w.current()
	if e1 != linkedEpoch+1 || rep.Epoch != e1 {
		w.k.fail("r1_epoch", "hub epoch %d (linked in %d), the phone's %d", e1, linkedEpoch, rep.Epoch)
	}
	if d := w.device(phone); d.RelayDeviceID != rep.RelayA {
		w.k.fail("r1_relay_id", "the offering phone's relay id is not stored")
	}
	if devs, err := w.st.EpochRelayKeyDevices(e1); err != nil || len(devs) != 0 {
		w.k.fail("r1_static", "the switch's epoch %d holds %d relay-key rows (%v), want a static epoch", e1, len(devs), err)
	}
	w.ackedWithOffer("r1_offer", phone, e1, w.offerOf("r1_offer", rep.Offer))
	w.ackedWithOffer("r1_static_ack", static, e1, nil)
	w.k.rotAnswer("r1.ok", w.clock, nil)
	return e1
}

// Step 2 (and step 6 for the static phone): one rotation. The offering
// phone's row names its offer; the static phone has none; one action of
// each is applied once.
func (w *kitRotWorld) rotStepEphemeral(phone, static string, e1 uint32) uint32 {
	offer := w.offerOf("r2_offer", w.k.rotStep("r1.ready").Offer)
	e2 := w.rotate("r2_rotate")
	if pub, ok := w.relayKX(e2, phone); !ok || !bytes.Equal(pub, offer) {
		w.k.fail("r2_relay_kx", "epoch %d: row %v, device_pub is the offer %v", e2, ok, bytes.Equal(pub, offer))
	}
	if _, ok := w.relayKX(e2, static); ok {
		w.k.fail("r2_static", "the static phone has a relay-key row in epoch %d", e2)
	}
	w.k.rotAnswer("r2.go", w.clock, nil)
	rep := w.k.rotStep("r2")
	if rep.Epoch != e2 {
		w.k.fail("r2_epoch", "the phone is in epoch %d, the hub in %d", rep.Epoch, e2)
	}
	appliedOnce(w.k, w.marks, "r2_applied", append(rep.Marks, rep.FreeMarks...)...)
	w.prevKX("r2_previous_kx", rep, e2, phone)
	w.ackedWithOffer("r2_ack", phone, e2, w.offerOf("r2_ack", rep.Offer))
	w.ackedWithOffer("r2_static_ack", static, e2, nil)
	w.k.rotAnswer("r2.ok", w.clock, nil)
	return e2
}

// Step 3 (and step 6): one rotation with the offering phone away. Its action
// sealed in e2 is accepted after the rotation; the alert raised while it is
// away is pushed sealed in its acked epoch e2, which the hub still holds; the
// keybox of e3 carries previous_relay_kx for e2 (checked on the phone).
func (w *kitRotWorld) rotStepAway(phone, static string, e2 uint32) uint32 {
	rep := w.k.rotStep("r3.ready")
	offer := w.offerOf("r3_offer", rep.Offer)
	relayA := w.device(phone).RelayDeviceID
	e3 := w.rotate("r3_rotate")
	if pub, ok := w.relayKX(e3, phone); !ok || !bytes.Equal(pub, offer) {
		w.k.fail("r3_relay_kx", "epoch %d: row %v, device_pub is the offer %v", e3, ok, bytes.Equal(pub, offer))
	}
	if _, ok := w.relayKX(e2, phone); !ok {
		w.k.fail("r3_previous_row", "the hub no longer holds the phone's row of epoch %d", e2)
	}
	before := w.pushes.last(relayA)
	w.alerts.set(w.t, workAlert("ask-rot"))
	var push []byte
	if !within(time.Minute, func() bool {
		push = w.pushes.last(relayA)
		return push != nil && !bytes.Equal(push, before)
	}) {
		w.k.fail("r3_push", "no alert push to the away phone")
	}
	w.k.rotAnswer("r3.go", w.clock, push)
	rep = w.k.rotStep("r3")
	appliedOnce(w.k, w.marks, "r3_held", rep.HeldMark)
	seqOf(w.k, w.marks, "r3_held_seq", rep.HeldMark, rep.HeldSeq)
	appliedOnce(w.k, w.marks, "r3_static", rep.FreeMarks...)
	w.prevKX("r3_previous_kx", rep, e3, phone)
	if rep.Epoch != e3 {
		w.k.fail("r3_epoch", "the phone is in epoch %d, the hub in %d", rep.Epoch, e3)
	}
	w.ackedWithOffer("r3_ack", phone, e3, w.offerOf("r3_ack", rep.Offer))
	w.ackedWithOffer("r3_static_ack", static, e3, nil)
	w.k.rotAnswer("r3.ok", w.clock, nil)
	return e3
}

// Step 4: three rotations with the offering phone away. Every new epoch's row
// names its one outstanding offer; e3 is erased; the action it held, sealed in
// e3, is answered resend_from, resealed under the same action_seq and applied
// once, and a later one goes through. Then an echo left in an epoch the phone
// no longer holds: dropped, the action resent, answered as a repeat.
func (w *kitRotWorld) rotStepLongAway(phone string, e3 uint32) {
	rep := w.k.rotStep("r4.ready")
	offer := w.offerOf("r4_offer", rep.Offer)
	var e6 uint32
	for range 3 {
		e6 = w.rotate("r4_rotate")
		if pub, ok := w.relayKX(e6, phone); !ok || !bytes.Equal(pub, offer) {
			w.k.fail("r4_relay_kx", "epoch %d: row %v, device_pub is the one offer %v", e6, ok, bytes.Equal(pub, offer))
		}
	}
	if kept, err := w.kr.Retained(); err != nil || slices.Contains(kept, e3) {
		w.k.fail("r4_erased", "epoch %d is still retained after three rotations (%v)", e3, err)
	}
	if _, ok := w.relayKX(e3, phone); ok {
		w.k.fail("r4_erased", "epoch %d's relay-key row is still there", e3)
	}
	mark := w.logs.len()
	w.k.rotAnswer("r4.go", w.clock, nil)

	rep = w.k.rotStep("r4")
	// The held action, sealed in the erased e3, drew resend_from from the hub.
	if !strings.Contains(w.logs.since(mark), "sealed in an epoch the hub no longer holds: resend_from asked") {
		w.k.fail("r4_resend_from", "the hub did not answer the action sealed in erased epoch %d with resend_from", e3)
	}
	appliedOnce(w.k, w.marks, "r4_held", rep.HeldMark)
	seqOf(w.k, w.marks, "r4_held_seq", rep.HeldMark, rep.HeldSeq)
	appliedOnce(w.k, w.marks, "r4_after", rep.Marks...)
	w.prevKX("r4_previous_kx", rep, e6, phone)
	if rep.Epoch != e6 {
		w.k.fail("r4_epoch", "the phone is in epoch %d, the hub in %d", rep.Epoch, e6)
	}
	// The action whose echo the phone leaves unread: applied, echoed in e6.
	appliedOnce(w.k, w.marks, "r4_gone_first", rep.GoneMark)
	w.ackedWithOffer("r4_ack", phone, e6, w.offerOf("r4_ack", rep.Offer))
	e7 := w.rotate("r5_rotate")
	w.k.rotAnswer("r5.go", w.clock, nil)
	rep = w.k.rotStep("r5.ready")
	w.ackedWithOffer("r5_ack", phone, e7, w.offerOf("r5_ack", rep.Offer))
	w.rotate("r6_rotate")
	w.k.rotAnswer("r6.go", w.clock, nil)
	rep = w.k.rotStep("r6")
	// The resent copy is a repeat: the handler still ran once, under its seq.
	appliedOnce(w.k, w.marks, "r6_repeat", rep.GoneMark)
	seqOf(w.k, w.marks, "r6_repeat_seq", rep.GoneMark, rep.GoneSeq)
	w.k.rotAnswer("r6.ok", w.clock, nil)
}

// onTransport waits until the hub's stored transport is kind.
func (w *kitRotWorld) onTransport(check string, kind transport.Kind) {
	w.t.Helper()
	if !within(time.Minute, func() bool {
		v, _, err := w.st.Meta(switcher.MetaTransport)
		return err == nil && v == string(kind)
	}) {
		w.k.fail(check, "the hub is not on %s", kind)
	}
}

// staticEpoch: epoch holds no relay-key row.
func (w *kitRotWorld) staticEpoch(check string, epoch uint32) {
	w.t.Helper()
	if devs, err := w.st.EpochRelayKeyDevices(epoch); err != nil || len(devs) != 0 {
		w.k.fail(check, "epoch %d holds %d relay-key rows (%v), want a static epoch", epoch, len(devs), err)
	}
}

// Step 5: the offering phone asks for iCloud with its offer out. The new
// epoch is static, the hub holds no offer, an action is applied. Past the
// 5-minute rule it asks for the relay again: a static epoch whose ack
// carries a fresh offer, then an ephemeral one at the next rotation.
func (w *kitRotWorld) rotStepICloudAndBack(phone, static string) {
	rep := w.k.rotStep("s5.icloud")
	w.onTransport("s5_icloud", transport.KindCloudKit)
	onICloud := w.current()
	if rep.Epoch != onICloud {
		w.k.fail("s5_icloud_epoch", "the phone is in epoch %d, the hub in %d", rep.Epoch, onICloud)
	}
	w.staticEpoch("s5_icloud_static", onICloud)
	w.ackedWithOffer("s5_icloud_offer_cleared", phone, onICloud, nil)
	w.ackedWithOffer("s5_icloud_static_ack", static, onICloud, nil)
	appliedOnce(w.k, w.marks, "s5_icloud_applied", rep.Marks...)
	// Past the anti-flap on the hub's clock, short of a rotation.
	w.clock.jump(6 * time.Minute)
	w.k.rotAnswer("s5.icloud.ok", w.clock, nil)

	rep = w.k.rotStep("s5.relay")
	w.onTransport("s5_relay", transport.KindRelay)
	back := w.current()
	if back != onICloud+1 || rep.Epoch != back {
		w.k.fail("s5_relay_epoch", "hub epoch %d (iCloud in %d), the phone's %d", back, onICloud, rep.Epoch)
	}
	w.staticEpoch("s5_relay_static", back)
	offer := w.offerOf("s5_relay_offer", rep.Offer)
	w.ackedWithOffer("s5_relay_offer", phone, back, offer)
	w.ackedWithOffer("s5_relay_static_ack", static, back, nil)
	e := w.rotate("s5_rotate")
	if pub, ok := w.relayKX(e, phone); !ok || !bytes.Equal(pub, offer) {
		w.k.fail("s5_relay_kx", "epoch %d: row %v, device_pub is the offer %v", e, ok, bytes.Equal(pub, offer))
	}
	if _, ok := w.relayKX(e, static); ok {
		w.k.fail("s5_static", "the static phone has a relay-key row in epoch %d", e)
	}
	w.k.rotAnswer("s5.go", w.clock, nil)
	rep = w.k.rotStep("s5")
	if rep.Epoch != e {
		w.k.fail("s5_epoch", "the phone is in epoch %d, the hub in %d", rep.Epoch, e)
	}
	appliedOnce(w.k, w.marks, "s5_applied", rep.Marks...)
	w.prevKX("s5_previous_kx", rep, e, phone)
	w.ackedWithOffer("s5_ack", phone, e, w.offerOf("s5_ack", rep.Offer))
	w.k.rotAnswer("s5.ok", w.clock, nil)
}

// Step 8: the offering phone's entitlement expires while the static phone
// still pays. The hub stays on the relay and clears the lapsed phone's
// offer and every relay-key row it held; the static phone goes on rotating.
// 15 moved days later the phone pays again: its request is followed, its ack
// carries a new offer, and the next rotation is ephemeral for it.
func (w *kitRotWorld) rotStepLapse(phone, static string) {
	w.k.rotStep("s8.left")
	w.onTransport("s8_stays", transport.KindRelay)
	if !within(time.Minute, func() bool { return w.device(phone).KXOffer == nil }) {
		w.k.fail("s8_offer_gone", "the lapsed phone's offer is still stored")
	}
	kept, err := w.kr.Retained()
	if err != nil {
		w.t.Fatal(err)
	}
	for _, e := range kept {
		if _, ok := w.relayKX(e, phone); ok {
			w.k.fail("s8_rows_gone", "the lapsed phone still has a relay-key row in epoch %d", e)
		}
	}
	e := w.rotate("s8_rotate")
	if _, ok := w.relayKX(e, phone); ok {
		w.k.fail("s8_lapsed_static", "the lapsed phone has a relay-key row in epoch %d", e)
	}
	w.onTransport("s8_stays_rotated", transport.KindRelay)
	w.k.rotAnswerAt("s8.go", w.clock, nil, e)
	rep := w.k.rotStep("s8")
	appliedOnce(w.k, w.marks, "s8_static_applied", rep.FreeMarks...)
	w.ackedWithOffer("s8_static_ack", static, e, nil)
	// 15 days after the lapse on the hub's clock (8 of them in the rotation).
	w.clock.jump(7 * 24 * time.Hour)
	w.k.rotAnswerAt("s8.ok", w.clock, nil, w.current())

	rep = w.k.rotStep("s8.back")
	w.onTransport("s8_back", transport.KindRelay)
	cur := w.current()
	if rep.Epoch != cur {
		w.k.fail("s8_back_epoch", "the phone is in epoch %d, the hub in %d", rep.Epoch, cur)
	}
	offer := w.offerOf("s8_back_offer", rep.Offer)
	w.ackedWithOffer("s8_back_offer", phone, cur, offer)
	e = w.rotate("s8_rotate_back")
	if pub, ok := w.relayKX(e, phone); !ok || !bytes.Equal(pub, offer) {
		w.k.fail("s8_relay_kx", "epoch %d: row %v, device_pub is the new offer %v", e, ok, bytes.Equal(pub, offer))
	}
	w.k.rotAnswerAt("s8.rot", w.clock, nil, e)
	rep = w.k.rotStep("s8.done")
	appliedOnce(w.k, w.marks, "s8_applied", rep.Marks...)
	w.prevKX("s8_previous_kx", rep, e, phone)
	w.ackedWithOffer("s8_ack", phone, e, w.offerOf("s8_ack", rep.Offer))
	w.k.rotAnswer("s8.done.ok", w.clock, nil)
}

// seqOf: mark was applied under action_seq seq.
func seqOf(k kitRun, m *kitMarks, check, mark string, seq uint64) {
	k.t.Helper()
	for _, c := range m.all() {
		if c.mark == mark && c.seq != seq {
			k.fail(check, "applied under action_seq %d, sealed under %d", c.seq, seq)
		}
	}
}

// ---- the first upgrade from a hub on CloudKit (Phase 5 Task 11, PR C review) ----

var kitUpgrade = flag.Bool("kit-upgrade", false, "the Kit run is the first-upgrade case's (RELAY_INTEROP_UPGRADE=1)")

// TestInterop_KitPhoneUpgradesOnCloudKit: a phone linked over iCloud upgrades
// a Go hub that runs on CloudKit to the relay the way the app's upgrader
// does (RelayUpgrade.readerConfirmed after the PR C fix): after vouch and
// add_slot, the first read of data/<mac> confirms it a reader whether or not
// a keybox of it is there (this hub, on CloudKit, writes none); a keybox with
// keys would be merged first. Then it asks for the relay and follows. The
// handoff, beyond kitLink's pair.*
// files and ck.url: the phone writes upgraded (its relay device id) once it
// follows the move; the hub answers go.ok or go.fail.
func TestInterop_KitPhoneUpgradesOnCloudKit(t *testing.T) {
	if *kitDir == "" || !*kitDesktop || !*kitUpgrade {
		t.Skip("needs -kit-dir, -kit-desktop and -kit-upgrade: run `make relay-interop-kit-hub RELAY=<relay checkout> RELAY_INTEROP_UPGRADE=1`")
	}
	k := kitRun{t: t, dir: *kitDir}
	logs := &logTap{}
	log.SetOutput(logs)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	h := startDesktopHub(t, interopOpts{passEvery: time.Second, linkEvery: time.Second, away: alwaysAway{}})
	url, token := serveCloudKitLoop(t, h.bridge)
	k.writeCloudKitURL(url, token)
	phone := kitLink(t, k, h, "pair.url", "pair.sas", "confirmed")
	st, err := state.Open(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if v, _, err := st.Meta(switcher.MetaTransport); err != nil || v == string(transport.KindRelay) {
		k.fail("upgrade_start", "the hub is not on CloudKit before the upgrade (%q, %v)", v, err)
	}
	relayID := strings.TrimSpace(k.wait("upgraded", kitStepWait))
	if !within(time.Minute, func() bool {
		v, _, err := st.Meta(switcher.MetaTransport)
		return err == nil && v == string(transport.KindRelay)
	}) {
		k.fail("upgrade_relay", "the hub did not move to the relay")
	}
	if d, ok, err := st.Device(phone); err != nil || !ok || d.RelayDeviceID != relayID {
		k.fail("upgrade_relay_id", "the phone's relay id is not stored (%v)", err)
	}
	k.write("go.ok", "")
}
