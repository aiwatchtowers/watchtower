package link

import (
	"context"
	"database/sql"
	"strings"
	"testing"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// #2387 review: a proven request re-sent without its proof (same keys and
// relay id) is a new request that loses the mark.
func TestASlotHelloLosingItsProofReplacesItsRequest(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	p := newPhone(t)
	key := newRelayKey(t)
	first := r.slotHello("slot1", p, code.Nonce, withRelayProof(key, r.kr.HubID(), p))
	if !first.OverRelay {
		t.Fatalf("the proven hello's sas: %+v", first)
	}
	again := r.slotHello("slot2", p, code.Nonce, withRelayID(relayIDOf(key)))
	if again.OverRelay || again.Request == first.Request {
		t.Fatalf("the unproven re-send's sas: %+v (first %+v)", again, first)
	}
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		t.Fatal(err)
	}
	r.wantSlotLinked(p, false)
}

// #2387 review: a proven slot hello takes its relay id from a row that only
// claims it (an older phone's unproven hello, or a stale row), as a proven
// device record does; an unproven one never takes it.
func TestAProvenSlotHelloTakesItsRelayIDFromAClaim(t *testing.T) {
	r := newRig(t)
	key := newRelayKey(t)
	id := relayIDOf(key)
	claimer := r.linkPhone(withRelayID(id)) // unproven, the id was free
	if got, _ := r.relayIDOf(claimer); got != id {
		t.Fatalf("the claim was not stored: %q", got)
	}

	late := newPhone(t) // a second unproven claim never takes it
	r.slotHello("slot1", late, r.issue().Nonce, withRelayID(id))
	if err := r.c.Confirm(late.id.String(), r.code(late), true); err != nil {
		t.Fatal(err)
	}
	if got, _ := r.relayIDOf(late); got != "" {
		t.Fatalf("an unproven hello took a held id: %q", got)
	}

	owner := newPhone(t)
	if ev := r.slotHello("slot2", owner, r.issue().Nonce, withRelayProof(key, r.kr.HubID(), owner)); !ev.OverRelay {
		t.Fatalf("the proven hello's sas: %+v", ev)
	}
	if err := r.c.Confirm(owner.id.String(), r.code(owner), true); err != nil {
		t.Fatal(err)
	}
	if got, _ := r.relayIDOf(owner); got != id {
		t.Fatalf("the proven link has relay id %q, want the proven one", got)
	}
	if got, _ := r.relayIDOf(claimer); got != "" {
		t.Fatalf("the claimer kept the id: %q", got)
	}
	r.wantSlotLinked(owner, true)
}

// #2387 review: the route and the mark are apart. An unproven hello through a
// slot and then the same hello over CloudKit is a route change (the CloudKit
// request replaces it and keeps its verified iCloud user), and the other way
// round the slot hello replaces the CloudKit request.
func TestAnUnprovenSlotHelloStillCountsAsTheSlotRoute(t *testing.T) {
	const user = "_colleague-a"
	same := func(id string) []func(*wire.DeviceHello) {
		return []func(*wire.DeviceHello){withRelayID(id), sharedHello(user)}
	}
	drawn := func(r *ckRig, nonce string) int {
		var n int
		if err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
			return tx.QueryRow(`SELECT confirm_nonces_drawn FROM link_codes WHERE nonce = ?`, nonce).Scan(&n)
		}); err != nil {
			t.Fatal(err)
		}
		return n
	}
	t.Run("slot then CloudKit", func(t *testing.T) {
		r := newCKRig(t)
		r.s.join(user)
		p, code, id := newPhone(t), r.issue(), relayID(t)
		r.handle(p, code.Nonce, same(id)...)
		if got, err := r.ckHello(p, code.Nonce, same(id)...); err != nil || got.Code == "" {
			t.Fatalf("CloudKit hello not waiting: %+v %v", got, err)
		}
		if n := drawn(r, code.Nonce); n != 2 {
			t.Fatalf("%d nonces drawn, want 2: the CloudKit hello read as unchanged", n)
		}
		if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
			t.Fatal(err)
		}
		if got := r.userOf(p); got != user {
			t.Fatalf("the CloudKit link lost its iCloud user: %q", got)
		}
		r.wantSlotLinked(p, false)
	})
	t.Run("CloudKit then slot", func(t *testing.T) {
		r := newCKRig(t)
		r.s.join(user)
		p, code, id := newPhone(t), r.issue(), relayID(t)
		if got, err := r.ckHello(p, code.Nonce, same(id)...); err != nil || got.Code == "" {
			t.Fatalf("CloudKit hello not waiting: %+v %v", got, err)
		}
		r.handle(p, code.Nonce, same(id)...)
		if n := drawn(r, code.Nonce); n != 2 {
			t.Fatalf("%d nonces drawn, want 2: the slot hello read as unchanged", n)
		}
		if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
			t.Fatal(err)
		}
		if got := r.userOf(p); got != "" {
			t.Fatalf("the slot link kept the CloudKit user %q", got)
		}
		r.wantSlotLinked(p, false)
	})
}

