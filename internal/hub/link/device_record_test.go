package link

import (
	"context"
	"crypto/ed25519"
	"database/sql"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// linkPhone links a new phone over a hello with no relay id (an iCloud
// link's), edited by edit.
func (r *rig) linkPhone(edit ...func(*wire.DeviceHello)) phone {
	r.t.Helper()
	p := newPhone(r.t)
	r.handle(p, r.issue().Nonce, edit...)
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		r.t.Fatalf("Confirm: %v", err)
	}
	return p
}

// relayIDOf is p's stored relay id and whether its admission stamp is set.
func (r *rig) relayIDOf(p phone) (id string, admitted bool) {
	r.t.Helper()
	d, ok, err := r.st.Device(p.id.String())
	if err != nil || !ok {
		r.t.Fatalf("device %v %v", ok, err)
	}
	return d.RelayDeviceID, !d.RelayAdmittedAt.IsZero()
}

// provenBy is a device record edit naming key's relay id, signed by key for
// this hub and p.
func (r *rig) provenBy(p phone, key ed25519.PrivateKey) func(*wire.DevicePayload) {
	return func(d *wire.DevicePayload) { signRelayID(d, key, r.kr.HubID(), p.id) }
}

func TestADeviceRecordWithAProofGivesAnICloudLinkItsRelayID(t *testing.T) {
	r := newRig(t)
	p := r.linkPhone()
	if id, _ := r.relayIDOf(p); id != "" {
		t.Fatalf("an iCloud link has a relay id: %q", id)
	}
	key := newRelayKey(t)
	named := 0
	r.c.OnRelayIDNamed(func(device string) {
		if device == strings.ToUpper(p.id.String()) {
			named++
		}
	})
	r.rewriteRecord(p, r.provenBy(p, key))
	want := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	if id, admitted := r.relayIDOf(p); id != want || admitted {
		t.Fatalf("relay id %q admitted %v, want %q not admitted", id, admitted, want)
	}
	if named != 1 {
		t.Fatalf("the relay id seam ran %d times", named)
	}
	if _, err := r.st.MarkRelayAdmitted([]string{want}, r.clock()); err != nil {
		t.Fatal(err)
	}
	// The same record again names nothing new: the stamp stays.
	r.rewriteRecord(p, r.provenBy(p, key))
	if id, admitted := r.relayIDOf(p); id != want || !admitted || named != 1 {
		t.Fatalf("a repeat: id %q admitted %v named %d", id, admitted, named)
	}
	// A new proven id replaces it and clears the stamp, so the stamp
	// follows the account again.
	key2 := newRelayKey(t)
	r.rewriteRecord(p, r.provenBy(p, key2))
	if id, admitted := r.relayIDOf(p); id != identity.RelayDeviceID(key2.Public().(ed25519.PublicKey)) || admitted || named != 2 {
		t.Fatalf("a new id: %q admitted %v named %d", id, admitted, named)
	}
}

func TestAnUnprovenRelayIDIsIgnored(t *testing.T) {
	key, other := newRelayKey(t), newRelayKey(t)
	cases := map[string]func(r *rig, p phone) func(*wire.DevicePayload){
		"no key": func(r *rig, p phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) { r.provenBy(p, key)(d); d.RelayAuthPub, d.RelayIDSig = "", "" }
		},
		"a key that is not the id's": func(r *rig, p phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) {
				id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
				r.provenBy(p, other)(d)
				d.RelayDeviceID = id
			}
		},
		"a bad signature": func(r *rig, p phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) {
				r.provenBy(p, key)(d)
				d.RelayIDSig = b64.EncodeToString(ed25519.Sign(other, []byte("x")))
			}
		},
		"signed for another hub": func(_ *rig, p phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) { signRelayID(d, key, secure.ID{0xEE}, p.id) }
		},
		"signed for another device": func(r *rig, _ phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) { signRelayID(d, key, r.kr.HubID(), secure.ID{0xEE}) }
		},
		"an invalid id": func(r *rig, p phone) func(*wire.DevicePayload) {
			return func(d *wire.DevicePayload) { r.provenBy(p, key)(d); d.RelayDeviceID = strings.ToUpper(d.RelayDeviceID) }
		},
	}
	for name, edit := range cases {
		t.Run(name, func(t *testing.T) {
			r := newRig(t)
			p := r.linkPhone()
			claim := edit(r, p)
			r.rewriteRecord(p, func(d *wire.DevicePayload) { claim(d); d.Name = "Renamed" })
			if id, _ := r.relayIDOf(p); id != "" {
				t.Fatalf("stored %q", id)
			}
			if d, _, _ := r.st.Device(p.id.String()); d.Name != "Renamed" {
				t.Fatalf("the rest of the record was not applied: name %q", d.Name)
			}
		})
	}
}

