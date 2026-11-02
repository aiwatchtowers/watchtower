package hub

import (
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

func disableHub(t *testing.T, dir string) {
	t.Helper()
	c, err := Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	if a, err := c.Do(ControlRequest{Op: OpDisable}); err != nil || !a.OK {
		t.Fatalf("disable: %+v, %v", a, err)
	}
}

// TestOwnerOffDeletesWhatWasPublished: the owner's off deletes what the hub
// published (as the Swift hub's deleteZonesForHubOff and POLICY-03's wipe),
// keeps the linked phones, and says so in status (off_delete ok).
func TestOwnerOffDeletesWhatWasPublished(t *testing.T) {
	r, data := ownerOffRig(t)
	disableHub(t, r.dir)
	r.waitState(StateOff, ReasonDisabled)
	if got := liveRecords(t, r.fake, data); len(got) != 0 {
		t.Fatalf("the data zone still holds %v after the owner's off", got)
	}
	eventually(t, 10*time.Second, "off_delete ok", func() bool {
		d := r.rec.last().OffDelete
		return d.State == OffDeleteOK && d.At != ""
	})
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(r.dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	if devices, err := st.Devices(); err != nil || len(devices) != 1 {
		t.Fatalf("the linked phone went with the off: %v %v", devices, err)
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
