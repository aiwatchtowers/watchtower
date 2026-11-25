package link

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// slotLinked is the phones hub_meta relay_slot_links lists as linked
// through a pairing slot, with their link nonces.
func (r *rig) slotLinked() map[string]string {
	r.t.Helper()
	got, err := r.st.RelaySlotLinked()
	if err != nil {
		r.t.Fatal(err)
	}
	return got
}

// wantSlotLinked checks p's mark, which counts only under the link nonce its
// devices row carries.
func (r *rig) wantSlotLinked(p phone, want bool) {
	r.t.Helper()
	var got bool
	err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		nonce, _, err := state.LinkNonceTx(tx, p.id.String())
		if err != nil {
			return err
		}
		got, err = state.RelaySlotLinkedTx(tx, strings.ToLower(p.id.String()), nonce)
		return err
	})
	if err != nil {
		r.t.Fatal(err)
	}
	if got != want {
		r.t.Fatalf("%s slot-linked %v, want %v (row %v)", p.id, got, want, r.slotLinked())
	}
}

// slotRow is the raw row ("" when absent).
func (r *rig) slotRow() string {
	r.t.Helper()
	v, _, err := r.st.Meta(state.MetaRelaySlotLinks)
	if err != nil {
		r.t.Fatal(err)
	}
	return v
}

// slotHandle is p's hello read from a pairing slot, proving p's relay id
// (#2387; the relay_auth key is p's signing key, as hubtest's phone has it,
// so a re-send proves the same id).
func (r *rig) slotHandle(p phone, nonce string, edit ...func(*wire.DeviceHello)) Pending {
	r.t.Helper()
	return r.handle(p, nonce, append([]func(*wire.DeviceHello){withRelayProof(p.sig, r.kr.HubID(), p)}, edit...)...)
}

// confirmSlotLinked is confirmLinked through a pairing slot with a proven
// relay id: a Relay link.
func (r *rig) confirmSlotLinked(p phone) {
	r.t.Helper()
	code := r.issue()
	if got := r.slotHandle(p, code.Nonce); got.Code == "" {
		r.t.Fatalf("hello not waiting: %+v", got)
	}
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		r.t.Fatalf("Confirm: %v", err)
	}
	if !r.linked(p) {
		r.t.Fatal("not linked after Confirm")
	}
}

// unreadableOwner makes the Mac's iCloud user unknown, so a private hello
// written as the current user links with no iCloud user (no route).
func (r *ckRig) unreadableOwner() {
	r.c.ck.mu.Lock()
	r.c.ck.owner = ""
	r.c.ck.mu.Unlock()
	r.s.setFailing("owner_user")
}

// A request through a pairing slot is marked when saved and promoted at the
// confirm; a private CloudKit link whose owner could not be read (no iCloud
// user either) is never marked.
func TestASlotLinkIsRecordedAndACloudKitLinkIsNot(t *testing.T) {
	r := newCKRig(t)
	a, b := newPhone(t), newPhone(t)
	code := r.issue()
	r.slotHandle(a, code.Nonce)
	if row := r.slotRow(); row == "" {
		t.Fatal("the slot request left no mark")
	}
	r.wantSlotLinked(a, false) // waiting is not linked
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	r.wantSlotLinked(a, true)

	ck := r.issueCK()
	r.unreadableOwner()
	r.linkCK(b, ck.Nonce)
	if u := r.userOf(b); u != "" {
		t.Fatalf("the CloudKit link carries user %q, want none for this case", u)
	}
	r.wantSlotLinked(b, false)
	r.wantSlotLinked(a, true)
}

// The route is part of a request: a hello identical but for the route it
// came by (same phone, keys, code and relay id) replaces the request, so the
// confirm links the phone by the route of the last hello, either way.
func TestOnlyTheRouteChangingReplacesTheRequest(t *testing.T) {
	r := newCKRig(t)
	a := newPhone(t)
	code := r.issue()
	r.slotHandle(a, code.Nonce)                                     // through a slot
	r.linkCK(a, code.Nonce, withRelayProof(a.sig, r.kr.HubID(), a)) // the same hello over CloudKit, then Link
	r.wantSlotLinked(a, false)
	if r.userOf(a) == "" {
		t.Fatal("the CloudKit request did not replace the slot one")
	}

	b := newPhone(t)
	code = r.issue()
	if got, err := r.ckHello(b, code.Nonce, withRelayProof(b.sig, r.kr.HubID(), b)); err != nil || got.Code == "" {
		t.Fatalf("CloudKit hello not waiting: %+v %v", got, err)
	}
	r.slotHandle(b, code.Nonce) // the same hello through a slot
	if err := r.c.Confirm(b.id.String(), r.code(b), true); err != nil {
		t.Fatal(err)
	}
	r.wantSlotLinked(b, true)
}

