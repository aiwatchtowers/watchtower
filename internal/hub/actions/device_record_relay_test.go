package actions

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// G1: a phone on the hosted relay writes its device record into its own
// mailbox, and the hub applies it there as it does on CloudKit. What differs:
// the relay names no creator, so the record's authority is the envelope (a key
// only this phone and the hub derive) and the relay's mailbox rule.

func onRelay(t *testing.T) *world {
	t.Helper()
	return newWorld(t, transport.KindRelay)
}

func (w *world) stillLinked(ph *hubtest.Phone) bool {
	w.t.Helper()
	_, linked, err := w.st.Device(ph.ID().String())
	if err != nil {
		w.t.Fatal(err)
	}
	return linked
}

func TestDeviceRecordOnTheRelayRenamesAndAsks(t *testing.T) {
	w := onRelay(t)
	w.rewrite(wire.DevicePayload{TypingRequested: true, Name: "Renamed", StartSessions: false})
	d := w.device(w.phone)
	if d.Name != "Renamed" || !d.TypingRequested || d.StartSessionsAllowed {
		t.Fatalf("device %+v", d)
	}
	if d.TypingAllowed {
		t.Fatal("a request became a grant")
	}
}

// PROJ-21 on the relay: the toggle stores a request for the owner, never a grant.
func TestDeviceRecordOnTheRelayStoresThePermissionRequestAndNeverGrants(t *testing.T) {
	w := onRelay(t)
	on := true
	w.rewrite(wire.DevicePayload{PermissionsRequested: &on})
	d := w.device(w.phone)
	if !d.PermissionsRequested || d.PermissionsAllowed {
		t.Fatalf("device %+v", d)
	}
}

func TestDeviceRecordOnTheRelayOffRevokesTheGrant(t *testing.T) {
	w := onRelay(t)
	on, off := true, false
	w.rewrite(wire.DevicePayload{TypingRequested: true, PermissionsRequested: &on})
	device := w.phone.ID().String()
	for _, g := range []link.Grant{link.GrantTyping, link.GrantPermissions} {
		if err := w.links.Allow(device, g, true); err != nil {
			t.Fatal(err)
		}
	}
	w.rewrite(wire.DevicePayload{TypingRequested: false, PermissionsRequested: &off})
	if d := w.device(w.phone); d.TypingAllowed || d.PermissionsAllowed || d.TypingRequested || d.PermissionsRequested {
		t.Fatalf("device %+v", d)
	}
}

func TestDeviceRecordOnTheRelayFarewellUnlinks(t *testing.T) {
	w := onRelay(t)
	epoch, err := w.keys.CurrentEpoch()
	if err != nil {
		t.Fatal(err)
	}
	unlinked := true
	w.rewrite(wire.DevicePayload{Unlinked: &unlinked})
	if w.stillLinked(w.phone) {
		t.Fatal("still linked after the farewell")
	}
	if now, err := w.keys.CurrentEpoch(); err != nil || now != epoch+1 {
		t.Fatalf("epoch %d → %d (%v): an unlink rotates", epoch, now, err)
	}
}

// A shared-scope iCloud phone keeps its scope after its upgrade to the relay,
// where no record has a creator.
func TestDeviceRecordOnTheRelaySharedScopeWithNoCreatorApplies(t *testing.T) {
	w := onRelay(t)
	w.setScope(w.phone, wire.ScopeShared, "_user-a")
	w.rewrite(wire.DevicePayload{Scope: wire.ScopeShared, UserRecordName: "_user-a", Name: "Renamed"})
	if d := w.device(w.phone); d.Name != "Renamed" {
		t.Fatalf("name %q", d.Name)
	}
}

// The scope check stays: a record naming another scope than the link's is not
// this link's record.
func TestDeviceRecordOnTheRelayWrongScopeIsIgnored(t *testing.T) {
	w := onRelay(t)
	w.rewrite(wire.DevicePayload{Scope: wire.ScopeShared, Name: "Renamed"})
	if d := w.device(w.phone); d.Name != "Test Phone" {
		t.Fatalf("name %q", d.Name)
	}
}

