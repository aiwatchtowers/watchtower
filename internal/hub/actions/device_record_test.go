package actions

import (
	"database/sql"
	"testing"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/wire"
)

// Go twins of the Swift hub's device-record tests (RelayProcessor →
// MobileLinkCenter.handleDevice: MobileLinkCenterTests+Permissions,
// +StartSessions and the typing-request tests), on every memfake kind.

// rewrite is the phone's own device record with the toggles given.
func (w *world) rewrite(d wire.DevicePayload) {
	w.t.Helper()
	d.DeviceID = w.phone.ID().String()
	if d.Scope == "" {
		d.Scope = "private"
	}
	if d.Name == "" {
		d.Name = "Test Phone"
	}
	d.UpdatedAt = wire.Time{Time: w.clock()}
	if _, err := w.phone.WriteDeviceRecord(d, ""); err != nil {
		w.t.Fatal(err)
	}
	w.pass()
}

func TestDeviceRecordUnlinkedUnlinks(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		epoch, err := w.keys.CurrentEpoch()
		if err != nil {
			t.Fatal(err)
		}
		unlinked := true
		w.rewrite(wire.DevicePayload{Unlinked: &unlinked})
		if _, linked, err := w.st.Device(w.phone.ID().String()); err != nil || linked {
			t.Fatalf("still linked: %v %v", linked, err)
		}
		if now, err := w.keys.CurrentEpoch(); err != nil || now != epoch+1 {
			t.Fatalf("epoch %d → %d (%v): an unlink rotates", epoch, now, err)
		}
		// Read again (a resync), the record unlinks nothing more.
		if r := w.pass(); r.Applied != 0 {
			t.Fatalf("pass %+v", r)
		}
	})
}

// A request is stored for the owner and is never a grant; it decides
// nothing (decided_at stays), and the phone's start-sessions toggle is only
// its opt-out, never the owner's grant.
func TestDeviceRecordRequestsAreNotGrants(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		on := true
		w.rewrite(wire.DevicePayload{TypingRequested: true, PermissionsRequested: &on, StartSessions: true,
			Name: "Ana's\niPhone", UserRecordName: "_user-a"})
		d := w.device(w.phone)
		if !d.TypingRequested || d.TypingAllowed || !d.PermissionsRequested || d.PermissionsAllowed {
			t.Fatalf("requests became grants: %+v", d)
		}
		if !d.StartSessionsAllowed || d.StartSessionsGranted {
			t.Fatalf("start sessions: %+v", d)
		}
		if d.Name != "Ana's iPhone" {
			t.Fatalf("name %q", d.Name)
		}
		var decided sql.NullFloat64
		var user string
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
			return tx.QueryRow(`SELECT decided_at, user_record_name FROM devices WHERE device_id = ?`,
				w.phone.ID().String()).Scan(&decided, &user)
		}); err != nil {
			t.Fatal(err)
		}
		if decided.Valid {
			t.Fatalf("a request decided at %v", decided.Float64)
		}
		if user != "_user-a" {
			t.Fatalf("user_record_name %q", user)
		}
		grants, err := w.links.Grants()
		if err != nil {
			t.Fatal(err)
		}
		for _, g := range grants {
			if g.DeviceID == w.phone.ID().String() &&
				(g.TypingAllowed || g.PermissionsAllowed != nil || (g.StartSessionsGranted != nil && *g.StartSessionsGranted)) {
				t.Fatalf("grant %+v", g)
			}
		}
	})
}

// The phone's toggle going from on to off revokes that grant; a rewrite for
// another toggle keeps it.
func TestDeviceRecordToggleOffRevokesTheGrant(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		on, off := true, false
		w.rewrite(wire.DevicePayload{TypingRequested: true, PermissionsRequested: &on, StartSessions: true})
		device := w.phone.ID().String()
		for _, g := range []link.Grant{link.GrantTyping, link.GrantPermissions} {
			if err := w.links.Allow(device, g, true); err != nil {
				t.Fatal(err)
			}
		}
		// Another toggle changes: both grants stay.
		w.rewrite(wire.DevicePayload{TypingRequested: true, PermissionsRequested: &on, StartSessions: false})
		if d := w.device(w.phone); !d.TypingAllowed || !d.PermissionsAllowed || d.StartSessionsAllowed {
			t.Fatalf("after the start toggle: %+v", d)
		}
		w.rewrite(wire.DevicePayload{TypingRequested: false, PermissionsRequested: &on})
		if d := w.device(w.phone); d.TypingAllowed || d.TypingRequested || !d.PermissionsAllowed {
			t.Fatalf("after typing off: %+v", d)
		}
		w.rewrite(wire.DevicePayload{PermissionsRequested: &off})
		if d := w.device(w.phone); d.PermissionsAllowed || d.PermissionsRequested {
			t.Fatalf("after permissions off: %+v", d)
		}
	})
}

// A device record carrying a link nonce asks for a link, which only a hello
// makes: it changes nothing.
func TestDeviceRecordWithACodeIsIgnored(t *testing.T) {
	eachKind(t, func(t *testing.T, w *world) {
		nonce := "a-code"
		w.rewrite(wire.DevicePayload{LinkNonce: &nonce, TypingRequested: true, Name: "Renamed"})
		if d := w.device(w.phone); d.TypingRequested || d.Name != "Test Phone" {
			t.Fatalf("device %+v", d)
		}
	})
}
