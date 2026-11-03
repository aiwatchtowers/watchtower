package hub

import (
	"context"
	"database/sql"
	"slices"
	"testing"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/policy/policytest"
)

// ownerOffRig runs an enabled hub with a linked phone until its heartbeat
// is published; it returns the rig and the data zone.
func ownerOffRig(t *testing.T) (*rig, string) {
	t.Helper()
	policytest.Set(t, map[string]any{"MobileSync": "allowed"})
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	linkPhoneDirectly(t, dir)
	r := newRig(t, dir)
	r.start(r.options())
	r.waitState(StateRunning, "")
	s, err := ReadStatus(dir)
	if err != nil {
		t.Fatal(err)
	}
	data := transport.DataZone(s.RelayDeviceID)
	eventually(t, 10*time.Second, "the heartbeat published", func() bool {
		return slices.Contains(liveRecords(t, r.fake, data), "heartbeat")
	})
	return r, data
}

func switchHub(t *testing.T, dir, op string) {
	t.Helper()
	c, err := Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	if a, err := c.Do(ControlRequest{Op: op}); err != nil || !a.OK {
		t.Fatalf("%s: %+v, %v", op, a, err)
	}
}

func disableHub(t *testing.T, dir string) {
	t.Helper()
	switchHub(t, dir, OpDisable)
}

// TestOwnerOffDeletesWhatWasPublished: the owner's off deletes what the hub
// published (as the Swift hub's deleteZonesForHubOff and POLICY-03's wipe),
// unlinks the phones (ask #956: the phone's row goes, it reads revoked) and
// says so in status (off_delete ok, no phones).
func TestOwnerOffDeletesWhatWasPublished(t *testing.T) {
	r, data := ownerOffRig(t)
	disableHub(t, r.dir)
	r.waitState(StateOff, ReasonDisabled)
	if got := liveRecords(t, r.fake, data); len(got) != 0 {
		t.Fatalf("the data zone still holds %v after the owner's off", got)
	}
	eventually(t, 10*time.Second, "off_delete ok, no phones", func() bool {
		s := r.rec.last()
		return s.OffDelete.State == OffDeleteOK && s.OffDelete.At != "" && s.Phones == 0
	})
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(r.dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	if devices, err := st.Devices(); err != nil || len(devices) != 0 {
		t.Fatalf("the phone stayed linked after the owner's off: %v %v", devices, err)
	}
	var revoked int
	if err := st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT COUNT(*) FROM revoked_devices`).Scan(&revoked)
	}); err != nil || revoked != 1 {
		t.Fatalf("the unlinked phone's revoked row: %d, %v", revoked, err)
	}
}

// TestOwnerOffThenOnNeedsAFreshPairing: after the owner's off, turning on
// again runs the same hub (its identity kept, as the Swift hub's Keychain
// identity) with no linked phone, so the phone has to pair again.
func TestOwnerOffThenOnNeedsAFreshPairing(t *testing.T) {
	r, _ := ownerOffRig(t)
	hubID := r.rec.last().HubID
	disableHub(t, r.dir)
	r.waitState(StateOff, ReasonDisabled)
	switchHub(t, r.dir, OpEnable)
	r.waitState(StateRunning, "")
	if s := r.rec.last(); s.HubID != hubID || s.Phones != 0 {
		t.Fatalf("after off and on: hub %q (was %q), %d phones", s.HubID, hubID, s.Phones)
	}
}

// TestOwnerOffRetriesAFailedDelete: a wipe that fails reads failed in
// status and is tried again while the hub stays off, until nothing
// published is left.
func TestOwnerOffRetriesAFailedDelete(t *testing.T) {
	prev := offWipeRetry
	offWipeRetry = 100 * time.Millisecond
	t.Cleanup(func() { offWipeRetry = prev })
	r, data := ownerOffRig(t)
	r.fake.FailNext("delete", transport.ErrUnavailable)
	r.fake.FailNext("delete", transport.ErrUnavailable)
	disableHub(t, r.dir)
	r.waitState(StateOff, ReasonDisabled)
	eventually(t, 10*time.Second, "off_delete failed", func() bool {
		return r.rec.last().OffDelete.State == OffDeleteFailed
	})
	if got := liveRecords(t, r.fake, data); len(got) == 0 {
		t.Fatal("the failed delete deleted anyway")
	}
	eventually(t, 10*time.Second, "the retry deleted it", func() bool {
		return len(liveRecords(t, r.fake, data)) == 0 && r.rec.last().OffDelete.State == OffDeleteOK
	})
}

// TestOffDeleteIsEmptyWhileOn: off_delete says nothing while the owner's
// switch is on.
func TestOffDeleteIsEmptyWhileOn(t *testing.T) {
	r, _ := ownerOffRig(t)
	if d := r.rec.last().OffDelete; d != (OffDeleteStatus{}) {
		t.Fatalf("off_delete while on: %+v", d)
	}
}

// TestOffWipeBacksOffWhileRecordsStay: a stopped retry that leaves records
// doubles its wait up to the cap (a permanently refused record does not
// start a desktop host's bridge every minute); a read failure is logged
// once per streak and keeps the base wait.
func TestOffWipeBacksOffWhileRecordsStay(t *testing.T) {
	prevRetry, prevMax := offWipeRetry, offWipeMaxBackoff
	offWipeRetry, offWipeMaxBackoff = time.Second, 4*time.Second
	t.Cleanup(func() { offWipeRetry, offWipeMaxBackoff = prevRetry, prevMax })
	r, data := ownerOffRig(t)
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(r.dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	// The relay refuses every delete: what was published stays.
	for i := 0; i < 4; i++ {
		r.fake.FailNext("delete", transport.ErrForbidden)
	}
	if len(liveRecords(t, r.fake, data)) == 0 {
		t.Fatal("nothing published to wipe")
	}
	s := &supervisor{o: r.options().withDefaults(), st: st, offWipeBackoff: offWipeRetry} // as ownerOff left it
	var waits []time.Duration
	for i := 0; i < 4; i++ {
		s.offDeleteFailed = true
		before := time.Now()
		s.retryOffWipe(context.Background())
		waits = append(waits, s.nextOffWipe.Sub(before).Round(time.Second))
	}
	if want := []time.Duration{2 * time.Second, 4 * time.Second, 4 * time.Second, 4 * time.Second}; !slices.Equal(waits, want) {
		t.Fatalf("waits %v, want %v", waits, want)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	s.offWipeBackoff = 4 * time.Second
	s.retryOffWipe(context.Background()) // the store is closed: the read fails
	if !s.offWipeReadLogged || s.offWipeBackoff != time.Second {
		t.Fatalf("a failed read: logged %v, backoff %v", s.offWipeReadLogged, s.offWipeBackoff)
	}
}
