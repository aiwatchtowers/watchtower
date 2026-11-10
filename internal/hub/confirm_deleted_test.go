package hub

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/hub/adopt"
	"watchtower/internal/hub/state"
	"watchtower/internal/policy/policytest"
)

// TestControlConfirmDeleted: with a hub running (it holds the lock and is
// the sidecar's one writer), confirm_deleted goes over the control socket:
// refused before the identity is adopted, then adopted → confirmed.
func TestControlConfirmDeleted(t *testing.T) {
	policytest.Set(t, nil)
	dir := shortDir(t)
	r := newRig(t, dir)
	r.start(r.options())
	r.waitState(StateOff, ReasonDisabled)
	eventually(t, 5*time.Second, "the control socket", func() bool {
		_, err := os.Stat(filepath.Join(dir, SocketName))
		return err == nil
	})
	c, err := Dial(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	if a, err := c.Do(ControlRequest{Op: OpConfirmDeleted}); err != nil || a.OK || a.Error != ErrClassNotAdopted {
		t.Fatalf("before adopted: %+v, %v", a, err)
	}
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	if err := st.SetMeta(adopt.MetaIdentity, adopt.IdentityAdopted); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if a, err := c.Do(ControlRequest{Op: OpConfirmDeleted}); err != nil || !a.OK {
			t.Fatalf("confirm: %+v, %v", a, err)
		}
	}
	if v, _, err := st.Meta(adopt.MetaIdentity); err != nil || v != adopt.IdentityConfirmed {
		t.Fatalf("identity = %q, %v", v, err)
	}
}
