//go:build interop

package hub

import (
	"testing"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/state"
)

// dumpOrder logs, after a failed ordering test, what each side holds: the
// phone's echoes, controls and outbox; the hub's handler calls, devices'
// order, held actions and queued rows (kinds, attempts and ids only).
func dumpOrder(t *testing.T, h *interopHub, p *hubtest.Phone, m *markCounter) {
	t.Helper()
	for s := uint64(1); s <= 5; s++ {
		e := p.Echoes[s]
		t.Logf("dump: phone echo a%d=%q, hub applied %d times", s, e.Status, m.count(s))
	}
	for _, c := range p.Controls {
		seq := uint64(0)
		if c.Seq != nil {
			seq = *c.Seq
		}
		t.Logf("dump: phone control %s %d", c.Kind, seq)
	}
	t.Logf("dump: phone outbox %v", p.Outbox())
	st, err := state.OpenReadOnly(h.dir)
	if err != nil {
		t.Logf("dump: sidecar: %v", err)
		return
	}
	defer func() { _ = st.Close() }()
	devices, err := st.Devices()
	if err != nil {
		t.Logf("dump: devices: %v", err)
		return
	}
	for _, d := range devices {
		t.Logf("dump: hub device last_applied=%d resend_requested_from=%d", d.LastAppliedActionSeq, d.ResendRequestedFrom)
		held, _ := st.HeldActions(d.ID)
		for _, x := range held {
			t.Logf("dump: hub held a%d", x.ActionSeq)
		}
	}
	rows, err := st.PendingControls(p.Zone())
	if err != nil {
		t.Logf("dump: queue: %v", err)
	}
	for _, r := range rows {
		t.Logf("dump: hub queued %s id=%d expect=%s attempts=%d", r.Kind, r.ID, r.Expect, r.Attempts)
	}
}