// A route change that finds the code's confirm nonces spent cannot be saved:
// the superseded request and its slot mark go with the refusal, so nothing of
// the old route can be confirmed; the other phones' requests stay.
func TestARouteChangePastTheCapRemovesTheOldRequest(t *testing.T) {
	r := newCKRig(t)
	a, b, c := newPhone(t), newPhone(t), newPhone(t)
	code := r.issue()
	for _, p := range []phone{a, b, c} { // MaxNoncesPerCode slot requests
		if got := r.slotHandle(p, code.Nonce); got.Code == "" {
			t.Fatalf("not waiting: %+v", got)
		}
	}
	got, err := r.ckHello(a, code.Nonce, withRelayProof(a.sig, r.kr.HubID(), a)) // a's same hello over CloudKit
	if err != nil {
		t.Fatal(err)
	}
	if got.Refused != wire.RefusedTooManyRequests {
		t.Fatalf("the capped route change answered %+v, want too_many_requests", got)
	}
	if ids := pendingIDs(t, r.c); !slices.Equal(ids, sortedIDs(b, c)) {
		t.Fatalf("waiting %v, want only b and c", ids)
	}
	if err := r.c.Confirm(a.id.String(), "0000", true); !errors.Is(err, ErrNoRequest) {
		t.Fatalf("the superseded request could still be confirmed: %v", err)
	}
	if strings.Contains(r.slotRow(), strings.ToUpper(a.id.String())) {
		t.Fatalf("a's slot mark stayed: %s", r.slotRow())
	}
}

