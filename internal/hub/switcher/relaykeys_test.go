package switcher_test

import (
	"testing"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// relay_serving_nobody_since never outlives the relay: an answered account
// read between a switch's rotation toward iCloud (which removes the mark) and
// its announce writes it back, and the announce, which moves the hub, removes
// it again in its own transaction.
func TestSwitchToICloudRemovesServingNobodyAtTheAnnounce(t *testing.T) {
	w := newWorld(t, "memfake")
	ph := w.addPhone(true)
	if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), ph.ID().String(), transport.KindRelay, ""); err != nil {
		t.Fatal(err)
	}
	if err := w.sw.Step(w.ctx); err != nil {
		t.Fatal(err)
	}
	if w.sw.Active().Kind() != transport.KindRelay {
		t.Fatal("the hub did not move to the relay")
	}
	w.advance(time.Hour)
	w.rebuild(func(c *switcher.Config) {
		keyboxes := c.KeyboxesAll
		c.KeyboxesAll = func() ([]wire.Keybox, error) {
			// An answered read on the relay inside the step 3→4 window.
			if err := w.st.SetMeta(state.MetaServingNobodySince, "1800000000"); err != nil {
				t.Fatal(err)
			}
			return keyboxes()
		}
	})
	if err := w.sw.Request(w.ctx, transport.KindRelay, ph.ID().String(), transport.KindCloudKit, ""); err != nil {
		t.Fatal(err)
	}
	if err := w.sw.Step(w.ctx); err != nil {
		t.Fatal(err)
	}
	if w.sw.Active().Kind() != transport.KindCloudKit {
		t.Fatal("the hub did not move to iCloud")
	}
	if _, ok, _ := w.st.Meta(state.MetaServingNobodySince); ok {
		t.Fatal("relay_serving_nobody_since outlived the relay")
	}
}

// An unlink between a switch's rotation (step 3) and its announce (step 4):
// its epoch takes the switch target's on_relay (the current epoch's), not the
// old hub_meta.transport, so an iCloud epoch is never erased as a relay one
// (ask #1066) and a relay epoch is.
func TestUnlinkInsideASwitchTakesTheTargetsOnRelay(t *testing.T) {
	for _, target := range []transport.Kind{transport.KindCloudKit, transport.KindRelay} {
		t.Run(string(target), func(t *testing.T) {
			w := newWorld(t, "memfake")
			ph := w.addPhone(true)
			gone := w.addPhone(true)
			if target == transport.KindCloudKit {
				if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), ph.ID().String(), transport.KindRelay, ""); err != nil {
					t.Fatal(err)
				}
				if err := w.sw.Step(w.ctx); err != nil {
					t.Fatal(err)
				}
				w.advance(time.Hour)
			}
			from := w.sw.Active().Kind()
			// The announce fails: the record keeps its epoch, not done.
			w.rebuild(func(c *switcher.Config) {
				c.KeyboxesAll = func() ([]wire.Keybox, error) { return nil, errBoom }
			})
			if err := w.sw.Request(w.ctx, from, ph.ID().String(), target, ""); err != nil {
				t.Fatal(err)
			}
			_ = w.sw.Step(w.ctx)
			if v, _, _ := w.st.Meta(state.MetaTransport); v != string(from) {
				t.Fatalf("transport %q: the announce was not held back", v)
			}
			switchEpoch := w.epoch()
			if err := w.center.Unlink(gone.ID().String()); err != nil {
				t.Fatal(err)
			}
			if w.epoch() != switchEpoch+1 {
				t.Fatalf("epoch %d after the unlink, want %d", w.epoch(), switchEpoch+1)
			}
			epochs, err := w.st.Epochs()
			if err != nil {
				t.Fatal(err)
			}
			on := epochs[len(epochs)-1].OnRelay
			if on == nil || *on != (target == transport.KindRelay) {
				t.Fatalf("the unlink's epoch on_relay %v (nil: unset), want the target %s's", on != nil && *on, target)
			}
		})
	}
}

var errBoom = errorString("boom")

type errorString string

func (e errorString) Error() string { return string(e) }