func TestAPhoneCannotClaimAPayingPhonesRelayID(t *testing.T) {
	r := newRig(t)
	aKey := newRelayKey(t)
	aID := identity.RelayDeviceID(aKey.Public().(ed25519.PublicKey))
	a := r.linkPhone(withRelayID(aID)) // a relay link, the paying phone
	b := r.linkPhone()
	bKey := newRelayKey(t)

	// B names A's id with its own key: the key is not the id's.
	r.rewriteRecord(b, func(d *wire.DevicePayload) { r.provenBy(b, bKey)(d); d.RelayDeviceID = aID })
	if id, _ := r.relayIDOf(b); id != "" {
		t.Fatalf("B took A's id with its own key: %q", id)
	}
	// B names A's id with A's public key but cannot sign with it.
	r.rewriteRecord(b, func(d *wire.DevicePayload) {
		r.provenBy(b, bKey)(d)
		d.RelayDeviceID, d.RelayAuthPub = aID, b64.EncodeToString(aKey.Public().(ed25519.PublicKey))
	})
	if id, _ := r.relayIDOf(b); id != "" {
		t.Fatalf("B took A's id with A's key and its own signature: %q", id)
	}
	if id, _ := r.relayIDOf(a); id != aID {
		t.Fatalf("A's id changed: %q", id)
	}
}

// A row that holds the id (a stale link, or an unproven hello) loses it to a
// proven record: only the relay_auth key's holder can sign the proof. The
// old row stops being a reader and stops counting; the seam runs once.
func TestAProvenRelayIDMovesFromAStaleRow(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	key := newRelayKey(t)
	id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	stale := r.linkPhone(withRelayID(id))
	if _, err := r.st.MarkRelayAdmitted([]string{id}, r.clock()); err != nil {
		t.Fatal(err)
	}
	if err := r.st.WithTx(ctx, func(tx *sql.Tx) error {
		_, err := state.LapseRelay(tx, stale.id.String(), r.clock())
		return err
	}); err != nil {
		t.Fatal(err)
	}
	prover := r.linkPhone()
	named := 0
	r.c.OnRelayIDNamed(func(string) { named++ })

	r.rewriteRecord(prover, r.provenBy(prover, key))

	if got, admitted := r.relayIDOf(stale); got != "" || admitted {
		t.Fatalf("the old row: id %q admitted %v", got, admitted)
	}
	if d, _, _ := r.st.Device(stale.id.String()); d.RelayLapsedAt != nil {
		t.Fatal("the old row is still lapsed on the relay")
	}
	if got, admitted := r.relayIDOf(prover); got != id || admitted {
		t.Fatalf("the prover: id %q admitted %v", got, admitted)
	}
	if named != 1 {
		t.Fatalf("the relay id seam ran %d times", named)
	}
	var rd readers
	if err := r.c.SyncReaders(ctx, rd.set); err != nil {
		t.Fatal(err)
	}
	if got := rd.last(t); !slices.Equal(got, []string{id}) {
		t.Fatalf("readers %v", got)
	}
	// The relay's stamp now lands on the prover alone.
	if n, err := r.st.MarkRelayAdmitted([]string{id}, r.clock()); err != nil || n != 1 {
		t.Fatalf("stamped %d, %v", n, err)
	}
	if _, admitted := r.relayIDOf(stale); admitted {
		t.Fatal("the old row was stamped")
	}
	if _, admitted := r.relayIDOf(prover); !admitted {
		t.Fatal("the prover was not stamped")
	}
}

