package switcher_test

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"database/sql"
	"encoding/base64"
	"maps"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Losing and regaining reader status (relay client Phase 5, Task 13): a phone
// gone from its slot while the Mac stays (checkDeparted, ReaderLost), and the
// outcomes table of the plan's section of that name.

// slotted is the world's Config.Slotted: the relay ids of the linked phones
// the account holds in a slot (all but the gone ones), and a paying phone no
// linked device names when unmatched.
func (w *world) slotted(ctx context.Context) ([]string, error) {
	w.mu.Lock()
	w.slotReads++
	hang, err, notFresh, unmatched, empty := w.payHang, w.payErr, w.notFresh, w.unmatched, w.emptyList
	gone := maps.Clone(w.gone)
	w.mu.Unlock()
	if hang {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if notFresh {
		return nil, switcher.ErrNotFresh
	}
	if err != nil {
		return nil, err
	}
	if empty {
		return nil, nil
	}
	devices, err := w.st.Devices()
	if err != nil {
		return nil, err
	}
	var out []string
	for _, d := range devices {
		if d.RelayDeviceID != "" && !gone[strings.ToUpper(d.ID)] {
			out = append(out, d.RelayDeviceID)
		}
	}
	if unmatched {
		out = append(out, "unlinked-phone")
	}
	return out, nil
}

// leave takes ph out of the account's slots (its subscription moved, its
// slot removed); back puts it in again.
func (w *world) leave(ph *hubtest.Phone) { w.setGone(ph, true) }
func (w *world) back(ph *hubtest.Phone)  { w.setGone(ph, false) }

func (w *world) setGone(ph *hubtest.Phone, gone bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.gone == nil {
		w.gone = map[string]bool{}
	}
	w.gone[strings.ToUpper(ph.ID().String())] = gone
}

func (w *world) setPaying(ph *hubtest.Phone, pays bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.paying[ph.ID().String()] = pays
}

// ephemeral gives ph (on the relay, the hub on the relay) an offer stored by
// the hub, an epoch derived from it and that epoch's pair, then a new offer
// outstanding: it has ephemeral state on both sides.
func (w *world) ephemeral(ph *hubtest.Phone) {
	w.t.Helper()
	w.offer(ph)
	if err := w.keys.Rotate(identity.ReasonManual); err != nil {
		w.t.Fatal(err)
	}
	w.takeKeys(ph)
	if !ph.HoldsPair(w.epoch()) {
		w.t.Fatalf("the phone holds no pair for epoch %d", w.epoch())
	}
	w.offer(ph)
	if offer, rows := w.kx(ph); !offer || rows == 0 {
		w.t.Fatalf("no ephemeral state on the hub: offer %v, %d rows", offer, rows)
	}
}

// offer is ph's epoch_ack with its offer, read by the hub.
func (w *world) offer(ph *hubtest.Phone) {
	w.t.Helper()
	if _, err := ph.AckEpoch(w.epoch()); err != nil {
		w.t.Fatal(err)
	}
	w.hub()
}

// kx is ph's offer (stored or not) and its relay-key rows on the hub.
func (w *world) kx(ph *hubtest.Phone) (offer bool, rows int) {
	w.t.Helper()
	d, _, err := w.st.Device(ph.ID().String())
	if err != nil {
		w.t.Fatal(err)
	}
	if err := w.st.ReadTx(w.ctx, func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT COUNT(*) FROM epoch_relay_keys WHERE device_id = ? COLLATE NOCASE`, ph.ID().String()).Scan(&rows)
	}); err != nil {
		w.t.Fatal(err)
	}
	return d.KXOffer != nil, rows
}

func (w *world) wantCleared(ph *hubtest.Phone) {
	w.t.Helper()
	if offer, rows := w.kx(ph); offer || rows != 0 {
		w.t.Fatalf("the phone's relay keys are not cleared: offer %v, %d rows", offer, rows)
	}
	w.wantStatic(ph)
}

func (w *world) wantHeld(ph *hubtest.Phone) {
	w.t.Helper()
	if offer, rows := w.kx(ph); !offer || rows == 0 {
		w.t.Fatalf("the phone's relay keys are gone: offer %v, %d rows", offer, rows)
	}
}

// wantStatic: every relay key the hub has for ph, in every retained epoch and
// both directions, is the static wt/relay/v1/ key, and its keybox goes to
// dev_kx.
func (w *world) wantStatic(ph *hubtest.Phone) {
	w.t.Helper()
	d := ph.Device()
	peer, err := ecdh.X25519().NewPublicKey(d.AgreementKey)
	if err != nil {
		w.t.Fatal(err)
	}
	nonce, err := base64.RawURLEncoding.DecodeString(d.LinkNonce)
	if err != nil {
		w.t.Fatal(err)
	}
	epochs, err := w.keys.Retained()
	if err != nil {
		w.t.Fatal(err)
	}
	for _, e := range epochs {
		for _, dir := range []secure.Direction{secure.PhoneToHub, secure.HubToPhone} {
			got, err := w.keys.RelayKey(dir, ph.ID(), e)
			if err != nil {
				w.t.Fatal(err)
			}
			want, err := secure.RelayKey(w.ident.Agreement, peer, nonce, w.keys.HubID(), ph.ID(), e, dir)
			if err != nil {
				w.t.Fatal(err)
			}
			if !bytes.Equal(got, want) {
				w.t.Fatalf("epoch %d %s: the relay key is not static", e, dir)
			}
		}
	}
	pub, err := w.keys.KeyboxRecipient(ph.ID())
	if err != nil {
		w.t.Fatal(err)
	}
	if !bytes.Equal(pub.Bytes(), d.AgreementKey) {
		w.t.Fatal("the keybox is not sealed to dev_kx")
	}
}

// relayPair is a world on the relay with two paying phones there; a has
// ephemeral state. Their links are older than NoPayerPoll.
func relayPair(t *testing.T) (w *world, a, b *hubtest.Phone) {
	t.Helper()
	w = newWorld(t, "memfake")
	a, b = w.addPhone(true), w.addPhone(true)
	w.route(a, true)
	w.route(b, true)
	w.moveTo(a, wire.TransportRelay, b)
	w.ephemeral(a)
	return w, a, b
}

func TestReaderLostAfterTwoReadsClearsKeys(t *testing.T) {
	w, a, b := relayPair(t)
	e := w.epoch()
	w.leave(a)
	w.pollAfterInterval()
	w.wantHeld(a)
	if w.lapsedNow(a) {
		t.Fatal("one read marked the phone lapsed")
	}
	w.pollAfterInterval()
	w.wantCleared(a)
	if !w.lapsedNow(a) || w.lapsedNow(b) {
		t.Fatalf("lapsed: a %v, b %v; want a only", w.lapsedNow(a), w.lapsedNow(b))
	}
	w.wantActive(transport.KindRelay)
	if w.epoch() != e {
		t.Fatalf("epoch %d → %d: a lost reader rotates nothing", e, w.epoch())
	}
	w.onCloudKit(a)
	w.settle(a, b)
	if n := count(a, wire.ControlHubOnRelay); n != 1 {
		t.Fatalf("%d hub_on_relay, want 1", n)
	}
}

// F27: a false absence from one read changes nothing.
func TestOneMissingReadChangesNothing(t *testing.T) {
	w, a, _ := relayPair(t)
	w.leave(a)
	w.pollAfterInterval()
	w.back(a)
	w.pollAfterInterval()
	w.leave(a)
	w.pollAfterInterval() // a new run: one read again
	w.wantHeld(a)
	if w.lapsedNow(a) {
		t.Fatal("the phone is marked lapsed")
	}
}

// A read not made afresh (ErrNotFresh) is no read: it neither counts nor
// resets, and the next answered read decides.
func TestAnUnansweredReadCountsAsNothing(t *testing.T) {
	w, a, _ := relayPair(t)
	w.leave(a)
	w.pollAfterInterval()
	w.mu.Lock()
	w.notFresh = true
	w.mu.Unlock()
	for range 3 {
		w.pollAfterInterval()
	}
	w.wantHeld(a)
	w.mu.Lock()
	w.notFresh = false
	w.mu.Unlock()
	w.advance(switcher.OtherPoll) // a not-fresh read is retried at the next poll
	w.sw.PollOther(w.ctx)
	w.wantCleared(a)
}

func TestReaderLostIgnoresAPhoneWithNoEphemeralState(t *testing.T) {
	w, a, b := relayPair(t)
	w.leave(b) // b never offered: it has no ephemeral state here
	w.pollAfterInterval()
	w.pollAfterInterval()
	if w.lapsedNow(b) {
		t.Fatal("a departed phone with no ephemeral state was marked lapsed")
	}
	if err := w.sw.ReaderLost(b.ID().String()); err != nil {
		t.Fatal(err)
	}
	if w.lapsedNow(b) {
		t.Fatal("ReaderLost marked a phone with no ephemeral state")
	}
	w.wantHeld(a)
}

func TestReaderLostNeverMovesTheMac(t *testing.T) {
	w, a, b := relayPair(t)
	w.setPaying(a, false)
	w.setPaying(b, false) // nobody pays: rule 16 would move it, ReaderLost must not
	e := w.epoch()
	if err := w.sw.ReaderLost(a.ID().String()); err != nil {
		t.Fatal(err)
	}
	if err := w.sw.Step(w.ctx); err != nil {
		t.Fatal(err)
	}
	w.wantActive(transport.KindRelay)
	if w.sw.Pending() || w.epoch() != e {
		t.Fatalf("pending %v, epoch %d → %d", w.sw.Pending(), e, w.epoch())
	}
	w.wantCleared(a)
}

// A phone with no iCloud route (a host with no CloudKit) is marked lapsed all
// the same: none of its relay actions written before is applied.
func TestReaderLostMarksARouteLessPhoneLapsed(t *testing.T) {
	w := newWorld(t, "memfake")
	a, b := w.addPhone(true), w.addPhone(true)
	w.rebuild(func(c *switcher.Config) { c.CloudKit = nil })
	w.wantActive(transport.KindRelay)
	w.onRelay(a)
	w.onRelay(b)
	w.ephemeral(a)
	w.leave(a)
	w.pollAfterInterval()
	w.pollAfterInterval()
	if !w.lapsedNow(a) {
		t.Fatal("the route-less phone is not marked lapsed")
	}
	w.wantCleared(a)
	x := w.act(a)
	w.relay.RefuseWrites(relayZone(a), nil)
	w.settle(b)
	if slices.Contains(w.callLog(), call(a, x)) {
		t.Fatal("an action of the departed phone applied")
	}
}

// The account's only paying phone is not linked to this Mac (ask #1070): the
// Mac stays, and a linked phone absent from the list departs.
func TestDepartedUnlinkedPayerMacStaysKeysCleared(t *testing.T) {
	w := newWorld(t, "memfake")
	a := w.addPhone(true)
	w.route(a, true)
	w.moveTo(a, wire.TransportRelay)
	w.ephemeral(a)
	w.mu.Lock()
	w.unmatched = true
	w.mu.Unlock()
	w.setPaying(a, false)
	w.leave(a)
	w.pollAfterInterval()
	w.pollAfterInterval()
	w.wantActive(transport.KindRelay)
	w.wantCleared(a)
}

// Nobody pays, the list is not empty, a linked phone has no route: G2 keeps
// the Mac (ask #1072), no rotation, and the phone absent from the list
// departs.
func TestDepartedPhoneNoRouteMacStaysKeysCleared(t *testing.T) {
	w, a, b := relayPair(t)
	w.route(b, false)
	w.setPaying(a, false)
	w.setPaying(b, false)
	w.leave(a)
	e := w.epoch()
	for range 4 {
		w.pollAfterInterval()
	}
	w.wantActive(transport.KindRelay)
	if w.epoch() != e {
		t.Fatalf("epoch %d → %d", e, w.epoch())
	}
	w.wantCleared(a)
	if w.lapsedNow(b) {
		t.Fatal("the listed phone was marked lapsed")
	}
}

// F37: a departed phone returns to the list paying: its lapse ends at the
// next poll, its next ack's offer is stored, and the next epoch is ephemeral
// for it again.
func TestDepartedRelayOnlyPhoneReturnsAndOffersAgain(t *testing.T) {
	w, a, _ := relayPair(t)
	w.leave(a)
	w.pollAfterInterval()
	w.pollAfterInterval()
	w.wantCleared(a)
	w.back(a)
	w.relay.RefuseWrites(relayZone(a), nil)
	w.sw.PollOther(w.ctx) // recheckLapsed: listed paying
	if w.lapsedNow(a) {
		t.Fatal("still lapsed after its return")
	}
	w.takeKeys(a) // its static keybox drops the pair the hub no longer has
	w.offer(a)
	if offer, _ := w.kx(a); !offer {
		t.Fatal("the returned phone's offer was refused")
	}
	if err := w.keys.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	w.takeKeys(a)
	if !a.HoldsPair(w.epoch()) {
		t.Fatal("the epoch after the return is not ephemeral for the phone")
	}
}

// The list answers empty (it cannot be told from a revoked account): nobody
// departs, the keys are held, and a phone back before day 14 opens the
// keybox sealed to its offer.
func TestReturnAfterAnEmptyListOpensTheKeybox(t *testing.T) {
	w, a, b := relayPair(t)
	w.route(b, false)
	w.mu.Lock()
	w.emptyList = true
	w.mu.Unlock()
	for range 6 {
		w.pollAfterInterval()
	}
	w.wantActive(transport.KindRelay)
	w.wantHeld(a)
	if w.lapsedNow(a) {
		t.Fatal("an empty list marked the phone lapsed")
	}
	w.mu.Lock()
	w.emptyList = false
	w.mu.Unlock()
	w.pollAfterInterval()
	kk, err := w.keys.KeyboxKeysFor(a.ID())
	if err != nil {
		t.Fatal(err)
	}
	if kk.RelayKX == nil {
		t.Fatal("the keybox names no relay_kx after the return")
	}
	pub, err := w.keys.KeyboxRecipient(a.ID())
	if err != nil || !bytes.Equal(pub.Bytes(), a.Offered()) {
		t.Fatalf("the keybox is not sealed to the phone's offer (%v)", err)
	}
	if err := a.Keep(kk); err != nil {
		t.Fatalf("the phone cannot take its keybox: %v", err)
	}
}

func TestEmptyListNoRouteMacStaysKeysHeld(t *testing.T) {
	w, a, b := relayPair(t)
	w.route(b, false)
	w.setPaying(a, false)
	w.setPaying(b, false)
	w.mu.Lock()
	w.emptyList = true
	w.mu.Unlock()
	e := w.epoch()
	for range 10 {
		w.pollAfterInterval()
	}
	w.wantActive(transport.KindRelay)
	if w.epoch() != e {
		t.Fatalf("epoch %d → %d", e, w.epoch())
	}
	w.wantHeld(a)
}

// F42: nobody pays, the list is not empty and a phone has no route: G2 holds,
// until a hub write into a slotted phone's mailbox is refused
// ENTITLEMENT_INACTIVE (rule 16, ask #1087), which moves the Mac; the
// rotation clears every offer.
func TestFirstRefusedWriteEndsG2sHold(t *testing.T) {
	w, a, b := relayPair(t)
	w.route(b, false)
	w.setPaying(a, false)
	w.setPaying(b, false)
	for range 3 {
		w.pollAfterInterval()
	}
	w.wantActive(transport.KindRelay)
	w.sw.EntitlementInactive(transport.KindRelay, b.ID().String())
	w.settle()
	w.wantActive(transport.KindCloudKit)
	for _, ph := range []*hubtest.Phone{a, b} {
		if offer, _ := w.kx(ph); offer {
			t.Fatal("an offer outlived the move to iCloud")
		}
	}
}

// F45: an empty list and a write refused FORBIDDEN (no slot) move nothing.
func TestEmptyListForbiddenWriteMovesNothing(t *testing.T) {
	w, a, b := relayPair(t)
	w.route(b, false)
	w.mu.Lock()
	w.emptyList = true
	w.mu.Unlock()
	x := w.act(a)
	w.relay.RefuseWrites(relayZone(a), transport.ErrForbidden)
	e := w.epoch()
	for range 3 {
		w.pollAfterInterval()
		w.hub()
	}
	w.wantActive(transport.KindRelay)
	if w.epoch() != e || w.lapsedNow(a) {
		t.Fatalf("epoch %d → %d, lapsed %v", e, w.epoch(), w.lapsedNow(a))
	}
	w.wantHeld(a)
	w.appliedOnce(a, x)
}

// Nobody pays and every phone has a route: G2 goes first in the poll and
// moves the hub; the departure check skips that poll.
func TestAllRoutesNobodyPaysG2MovesDepartedSkips(t *testing.T) {
	w, a, b := relayPair(t)
	w.setPaying(a, false)
	w.setPaying(b, false)
	w.leave(a)
	w.advance(switcher.NoPayerPoll)
	w.sw.PollOther(w.ctx) // G2 count 1, departure count 1
	w.advance(switcher.NoPayerPoll)
	w.sw.PollOther(w.ctx) // G2 moves; the departure check skips
	if !w.sw.Pending() {
		t.Fatal("G2 did not move the hub")
	}
	if w.lapsedNow(a) {
		t.Fatal("the departure check ran in the poll G2 moved the hub")
	}
	w.settle(a, b)
	w.wantActive(transport.KindCloudKit)
	if offer, _ := w.kx(a); offer {
		t.Fatal("the rotation toward iCloud left an offer")
	}
}

// F34: an unknown read moves and clears nothing, and the count holds.
func TestUnknownReadMovesAndClearsNothing(t *testing.T) {
	w, a, _ := relayPair(t)
	w.leave(a)
	w.pollAfterInterval()
	w.mu.Lock()
	w.payErr = errBoom
	w.mu.Unlock()
	w.pollAfterInterval()
	w.wantHeld(a)
	w.wantActive(transport.KindRelay)
	w.mu.Lock()
	w.payErr = nil
	w.mu.Unlock()
	w.pollAfterInterval() // the second answered miss, more than 5 minutes after the first
	w.wantCleared(a)
}

// F35: the count is in memory: a restart between the two reads starts it
// again, which only delays.
func TestRestartRestartsTheDepartureCount(t *testing.T) {
	w, a, _ := relayPair(t)
	w.leave(a)
	w.pollAfterInterval()
	w.rebuild(nil)
	w.pollAfterInterval()
	w.wantHeld(a)
	w.pollAfterInterval()
	w.wantCleared(a)
}

// G2's move clears every offer in its rotation.
func TestNoPayerMoveClearsOffers(t *testing.T) {
	w, a, b := relayPair(t)
	w.offer(b)
	w.setPaying(a, false)
	w.setPaying(b, false)
	w.pollAfterInterval()
	w.pollAfterInterval()
	w.settle(a, b)
	w.wantActive(transport.KindCloudKit)
	for _, ph := range []*hubtest.Phone{a, b} {
		if offer, _ := w.kx(ph); offer {
			t.Fatal("an offer outlived G2's move")
		}
	}
}

// An action the departed phone wrote under its pair, read after the hub
// cleared its rows, is never applied.
func TestDepartedPhoneActionNotAppliedOnceRowsAreCleared(t *testing.T) {
	w, a, b := relayPair(t)
	x := w.act(a) // sealed in the phone's ephemeral epoch, not yet read
	if err := w.sw.ReaderLost(a.ID().String()); err != nil {
		t.Fatal(err)
	}
	w.settle(b)
	if slices.Contains(w.callLog(), call(a, x)) {
		t.Fatal("the departed phone's action applied")
	}
}

// F39b: a withdrawn action (the phone deleted its own record before the hub
// read it) is never applied, before or after the phone's return.
func TestAWithdrawnActionIsNeverApplied(t *testing.T) {
	w, a, b := relayPair(t)
	x := w.act(a)
	name, _ := a.Sealed(x)
	if _, err := w.relay.Delete(w.ctx, relayZone(a), []transport.DeleteItem{{Name: name}}); err != nil {
		t.Fatal(err)
	}
	a.Forget(x)
	w.settle(a, b)
	if slices.Contains(w.callLog(), call(a, x)) {
		t.Fatal("the withdrawn action applied")
	}
}

// The departed phone returns: its next action leaves a gap where the
// withdrawn one was; the hub asks, the phone has no row, and skip_to closes
// it (#1498). The withdrawn action never applies.
func TestReturnAfterDepartureSkipsTheGap(t *testing.T) {
	w, a, b := relayPair(t)
	x := w.act(a)
	name, _ := a.Sealed(x)
	w.leave(a)
	w.pollAfterInterval()
	w.pollAfterInterval()
	w.wantCleared(a)
	if _, err := w.relay.Delete(w.ctx, relayZone(a), []transport.DeleteItem{{Name: name}}); err != nil {
		t.Fatal(err)
	}
	a.Forget(x)
	w.back(a)
	w.relay.RefuseWrites(relayZone(a), nil)
	w.sw.PollOther(w.ctx)
	if w.lapsedNow(a) {
		t.Fatal("still lapsed after the return")
	}
	if err := w.keys.Rotate(identity.ReasonManual); err != nil { // static for the phone now
		t.Fatal(err)
	}
	w.takeKeys(a)
	y := w.act(a)
	w.settle(a, b)
	w.appliedOnce(a, y)
	if slices.Contains(w.callLog(), call(a, x)) {
		t.Fatal("the withdrawn action applied")
	}
}

// F32: a farewell sealed in an epoch the hub erased is dropped and leaves the
// row; the slot is gone, so the departure check stops its keys.
func TestFarewellInARetiredEpochLeavesTheRowAndStopsKeys(t *testing.T) {
	w, a, b := relayPair(t)
	for range 2 {
		if err := w.keys.Rotate(identity.ReasonManual); err != nil {
			t.Fatal(err)
		}
	}
	w.advance(identity.PreviousEpochGrace + time.Hour)
	if err := w.keys.RetireOld(); err != nil {
		t.Fatal(err)
	}
	if _, err := w.keys.EraseExpired(); err != nil {
		t.Fatal(err)
	}
	w.offer(b) // b still acks: keep its epochs moving
	unlinked := true
	if _, err := a.WriteDeviceRecord(wire.DevicePayload{DeviceID: a.ID().String(), Name: "Test Phone", Scope: wire.ScopePrivate,
		Unlinked: &unlinked, UpdatedAt: wire.Time{Time: w.clock()}}, ""); err != nil {
		t.Fatal(err)
	}
	w.hub()
	if _, linked, err := w.st.Device(a.ID().String()); err != nil || !linked {
		t.Fatalf("the farewell in an erased epoch unlinked the phone (%v)", err)
	}
	w.leave(a)
	w.pollAfterInterval()
	w.pollAfterInterval()
	w.wantCleared(a)
}

// takeKeys hands ph the hub's current keybox keys for it.
func (w *world) takeKeys(ph *hubtest.Phone) {
	w.t.Helper()
	kk, err := w.keys.KeyboxKeysFor(ph.ID())
	if err != nil {
		w.t.Fatal(err)
	}
	if err := ph.Keep(kk); err != nil {
		w.t.Fatal(err)
	}
}
