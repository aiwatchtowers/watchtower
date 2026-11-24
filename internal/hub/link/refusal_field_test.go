package link

import (
	"crypto/ed25519"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

// publishedKeybox is p's keybox as the CloudKit data zone carries it: the
// row Keyboxes returns, sealed by the publisher's call (KeyboxTo with the
// recipient read with the row, wire.Keybox.To), then opened with p's own
// agreement key and the hub's signature checked, as the phone's replica and
// its direct read do. The test fails when no keybox is published for p or
// p cannot open it.
func (r *ckRig) publishedKeybox(p phone) wire.Keybox {
	r.t.Helper()
	boxes, err := r.c.Keyboxes()
	if err != nil {
		r.t.Fatalf("Keyboxes: %v", err)
	}
	for _, kb := range boxes {
		if !strings.EqualFold(kb.Grant.DeviceID, p.id.String()) {
			continue
		}
		payload, err := wire.Marshal(kb)
		if err != nil {
			r.t.Fatal(err)
		}
		rec, err := secure.NewSealer(r.kr).KeyboxTo("data", p.id, payload, kb.To)
		if err != nil {
			r.t.Fatalf("the publisher cannot seal the keybox: %v", err)
		}
		hub := r.kr.HubID()
		_, f, err := secure.OpenHPKE(rec.Envelope(), secure.ClassKeybox, p.kx, secure.KeyboxInfo(hub, p.id),
			secure.Context{Zone: secure.ZoneData, WireName: rec.WireName()}, r.kr.Signer().Public().(ed25519.PublicKey))
		if err != nil {
			r.t.Fatalf("the phone cannot open its published keybox: %v", err)
		}
		var out wire.Keybox
		if err := json.Unmarshal(f.Payload, &out); err != nil {
			r.t.Fatal(err)
		}
		return out
	}
	r.t.Fatalf("no keybox published for %s", p.id)
	return wire.Keybox{}
}

// #2190: the field timeline on a CloudKit hub, the owner's own iPhone (the
// private scope). QR 1's sheet closes after 66 s, QR 2 is shown, and the
// phone's hello under QR 1 lands 2 min 54 s after QR 1; later QR 3 is shown
// and closed, and the phone rescans and sends its hello under QR 3. Each hello
// gets a refusal keybox that the phone can open, names the code's hub as the
// phone compares it (grant.hub_id == the code's hub_id), and differs from the
// keybox the phone held before that hello (its scan's baseline), so the
// phone's wait reads it as this scan's answer. The Mac side of the report:
// what it published is what the phone needs; nothing of it was missing.
func TestTheFieldTimelinesRefusalsReachThePhone(t *testing.T) {
	r := newCKRig(t)
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

	got, err := r.ckHello(p, qr1.Nonce)
	if err != nil {
		t.Fatalf("late hello under QR 1: %v", err)
	}
	if got.Refused != wire.RefusedExpiredCode || got.Unanswered {
		t.Fatalf("late hello under QR 1: %+v, want an answered %s", got, wire.RefusedExpiredCode)
	}
	first := r.publishedKeybox(p)
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
	if baseline := r.publishedKeybox(p); !reflect.DeepEqual(baseline.Grant, first.Grant) {
		t.Fatalf("the rescan's baseline %+v, want the first refusal", baseline.Grant)
	}
	got, err = r.ckHello(p, qr3.Nonce)
	if err != nil {
		t.Fatalf("hello under the closed QR 3: %v", err)
	}
	if got.Refused != wire.RefusedNotConfirmed || got.Unanswered {
		t.Fatalf("hello under the closed QR 3: %+v, want an answered %s", got, wire.RefusedNotConfirmed)
	}
	second := r.publishedKeybox(p)
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
