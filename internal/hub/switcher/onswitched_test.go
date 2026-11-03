package switcher_test

import (
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// OnSwitched sees each committed switch with its target, the active
// transport already moved (the runtime drops its queued alert pushes there
// on a switch to CloudKit, before the publisher resumes).
func TestOnSwitchedSeesEachCommittedSwitch(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		var (
			mu  sync.Mutex
			got []string
		)
		w.rebuild(func(c *switcher.Config) {
			c.OnSwitched = func(target transport.Kind) {
				mu.Lock()
				defer mu.Unlock()
				got = append(got, string(target)+":"+string(w.sw.Active().Kind()))
			}
		})
		ph := w.addPhone(true)
		w.moveTo(ph, wire.TransportRelay)
		w.advance(time.Minute)
		w.moveTo(ph, wire.TransportCloudKit)
		mu.Lock()
		defer mu.Unlock()
		if want := []string{"relay:relay", "cloudkit:cloudkit"}; !slices.Equal(got, want) {
			t.Fatalf("OnSwitched %v, want %v", got, want)
		}
	})
}
