package hub

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"database/sql"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"
)

// The hub's side of the weekly relay keys (relay client Phase 5): the
// serving-nobody mark the answered account reads keep, the rotation's skip and
// the 14-day end, and the erasure's housekeeping.

type relayKeysRig struct {
	t   *testing.T
	dir string
	st  *state.Store
	kr  *identity.Keyring
	id  identity.Identity
	mu  sync.Mutex
	now time.Time
	tr  *memfake.Fake
}

func (r *relayKeysRig) clock() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.now
}

func (r *relayKeysRig) advance(d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.now = r.now.Add(d)
}

// newRelayKeysRig is a sidecar and keyring on transport kind ("relay" or
// "cloudkit", as hub_meta.transport says).
func newRelayKeysRig(t *testing.T, kind string) *relayKeysRig {
	t.Helper()
	r := &relayKeysRig{t: t, dir: t.TempDir(), now: time.Unix(1_800_000_000, 0)}
	r.openStore()
	var err error
	if r.id, err = identity.New(); err != nil {
		t.Fatal(err)
	}
	r.openKeyring()
	if err := r.st.SetMeta(state.MetaTransport, kind); err != nil {
		t.Fatal(err)
	}
	r.tr = memfake.New(transport.KindRelay, r.clock)
	return r
}

func (r *relayKeysRig) openStore() {
	st, err := state.Open(filepath.Join(r.dir, "hub"))
	if err != nil {
		r.t.Fatal(err)
	}
	r.t.Cleanup(func() { _ = st.Close() })
	r.st = st
}

func (r *relayKeysRig) openKeyring() {
	kr, err := identity.NewKeyring(r.id, r.st, r.clock)
	if err != nil {
		r.t.Fatal(err)
	}
	r.kr = kr
}

// restart is the hub started again over the same sidecar.
func (r *relayKeysRig) restart() { r.openKeyring() }

// phone links a twin phone (hubtest) and returns it.
func (r *relayKeysRig) phone() *hubtest.Phone {
	r.t.Helper()
	meta, err := r.kr.MetaKey()
	if err != nil {
		r.t.Fatal(err)
	}
	cur, _ := r.kr.CurrentEpoch()
	ph, err := hubtest.New(hubtest.Config{
		Hub: r.kr.HubID(), HubKX: r.kr.Agreement().PublicKey(), HubSig: r.kr.Signer().Public().(ed25519.PublicKey),
		MetaKey: meta, Epoch: cur, HubRelayID: "hubrelay", Transport: r.tr, Clock: r.clock,
	})
	if err != nil {
		r.t.Fatal(err)
	}
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, ph.Device()) }); err != nil {
		r.t.Fatal(err)
	}
	return ph
}

// offer stores the twin phone's offer, as its epoch_ack's pass would.
func (r *relayKeysRig) offer(ph *hubtest.Phone) {
	r.t.Helper()
	if _, err := ph.Offer(); err != nil {
		r.t.Fatal(err)
	}
	cur, _ := r.kr.CurrentEpoch()
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		ok, err := state.SetKXOffer(tx, ph.ID().String(), ph.Offered(), cur)
		if err == nil && !ok {
			err = errors.New("offer refused")
		}
		return err
	}); err != nil {
		r.t.Fatal(err)
	}
}

// keybox hands the phone the hub's keybox keys for it.
func (r *relayKeysRig) keybox(ph *hubtest.Phone) wire.KeyboxKeys {
	r.t.Helper()
	kk, err := r.kr.KeyboxKeysFor(ph.ID())
	if err != nil {
		r.t.Fatal(err)
	}
	if err := ph.Keep(kk); err != nil {
		r.t.Fatal(err)
	}
	return kk
}

// read is one answered account read of these slot holders.
func (r *relayKeysRig) read(holders ...*relayv1.SlotHolder) {
	r.t.Helper()
	if err := noteServingNobody(r.kr, r.st, &relayv1.AccountState{Phones: holders}, r.clock()); err != nil {
		r.t.Fatal(err)
	}
}

