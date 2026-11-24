package link

import (
	"testing"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// slotLinked is the phones hub_meta relay_slot_links lists as linked
// through a pairing slot.
func (r *rig) slotLinked() map[string]bool {
	r.t.Helper()
	got, err := r.st.RelaySlotLinked()
	if err != nil {
		r.t.Fatal(err)
	}
	return got
}

func (r *rig) wantSlotLinked(p phone, want bool) {
	r.t.Helper()
	if got := r.slotLinked()[p.id.String()]; got != want {
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
	r.handle(a, code.Nonce)
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

// A phone that re-links over CloudKit is no slot link any more, also when
// its slot request was replaced by a CloudKit hello before the confirm.
func TestARelinkOverCloudKitDropsTheSlotMark(t *testing.T) {
	r := newCKRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	r.wantSlotLinked(a, true)
	r.advance(time.Minute)
	r.linkCK(a, r.issueCK().Nonce)
	r.wantSlotLinked(a, false)

	// A slot hello, then a CloudKit hello of the same phone under new keys
	// and the same code: the request the owner confirms came over CloudKit.
	c := newPhone(t)
	code := r.issue()
	r.handle(c, code.Nonce)
	r.linkCK(phoneWith(t, c.sig), code.Nonce)
	r.wantSlotLinked(c, false)
}

// A slot request refused by the owner, or expired, leaves no mark.
func TestARefusedOrExpiredSlotRequestLeavesNoMark(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.handle(a, r.issue().Nonce)
	if err := r.c.Confirm(a.id.String(), r.code(a), false); err != nil {
		t.Fatal(err)
	}
	if row := r.slotRow(); row != "" {
		t.Fatalf("a refused request left %q", row)
	}

	b := newPhone(t)
	r.handle(b, r.issue().Nonce)
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
	r.confirmLinked(a)
	r.wantSlotLinked(a, true)
	if err := r.c.Unlink(a.id.String()); err != nil {
		t.Fatal(err)
	}
	if row := r.slotRow(); row != "" {
		t.Fatalf("an unlinked phone left %q", row)
	}
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
	r.confirmLinked(a)
	r.wantSlotLinked(a, true)
}