// A hello's unproven claim on someone else's id loses to the real owner's
// proof, whichever came first.
func TestAProvenRelayIDBeatsASquatThroughAHello(t *testing.T) {
	r := newRig(t)
	key := newRelayKey(t)
	id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	owner := r.linkPhone()
	squatter := r.linkPhone(withRelayID(id))
	if got, _ := r.relayIDOf(squatter); got != id {
		t.Fatalf("a free id in a hello is stored today: %q", got)
	}
	r.rewriteRecord(owner, r.provenBy(owner, key))
	if got, _ := r.relayIDOf(squatter); got != "" {
		t.Fatalf("the squatter keeps %q", got)
	}
	if got, _ := r.relayIDOf(owner); got != id {
		t.Fatalf("the owner holds %q", got)
	}
}

// A sidecar written before the hello rule can have two rows holding one id,
// the prover among them: its repeat of a stored id still clears the other.
func TestAProvenRelayIDClearsAnotherHolderOfTheSameStoredID(t *testing.T) {
	r := newRig(t)
	key := newRelayKey(t)
	id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	owner := r.linkPhone(withRelayID(id))
	other := r.linkPhone()
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.SetRelayDeviceIDTx(tx, other.id.String(), id)
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := r.st.MarkRelayAdmitted([]string{id}, r.clock()); err != nil {
		t.Fatal(err)
	}
	named := 0
	r.c.OnRelayIDNamed(func(string) { named++ })
	r.rewriteRecord(owner, r.provenBy(owner, key))
	if got, _ := r.relayIDOf(other); got != "" {
		t.Fatalf("the other row keeps %q", got)
	}
	if got, admitted := r.relayIDOf(owner); got != id || !admitted {
		t.Fatalf("the owner: %q admitted %v (its stored id and stamp stay)", got, admitted)
	}
	if named != 1 {
		t.Fatalf("the seam ran %d times", named)
	}
}

// relink links p again over a new code with a hello naming id.
func (r *rig) relink(p phone, id string) {
	r.t.Helper()
	r.handle(p, r.issue().Nonce, withRelayID(id))
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		r.t.Fatalf("Confirm: %v", err)
	}
}

// An unproven hello never takes an id another row holds: the id after a move
// stays with its prover, against the old row's re-link and a new phone's
// link alike. The link itself goes through, with no relay id.
func TestAnUnprovenHelloDoesNotTakeAHeldRelayID(t *testing.T) {
	r := newRig(t)
	key := newRelayKey(t)
	id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	old := r.linkPhone(withRelayID(id))
	prover := r.linkPhone()
	r.rewriteRecord(prover, r.provenBy(prover, key))

	r.relink(old, id)
	if got, _ := r.relayIDOf(old); got != "" {
		t.Fatalf("the old row's hello took %q back", got)
	}
	squatter := r.linkPhone(withRelayID(id))
	if got, _ := r.relayIDOf(squatter); got != "" {
		t.Fatalf("a new phone's hello took %q", got)
	}
	if got, _ := r.relayIDOf(prover); got != id {
		t.Fatalf("the prover holds %q", got)
	}
}

// The check runs when the link is confirmed, not when the hello arrives: a
// request waiting across the prover's record does not take the id.
func TestAHelloWaitingAcrossAProofDoesNotTakeTheID(t *testing.T) {
	r := newRig(t)
	key := newRelayKey(t)
	id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	prover := r.linkPhone()
	waiting := newPhone(t)
	r.handle(waiting, r.issue().Nonce, withRelayID(id))
	r.rewriteRecord(prover, r.provenBy(prover, key))
	if err := r.c.Confirm(waiting.id.String(), r.code(waiting), true); err != nil {
		t.Fatal(err)
	}
	if got, _ := r.relayIDOf(waiting); got != "" {
		t.Fatalf("the waiting hello took %q", got)
	}
	if got, _ := r.relayIDOf(prover); got != id {
		t.Fatalf("the prover holds %q", got)
	}
}

