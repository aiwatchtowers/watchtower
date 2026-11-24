package link

import (
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/wire"
)

// grantPublishes records each KindDeviceGrant publish the center makes, with
// the device_grant slice as the publisher reads it then (Keyboxes, from the
// Publish callback, as slices.Publisher does). A refusal saved but never
// published (no Center.changed) shows in no event.
type grantPublishes struct {
	mu     sync.Mutex
	events [][]wire.Keybox
}

// captureGrantPublishes rebuilds r's center with a Publish callback that
// records every device_grant publish.
func captureGrantPublishes(r *ckRig) *grantPublishes {
	r.t.Helper()
	g := &grantPublishes{}
	c := r.ckCenter(DefaultSweep)
	c.publish = func(kinds ...string) {
		for _, k := range kinds {
			if k != KindDeviceGrant {
				continue
			}
			boxes, err := c.Keyboxes()
			if err != nil {
				r.t.Errorf("Keyboxes in the publish callback: %v", err)
				return
			}
			g.mu.Lock()
			g.events = append(g.events, boxes)
			g.mu.Unlock()
		}
	}
	r.c = c
	return g
}

func (g *grantPublishes) count() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.events)
}

// publishedSince is p's keybox in the newest device_grant publish after the
// first `before` ones, sealed to the recipient read with it (wire.Keybox.To,
// which must be p's own agreement key) and opened with p's key. The test
// fails when nothing was published since, or the publish carries no keybox
// for p.
func (g *grantPublishes) publishedSince(r *ckRig, before int, p phone) wire.Keybox {
	r.t.Helper()
	g.mu.Lock()
	events := g.events[before:]
	g.mu.Unlock()
	if len(events) == 0 {
		r.t.Fatal("no device_grant publish since the hello")
	}
	for _, kb := range events[len(events)-1] {
		if !strings.EqualFold(kb.Grant.DeviceID, p.id.String()) {
			continue
		}
		if kb.To == nil || !kb.To.Equal(p.kx.PublicKey()) {
			r.t.Fatalf("the keybox is sealed to %v, not to the phone's agreement key", kb.To)
		}
		return r.openAsPhone(p, kb, kb.To)
	}
	r.t.Fatalf("the device_grant publish carries no keybox for %s", p.id)
	return wire.Keybox{}
}

// #2190: the field timeline on a CloudKit hub, the owner's own iPhone (the
// private scope). QR 1's sheet closes after 66 s, QR 2 is shown, and the
// phone's hello under QR 1 lands 2 min 54 s after QR 1; later QR 3 is shown
// and closed, and the phone rescans and sends its hello under QR 3. Each hello
// is answered by a device_grant publish whose keybox for the phone is sealed
// to the phone's agreement key, opens with it, names the code's hub as the
// phone compares it (grant.hub_id == the code's hub_id), and differs from the
// keybox the phone held before that hello (its scan's baseline), so the
// phone's wait reads it as this scan's answer. The Mac side of the report:
// what it published is what the phone needed.
func TestTheFieldTimelinesRefusalsReachThePhone(t *testing.T) {
	r := newCKRig(t)
	published := captureGrantPublishes(r)
	p := newPhone(t)
	start := r.clock()
	if _, ok := r.keybox(p); ok {
		t.Fatal("a keybox before any hello")
	}

	qr1 := r.issueCK()
	r.advance(66 * time.Second)
	if err := r.c.CloseCode(r.ctx, r.s, qr1.Nonce, CloseSheetClosed); err != nil {
		t.Fatal(err)
	}
	r.advance(30 * time.Second)
	r.issueCK() // QR 2: a new code retires every open one, so a hello under QR 1 reads expired_code
	r.advance(start.Add(174 * time.Second).Sub(r.clock()))

	before := published.count()
	got, err := r.ckHello(p, qr1.Nonce)
	if err != nil {
		t.Fatalf("late hello under QR 1: %v", err)
	}
	if got.Refused != wire.RefusedExpiredCode || got.Unanswered {
		t.Fatalf("late hello under QR 1: %+v, want an answered %s", got, wire.RefusedExpiredCode)
	}
	first := published.publishedSince(r, before, p)
	assertRefusalFor(t, first, qr1, wire.RefusedExpiredCode, r.clock())

	// QR 3, shown 9 min 56 s after QR 1 and closed before the phone's rescan lands.
	r.advance(start.Add(596 * time.Second).Sub(r.clock()))
	qr3 := r.issueCK()
	r.advance(60 * time.Second)
	if err := r.c.CloseCode(r.ctx, r.s, qr3.Nonce, CloseSheetClosed); err != nil {
		t.Fatal(err)
	}
	r.advance(52 * time.Second)

	// The rescan's baseline is the first refusal (still published); the answer must differ from it.
	if baseline, ok := r.keybox(p); !ok || !reflect.DeepEqual(baseline.Grant, first.Grant) {
		t.Fatalf("the rescan's baseline %+v, want the first refusal", baseline.Grant)
	}
	before = published.count()
	got, err = r.ckHello(p, qr3.Nonce)
	if err != nil {
		t.Fatalf("hello under the closed QR 3: %v", err)
	}
	if got.Refused != wire.RefusedNotConfirmed || got.Unanswered {
		t.Fatalf("hello under the closed QR 3: %+v, want an answered %s", got, wire.RefusedNotConfirmed)
	}
	second := published.publishedSince(r, before, p)
	assertRefusalFor(t, second, qr3, wire.RefusedNotConfirmed, r.clock())
	if reflect.DeepEqual(second.Grant, first.Grant) {
		t.Fatal("the rescan's refusal equals its baseline: the phone could not tell it from the earlier one")
	}
}

// assertRefusalFor checks a refusal keybox as the phone's wait reads it.
func assertRefusalFor(t *testing.T, kb wire.Keybox, code wire.LinkPayload, reason string, decided time.Time) {
	t.Helper()
	if refusal(kb) != reason || kb.Keys != nil {
		t.Errorf("keybox refusal %q keys %v, want %q without keys", refusal(kb), kb.Keys != nil, reason)
	}
	if kb.Grant.HubID != code.HubID {
		t.Errorf("grant hub %q, the code's %q: the phone would skip it", kb.Grant.HubID, code.HubID)
	}
	if kb.Grant.Linked || kb.Grant.AwaitingConfirmation != nil {
		t.Errorf("a refusal reads linked %v, awaiting %v", kb.Grant.Linked, kb.Grant.AwaitingConfirmation)
	}
	if kb.Grant.DecidedAt == nil || !kb.Grant.DecidedAt.Equal(decided) {
		t.Errorf("decided_at %v, want %v", kb.Grant.DecidedAt, decided)
	}
}