// A route that cannot be read (an undecodable relay_slot_links row) is
// unknown, never "unchanged": the same hello replaces the request (drawing a
// nonce) and the row is written whole again.
func TestAnUnreadableRouteReplacesTheRequest(t *testing.T) {
	r := newCKRig(t)
	a := newPhone(t)
	code := r.issueCK()
	if got, err := r.ckHello(a, code.Nonce); err != nil || got.Code == "" {
		t.Fatalf("not waiting: %+v %v", got, err)
	}
	if err := r.st.SetMeta(state.MetaRelaySlotLinks, "{"); err != nil {
		t.Fatal(err)
	}
	if got, err := r.ckHello(a, code.Nonce); err != nil || got.Code == "" {
		t.Fatalf("the resent hello is not waiting: %+v %v", got, err)
	}
	var drawn int
	if err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT confirm_nonces_drawn FROM link_codes WHERE nonce = ?`, code.Nonce).Scan(&drawn)
	}); err != nil {
		t.Fatal(err)
	}
	if drawn != 2 {
		t.Fatalf("%d nonces drawn, want 2: the request was kept as unchanged", drawn)
	}
	if _, err := r.st.RelaySlotLinked(); err != nil {
		t.Fatalf("the row was not written whole again: %v", err)
	}
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	r.wantSlotLinked(a, false)
	if r.userOf(a) == "" {
		t.Fatal("the CloudKit link lost its iCloud user")
	}
}

// A re-pairing request of a phone already linked through a slot that is
// refused, expires, or meets its code already used by this phone leaves the
// phone's link and its slot mark as they were.
func TestARelinkRequestThatEndsKeepsTheSlotMark(t *testing.T) {
	for _, how := range []string{"refused", "expired", "used_by_this_device"} {
		t.Run(how, func(t *testing.T) {
			r := newRig(t)
			a := newPhone(t)
			r.confirmSlotLinked(a)
			r.wantSlotLinked(a, true)
			code := r.issue()
			if got := r.slotHandle(a, code.Nonce); got.Code == "" {
				t.Fatalf("the re-pairing request is not waiting: %+v", got)
			}
			switch how {
			case "refused":
				if err := r.c.Confirm(a.id.String(), r.code(a), false); err != nil {
					t.Fatal(err)
				}
			case "expired":
				r.advance(wire.LinkLifetime + time.Second)
				if err := r.c.Sweep(); err != nil {
					t.Fatal(err)
				}
			case "used_by_this_device":
				if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
					_, err := tx.Exec(`UPDATE link_codes SET used_by_device = ? WHERE nonce = ?`, a.id.String(), code.Nonce)
					return err
				}); err != nil {
					t.Fatal(err)
				}
				if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
					t.Fatal(err)
				}
			}
			if ids := pendingIDs(t, r.c); len(ids) != 0 {
				t.Fatalf("still waiting: %v", ids)
			}
			if !r.linked(a) {
				t.Fatal("the link went")
			}
			r.wantSlotLinked(a, true)
			if row := r.slotRow(); strings.Contains(row, `"pending"`) {
				t.Fatalf("the request's mark stayed: %s", row)
			}
		})
	}
}

// A phone that re-links over CloudKit is no slot link any more, also when
// its slot request was replaced by a CloudKit hello before the confirm.
func TestARelinkOverCloudKitDropsTheSlotMark(t *testing.T) {
	r := newCKRig(t)
	a := newPhone(t)
	r.confirmSlotLinked(a)
	r.wantSlotLinked(a, true)
	r.advance(time.Minute)
	r.linkCK(a, r.issueCK().Nonce)
	r.wantSlotLinked(a, false)

	// A slot hello, then a CloudKit hello of the same phone under new keys
	// and the same code: the request the owner confirms came over CloudKit.
	c := newPhone(t)
	code := r.issue()
	r.slotHandle(c, code.Nonce)
	r.linkCK(phoneWith(t, c.sig), code.Nonce)
	r.wantSlotLinked(c, false)
}

// A slot request refused by the owner, or expired, leaves no mark.
func TestARefusedOrExpiredSlotRequestLeavesNoMark(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.slotHandle(a, r.issue().Nonce)
	if err := r.c.Confirm(a.id.String(), r.code(a), false); err != nil {
		t.Fatal(err)
	}
	if row := r.slotRow(); row != "" {
		t.Fatalf("a refused request left %q", row)
	}

	b := newPhone(t)
	r.slotHandle(b, r.issue().Nonce)
	r.advance(wire.LinkLifetime + time.Second)
	if err := r.c.Sweep(); err != nil {
		t.Fatal(err)
	}
	if row := r.slotRow(); row != "" {
		t.Fatalf("an expired request left %q", row)
	}
}

// An unlink takes the phone out of the row.
func TestUnlinkDropsTheSlotMark(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmSlotLinked(a)
	r.wantSlotLinked(a, true)
	if err := r.c.Unlink(a.id.String()); err != nil {
		t.Fatal(err)
	}
	if row := r.slotRow(); row != "" {
		t.Fatalf("an unlinked phone left %q", row)
	}
}

// A mark whose link nonce the phone's row no longer carries (a re-link by a
// writer that never updated the record) does not count, and the next write
// of the row drops it.
func TestAStaleSlotMarkIsPrunedByTheNextWrite(t *testing.T) {
	r := newRig(t)
	a, b := newPhone(t), newPhone(t)
	r.confirmSlotLinked(a)
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE devices SET link_nonce = 'relinked' WHERE device_id = ? COLLATE NOCASE`, a.id.String())
		return err
	}); err != nil {
		t.Fatal(err)
	}
	r.wantSlotLinked(a, false)
	r.confirmSlotLinked(b)
	if _, ok := r.slotLinked()[a.id.String()]; ok {
		t.Fatalf("the stale mark stayed: %s", r.slotRow())
	}
	r.wantSlotLinked(b, true)
}

// An undecodable row reads as an error, and the next write replaces it with
// its own change (losing entries only takes candidates away).
func TestACorruptSlotRowIsReplacedByTheNextWrite(t *testing.T) {
	r := newRig(t)
	if err := r.st.SetMeta(state.MetaRelaySlotLinks, "{"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.st.RelaySlotLinked(); err == nil {
		t.Fatal("a corrupt row read as a set")
	}
	a := newPhone(t)
	r.confirmSlotLinked(a)
	r.wantSlotLinked(a, true)
}

// Every code this Mac issues, relay or CloudKit, says it moves itself to
// Relay when a paying phone links over a slot (the phone's route rule reads
// relay_switch).
func TestEveryCodeSaysTheMacMovesToRelay(t *testing.T) {
	r := newCKRig(t)
	relay, relayURL, err := r.c.Issue()
	if err != nil {
		t.Fatal(err)
	}
	ck, ckURL, err := r.c.IssueCloudKit(r.ctx, r.s)
	if err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		p   wire.LinkPayload
		url string
	}{"relay": {relay, relayURL}, "cloudkit": {ck, ckURL}} {
		parsed, err := wire.ParseLinkURL(c.url)
		if err != nil {
			t.Fatal(err)
		}
		if !c.p.RelaySwitch || !parsed.RelaySwitch {
			t.Errorf("%s code: relay_switch %v, parsed %v", name, c.p.RelaySwitch, parsed.RelaySwitch)
		}
	}
}