// A phone's own re-link keeps its own id: only another row's hold counts.
func TestARelinkKeepsThePhonesOwnRelayID(t *testing.T) {
	r := newRig(t)
	id := relayID(t)
	p := r.linkPhone(withRelayID(id))
	r.relink(p, id)
	if got, _ := r.relayIDOf(p); got != id {
		t.Fatalf("the re-link stored %q", got)
	}
}

// The old row's phone, if still alive, keeps its link and loses only the id:
// a keyless claim on the id stays refused and the rest of its record applies,
// its own key's id is free to take, and a proof from the id's real key is a
// move like any other.
func TestTheOldRowsPhoneAfterTheMove(t *testing.T) {
	r := newRig(t)
	key := newRelayKey(t)
	id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	old := r.linkPhone(withRelayID(id))
	prover := r.linkPhone()
	r.rewriteRecord(prover, r.provenBy(prover, key))

	if _, linked, err := r.st.Device(old.id.String()); err != nil || !linked {
		t.Fatalf("the old row lost its link: %v %v", linked, err)
	}
	ownKey := newRelayKey(t)
	r.rewriteRecord(old, func(d *wire.DevicePayload) {
		r.provenBy(old, ownKey)(d)
		d.RelayDeviceID, d.Name = id, "Renamed"
	})
	if got, _ := r.relayIDOf(old); got != "" {
		t.Fatalf("a keyless claim stored %q", got)
	}
	if d, _, _ := r.st.Device(old.id.String()); d.Name != "Renamed" {
		t.Fatalf("the rest of the record was not applied: %q", d.Name)
	}
	if got, _ := r.relayIDOf(prover); got != id {
		t.Fatalf("a keyless claim moved the id: %q", got)
	}

	r.rewriteRecord(old, r.provenBy(old, ownKey))
	ownID := identity.RelayDeviceID(ownKey.Public().(ed25519.PublicKey))
	if got, _ := r.relayIDOf(old); got != ownID {
		t.Fatalf("its own id: %q", got)
	}
	if got, _ := r.relayIDOf(prover); got != id {
		t.Fatalf("its own id touched the prover: %q", got)
	}

	r.rewriteRecord(old, r.provenBy(old, key))
	if got, _ := r.relayIDOf(old); got != id {
		t.Fatalf("a proof from the real key: %q", got)
	}
	if got, _ := r.relayIDOf(prover); got != "" {
		t.Fatalf("the prover keeps %q after a newer proof", got)
	}
}

