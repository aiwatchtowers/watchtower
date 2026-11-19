package switcher_test

import (
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// OnSwitched sees each committed switch with its target, the active
// transport already moved and the publisher still held (the runtime drops
// its queued alert pushes there on a switch to CloudKit and asks for their
// signals before the publisher resumes).
func TestOnSwitchedSeesEachCommittedSwitch(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		var (
			mu  sync.Mutex
			got []string
		)
		w.rebuild(func(c *switcher.Config) {
			c.OnSwitched = func(target transport.Kind) {
				// A held publisher's cycle reads and writes nothing.
				rep, err := w.pub.Cycle(w.ctx, nil)
				held := err == nil && rep.Aborted
				mu.Lock()
				defer mu.Unlock()
				got = append(got, fmt.Sprintf("%s:%s:held=%v", target, w.sw.Active().Kind(), held))
			}
		})
		ph := w.addPhone(true)
		w.moveTo(ph, wire.TransportRelay)
		w.advance(time.Minute)
		w.moveTo(ph, wire.TransportCloudKit)
		mu.Lock()
		defer mu.Unlock()
		if want := []string{"relay:relay:held=true", "cloudkit:cloudkit:held=true"}; !slices.Equal(got, want) {
			t.Fatalf("OnSwitched %v, want %v", got, want)
		}
	})
}