func TestDeviceRecordCloudKitStillChecksTheCreator(t *testing.T) {
	onShared(t, func(t *testing.T, w *world) {
		w.setScope(w.phone, wire.ScopeShared, "_user-a")
		w.setStoredUser(w.phone, "_user-a")
		w.phone.Creator = "_a-stranger"
		w.rewrite(wire.DevicePayload{Scope: wire.ScopeShared, UserRecordName: "_user-a", Name: "Renamed"})
		if d := w.device(w.phone); d.Name != "Test Phone" {
			t.Fatalf("name %q", d.Name)
		}
	})
}

// A record named device-<other> sealed by this phone, its payload naming
// itself: the name must name its sender, as on CloudKit.
func TestDeviceRecordOnTheRelayNamingAnotherPhoneIsDropped(t *testing.T) {
	w := onRelay(t)
	other := w.addPhone()
	d := wire.DevicePayload{DeviceID: w.phone.ID().String(), Name: "Forged", Scope: wire.ScopePrivate,
		UpdatedAt: wire.Time{Time: w.clock()}}
	if _, err := w.phone.WriteDeviceRecord(d, "device-"+other.ID().String()); err != nil {
		t.Fatal(err)
	}
	w.pass()
	if got := w.device(w.phone).Name; got != "Test Phone" {
		t.Fatalf("name %q", got)
	}
}

// The authorization path: nothing but the mailbox's own phone, sealing under
// its own keys for this hub, changes its row.
func TestDeviceRecordOnTheRelayRefusesEveryOtherWriter(t *testing.T) {
	unlinked := true
	for _, tc := range []struct {
		name  string
		write func(t *testing.T, w *world, d wire.DevicePayload) error
	}{
		{"another linked phone in this mailbox", func(_ *testing.T, w *world, d wire.DevicePayload) error {
			b := w.linkedPhoneIn(w.phone.Zone())
			d.DeviceID = b.ID().String() // its own record, in the wrong mailbox
			_, err := b.WriteDeviceRecord(d, "")
			return err
		}},
		{"another linked phone naming this one", func(_ *testing.T, w *world, d wire.DevicePayload) error {
			b := w.linkedPhoneIn(w.phone.Zone())
			_, err := b.WriteDeviceRecord(d, "device-"+w.phone.ID().String())
			return err
		}},
		{"another linked phone, its own name, this phone in the payload", func(_ *testing.T, w *world, d wire.DevicePayload) error {
			_, err := w.linkedPhoneIn(w.phone.Zone()).WriteDeviceRecord(d, "")
			return err
		}},
		{"a phone that was never linked", func(t *testing.T, w *world, d wire.DevicePayload) error {
			_, err := w.strangerIn(t, w.keys.HubID()).WriteDeviceRecord(d, "device-"+w.phone.ID().String())
			return err
		}},
		{"an envelope sealed by another device, naming this phone", func(t *testing.T, w *world, d wire.DevicePayload) error {
			_, err := w.strangerIn(t, w.keys.HubID()).WriteForgedDeviceRecord(d, w.phone.ID())
			return err
		}},
		{"an envelope sealed by a linked device, naming this phone", func(_ *testing.T, w *world, d wire.DevicePayload) error {
			_, err := w.linkedPhoneIn(w.phone.Zone()).WriteForgedDeviceRecord(d, w.phone.ID())
			return err
		}},
		{"a record for another hub", func(t *testing.T, w *world, d wire.DevicePayload) error {
			other, err := secure.ParseID("AAAAAAAA-0000-4000-8000-000000000009")
			if err != nil {
				return err
			}
			_, err = w.strangerIn(t, other).WriteForgedDeviceRecord(d, w.phone.ID())
			return err
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, farewell := range []bool{false, true} {
				w := onRelay(t)
				d := wire.DevicePayload{DeviceID: w.phone.ID().String(), Name: "Forged", Scope: wire.ScopePrivate,
					TypingRequested: true, UpdatedAt: wire.Time{Time: w.clock()}}
				if farewell {
					d.Unlinked = &unlinked
				}
				if err := tc.write(t, w, d); err != nil {
					t.Fatal(err)
				}
				w.pass()
				if !w.stillLinked(w.phone) {
					t.Fatal("unlinked by another writer")
				}
				if got := w.device(w.phone); got.Name != "Test Phone" || got.TypingRequested {
					t.Fatalf("changed by another writer: %+v", got)
				}
			}
		})
	}
}