// #2387 review: a v1 row (no "v"), written by the builds between #2191 and
// #2387, keeps its pending entries as slot requests, unproven: the route
// still counts, so the same hello over CloudKit replaces the request and
// binds its iCloud user, and nothing it marked is promoted.
func TestALegacyPendingEntryKeepsItsRouteUnproven(t *testing.T) {
	const user = "_colleague-a"
	r := newCKRig(t)
	r.s.join(user)
	p, code, rid := newPhone(t), r.issue(), relayID(t)
	same := []func(*wire.DeviceHello){withRelayID(rid), sharedHello(user)}
	r.handle(p, code.Nonce, same...)
	id := strings.ToUpper(p.id.String())
	if err := r.st.SetMeta(state.MetaRelaySlotLinks, `{"pending":{"`+id+`":"`+code.Nonce+`"}}`); err != nil {
		t.Fatal(err)
	}
	if got, err := r.ckHello(p, code.Nonce, same...); err != nil || got.Code == "" {
		t.Fatalf("CloudKit hello not waiting: %+v %v", got, err)
	}
	var drawn int
	if err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT confirm_nonces_drawn FROM link_codes WHERE nonce = ?`, code.Nonce).Scan(&drawn)
	}); err != nil {
		t.Fatal(err)
	}
	if drawn != 2 {
		t.Fatalf("%d nonces drawn, want 2: the legacy slot route read as CloudKit", drawn)
	}
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		t.Fatal(err)
	}
	if got := r.userOf(p); got != user {
		t.Fatalf("the CloudKit link lost its iCloud user: %q", got)
	}
	r.wantSlotLinked(p, false)

	// A v1 waiting slot request confirmed as it is: linked, not a Relay link.
	q, code2 := newPhone(t), r.issue()
	r.handle(q, code2.Nonce, withRelayID(relayID(t)))
	qid := strings.ToUpper(q.id.String())
	if err := r.st.SetMeta(state.MetaRelaySlotLinks, `{"pending":{"`+qid+`":"`+code2.Nonce+`"}}`); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Confirm(q.id.String(), r.code(q), true); err != nil {
		t.Fatal(err)
	}
	r.wantSlotLinked(q, false)
}

// #2387 review: a v1 row's linked marks were never proven: they read as no
// Relay link, and the next write drops them, logging it once.
func TestALegacyLinkedMarkIsDroppedOnce(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newRig(t)
	p := r.linkPhone()
	id := strings.ToUpper(p.id.String())
	nonce := r.linkNonceOf(p)
	if err := r.st.SetMeta(state.MetaRelaySlotLinks, `{"linked":{"`+id+`":"`+nonce+`"}}`); err != nil {
		t.Fatal(err)
	}
	if got, err := r.st.RelaySlotLinked(); err != nil || len(got) != 0 {
		t.Fatalf("a legacy linked mark read as %v %v", got, err)
	}
	r.wantSlotLinked(p, false)
	r.linkPhone() // a write
	r.linkPhone() // another one, on the v2 row
	if row := r.slotRow(); strings.Contains(row, id) {
		t.Fatalf("the legacy mark survived the next write: %s", row)
	}
	if n := strings.Count(sink.String(), "of an older build dropped"); n != 1 {
		t.Fatalf("the drop logged %d times, want once: %s", n, sink.String())
	}
}

// linkNonceOf is p's devices.link_nonce.
func (r *rig) linkNonceOf(p phone) string {
	r.t.Helper()
	var nonce string
	if err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		var err error
		nonce, _, err = state.LinkNonceTx(tx, p.id.String())
		return err
	}); err != nil {
		r.t.Fatal(err)
	}
	return nonce
}

// #2387 review: a row corrupted between the hello and the confirm proves
// nothing: the request still links, unproven, with no mark, and the row is
// written whole again.
func TestAConfirmOverACorruptSlotRowLinksUnmarked(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	p := newPhone(t)
	r.slotHello("slot1", p, code.Nonce, withRelayProof(newRelayKey(t), r.kr.HubID(), p))
	if err := r.st.SetMeta(state.MetaRelaySlotLinks, "{"); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		t.Fatal(err)
	}
	if !r.linked(p) {
		t.Fatal("not linked")
	}
	r.wantSlotLinked(p, false)
}