// The move and the store are one transaction with the rest of the record: a
// failure at the store leaves the old row holding the id.
func TestAFailedMoveRollsBack(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	key := newRelayKey(t)
	id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	old := r.linkPhone(withRelayID(id))
	if _, err := r.st.MarkRelayAdmitted([]string{id}, r.clock()); err != nil {
		t.Fatal(err)
	}
	prover := r.linkPhone()
	// The old row's clear goes through; the prover's store fails.
	if err := r.st.WithTx(ctx, func(tx *sql.Tx) error {
		_, err := tx.Exec(`CREATE TRIGGER fail_the_store BEFORE UPDATE OF relay_device_id ON devices
			WHEN NEW.relay_device_id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'test: store failed'); END`)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	named := 0
	r.c.OnRelayIDNamed(func(string) { named++ })
	d := wire.DevicePayload{DeviceID: prover.id.String(), Name: "Renamed", Scope: wire.ScopePrivate,
		StartSessions: true, UpdatedAt: wire.Time{Time: r.clock()}}
	r.provenBy(prover, key)(&d)
	if err := r.c.ApplyDeviceRecord(ctx, prover.id.String(), DeviceRecord{Payload: d}); err == nil {
		t.Fatal("the failed store came back as no error")
	}
	if got, admitted := r.relayIDOf(old); got != id || !admitted {
		t.Fatalf("the old row after the failure: %q admitted %v", got, admitted)
	}
	if got, _ := r.relayIDOf(prover); got != "" {
		t.Fatalf("the prover after the failure: %q", got)
	}
	if row, _, _ := r.st.Device(prover.id.String()); row.Name == "Renamed" {
		t.Fatal("the record's other fields survived the failure")
	}
	if named != 0 {
		t.Fatalf("the seam ran %d times for a failed record", named)
	}
}

func TestFILES01_RelayIDMoveLogsNoID(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newRig(t)
	key := newRelayKey(t)
	id := identity.RelayDeviceID(key.Public().(ed25519.PublicKey))
	r.linkPhone(withRelayID(id))
	p := r.linkPhone()
	r.rewriteRecord(p, r.provenBy(p, key))
	r.linkPhone(withRelayID(id))
	sink.AssertClean(t)
	out := sink.String()
	if !strings.Contains(out, relayIDMoved) || !strings.Contains(out, relayIDTaken) {
		t.Fatalf("the move and the refused hello are not in the log: %s", out)
	}
	if strings.Contains(out, id) {
		t.Error("a relay id reached the log")
	}
}

func TestADeviceRecordFromAnotherWriterNamesNoRelayID(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	r.s.join("_colleague-a")
	p := newPhone(t)
	r.linkCK(p, code.Nonce, sharedHello("_colleague-a"))
	d := wire.DevicePayload{DeviceID: p.id.String(), Name: "iPhone", Scope: wire.ScopeShared,
		UserRecordName: "_colleague-a", StartSessions: true, UpdatedAt: wire.Time{Time: r.clock()}}
	r.provenBy(p, newRelayKey(t))(&d)
	if err := r.c.ApplyDeviceRecord(r.ctx, p.id.String(), DeviceRecord{Payload: d, Creator: "_colleague-b", Shares: r.s}); err != nil {
		t.Fatal(err)
	}
	if id, _ := r.relayIDOf(p); id != "" {
		t.Fatalf("a record another user wrote named %q", id)
	}
	// Written by the phone's own user, the same record names it.
	if err := r.c.ApplyDeviceRecord(r.ctx, p.id.String(), DeviceRecord{Payload: d, Creator: "_colleague-a", Shares: r.s}); err != nil {
		t.Fatal(err)
	}
	if id, _ := r.relayIDOf(p); id != d.RelayDeviceID {
		t.Fatalf("the phone's own record: %q", id)
	}
}

func TestTheUpgradedPhoneIsAReaderAfterItsRecord(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	relayLinked := relayID(t)
	r.linkPhone(withRelayID(relayLinked))
	p := r.linkPhone()
	var rd readers
	if err := r.c.SyncReaders(ctx, rd.set); err != nil {
		t.Fatal(err)
	}
	if got := rd.last(t); !slices.Equal(got, []string{relayLinked}) {
		t.Fatalf("readers before the record: %v", got)
	}
	key := newRelayKey(t)
	r.rewriteRecord(p, r.provenBy(p, key))
	if err := r.c.SyncReaders(ctx, rd.set); err != nil {
		t.Fatal(err)
	}
	want := []string{relayLinked, identity.RelayDeviceID(key.Public().(ed25519.PublicKey))}
	slices.Sort(want)
	if got := rd.last(t); !slices.Equal(got, want) {
		t.Fatalf("readers after the record: %v, want %v", got, want)
	}
}

func TestFILES01_DeviceRecordRelayIDLogsNoNames(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newRig(t)
	name := logcanary.Text("device.name")
	p := r.linkPhone()
	key := newRelayKey(t)
	r.rewriteRecord(p, func(d *wire.DevicePayload) { r.provenBy(p, key)(d); d.Name = name })
	r.rewriteRecord(p, func(d *wire.DevicePayload) {
		r.provenBy(p, newRelayKey(t))(d)
		d.RelayIDSig = b64.EncodeToString(make([]byte, 64))
		d.Name = name
	})
	sink.AssertClean(t)
	out := sink.String()
	if !strings.Contains(out, "named its relay id") || !strings.Contains(out, "bad_signature") {
		t.Fatalf("the relay id lines are missing: %s", out)
	}
	pub := b64.EncodeToString(key.Public().(ed25519.PublicKey))
	if strings.Contains(out, pub) || strings.Contains(out, identity.RelayDeviceID(key.Public().(ed25519.PublicKey))) {
		t.Error("a relay key or id reached the log")
	}
}