// A switch rewinds the mailbox: the record is read again as Same, applies
// again, and never replays its relay id proof.
func TestDeviceRecordOnTheRelayRewindStripsTheProof(t *testing.T) {
	w := onRelay(t)
	d, id := proofRecord(t, w, w.phone, "Renamed")
	if _, err := w.phone.WriteDeviceRecord(d, ""); err != nil {
		t.Fatal(err)
	}
	w.pass()
	if got := w.device(w.phone); got.Name != "Renamed" || got.RelayDeviceID != id {
		t.Fatalf("device %+v", got)
	}
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE devices SET relay_device_id = ? WHERE device_id = ?`, "moved-away", w.phone.ID().String())
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if err := w.st.SetZoneToken(w.phone.Zone(), 0); err != nil {
		t.Fatal(err)
	}
	// The row's relay id moved, so the mailbox is no longer listed under it:
	// read the zone the record is in by the processor's own path.
	b := mailbox{id: w.phone.ID(), zone: w.phone.Zone(), queue: w.phone.Zone(), link: w.device(w.phone).LinkNonce}
	if err := w.proc.readMailbox(w.ctx, b, w.proc.newPass()); err != nil {
		t.Fatal(err)
	}
	if got := w.device(w.phone).RelayDeviceID; got != "moved-away" {
		t.Fatalf("a re-read replayed the proof: %q", got)
	}
}

// failingLinks applies a record, then fails as a crash right after its commit.
type failingLinks struct {
	Links
	fail *bool
}

var errCrash = errors.New("crash")

func (f failingLinks) ApplyDeviceRecord(ctx context.Context, device string, r link.DeviceRecord) error {
	if err := f.Links.ApplyDeviceRecord(ctx, device, r); err != nil {
		return err
	}
	if *f.fail {
		return errCrash
	}
	return nil
}

// A crash after the commit: the record and its mark are in, and the re-read is
// Same and applies nothing new.
func TestDeviceRecordOnTheRelayCrashAfterTheCommitAppliesAgain(t *testing.T) {
	w := onRelay(t)
	fail := true
	w.proc.cfg.Links = failingLinks{w.links, &fail}
	name, err := w.phone.WriteDeviceRecord(wire.DevicePayload{DeviceID: w.phone.ID().String(), Name: "Renamed",
		Scope: wire.ScopePrivate, UpdatedAt: wire.Time{Time: w.clock()}}, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.proc.Pass(w.ctx); !errors.Is(err, errCrash) {
		t.Fatalf("pass: %v", err)
	}
	if _, _, ok, err := w.st.RelaySeen(name, w.phone.ID().String()); err != nil || !ok {
		t.Fatalf("the mark did not commit with the record: %v %v", ok, err)
	}
	fail = false
	w.pass()
	if got := w.device(w.phone).Name; got != "Renamed" {
		t.Fatalf("name %q", got)
	}
}

// A failure inside the transaction takes record and mark back together.
func TestDeviceRecordOnTheRelayFailedCommitAppliesNothing(t *testing.T) {
	w := onRelay(t)
	name, err := w.phone.WriteDeviceRecord(wire.DevicePayload{DeviceID: w.phone.ID().String(), Name: "Renamed",
		Scope: wire.ScopePrivate, UpdatedAt: wire.Time{Time: w.clock()}}, "")
	if err != nil {
		t.Fatal(err)
	}
	exec := func(q string) {
		t.Helper()
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { _, err := tx.Exec(q); return err }); err != nil {
			t.Fatal(err)
		}
	}
	exec(`CREATE TRIGGER no_marks BEFORE INSERT ON relay_seen BEGIN SELECT RAISE(ABORT, 'crash'); END`)
	if _, err := w.proc.Pass(w.ctx); err == nil {
		t.Fatal("no error")
	}
	if got := w.device(w.phone).Name; got != "Test Phone" {
		t.Fatalf("applied with no mark: %q", got)
	}
	exec(`DROP TRIGGER no_marks`)
	w.pass()
	if got := w.device(w.phone).Name; got != "Renamed" {
		t.Fatalf("name %q", got)
	}
	if _, _, ok, err := w.st.RelaySeen(name, w.phone.ID().String()); err != nil || !ok {
		t.Fatalf("not marked: %v %v", ok, err)
	}
}

// The mark is shared by both transports (wire name and sender, no zone): an
// older copy from the other transport is dropped. This is the stale iCloud
// record after a move to the relay, and the stale relay record after a switch back.
func TestDeviceRecordOlderOnTheOtherTransportIsDropped(t *testing.T) {
	w := onRelay(t)
	base := wire.DevicePayload{DeviceID: w.phone.ID().String(), Scope: wire.ScopePrivate, UpdatedAt: wire.Time{Time: w.clock()}}
	older := base
	older.Name = "Older"
	name, err := w.phone.WriteDeviceRecord(older, "")
	if err != nil {
		t.Fatal(err)
	}
	stale := w.envelope(w.phone.Zone(), name)
	newer := base
	newer.Name = "Newer"
	if _, err := w.phone.WriteDeviceRecord(newer, ""); err != nil {
		t.Fatal(err)
	}
	w.pass()
	if _, err := w.fake.Write(w.phone.Zone(), name, stale, transport.Expect{Mode: transport.ExpectNone}); err != nil {
		t.Fatal(err)
	}
	w.pass()
	if got := w.device(w.phone).Name; got != "Newer" {
		t.Fatalf("name %q", got)
	}
}

// Two lanes: this processor opened an older record, and before it applies, the
// other transport's processor applies and marks a newer one. The older one
// must not overwrite it (re-checked in rewrite's transaction).
func TestDeviceRecordOlderLaneDoesNotOverwriteNewer(t *testing.T) {
	w := onRelay(t)
	device := w.phone.ID().String()
	name, err := w.phone.WriteDeviceRecord(wire.DevicePayload{DeviceID: device, Name: "Older", Scope: wire.ScopePrivate,
		UpdatedAt: wire.Time{Time: w.clock()}}, "")
	if err != nil {
		t.Fatal(err)
	}
	done := false
	w.proc.fault = func(stage string) error {
		if done || stage != "opened" {
			return nil
		}
		done = true
		if err := w.links.ApplyDeviceRecord(w.ctx, device, link.DeviceRecord{Payload: wire.DevicePayload{DeviceID: device,
			Name: "Newer", Scope: wire.ScopePrivate, UpdatedAt: wire.Time{Time: w.clock()}}}); err != nil {
			return err
		}
		epoch, err := w.keys.CurrentEpoch()
		if err != nil {
			return err
		}
		return w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.RecordSeen(tx, name, device, epoch, 1000) })
	}
	w.pass()
	if !done {
		t.Fatal("the other lane never ran")
	}
	if got := w.device(w.phone).Name; got != "Newer" {
		t.Fatalf("an older lane overwrote the newer record: %q", got)
	}
}

// afterApply runs after, once, the first apply returns: the moment between a
// record's commit and anything its processor does next.
type afterApply struct {
	Links
	after *func()
}

func (a afterApply) ApplyDeviceRecord(ctx context.Context, device string, r link.DeviceRecord) error {
	err := a.Links.ApplyDeviceRecord(ctx, device, r)
	if f := *a.after; f != nil {
		*a.after = nil
		f()
	}
	return err
}

// The other lane runs between this record's commit and whatever follows it: its
// older record, saying typing off, must not overwrite the newer one nor revoke
// the grant. The mark commits with the record, so there is no such window.
func TestDeviceRecordOlderLaneBetweenCommitAndMarkDoesNotOverwrite(t *testing.T) {
	w := onRelay(t)
	device := w.phone.ID().String()
	w.rewrite(wire.DevicePayload{TypingRequested: true})
	if err := w.links.Allow(device, link.GrantTyping, true); err != nil {
		t.Fatal(err)
	}
	record := func(name string, typing bool) string {
		t.Helper()
		id, err := w.phone.WriteDeviceRecord(wire.DevicePayload{DeviceID: device, Name: name, Scope: wire.ScopePrivate,
			TypingRequested: typing, UpdatedAt: wire.Time{Time: w.clock()}}, "")
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	wireName := record("Older", false)
	stale := w.envelope(w.phone.Zone(), wireName)
	record("Newer", true)
	boxes, err := w.proc.mailboxes()
	if err != nil {
		t.Fatal(err)
	}
	ran := false
	hook := func() {
		ran = true
		if err := w.proc.handle(w.ctx, boxes[0], transport.Stored{Name: wireName, Envelope: stale}, w.proc.newPass()); err != nil {
			t.Error(err)
		}
	}
	w.proc.cfg.Links = afterApply{w.links, &hook}
	w.pass()
	if !ran {
		t.Fatal("the other lane never ran")
	}
	if d := w.device(w.phone); d.Name != "Newer" || !d.TypingRequested || !d.TypingAllowed {
		t.Fatalf("the older lane overwrote the newer record: %+v", d)
	}
}

// A record opened under a link that no longer stands applies nothing: the claim
// checks the link in the rewrite's transaction.
func TestDeviceRecordOpenedBeforeARelinkAppliesNothing(t *testing.T) {
	w := onRelay(t)
	name, err := w.phone.WriteDeviceRecord(wire.DevicePayload{DeviceID: w.phone.ID().String(), Name: "Old link",
		Scope: wire.ScopePrivate, UpdatedAt: wire.Time{Time: w.clock()}}, "")
	if err != nil {
		t.Fatal(err)
	}
	done := false
	w.proc.fault = func(stage string) error {
		if !done && stage == "opened" {
			done = true
			w.relink(w.phone)
		}
		return nil
	}
	w.pass()
	if !done {
		t.Fatal("never opened")
	}
	if got := w.device(w.phone).Name; got != "Test Phone" {
		t.Fatalf("name %q", got)
	}
	if _, _, ok, err := w.st.RelaySeen(name, w.phone.ID().String()); err != nil || ok {
		t.Fatalf("marked under the new link: %v %v", ok, err)
	}
}

// A farewell opened before a re-link does not unlink the live phone: it read
// the new row, and the link check runs in the unlink's own transaction. No
// epoch rotates.
func TestFarewellOpenedBeforeARelinkAppliesNothing(t *testing.T) {
	w := onRelay(t)
	unlinked := true
	name, err := w.phone.WriteDeviceRecord(wire.DevicePayload{DeviceID: w.phone.ID().String(), Name: "Test Phone",
		Scope: wire.ScopePrivate, Unlinked: &unlinked, UpdatedAt: wire.Time{Time: w.clock()}}, "")
	if err != nil {
		t.Fatal(err)
	}
	epoch, err := w.keys.CurrentEpoch()
	if err != nil {
		t.Fatal(err)
	}
	done := false
	w.proc.fault = func(stage string) error {
		if !done && stage == "opened" {
			done = true
			w.relink(w.phone)
		}
		return nil
	}
	w.pass()
	if !done {
		t.Fatal("never opened")
	}
	if !w.stillLinked(w.phone) {
		t.Fatal("an old farewell unlinked the new link")
	}
	if now, err := w.keys.CurrentEpoch(); err != nil || now != epoch {
		t.Fatalf("epoch %d → %d (%v)", epoch, now, err)
	}
	if _, _, ok, err := w.st.RelaySeen(name, w.phone.ID().String()); err != nil || ok {
		t.Fatalf("marked under the new link: %v %v", ok, err)
	}
}

// A farewell older than a marked rewrite still comes from a phone that has
// left: no version check stands in its way.
func TestFarewellOlderThanAMarkedRewriteStillUnlinks(t *testing.T) {
	w := onRelay(t)
	device := w.phone.ID().String()
	unlinked := true
	wireName, err := w.phone.WriteDeviceRecord(wire.DevicePayload{DeviceID: device, Name: "Test Phone",
		Scope: wire.ScopePrivate, Unlinked: &unlinked, UpdatedAt: wire.Time{Time: w.clock()}}, "")
	if err != nil {
		t.Fatal(err)
	}
	done := false
	w.proc.fault = func(stage string) error {
		if done || stage != "opened" {
			return nil
		}
		done = true
		epoch, err := w.keys.CurrentEpoch()
		if err != nil {
			return err
		}
		return w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.RecordSeen(tx, wireName, device, epoch, 1000) })
	}
	w.pass()
	if !done {
		t.Fatal("never opened")
	}
	if w.stillLinked(w.phone) {
		t.Fatal("still linked after its farewell")
	}
}

// A farewell read, a re-link (marks gone), a switch's rewind: the old farewell
// is read again. It no longer opens, since the relay key takes the link nonce.
func TestOldFarewellAfterARelinkAndARewindKeepsTheLink(t *testing.T) {
	w := onRelay(t)
	unlinked := true
	w.rewrite(wire.DevicePayload{Unlinked: &unlinked})
	if w.stillLinked(w.phone) {
		t.Fatal("the farewell did not apply")
	}
	w.advance(time.Hour)
	w.relink(w.phone)
	if err := w.st.SetZoneToken(w.phone.Zone(), 0); err != nil {
		t.Fatal(err)
	}
	w.pass()
	if !w.stillLinked(w.phone) {
		t.Fatal("an old farewell unlinked the new link")
	}
}

// On standby a device record is read as on the active side.
func TestDeviceRecordOnRelayStandbyApplies(t *testing.T) {
	w := onRelay(t)
	w.withSwitch(&fakeSwitch{active: transport.KindCloudKit})
	w.rewrite(wire.DevicePayload{Name: "Renamed"})
	if got := w.device(w.phone).Name; got != "Renamed" {
		t.Fatalf("name %q", got)
	}
}

func TestDeviceRecordOnTheRelayStoresWorkAlertsOff(t *testing.T) {
	w := onRelay(t)
	on, off := true, false
	w.rewrite(wire.DevicePayload{WorkAlertsOff: &on})
	if !w.device(w.phone).WorkAlertsOff {
		t.Fatal("off not stored")
	}
	w.rewrite(wire.DevicePayload{WorkAlertsOff: &off})
	if w.device(w.phone).WorkAlertsOff {
		t.Fatal("false did not clear it")
	}
	w.rewrite(wire.DevicePayload{WorkAlertsOff: &on})
	w.rewrite(wire.DevicePayload{})
	if w.device(w.phone).WorkAlertsOff {
		t.Fatal("an absent key did not clear it")
	}
}

func TestRelinkClearsWorkAlertsOff(t *testing.T) {
	w := onRelay(t)
	on := true
	w.rewrite(wire.DevicePayload{WorkAlertsOff: &on})
	w.relink(w.phone)
	if w.device(w.phone).WorkAlertsOff {
		t.Fatal("a re-link kept the old switch")
	}
}

// envelope reads the stored envelope of name in zone.
func (w *world) envelope(zone, name string) []byte {
	w.t.Helper()
	b, err := w.fake.Changes(w.ctx, zone, 0)
	if err != nil {
		w.t.Fatal(err)
	}
	for _, rec := range b.Changed {
		if rec.Name == name {
			return rec.Envelope
		}
	}
	w.t.Fatalf("no record %s in %s", name, zone)
	return nil
}

// setScope sets the link's scope and stored iCloud user.
func (w *world) setScope(ph *hubtest.Phone, scope, user string) {
	w.t.Helper()
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE devices SET scope = ?, user_record_name = ? WHERE device_id = ?`, scope, user, ph.ID().String())
		return err
	}); err != nil {
		w.t.Fatal(err)
	}
}

