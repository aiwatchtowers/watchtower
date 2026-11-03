package hub

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/policy/policytest"
)

// TestControlRecordingsSwitch: the recording switch over the control socket
// (`hub recordings` beside a running supervisor): on is refused until a
// Desktop heartbeat arrived, then the stored value is answered.
func TestControlRecordingsSwitch(t *testing.T) {
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
	if a, err := c.Do(ControlRequest{Op: OpRecordings, On: true}); err != nil || a.OK || a.Error != ErrClassNoTranscriber {
		t.Fatalf("on without a transcriber: %+v, %v", a, err)
	}
	if a, err := c.Do(ControlRequest{Op: OpDesktopHeartbeat}); err != nil || !a.OK {
		t.Fatalf("heartbeat: %+v, %v", a, err)
	}
	for _, on := range []bool{true, false} {
		want := map[bool]string{true: "on", false: "off"}[on]
		if a, err := c.Do(ControlRequest{Op: OpRecordings, On: on}); err != nil || !a.OK || a.Recordings != want {
			t.Fatalf("recordings %s: %+v, %v", want, a, err)
		}
	}
}