func holder(ph *hubtest.Phone, paying bool) *relayv1.SlotHolder {
	return &relayv1.SlotHolder{PhoneDeviceId: ph.RelayDeviceID(), Paying: paying}
}

func (r *relayKeysRig) mark() (string, bool) {
	r.t.Helper()
	v, ok, err := r.st.Meta(state.MetaServingNobodySince)
	if err != nil {
		r.t.Fatal(err)
	}
	return v, ok
}

func (r *relayKeysRig) rotateIfDue(want bool) {
	r.t.Helper()
	got, err := r.kr.RotateIfDue(rotationAlso)
	if err != nil || got != want {
		r.t.Fatalf("RotateIfDue = %v, %v; want %v", got, err, want)
	}
}

func (r *relayKeysRig) epoch() uint32 {
	r.t.Helper()
	e, err := r.kr.CurrentEpoch()
	if err != nil {
		r.t.Fatal(err)
	}
	return e
}

func (r *relayKeysRig) relayRows() int {
	r.t.Helper()
	var n int
	if err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT COUNT(*) FROM epoch_relay_keys`).Scan(&n)
	}); err != nil {
		r.t.Fatal(err)
	}
	return n
}

func (r *relayKeysRig) offers() int {
	r.t.Helper()
	devs, err := r.st.Devices()
	if err != nil {
		r.t.Fatal(err)
	}
	n := 0
	for _, d := range devs {
		if d.KXOffer != nil {
			n++
		}
	}
	return n
}

const week = 7 * 24 * time.Hour

func TestNobodyPaysListNotEmptyNoRotation(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	ph := r.phone()
	r.read(holder(ph, false)) // in a slot, nobody pays
	if v, ok := r.mark(); !ok || v != strconv.FormatInt(r.clock().Unix(), 10) {
		t.Fatalf("mark %q, %v; want set now", v, ok)
	}
	r.advance(13 * 24 * time.Hour) // past the 7-day age, before the hold's end
	r.rotateIfDue(false)
}

func TestNoRotationWithNoReaderOnAnsweredList(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	r.phone()
	stranger := &relayv1.SlotHolder{PhoneDeviceId: "not-linked-here", Paying: true}
	r.read(stranger) // a paying phone, but no linked phone in a slot
	if _, ok := r.mark(); !ok {
		t.Fatal("no mark with no linked reader")
	}
	r.advance(10 * 24 * time.Hour)
	r.rotateIfDue(false)
	r.read() // the empty list: still nobody, since stays
	r.advance(time.Hour)
	r.rotateIfDue(false)
}

// A hub write into a phone's mailbox refused ENTITLEMENT_INACTIVE or
// FORBIDDEN (a refusal, not an account read) leaves the mark alone, so the
// age rotation still runs.
func TestRefusalAloneDoesNotSetServingNobody(t *testing.T) {
	for _, refusal := range []error{transport.ErrEntitlementInactive, transport.ErrForbidden} {
		t.Run(errClass(refusal), func(t *testing.T) {
			r := newRelayKeysRig(t, "relay")
			ph := r.phone()
			d := actions.NewDispatcher()
			applied := 0
			d.Register("test_noop", func(context.Context, actions.Request) actions.Outcome {
				applied++
				return actions.Outcome{Status: wire.StatusApplied}
			}, actions.KindOptions{})
			proc := actions.NewProcessor(actions.Config{
				Store: r.st, Transport: r.tr, Sealer: secure.NewSealer(r.kr), Opener: secure.NewOpener(r.kr, r.kr),
				Keys: r.kr, Dispatcher: d, HubRelayID: "hubrelay", Clock: r.clock,
			})
			if _, err := ph.Act("test_noop"); err != nil {
				t.Fatal(err)
			}
			r.tr.RefuseWrites(ph.Zone(), refusal)
			if _, err := proc.Pass(context.Background()); err != nil {
				t.Fatal(err)
			}
			if applied != 1 {
				t.Fatalf("applied %d, want 1", applied)
			}
			if _, err := ph.Sync(); err != nil {
				t.Fatal(err)
			}
			if len(ph.Echoes) != 0 {
				t.Fatal("the echo was written: the refusal did not happen")
			}
			if _, ok := r.mark(); ok {
				t.Fatal("a refused write set relay_serving_nobody_since")
			}
			r.advance(week)
			r.rotateIfDue(true)
		})
	}
}

func TestFailedReadLeavesServingNobodyAsItWas(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	h := &hubRuntime{st: r.st, kr: r.kr}
	r.read() // set
	before, _ := r.mark()
	r.advance(time.Hour)
	if _, err := h.followed(nil, errors.New("unreachable")); err == nil {
		t.Fatal("a failed read answered")
	}
	if after, ok := r.mark(); !ok || after != before {
		t.Fatalf("a failed read moved the mark: %q → %q", before, after)
	}
	ph := r.phone()
	r.read(holder(ph, true)) // cleared
	if _, err := h.followed(nil, errors.New("unreachable")); err == nil {
		t.Fatal("a failed read answered")
	}
	if _, ok := r.mark(); ok {
		t.Fatal("a failed read set the mark")
	}
}

func TestLeavingTheRelayClearsServingNobody(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	r.read()
	if err := r.kr.RotateToward(identity.ReasonTransportSwitch, false, nil); err != nil {
		t.Fatal(err)
	}
	if _, ok := r.mark(); ok {
		t.Fatal("a rotation toward iCloud kept the mark")
	}
	// Off the relay an answered read writes nothing.
	if err := r.st.SetMeta(state.MetaTransport, "cloudkit"); err != nil {
		t.Fatal(err)
	}
	r.read()
	if _, ok := r.mark(); ok {
		t.Fatal("a read on iCloud set the mark")
	}
}

// Between a switch's rotation toward iCloud and its announce,
// hub_meta.transport still says relay but the current epoch is iCloud's: an
// answered read writes no mark then (the keyring's relay rule).
func TestReadInsideASwitchToICloudWritesNoMark(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	if err := r.kr.RotateToward(identity.ReasonTransportSwitch, false, nil); err != nil {
		t.Fatal(err)
	}
	r.read()
	if _, ok := r.mark(); ok {
		t.Fatal("a read inside the switch window set the mark")
	}
}

func TestRestartWithNoReaderMetaDoesNotRotate(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	r.read()
	r.restart()
	r.advance(13 * 24 * time.Hour)
	r.rotateIfDue(false)
	ph := r.phone()
	r.read(holder(ph, true)) // the first answer after the restart clears it
	if _, ok := r.mark(); ok {
		t.Fatal("a paying linked reader left the mark")
	}
	r.rotateIfDue(true) // the normal age, due at once
}

func TestUnknownListWithoutMetaRotates(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	r.restart() // no read answered since
	r.advance(week)
	r.rotateIfDue(true)
}

// The hold's end: 14 days after the mark, one rotation that derives nothing
// and clears every offer and row; the mark stays, so nothing more rotates.
func holdEnds(t *testing.T, reads func(r *relayKeysRig, ph *hubtest.Phone)) (*relayKeysRig, *hubtest.Phone) {
	t.Helper()
	r := newRelayKeysRig(t, "relay")
	ph := r.phone()
	r.offer(ph)
	if err := r.kr.Rotate(identity.ReasonManual); err != nil { // epoch 2: the phone's keys
		t.Fatal(err)
	}
	r.keybox(ph)
	if !ph.HoldsPair(2) {
		t.Fatal("the phone holds no pair for epoch 2")
	}
	r.offer(ph)
	reads(r, ph)
	r.advance(14*24*time.Hour - time.Second)
	r.rotateIfDue(false)
	if r.relayRows() != 1 || r.offers() != 1 {
		t.Fatal("the hold cleared keys before day 14")
	}
	r.advance(time.Second)
	r.rotateIfDue(true)
	if r.epoch() != 3 || r.relayRows() != 0 || r.offers() != 0 {
		t.Fatalf("day 14: epoch %d, %d rows, %d offers; want 3, 0, 0", r.epoch(), r.relayRows(), r.offers())
	}
	if _, ok := r.mark(); !ok {
		t.Fatal("the day-14 rotation wrote the mark")
	}
	r.advance(30 * 24 * time.Hour)
	r.rotateIfDue(false)
	return r, ph
}

func TestEmptyListHoldEndsAt14DaysRotatesOnceAndClears(t *testing.T) {
	holdEnds(t, func(r *relayKeysRig, _ *hubtest.Phone) { r.read() })
}

func TestNobodyPaysListNotEmptyEndsAt14Days(t *testing.T) {
	holdEnds(t, func(r *relayKeysRig, ph *hubtest.Phone) { r.read(holder(ph, false)) })
}

func TestDay14RotationOnceAcrossRestart(t *testing.T) {
	r, _ := holdEnds(t, func(r *relayKeysRig, _ *hubtest.Phone) { r.read() })
	r.restart()
	r.advance(60 * 24 * time.Hour)
	r.rotateIfDue(false)
	if r.epoch() != 3 {
		t.Fatalf("epoch %d after the restart, want 3", r.epoch())
	}
}

func TestRealPhoneAfterHoldEndRecovers(t *testing.T) {
	r, ph := holdEnds(t, func(r *relayKeysRig, ph *hubtest.Phone) { r.read(holder(ph, false)) })
	if pub, _ := r.kr.KeyboxRecipient(ph.ID()); !bytes.Equal(pub.Bytes(), ph.Device().AgreementKey) {
		t.Fatal("the keybox after the hold is not sealed to dev_kx")
	}
	kk := r.keybox(ph) // static for epoch 3
	if kk.Epoch != 3 || kk.RelayKX != nil || kk.PreviousRelayKX != nil || ph.HoldsPair(3) {
		t.Fatalf("after the hold: epoch %d, relay_kx %+v / %+v, pair 3 held %v", kk.Epoch, kk.RelayKX, kk.PreviousRelayKX, ph.HoldsPair(3))
	}
	r.toPhone(ph, 0) // a hub control in epoch 3 opens on static keys

	// The phone pays again: the mark clears, its new offer counts at the
	// next rotation, and that epoch is ephemeral again.
	r.read(holder(ph, true))
	r.offer(ph)
	r.rotateIfDue(true)
	r.keybox(ph)
	if !ph.HoldsPair(4) {
		t.Fatal("the phone holds no pair for epoch 4")
	}
	r.toPhone(ph, 0)
}

// toPhone seals a hub control for ph in epoch (0 = current) and checks the
// phone opens it.
func (r *relayKeysRig) toPhone(ph *hubtest.Phone, epoch uint32) {
	r.t.Helper()
	s := secure.NewSealer(r.kr)
	if epoch != 0 {
		s = s.InEpoch(epoch)
	}
	plain := "c-" + strconv.FormatInt(r.clock().UnixNano(), 10)
	name, err := s.WireName(secure.ZoneRelay, plain)
	if err != nil {
		r.t.Fatal(err)
	}
	rec, err := s.ToPhone(ph.Zone(), ph.ID(), name, "control", plain, []byte(`{"kind":"resend_from"}`))
	if err != nil {
		r.t.Fatal(err)
	}
	if _, err := ph.Open(name, rec.Envelope()); err != nil {
		r.t.Fatalf("the phone does not open the hub's control: %v", err)
	}
}

func TestRotateIfDueSkipsWhileASwitchIsRunningOnTheHub(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	if err := r.st.SetMeta("transport_switch", `{"id":"s","from":"relay","target":"cloudkit","by":"d","at":"2026-11-01T00:00:00Z"}`); err != nil {
		t.Fatal(err)
	}
	r.advance(2 * week)
	r.rotateIfDue(false)
	if err := r.st.SetMeta("transport_switch", `{"id":"s","from":"relay","target":"cloudkit","by":"d","at":"2026-11-01T00:00:00Z","epoch":1,"done":true}`); err != nil {
		t.Fatal(err)
	}
	r.rotateIfDue(true) // a finished switch blocks nothing
}

func epochRows(t *testing.T, st *state.Store) []string {
	t.Helper()
	var out []string
	if err := st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		rows, err := tx.Query(`SELECT quote(epoch), quote(sealed_keys), quote(created_at), quote(first_seq), quote(retired_at),
			quote(reason), quote(retire_after), quote(on_relay) FROM hub_epochs ORDER BY epoch`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var cols [8]string
			if err := rows.Scan(&cols[0], &cols[1], &cols[2], &cols[3], &cols[4], &cols[5], &cols[6], &cols[7]); err != nil {
				return err
			}
			out = append(out, cols[0]+"|"+cols[1]+"|"+cols[2]+"|"+cols[3]+"|"+cols[4]+"|"+cols[5]+"|"+cols[6]+"|"+cols[7])
		}
		return rows.Err()
	}); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestICloudHubHousekeepingIsAsToday(t *testing.T) {
	r := newRelayKeysRig(t, "cloudkit")
	r.advance(identity.RotationAge)
	r.rotateIfDue(true)
	r.advance(2 * week) // epoch 1 past its retention
	if err := r.kr.RetireOld(); err != nil {
		t.Fatal(err)
	}
	before := epochRows(t, r.st)
	if n, err := r.kr.EraseExpired(); err != nil || n != 0 {
		t.Fatalf("EraseExpired on iCloud = %d, %v", n, err)
	}
	if after := epochRows(t, r.st); len(after) != len(before) || after[0] != before[0] || after[1] != before[1] {
		t.Fatalf("an iCloud hub's epoch rows changed:\n%v\n%v", before, after)
	}
}

// TestStuckRotationLogsOncePerDay: a relay hub whose epoch is past 14 days
// (the weekly rotation did not happen: held, or serving nobody) logs a line
// once a day; a younger epoch or a hub off the relay logs nothing.
func TestStuckRotationLogsOncePerDay(t *testing.T) {
	var buf strings.Builder
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	r := newRelayKeysRig(t, "relay")
	var note stuckRotationNote
	note.check(r.kr, r.st, r.clock())
	if buf.Len() != 0 {
		t.Fatalf("a fresh epoch logged: %q", buf.String())
	}
	r.advance(15 * 24 * time.Hour)
	note.check(r.kr, r.st, r.clock())
	note.check(r.kr, r.st, r.clock())
	if n := strings.Count(buf.String(), "epoch rotation is stuck"); n != 1 {
		t.Fatalf("logged %d times in one day, want 1: %q", n, buf.String())
	}
	r.advance(23 * time.Hour)
	note.check(r.kr, r.st, r.clock())
	if n := strings.Count(buf.String(), "epoch rotation is stuck"); n != 1 {
		t.Fatalf("logged again within the day: %d", n)
	}
	r.advance(2 * time.Hour)
	note.check(r.kr, r.st, r.clock())
	if n := strings.Count(buf.String(), "epoch rotation is stuck"); n != 2 {
		t.Fatalf("logged %d times after a day, want 2", n)
	}
	if !strings.Contains(buf.String(), "15 days") || strings.Contains(buf.String(), r.dir) {
		t.Fatalf("line should carry the age and no path: %q", buf.String())
	}

	// Off the relay: the 90-day cadence, nothing to say at 15 days.
	buf.Reset()
	c := newRelayKeysRig(t, "cloudkit")
	c.advance(15 * 24 * time.Hour)
	var cn stuckRotationNote
	cn.check(c.kr, c.st, c.clock())
	if buf.Len() != 0 {
		t.Fatalf("a cloudkit hub logged: %q", buf.String())
	}
}