// phoneIn is a new phone of hub writing into zone, not linked.
func (w *world) phoneIn(hub secure.ID, zone string) *hubtest.Phone {
	w.t.Helper()
	meta, err := w.keys.MetaKey()
	if err != nil {
		w.t.Fatal(err)
	}
	epoch, err := w.keys.CurrentEpoch()
	if err != nil {
		w.t.Fatal(err)
	}
	ph, err := hubtest.New(hubtest.Config{Hub: hub, HubKX: w.ident.Agreement.PublicKey(), MetaKey: meta, Epoch: epoch,
		HubRelayID: hubRelayID, Transport: w.fake, Clock: w.clock, Mailbox: zone})
	if err != nil {
		w.t.Fatal(err)
	}
	return ph
}

// linkedPhoneIn is a linked phone whose writes land in zone.
func (w *world) linkedPhoneIn(zone string) *hubtest.Phone {
	w.t.Helper()
	ph := w.phoneIn(w.keys.HubID(), zone)
	d := ph.Device()
	if strings.HasSuffix(zone, d.RelayDeviceID) {
		w.t.Fatal("not another mailbox")
	}
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.LinkDevice(tx, d) }); err != nil {
		w.t.Fatal(err)
	}
	return ph
}

// strangerIn is an unlinked phone of hub writing into the world's phone's mailbox.
func (w *world) strangerIn(t *testing.T, hub secure.ID) *hubtest.Phone {
	t.Helper()
	return w.phoneIn(hub, w.phone.Zone())
}
